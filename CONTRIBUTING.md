# Contributing

Thanks for looking. This is a single-author tool that someone uses daily; it
is kept small on purpose. Small, well-tested changes are welcome.

## Before you start

- Open an issue first for anything bigger than a fix. It may already be a
  deliberate "no" (see below).
- Русский тоже подходит — и в обсуждениях, и в коде: интерфейс и комментарии
  сейчас на русском.

## Build and test

```bash
swift build -c release --package-path auth     # login window (ocbar-auth)
app/make-app.sh                                # menu bar app bundle
bin/ocbar selftest                             # CLI: parsing, limits, cleanup
tools/helper-selftest.sh                       # privileged helper, dry-run with stubs
auth/.build/release/ocbar-auth --selftest      # TOTP, fill scope, autofill limits
auth/.build/release/ocbar-auth --learn-selftest
app/.build/ocbar.app/Contents/MacOS/ocbar-app --selftest
```

The CLI and `ocbar-auth` self-tests also run inside the sandbox `brew test`
uses (`tools/brew-sandbox.sb`: no screen, camera or system services, writes
only to temporary directories), so a check that quietly relies on this
machine's permissions fails before release, not after:

```bash
TMPDIR=$(mktemp -d /private/tmp/ocbar-brewsb.XXXXXX) sandbox-exec -f tools/brew-sandbox.sb bin/ocbar selftest
```

All of these run in CI on every push and must stay green. No network, no
privileges, no VPN: configs are synthetic, state and logs go to a temporary
directory, the helper is replaced by a stub.

What a person would do is replaced by stand-ins, so the checks run
unattended: `OCBAR_SELFTEST_SECURITY` (the keychain — a script that records
what reached it), `OCBAR_SELFTEST_SCREENCAPTURE` (drawing a frame around a QR
code on screen — a ready-made image), `OCBAR_SELFTEST_CAMERA_FRAMES` (the
camera — PNG frames, no window), `OCBAR_SELFTEST_SCREEN_ACCESS` (the Screen
Recording permission). `ocbar-auth --qr-png FILE` turns a string into the QR
image these checks show. A new step that waits for a human needs its own
stand-in, not a line in "not verified".

**Every behaviour change needs a check that fails without it.** The self-tests
are the specification; a regression that no check catches is how this project
breaks. Prove it: temporarily revert your fix and show the check failing.

## The parts and their contracts

| Part | What it is | Contract not to break silently |
|---|---|---|
| `bin/ocbar` | CLI, bash, runs as the user | `ocbar status --json` is the machine-readable state the app reads; `--short` is `key=value` lines for scripts and SwiftBar; exit codes: 5 — a human must log in, 6 — network/gateway, other non-zero — failure |
| `libexec/ocbar-*.py`, `ocbar-selftest.sh` | helpers the CLI runs: state as JSON, merged logs, report redaction, password-group login, the CLI self-test | found next to `ocbar` or in the Homebrew `libexec`; they are code, not strings inside the shell script |
| `libexec/ocbar-helper` | everything that needs root | fixed subcommands, every argument validated, state only under `/var/db/ocbar`, touches only what it created; any change bumps its `VERSION` (`tools/helper-version-check.sh`, run by `release.sh`), or an outdated installed copy looks current |
| `auth/` | `ocbar-auth`: login window, autofill, TOTP | fills only over HTTPS on hosts of the login chain; password twice, code once per login |
| `app/` | SwiftUI menu bar app, no privileges | reads `status --json`, acts by calling `ocbar`; profile parsing must match the CLI (checked in `ocbar-app --selftest`) |

Profile format: one `.ocbar` file per connection, sections `[Connection]`,
`[Routes]`, `[DNS]`, `[Auth]`, `[Proxy]`, `[Health]`, `[Autofill]`. Adding a
key means: CLI parser, app parser, validation in both, example file, docs.

UI text: every string the person sees goes through `L("…")` with the Russian
text as the key, and `app/Resources/en.lproj/Localizable.strings` holds the
English. `tools/i18n-scan.py --check` lists what is missing and fails the
build, so a new screen cannot ship half-translated. The sign-in windows (`auth/`) use
the same `L("…")`; `ocbar-auth` has no bundle, so its English lives in
`auth/Sources/ocbar-auth/Translations.swift`, checked by the same scan. Log
lines and messages the CLI parses stay in Russian.

The CLI translates at output time: `ok`/`warn`/`bad`/`skip`/`info`/`die` and
notifications look the finished message up in `libexec/ocbar-en.tsv`
(Russian template, tab, English; `{}` stands for `$var`, `${…}` or `$(…)`,
`{1}`, `{2}`… when the order changes). Write messages as before; the scan
lists new ones without a translation. Do not build a message in a variable
and pass it on — the scan cannot see it. Anything the app or a script parses
must not depend on the language: use exit codes or `--json`. Strings that are compared
against output of the CLI, or written into files, are not UI text and stay
unwrapped.

Runtime state lives in small files under `~/Library/Application Support/ocbar`,
one value each: `desired` (profile that should be up), `autoconnect`,
`access`, `connecting`, `needs-login`, `link-lost`, `routes.disabled`,
`zones.disabled`, `skip-networks`. They are declared as constants at the top
of `bin/ocbar` — a new one belongs there, and `ocbar selftest` fails when a
path appears inline instead. They are written whole (`state_write`: temp file,
then rename), so a reader never sees a half-written file, and no locking is
needed because each value is independent. `ocbar state [--json]` prints the
whole picture at once.

The CLI has the final word on whether a profile is valid: the editor asks
`ocbar profile-check` before saving and refuses with the client's own words.
The editor may be stricter than the client — its checks are hints while you
type — but never more permissive. `ocbar-app --selftest` compares both
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

Use the issue templates. `ocbar report` produces a single file with versions,
diagnostics and log tails with hosts, addresses and logins masked — attach it,
but read it first: masking does not know your internal names.

Security issues: see [SECURITY.md](SECURITY.md), not a public issue.
