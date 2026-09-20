#!/usr/bin/env python3
"""Вход в парольную группу: ведёт `openconnect --authenticate` в
псевдотерминале. Логин и пароль подставляет сам, на остальные вопросы шлюза
(код из SMS) отвечает человек — окном ocbar-auth или в терминале.

Аргументы: команда openconnect. Печатает «token hash post_url».
Окружение: OCBAR_PASSWORD, OCBAR_USERNAME, OCBAR_PROMPT_TTY, OCBAR_PROMPT_CMD.
"""
import os, pty, re, select, signal, subprocess, sys, time
argv = sys.argv[1:]
env = os.environ
pw, user = env.get("OCBAR_PASSWORD", ""), env.get("OCBAR_USERNAME", "")
tty = env.get("OCBAR_PROMPT_TTY") == "1"
def log(m): sys.stderr.write("ocbar: " + m + "\n"); sys.stderr.flush()
def ask(label, secret=False):
    if tty:
        import getpass
        with open("/dev/tty", "r+") as t:
            if secret: return getpass.getpass(label + " ", stream=t), 0
            t.write(label + " "); t.flush(); return t.readline().strip(), 0
    r = subprocess.run(env["OCBAR_PROMPT_CMD"], shell=True, stdout=subprocess.PIPE,
                       env=dict(env, OCBAR_PROMPT_LABEL=label, OCBAR_PROMPT_SECRET="1" if secret else ""))
    if r.returncode != 0: return None, r.returncode
    out = r.stdout.decode()
    return (out[:-1] if out.endswith("\n") else out) if secret else out.strip(), 0
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
buf, out, sent_pw, humans, rc_human, secrets = b"", b"", False, 0, 0, set()
deadline = time.time() + float(env.get("OCBAR_PW_TIMEOUT", "600"))
def stop(code):
    try: os.kill(pid, signal.SIGTERM)
    except OSError: pass
    sys.exit(code)
while True:
    if time.time() > deadline: log("вход не завершился вовремя"); stop(2)
    r, _, _ = select.select([fd], [], [], 0.4)
    if r:
        try: data = os.read(fd, 4096)
        except OSError: break
        if not data: break
        out += data; buf += data; continue
    tail = buf.decode("utf-8", "replace").replace("\r", "").rsplit("\n", 1)[-1].strip()
    if not tail.endswith(":") and not tail.endswith("?"): continue
    buf = b""
    low = tail.lower()
    if "accept" in low and "yes" in low:
        log("сертификат шлюза не доверенный — отказываюсь (" + tail + ")"); os.write(fd, b"no\n"); stop(1)
    if low.startswith("group"):
        log("шлюз просит выбрать группу — укажите её в адресе профиля: " + tail); stop(1)
    if ("password" in low or "парол" in low) and not sent_pw:
        sent_pw = True
        if not pw:
            # Пароля нет в связке — спросить человека (окно со звёздочками).
            log("пароля нет в источнике профиля — спрашиваю человека")
            pw, rc = ask(tail, secret=True)
            if not pw: log("пароль не введён"); stop(rc if rc in (2, 3) else 3)
        secrets.add(pw); os.write(fd, (pw + "\n").encode()); log("пароль подставлен"); continue
    if "user" in low or "логин" in low or "имя" in low:
        os.write(fd, (user + "\n").encode()); continue
    humans += 1
    if humans > 3: log("шлюз спрашивает код в четвёртый раз — останавливаюсь"); stop(1)
    log("шлюз спрашивает: " + tail + " — вводит человек")
    code, rc = ask(tail)
    if not code:
        log("код не введён"); stop(rc if rc in (2, 3) else 3)
    secrets.add(code); os.write(fd, (code + "\n").encode())
_, status = os.waitpid(pid, 0)
text = out.decode("utf-8", "replace").replace("\r", "")
vals = dict(re.findall(r"^([A-Z_]+)='([^']*)'", text, re.M))
if os.waitstatus_to_exitcode(status) != 0 or not vals.get("COOKIE"):
    shown = [l for l in text.split("\n") if l.strip() and not any(x and x in l for x in secrets)
             and not l.startswith(("COOKIE=", "POST ", "Got ", "XML "))]
    log("вход не прошёл: " + " | ".join(shown[-4:]))
    sys.exit(1)
url = vals.get("CONNECT_URL") or ("https://" + vals.get("HOST", ""))
print(vals["COOKIE"], vals.get("FINGERPRINT", ""), url)
