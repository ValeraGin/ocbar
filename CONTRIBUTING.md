# Contributing

Thanks for looking. This is a single-author tool that someone uses daily; it
is kept small on purpose. Small, well-tested changes are welcome.

## Before you start

- Open an issue first for anything bigger than a fix. It may already be a
  deliberate "no" (see below).
- Русский тоже подходит — и в обсуждениях, и в коде: комментарии и журналы
  на русском, интерфейс — на двух языках (см. «UI text» ниже).

## Build and test

```bash
swift build -c release --package-path auth     # login window (ocmac-auth)
app/make-app.sh                                # menu bar app bundle
bin/ocmac selftest                             # CLI: parsing, limits, cleanup
tools/helper-selftest.sh                       # privileged helper, dry-run with stubs
auth/.build/release/ocmac-auth --selftest      # TOTP, fill scope, autofill limits
auth/.build/release/ocmac-auth --learn-selftest
app/.build/ocmac.app/Contents/MacOS/ocmac-app --selftest
python3 tools/gateway-matrix-test.py           # local TLS gateways + real WebKit
python3 tools/upstream-proxy-test.py            # HTTP CONNECT/SOCKS5 login + no direct fallback
python3 tools/hostscan-sequence-test.py        # external CSD wrapper handshake
python3 tools/macos-vpn-test-selftest.py       # live-runner setup, no network/privileges
```

[Server compatibility lab](tools/server-lab/README.md) also runs the real
OpenConnect password driver against two ocserv releases in disposable Docker
containers: passwords, groups, TOTP, client certificates, and a separate client
container with routed HTTP and VPN DNS. The gateway fixtures bind only to localhost; neither suite changes
the host VPN or routes. Local TLS tests need networking and WebKit outside the
brew sandbox. Real ocserv tests run in a separate Linux CI job.

`tools/macos-vpn-test.py --live` is a separate manual check of real profiles,
the installed helper and macOS split DNS. It temporarily changes host routes;
read the lab instructions first. Its `--mode proxy` variant checks SOCKS access
without changing host routes. External account credentials never belong in CI.
`tools/macos-ocserv-test.py --live` instead exercises the installed macOS helper
against disposable local ocserv servers with synthetic credentials, including
TLS 1.3/LZS, large HTTP/HTTPS responses, split DNS and reconnect. It changes one
host route and one resolver temporarily and is also a manual opt-in test.
`tools/macos-path-test.py --live --ssh-via HOST` compares an external gateway
directly and through an authorized SSH host with the same native helper, plus a
local-forward control. It restores the temporary routes, DNS and TCP listeners.

The CLI and `ocmac-auth` self-tests also run inside the sandbox `brew test`
uses (`tools/brew-sandbox.sb`: no screen, camera or system services, writes
only to temporary directories), so a check that quietly relies on this
machine's permissions fails before release, not after:

```bash
TMPDIR=$(mktemp -d /private/tmp/ocmac-brewsb.XXXXXX) sandbox-exec -f tools/brew-sandbox.sb bin/ocmac selftest
```

All of these run in CI on every push and must stay green. Unit self-tests use
no network, privileges or VPN: configs are synthetic, state and logs go to a
temporary directory, the helper is replaced by a stub. Integration suites use
local TLS and disposable servers with synthetic accounts, never personal VPNs.

What a person would do is replaced by stand-ins, so the checks run
unattended: `OCMAC_SELFTEST_SECURITY` (the keychain — a script that records
what reached it), `OCMAC_SELFTEST_SCREENCAPTURE` (drawing a frame around a QR
code on screen — a ready-made image), `OCMAC_SELFTEST_CAMERA_FRAMES` (the
camera — PNG frames, no window), `OCMAC_SELFTEST_SCREEN_ACCESS` (the Screen
Recording permission). `ocmac-auth --qr-png FILE` turns a string into the QR
image these checks show. A new step that waits for a human needs its own
stand-in, not a line in "not verified".

**Every behaviour change needs a check that fails without it.** The self-tests
are the specification; a regression that no check catches is how this project
breaks. Prove it: temporarily revert your fix and show the check failing.

## The parts and their contracts

| Part | What it is | Contract not to break silently |
|---|---|---|
| `bin/ocmac` | CLI, bash, runs as the user | `ocmac status --json` is the machine-readable state the app reads; `--short` is `key=value` lines for scripts and SwiftBar; exit codes: 5 — a human must log in, 6 — network/gateway, other non-zero — failure |
| `libexec/ocmac-*.py`, `ocmac-selftest.sh` | helpers the CLI runs: state as JSON, merged logs, report redaction, password-group login, the CLI self-test | found next to `ocmac` or in the Homebrew `libexec`; they are code, not strings inside the shell script |
| `libexec/ocmac-helper` | everything that needs root | fixed subcommands, every argument validated, state only under `/var/db/ocmac`, touches only what it created and records it before making the change; changing subcommands run one at a time (`/var/db/ocmac/lock`); any change bumps its `VERSION` (`tools/helper-version-check.sh`, run by `release.sh`), or an outdated installed copy looks current |
| `auth/` | `ocmac-auth`: login window, autofill, TOTP | fills only over HTTPS on hosts of the login chain; password twice, code once per login |
| `app/` | SwiftUI menu bar app, no privileges | reads `status --json`, acts by calling `ocmac`; profile parsing must match the CLI (checked in `ocmac-app --selftest`) |

Profile format: one `.ocmac` file per connection, sections `[Connection]`,
`[Routes]`, `[DNS]`, `[Auth]`, `[Proxy]`, `[Health]`, `[Autofill]`. Adding a
key means: CLI parser, app parser, validation in both, example file, docs.

UI text: every string the person sees goes through `L("…")` with the Russian
text as the key, and `app/Resources/en.lproj/Localizable.strings` holds the
English. `tools/i18n-scan.py --check` lists what is missing and fails the
build, so a new screen cannot ship half-translated. It treats every Cyrillic
string literal in the app outside `L("…")` as a mistake, except log lines
(`AppLog.write`, `print`), comparisons with the client's output
(`contains`, `hasPrefix`…) and lines marked `// i18n: не интерфейс`. The
app's `--selftest` always runs in Russian: its checks compare Russian text.
The sign-in windows (`auth/`) use the same `L("…")`; `ocmac-auth` has no bundle, so its English lives in
`auth/Sources/ocmac-auth/Translations.swift`, checked by the same scan. Log
lines and messages the CLI parses stay in Russian.

The CLI translates at output time: `ok`/`warn`/`bad`/`skip`/`info`/`die` and
notifications look the finished message up in `libexec/ocmac-en.tsv`
(Russian template, tab, English; `{}` stands for `$var`, `${…}` or `$(…)`,
`{1}`, `{2}`… when the order changes). Write messages as before; the scan
lists new ones without a translation. Do not build a message in a variable
and pass it on — the scan cannot see its text, and fails on a message passed
as a bare `"$var"`. Anything the app or a script parses
must not depend on the language: use exit codes or `--json`. Strings that are compared
against output of the CLI, or written into files, are not UI text and stay
unwrapped.

Visual review: build the app, then run `python3 tools/design-review.py --capture-active`.
It opens the production SwiftUI window scenes with synthetic data and captures
them through macOS `screencapture`. Windows take focus one at a time; do not
switch apps during the run. Screen Recording access must be available. Each PNG
has a JSON sidecar proving that its window was active, key and main, and recording
its actual size and appearance. Tall forms are reviewed by scrolling within the
screen, not by rendering an oversized invisible window. Use `--only <case>` to
repeat a case; the gallery is saved in `.local/active-design-review/`.
Active capture interrupts normal work: agree on a capture window before running
it. The runner requires an explicit capture mode and otherwise exits without
opening windows. While the user works, review saved frames and run checks that
do not activate UI; do not run menu benchmarks or active captures.
For an explicitly requested visible preview on the Mac's own screen, use
`--capture-passive`. It launches with `open -g` and uses a nonactivating NSPanel
that cannot become key/main and ignores mouse input. It uses the same SwiftUI
views, but native controls and title bar remain inactive. A SwiftUI
`appearsActive` override did not reproduce native active colors in the live check;
do not label these frames as active or use them to approve active colors.
It requires a connected, non-mirrored built-in display and never falls back to
the external monitor. Metadata records the display and verifies that the app
never activated. The separate gallery is `.local/passive-design-review/`.
`python3 tools/design-review-test.py` checks capture acceptance and the explicit
mode requirement without launching UI. macOS has one key/input window across
the user's desktop; see [Apple's window states](https://developer.apple.com/design/human-interface-guidelines/windows).
If another app takes focus, the case is rejected and retried. Use `--resume` to
continue an interrupted matrix: only verified captures from the same app binary
and case definition are reused. Activation is done through LaunchServices, while
the runner (with Screen Recording access) captures the window ID handed out by
the app; the app checks focus both before and after the capture.
`--offscreen` retains the old layout-only renderer: its inactive controls and
artificial background are **not evidence of the app's colors or materials**.

Menu latency: launch the app with `--stage --menu-benchmark` to open/cancel the
real status menu eight times without executing an item. `--live` uses a read-only
snapshot of the current client status; otherwise the data is synthetic. JSON
reports the delay from the programmatic click to tracking and to the menu window
appearing in WindowServer (not completion of its animation). `--cold` disables
startup preparation for comparison in the same build. Run via `open -n -W` with
`--stdout` and `--stderr` paths, separately from other UI tests. The probe does not
poll while the menu is open, so it is not a test of every intermittent live stall.
`--selftest-menu` runs the native menu/update regression checks on their own.

Runtime state lives in small files under `~/Library/Application Support/ocmac`,
one value each: `desired` (profile that should be up), `autoconnect`,
`access`, `connecting`, `needs-login`, `link-lost`, `routes.disabled`,
`zones.disabled`, `skip-networks`. They are declared as constants at the top
of `bin/ocmac` — a new one belongs there, and `ocmac selftest` fails when a
path appears inline instead. They are written whole (`state_write`: temp file,
then rename), so a reader never sees a half-written file, and no locking is
needed because each value is independent. `ocmac state [--json]` prints the
whole picture at once.

The CLI has the final word on whether a profile is valid: the editor asks
`ocmac profile-check` before saving and refuses with the client's own words.
The editor may be stricter than the client — its checks are hints while you
type — but never more permissive. `ocmac-app --selftest` compares both
verdicts on a set of profiles and fails when the editor would save something
the client will not load.

## Style

- Comments and commit messages explain **why**, not what. Russian is fine.
- `bash -n` and `shellcheck -S error` must pass; the code targets bash 3.2
  (the macOS system bash), so no `declare -A`, no `${var^^}`.
- Keep a change and its check in one commit where practical.

## Deliberate "no"

These were considered and rejected; please do not send PRs for them without
discussing first: a kill switch, IPv6 routes inside the tunnel, binding
autofill rules to page URLs, fallback selectors, logging in through an
external browser, iframe/shadow DOM traversal, HOTP, bottles or a cask
(there is no Developer ID), telemetry of any kind.

## Reporting a problem

Use the issue templates. `ocmac report` produces a single file with versions,
diagnostics and log tails with hosts, addresses and logins masked — attach it,
but read it first: masking does not know your internal names.

Security issues: see [SECURITY.md](SECURITY.md), not a public issue.
