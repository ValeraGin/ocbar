<img src="assets/mark.svg" width="72" height="72" alt="OpenConnect for Mac">

# OpenConnect for Mac

[Website](https://valeragin.github.io/openconnect-for-mac/)

**English** · [Русский](README.ru.md)

**Your work VPN, in your Mac’s menu bar.**

An open-source, Cisco AnyConnect–compatible client built on
[OpenConnect](https://www.infradead.org/openconnect/). Sign in with SSO,
choose which networks go through the tunnel, and pause or resume from a
native macOS menu. The supervisor reconnects after sleep and network changes.

Free under the MIT license. Install through Homebrew, which builds the app
on your Mac. Requires macOS 14.4+ and access to your own compatible VPN gateway;
OpenConnect for Mac does not provide VPN servers.

![OpenConnect for Mac menu: connect, toggle a network, pause](assets/demo.gif)

<sub>The real menu on a demo profile: connect, switch off a network, pause.</sub>

**Status:** a single-author tool used daily on a real AnyConnect gateway
with a Keycloak identity provider. The app, the sign-in windows and the CLI
support English and Russian, selectable in Settings; the longer guides,
[INSTALL.md](INSTALL.md) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md), are in
Russian; the first-connection problems are also in
[TROUBLESHOOTING.en.md](TROUBLESHOOTING.en.md). Version history is in [CHANGELOG.md](CHANGELOG.md).

> Independent project, not an official OpenConnect product. Not affiliated with
> the OpenConnect project or Cisco. “AnyConnect” describes protocol compatibility.

The CLI is `ocmac`; profiles use `.ocmac`. Existing installations can be
migrated with `ocmac migrate` followed by `ocmac prepare && sudo ocmac install`. Original user
files are preserved. System setup stops the previous VPN session.

## Quick install

Open Terminal and run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValeraGin/openconnect-for-mac/main/install.sh)"
```

The [installer](install.sh) offers to install missing Apple Command Line Tools
and Homebrew, installs OpenConnect for Mac and its helper, and opens the menu app. It asks for
administrator access when needed. Share one `.ocmac` file and the
[profile installation guide](https://valeragin.github.io/openconnect-for-mac/guide/#profile)
with a teammate. After installation, double-click their `.ocmac` file, enter their
own username and choose **Connect**. Networks and DNS come from the profile.
Choose English, Russian or System default in Settings → General → Interface language.


## Why

OpenConnect speaks the AnyConnect protocol, but on macOS the gaps are
everything around it: gateways that only allow SAML login, a
`vpnc-script` that routes all traffic and rewrites DNS, no reconnect after
sleep, and no menu bar UI. OpenConnect for Mac fills those gaps without a kernel extension,
a root daemon, or an Apple Developer ID.

## How it works

```
ocmac connect
  │
  ├─ ocmac-auth (Swift, WKWebView)        runs as the user
  │    init → SAML window → cookie → auth-reply → session token + server cert hash
  │
  └─ sudo -n ocmac-helper tunnel-start    root, the only NOPASSWD entry
       ├─ openconnect --cookie-on-stdin --script "ocmac-helper vpnc" -b
       └─ vpnc: ifconfig utunN, our routes, our /etc/resolver zones — nothing else

ocmac supervise (LaunchAgent)             runs as the user, every 5 s
       tunnel pid · kern.waketime · primary interface · routes in place
```

Privileged code lives in one file, [libexec/ocmac-helper](libexec/ocmac-helper):
fixed subcommands, every argument validated, state only in root-owned
directories, and it only touches what it created itself. See
[SECURITY.md](SECURITY.md) for the threat model.

## Features

- **SSO login** (`single-sign-on-v2`) in a WebKit window: the window stays
  hidden while a saved identity-provider session is enough, and appears only
  when a human is needed.
- **Autofill** with per-profile rules: username, password, TOTP, buttons,
  multi-step forms. Rules are recorded by clicking the form (`ocmac learn`) or
  by logging in once with "Remember how I sign in" (`ocmac connect --teach`).
  Filling happens only on HTTPS hosts of the login chain started by the
  gateway.
- **Secrets** from the macOS Keychain, KeePassXC (`keepassxc-cli`) or any
  command (e.g. `op item get … --otp`). TOTP secrets can be imported from
  `otpauth://` and Google Authenticator export QR codes, including via the Mac
  camera. Secrets never appear in process arguments.
- **Split tunneling and split DNS**: only listed networks go through the
  tunnel; DNS zones are added as `/etc/resolver` files. Both can be toggled
  on a live connection.
- **Pause**: remove routes and zones without dropping the session, resume
  instantly without logging in again (⌥⌘P).
- **Supervisor**: reconnects after sleep, network changes and dropped links;
  stops a connection attempt that hangs for 90 seconds and tries again;
  never opens a login window on its own; caps logins per hour.
- **Proxy mode**: `openconnect --script-tun` + `ocproxy` gives a local SOCKS
  proxy with no routes, no DNS changes and no root at all.
- **English and Russian**: the app, the sign-in windows and CLI messages
  follow the system language.
- **Menu bar app**: a native macOS menu — "Connect VPN" / "Disconnect VPN" on
  top, profiles as rows (the connected one shows its state and session time,
  or the connection step while connecting; click another to connect it),
  networks and DNS zones as checkmark submenus, pause and the usual commands
  below. The menu bar icon fills step by step while connecting. Hold ⌥ while
  opening the menu for connection details: tunnel address, gateway, MTU,
  resolvers, speed, traffic, latency. Settings hold the profile editor, notification
  settings and diagnostics with logs; a first-run wizard walks through system
  component → profile → first login.

## Try it without a VPN

The interface runs on synthetic data, so you can look before installing
anything that touches your network:

```bash
ocmac ui-lab                                              # menu states in a browser page
app/.build/ocmac.app/Contents/MacOS/ocmac-app --stage     # the real menu, every state at once
```

## Install

Requires macOS 14.4+ and Command Line Tools (full Xcode is not needed).

```bash
brew tap ValeraGin/openconnect-for-mac
brew trust ValeraGin/openconnect-for-mac            # third-party tap: Homebrew refuses untrusted formulae
brew install openconnect-for-mac                    # builds from source on your machine
sudo ocmac install                    # once: helper, sudoers rule, LaunchAgent

mkdir -p ~/.config/ocmac/profiles
cp "$(brew --prefix openconnect-for-mac)"/share/openconnect-for-mac/examples/example.ocmac ~/.config/ocmac/profiles/main.ocmac
$EDITOR ~/.config/ocmac/profiles/main.ocmac

ocmac secret set-password
ocmac connect --show
ocmac app start && ocmac app autostart on
```

Why a source build: without a Developer ID a prebuilt app is quarantined by
Gatekeeper, while a locally built one is not. `brew upgrade openconnect-for-mac` updates
it; when a release changes the privileged helper, run `sudo ocmac install`
once more (`ocmac doctor` says when the helper is behind). Uninstall in this order: `sudo ocmac uninstall`, then
`brew uninstall openconnect-for-mac` — otherwise the root helper and its sudoers rule stay
behind. Details (in Russian): [INSTALL.md](INSTALL.md).

## Profile

![Profile window](assets/profile.png)

![Notification settings](assets/notifications.png)

One file per connection, similar to WireGuard configs:
`~/.config/ocmac/profiles/<name>.ocmac`. No secrets inside — only references
to where they are stored, so a profile can be shared.

```ini
[Connection]
Name = Main
Url  = vpn.example.com/employees
User = alice

[Routes]
10.0.0.0/8
172.16.0.0/12

[DNS]
example.com      = 10.0.0.1
corp.example.com = vpn          # "vpn" = resolver pushed by the gateway

[Auth]
Password = keychain             # auto | keychain | keepassxc | command | ask
Totp     = keepassxc            # auto | keychain | keepassxc | command | sms | off
KeepassEntry = Group/Entry

[Health]
Check = wiki.example.com:443    # what must answer after connecting

[Autofill]
# step 1 — idp.example.com/login
fill  password input[id=password]
click button[type=submit]
# step 2 — idp.example.com/otp
fill  totp input[id=otp]
click input[id=kc-login]
```

Proxy mode instead of a tunnel:

```ini
[Connection]
Mode = proxy

[Proxy]
Port        = 11080
SystemProxy = off     # on — set this SOCKS on the active network service
```

```bash
brew install ocproxy
ocmac connect
curl --socks5-hostname 127.0.0.1:11080 https://wiki.example.com
```

A full annotated example: [etc/example.ocmac](etc/example.ocmac).

### External HostScan script

For gateways that request a device report, set your script in the profile:

```ini
[Connection]
CsdWrapper = ~/vpn/csd-post.sh
```

Use a wrapper approved for your organization's device policy. The bundled
`examples/csd-wrapper.sh` contains placeholder device report values; it is a
protocol example, not a compliance checker or a ready corporate configuration.
Do not deploy its default report as a device assessment. Make your approved
script executable with `chmod u+x "$HOME/vpn/csd-post.sh"`. Paths with spaces
work; do not put quotes around the value in the profile.
The script runs as your user before SSO, using OpenConnect's wrapper
arguments and `CSD_HOSTNAME`, `CSD_TOKEN`, `CSD_SHA256` environment variables.
It submits the prepared report itself; stdout is diagnostic output, not a
report for OpenConnect for Mac to submit. OpenConnect for Mac waits for the gateway, then resumes SSO.
A required HostScan check without a configured wrapper stops before SSO.
Missing files, execution errors and non-zero exit codes also stop sign-in.
Whether the report satisfies the device policy is decided by the gateway.

### Embed CSD in a portable profile

In the profile editor's advanced settings, choose **Embed CSD script…**.
The file is stored in `[Connection] CsdScriptBase64`, as one line of Base64.
The editor and `ocmac export` preserve it, so a colleague needs just one `.ocmac`.
Use a UTF-8 script starting with `#!`, up to 256 KiB. Choose either
`CsdWrapper` or `CsdScriptBase64`.

Import extracts the script into `~/.config/ocmac/csd/`; `sudo ocmac install`
prepares its system copy. The installer handles both steps with `--profile`
alone, without `--csd`. Reading, validating and importing never run the script.
After changing the embedded script, rerun `sudo ocmac install` to update its
system copy.

### Connecting through an upstream proxy

Set `[Connection] UpstreamProxy = http://127.0.0.1:10808` or
`socks5://127.0.0.1:10808` to send password login, SSO and VPN transport through
one proxy. Both `Mode = tunnel` and `Mode = proxy` support it. `[Proxy]` still
configures the local SOCKS endpoint exposed to applications after VPN login.

HTTP CONNECT and SOCKS5 without authentication are supported, with an explicit
port (1–65535) and DNS hostname or IPv4 address. Credentials, paths and IPv6
literals are rejected. Native tunnels require helper 0.8.3+ (`sudo ocmac install`).
It applies to password login, SSO and form learning.
Explicit upstream always disables DTLS: transport uses TCP. Proxy failure does
not fall back to a direct connection to the external gateway. WebKit/URLSession
exclude loopback destinations from proxying; this setting is not intended for
SSO gateways running on localhost.

CSD wrappers receive `http_proxy`, `https_proxy`, `all_proxy` and uppercase
variants, with `NO_PROXY` cleared. Custom scripts must honor these variables;
OpenConnect for Mac does not intercept arbitrary sockets opened by a script. The proxy must
already be running. An empty setting preserves existing connection behavior.

## Commands

```
ocmac connect [profile] [--show] [--teach] [-v]   log in and bring the tunnel up
ocmac disconnect
ocmac logout                          disconnect and forget identity-provider sessions
ocmac status [--short|--json]
ocmac profiles | import <file> | export <profile> [file] | order [name…]
ocmac routes on|off|toggle <CIDR>     also: apply | clear | status
ocmac dns on|off|toggle <zone>        also: apply | clear | status
ocmac autoconnect [manual|resume|always <profile>] who brings the tunnel up
ocmac report [file] [--raw]           support report; hosts and logins masked
ocmac logs [-f] [-n N] [source…]      all logs merged by time (supervisor, openconnect, auth, app)
ocmac profile-check <file>            will the client accept this profile file (the editor asks before saving)
ocmac state [--json]                  runtime state in one place: profile, auto-connect, access, flags
ocmac pause | resume | toggle
ocmac secret set-password|set-totp|status|code [profile]
ocmac secret add-totp <profile> --screen|--camera|--stdin   add the TOTP secret from a QR on screen, the camera or an otpauth:// link
ocmac secret import-qr <image> [--list] [--select NAME] [profile]
ocmac learn [profile] [--probe] [--out <file>]    record login form rules by clicking
ocmac rules show|import <file>|clear [profile]
ocmac app start|stop|status | autostart on|off | devmode on|off
ocmac supervisor status|start|stop|restart
ocmac doctor                          diagnostics, changes nothing: parts, leftovers, stray sessions, routes
ocmac cleanup                         remove leftovers after a crash (only ours)
ocmac selftest
sudo ocmac install [--trust] | uninstall
--dry-run                             print privileged commands instead of running them
```

## Automation

There is no Shortcuts action yet, but the CLI is the automation interface —
use "Run Shell Script" in Shortcuts, or call it from anything else:

```bash
ocmac connect work && ocmac status --short   # key=value lines, easy to parse
ocmac status --json                          # the same state as JSON (what the app reads)
ocmac pause; ocmac resume
ocmac autoconnect manual                     # stop the supervisor from logging in
```

Coming from Cisco Secure Client? `ocmac import profile.xml` reads the server
list from an AnyConnect XML profile and creates one `.ocmac` per server
(addresses only — routes, DNS and credentials stay yours to set).

## Self-tests

None of them needs a network or privileges: configs are synthetic, state and
logs go to a temporary directory, the helper is replaced by a stub.

```bash
ocmac selftest                  # CLI: profile parsing, rejections, cleanup, notifications
tools/helper-selftest.sh        # privileged helper on --dry-run with stubs
ocmac-auth --selftest           # TOTP (RFC 6238), XML, fill scope, limits, cookies
ocmac-auth --learn-selftest     # form recording and autofill on sample pages
ocmac-app --selftest            # profile read/write parity with the CLI, UI state
tools/i18n-scan.py --check      # every string a person sees has its English
```

They run in CI on every push.

## Supported systems

| | Status |
|---|---|
| macOS 26, Apple Silicon | used daily by the author; CI builds and runs every self-test |
| macOS 15, Apple Silicon | weekly CI build and self-tests; no real-device VPN verification |
| macOS 14.4, Apple Silicon | deployment target; no real-device verification |
| Intel Macs | expected to work; Homebrew prefix is `/usr/local`, which the helper checks for ownership. Not verified |

Tried OpenConnect for Mac with your gateway? [Tell whether it worked](https://github.com/ValeraGin/openconnect-for-mac/issues/new?template=gateway_report.yml) — one short report
per gateway and sign-in method fills the compatibility table.

No telemetry, crash reporting or analytics. OpenConnect for Mac talks to your gateway and
identity provider; configured resource checks contact the resource you choose.
Logs stay under `~/Library/Logs/ocmac`. Installing and updating downloads code
from GitHub and Homebrew; the app has no automatic update check.

## Limitations

- Password groups (`Auth = password`: login, password and an SMS code) need a
  human for the code: OpenConnect for Mac fills in the password and asks for the SMS code in
  a small window, so they never reconnect silently.
- Full tunnel is configured as `0.0.0.0/1` + `128.0.0.0/1`; there is no
  "route everything and rewrite system DNS" mode.
- IPv6 inside the tunnel: the address is set, routes are not.
- The Homebrew-installed shared libraries of `openconnect` stay in a
  user-writable prefix; the helper verifies their hashes, which catches
  accidental changes but not a targeted local attacker. See
  [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE). Author: Valery Ignatkovich
([@ValeraGin](https://github.com/ValeraGin)).

### Profile workflow API

`ocmac import --json <file> [name]` returns `{"profiles":["actual-id",…]}` on stdout;
import notices go to stderr. Cisco XML may create several profiles. Applications
must use these IDs rather than the input filename.

`ocmac csd-status [profile]` returns `required`, `ready` and the system script
`name` as JSON without installing or executing CSD. Missing or changed system
copies block connection before sign-in. Run `sudo ocmac install` and check again.
External wrappers use content-based names; an older basename is accepted only
when its contents match. `ocmac check-access [profile] [URL]` checks a work resource
once and returns `{"reachable":true|false|null}` without changing the connection
or the supervisor’s state. An optional URL is used only for that check.
