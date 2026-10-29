#!/usr/bin/env python3
"""Capture active production windows with isolated demo profiles, then write an HTML gallery.

Build with app/make-app.sh first. Output defaults to .local/active-design-review.
No connection or settings actions are performed; profile files are synthetic.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import html
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def valid_capture(report, passive):
    if passive:
        return (report.get('capture') == 'screencapture-passive-window'
                and report.get('appearanceMode') == 'inactive'
                and all(report.get(k) is True for k in ('focusPreserved', 'builtInDisplay'))
                and all(report.get(k) is False for k in ('active', 'keyWindow', 'mainWindow')))
    return (report.get('capture') == 'screencapture-window'
            and all(report.get(k) is True for k in ('active', 'keyWindow', 'mainWindow')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--resume', action='store_true', help='Reuse verified captures from the same binary and case')
    parser.add_argument('--capture-active', action='store_true', help='Explicitly allow real windows to take focus during capture')
    parser.add_argument('--capture-passive', action='store_true', help='Built-in display only; no input/focus; inactive native controls')
    parser.add_argument('--offscreen', action='store_true', help='Layout-only cache renders; not valid for color review')
    parser.add_argument('--only', action='append', default=[], help='Render IDs containing this text (repeatable)')
    args = parser.parse_args()
    if sum((args.capture_active, args.capture_passive, args.offscreen)) != 1:
        parser.error('Choose --capture-passive (built-in display, no focus), --capture-active (takes focus), or --offscreen (layout only)')
    if not args.offscreen and args.jobs != 1:
        parser.error("Active windows must be captured sequentially (--jobs 1)")
    out = (args.output or ROOT / ('.local/passive-design-review' if args.capture_passive else '.local/active-design-review')).resolve()
    out.mkdir(parents=True, exist_ok=True)
    app = ROOT / 'app/.build/ocmac.app/Contents/MacOS/ocmac-app'
    binary_hash = hashlib.sha256(app.read_bytes()).hexdigest()
    cases = []

    def add(name, lang, screen, width, height, extra=(), config=None, theme=None):
        cases.append(dict(id=f'{name}-{lang}', language=lang, screen=screen,
                          width=width, height=height, extra=list(extra),
                          config=str(config) if config else None,
                          theme=theme or ('light' if lang == 'en' else 'dark')))

    for lang in ('ru', 'en'):
        title = ('Корпоративный VPN — производственная сеть европейского филиала — резервное подключение'
                 if lang == 'ru' else 'Corporate VPN — European production network — backup connection')
        address = 'https://vpn-europe-production-gateway.example.com/employees/engineering/backup'
        error = out / f'error-{lang}.txt'
        error.write_text(('Не удалось подключиться к серверу. Проверьте подключение к интернету. '
                          'Проверка сертификата завершилась ошибкой. Подробности доступны в журнале. '
                          if lang == 'ru' else 'Could not connect to the server. Check your internet connection. '
                          'Certificate verification failed. See the log for details. ') * 4)
        for state in ('down', 'connected', 'paused', 'starting', 'needsLogin', 'lost',
                      'missing', 'foreign', 'proxy', 'proxy-lost', 'proxy-off', 'proxy-refused'):
            add(f'connection-{state}', lang, 'connection', 380, 240, ['--state', state])
        for count in (0, 1, 30):
            add(f'connection-count-{count}', lang, 'connection', 440, 240,
                ['--profile-count', str(count)])
        for width in (380, 1100):
            add(f'connection-long-{width}', lang, 'connection', width, 300,
                ['--profile-title', title, '--profile-url', address, '--state', 'needsLogin'])
            add(f'connection-error-{width}', lang, 'connection', width, 300,
                ['--error-file', str(error)])
        add('connection-disconnecting', lang, 'connection', 440, 240,
            ['--state', 'connected', '--disconnecting'])
        add('connection-long-active', lang, 'connection', 440, 240,
            ['--profile-title', title, '--profile-url', address, '--state', 'connected'])
        for tab in range(4):
            for width in (580, 1100):
                add(f'settings-tab-{tab}-{width}', lang, 'settings', width, 640,
                    ['--tab', str(tab)])
        for tab in (2, 3):
            add(f'settings-tab-{tab}-bottom', lang, 'settings', 580, 640,
                ['--tab', str(tab), '--capture-scroll-bottom'])
        for segment in range(3):
            add(f'advanced-{segment}', lang, 'settings', 620, 700,
                ['--segment', str(segment)])
            add(f'advanced-bottom-{segment}', lang, 'settings', 620, 700,
                ['--segment', str(segment), '--capture-scroll-bottom'])
            add(f'advanced-reveal-{segment}', lang, 'settings', 620, 640,
                ['--segment', str(segment), '--reveal-advanced'])
        for kind in ('empty', 'long', 'invalid', 'many', 'many-errors', 'password', 'proxy'):
            config = out / f'profiles-{kind}-{lang}'
            (config / 'profiles').mkdir(parents=True, exist_ok=True)
            if kind != 'empty':
                for index in range(30 if kind == 'many' else 1):
                    name = title if kind == 'long' else f'VPN {index + 1}'
                    url = address if kind == 'long' else ('not a URL' if kind == 'invalid' else 'https://vpn.example.com')
                    body = f'[Connection]\nName = {name}\nUrl = {url}\nUser = engineer.long.name@example.com\n'
                    if kind == 'password':
                        body += 'Auth = password\n[Auth]\nPassword = ask\n'
                    if kind == 'proxy':
                        body += 'Mode = proxy\n[Proxy]\nPort = 11080\nSystemProxy = off\n'
                    if kind == 'invalid':
                        body += '[Routes]\ninvalid-network\n[DNS]\nexample.com = invalid-address\n'
                    if kind == 'many-errors':
                        body += '[Routes]\n' + '\n'.join(f'invalid-network-{n}' for n in range(20)) + '\n'
                    (config / 'profiles' / f'p{index:02}.ocmac').write_text(body)
            add(f'profiles-{kind}', lang, 'settings', 580, 640, config=config)
        # Same language in both themes, avoiding a language/theme confound.
        add('connection-other-theme', lang, 'connection', 440, 240,
            ['--state', 'paused'], theme='dark' if lang == 'en' else 'light')
        add('settings-other-theme', lang, 'settings', 620, 640,
            theme='dark' if lang == 'en' else 'light')

    for lang in ('ru', 'en'):
        for step in range(3):
            add(f'setup-{step}', lang, 'setup', 740, 560, ['--step', str(step)])
        add('settings-system-wide', lang, 'settings', 1100, 820, theme='system')

    def render(case):
        signature = hashlib.sha256(json.dumps([case, args.capture_passive], sort_keys=True).encode()).hexdigest()
        png = out / (case['id'] + '.png')
        metadata = png.with_suffix('.json')
        if args.resume and not args.offscreen and png.is_file() and metadata.is_file():
            previous = json.loads(metadata.read_text())
            if (previous.get('binarySHA256') == binary_hash and previous.get('caseSignature') == signature
                    and valid_capture(previous, args.capture_passive)):
                print('reuse ' + case['id'], flush=True)
                return
        command = [str(app), '--stage', '--screenshot', case['screen'],
                   '--window-width', str(case['width']), '--window-height', str(case['height']),
                   '--shot', str(out / (case['id'] + '.png')),
                   '-AppleLanguages', '(' + case['language'] + ')',
                   '-InterfaceLanguage', case['language'], *case['extra']]
        if case['theme'] != 'system':
            command.append('--' + case['theme'])
        if not args.offscreen:
            command.append('--capture-passive' if args.capture_passive else '--capture-active')
        png = out / (case['id'] + '.png')
        metadata = png.with_suffix('.json')
        png.unlink(missing_ok=True)
        metadata.unlink(missing_ok=True)
        env = os.environ.copy()
        env.pop('OCMAC_CONFIG_DIR', None)
        if case['config']:
            env['OCMAC_CONFIG_DIR'] = case['config']
        attempts = []
        succeeded = False
        for attempt in range(1 if args.offscreen else 3):
            png.unlink(missing_ok=True)
            metadata.unlink(missing_ok=True)
            launch = command
            app_out = out / (case['id'] + '.stdout')
            app_err = out / (case['id'] + '.stderr')
            if not args.offscreen:
                # LaunchServices grants foreground activation; direct executable
                # launches may stay behind the app that initiated the command.
                app_out.write_text('')
                app_err.write_text('')
                launch = ['/usr/bin/open', '-n', '-W', '--stdout', str(app_out),
                          '--stderr', str(app_err)]
                if args.capture_passive:
                    launch.append('-g')
                if case['config']:
                    launch += ['--env', 'OCMAC_CONFIG_DIR=' + case['config']]
                launch += [str(app.parents[2]), '--args', *command[1:]]
            ready = png.with_suffix('.ready.json')
            done = png.with_suffix('.capture-done')
            ready.unlink(missing_ok=True)
            done.unlink(missing_ok=True)
            if args.offscreen:
                result = subprocess.run(launch, env=env, capture_output=True, text=True, timeout=45)
                output = result.stdout + result.stderr
                returncode = result.returncode
            else:
                process = subprocess.Popen(launch, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                deadline = time.monotonic() + 25
                while not ready.is_file() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.1)
                capture_log = ''
                if ready.is_file():
                    handoff = json.loads(ready.read_text())
                    shot = subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l',
                                           str(handoff['windowID']), str(png)],
                                          capture_output=True, text=True, timeout=10)
                    capture_log = shot.stdout + shot.stderr
                    done.write_text('ok' if shot.returncode == 0 else 'failed')
                stdout, stderr = process.communicate(timeout=25)
                returncode = process.returncode
                output = stdout + stderr + capture_log + app_out.read_text() + app_err.read_text()
                ready.unlink(missing_ok=True)
                done.unlink(missing_ok=True)
            attempts.append(f'Attempt {attempt + 1}\n' + output)
            succeeded = returncode == 0 and png.is_file()
            if not args.offscreen:
                report = json.loads(metadata.read_text()) if metadata.is_file() else {}
                succeeded = succeeded and valid_capture(report, args.capture_passive)
            if succeeded:
                break
            time.sleep(0.5)
        (out / (case['id'] + '.log')).write_text('\n'.join(attempts))
        if not succeeded:
            raise RuntimeError(f"Screenshot failed: {case['id']}; see its log")
        if not args.offscreen:
            report['binarySHA256'] = binary_hash
            report['caseSignature'] = signature
            metadata.write_text(json.dumps(report, indent=2))
        print(case['id'], flush=True)

    selected = [c for c in cases if not args.only or any(key in c['id'] for key in args.only)]
    failures = []
    if args.offscreen:
        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            list(pool.map(render, selected))
    else:
        for case in selected:
            try:
                render(case)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                failures.append(str(error))
                print(str(error), flush=True)
    cases = [c for c in cases if (out / (c['id'] + '.png')).is_file()
             and (args.offscreen or (out / (c['id'] + '.json')).is_file())]
    for case in cases:
        if not args.offscreen:
            case['capture'] = json.loads((out / (case['id'] + '.json')).read_text())
    if not args.offscreen:
        cases = [c for c in cases if valid_capture(c['capture'], args.capture_passive)]
    label = ('OFFSCREEN — layout only, inaccurate colors' if args.offscreen else
             'PASSIVE — built-in display, no focus; inactive controls and title bar, not valid for active colors' if args.capture_passive else
             'Active production windows — screen capture')
    (out / 'cases.json').write_text(json.dumps(cases, ensure_ascii=False, indent=2))
    cards = ''.join(f'<article><h2>{html.escape(c["id"])}</h2>'
                    f'<p>{c.get("capture", {}).get("contentWidth", c["width"])} × {c.get("capture", {}).get("contentHeight", c["height"])} pt · {c["theme"]}</p>'
                    f'<a href="{c["id"]}.png"><img loading="lazy" src="{c["id"]}.png"></a></article>'
                    for c in cases)
    (out / 'index.html').write_text('<!doctype html><meta charset="utf-8">'
        '<title>OpenConnect — design review</title><style>'
        'body{font:15px system-ui;background:#eee;margin:24px;color:#222}'
        'main{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:24px}'
        'article{background:white;padding:16px;border-radius:12px}h2{font-size:16px}'
        'img{width:100%;height:auto}p{color:#555}</style>'
        f'<h1>OpenConnect — {len(cases)} native UI cases</h1>'
        f'<p>{label}. Synthetic profiles and connection states. Click an image for full resolution.</p>'
        f'<main>{cards}</main>')
    print(f'{len(cases)} screenshots: {out / "index.html"}')
    if failures:
        raise SystemExit('Incomplete review; rerun with --resume.\n' + '\n'.join(failures))


if __name__ == '__main__':
    main()
