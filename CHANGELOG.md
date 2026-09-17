# Changelog

All notable changes. Versions are git tags; the Homebrew formula pins each
release to its tag and commit.

## 0.4.4 — 2026-09-17

- Captive portals (hotel Wi-Fi) are detected: the supervisor does not spend
  login attempts and says what to do.
- `Mtu` and `Dtls` in the profile reach openconnect (`--base-mtu`,
  `--no-dtls`) for nested VPNs and networks without UDP.

## 0.4.3 — 2026-09-17

- First-run wizard in the app: system component, profile, first login, each
  step with the equivalent command. Opens from the menu when there are no
  profiles yet ("Set up ocbar…").
- Menu rows are real buttons: keyboard and VoiceOver reach them.

## 0.4.2 — 2026-09-17

- `ocbar report` (and "Save report…" in Diagnostics): one file with versions,
  diagnostics, profiles and log tails; hosts, addresses, logins, e-mail and
  cookies are replaced with placeholders, `--raw` keeps them.
- `ocbar autoconnect manual | resume | always <profile>` and a picker in
  Settings → General: who brings the tunnel up. Default is unchanged.
- Settings → General: start at login, developer mode. The menu now says
  "Quit ocbar (tunnel stays up)".

## 0.4.1 — 2026-09-17

Fixes found by a review of what the app still lacks:

- The helper no longer removes a host route to the gateway that another VPN
  created: the route is recorded as ours only when we added it, and it is
  checked again before removal.
- Our `openconnect` is identified by start time as well as name, so a reused
  pid cannot be mistaken for our tunnel.
- The one-time code is fetched when the form is filled, not before the window
  opens: a code from KeePassXC or a custom command no longer expires in flight.
- A network failure during a silent login is no longer reported as "login
  required": the supervisor retries with backoff instead of stopping and
  waiting for a human.
- The liveness probe asks every resolver pushed by the gateway, not just the
  first one.
- `STATE=connected` is published only after routes and DNS zones are applied;
  an interrupted setup is visible and cleaned up.

## 0.4.0 — 2026-09-17

- Notifications are grouped (login required / connection problems /
  recovery and reconnects) and configurable in Settings → Notifications;
  recovery events are off by default.
- The same notification is shown at most once per 10 minutes; "Connected"
  is only shown after an automatic reconnect.

## 0.3.9 — 2026-09-14

- `ocbar logout`: disconnect and erase identity-provider sessions of the
  login window, so the next login shows the full form. In the menu when
  developer mode is on (`ocbar app devmode on`).

## 0.3.8 — 2026-09-14

- Autofill waits for a submit button that the page enables after input
  (Vue/React forms), and retries a click once if the page did not change.
- The notification token is no longer lost when the app restarts.

## 0.3.7 — 2026-09-13

- The supervisor no longer stops a tunnel that `ocbar connect` is still
  bringing up, and does not start a second login in parallel.

## 0.3.6 — 2026-09-13

- Autofill works when the gateway serves the login page from a load-balanced
  node.
- "Remember how I sign in" merges recorded steps into existing rules instead
  of replacing them.
- "Insert password" and "Insert code" buttons in the login window.
- Login window decisions are logged to `~/Library/Logs/ocbar/auth.log`.

## 0.3.5 — 2026-09-13

- The app is kept as a copy in `~/Applications`, so it shows up in
  Launchpad and Spotlight.

## 0.3.4 — 2026-09-11

- Spaces in notification text are no longer shown as `+`.

## 0.3.3 — 2026-09-11

- Profile order: drag in the profile list or `ocbar profiles order`.

## 0.3.2 — 2026-09-11

- Redesigned menu (profile and state in the header, on/off switch, shorter
  footer) and profile window (essentials first, password and code status).

## 0.3.1 — 2026-09-10

- Notifications come only from the app; no `osascript` fallback.

## 0.3.0 — 2026-09-10

Security and reliability fixes after a full review:

- Helper 0.8.0: state moved to `/var/db/ocbar`, all state and trust paths
  must be root-owned; signals only to our `openconnect`; exact zone, route
  and SOCKS matching; stricter argument validation; `uninstall` tears the
  session down. Run `sudo ocbar install` after upgrading.
- Autofill only over HTTPS on hosts of the login chain; `--insecure` applies
  to the gateway only; cookies accepted from the exact gateway host; form
  recording ignores synthetic events.
- App: status polling separate from actions, cancel during login, profile
  parsing identical to the CLI, external edits detected, notification token.
- CLI: correct exit codes, no duplicate profiles, safer self-test.

## 0.2.0 – 0.2.10 — 2026-09-08 … 2026-09-10

- Menu bar app, proxy mode, system SOCKS.
- Autofill rules inside the profile (`[Autofill]`), recorded by clicking,
  multi-step forms, pre-fill of standard fields, portal probe.
- "Remember how I sign in" during a real login; TOTP secret from the Mac
  camera; TOTP algorithm, digits and period in the profile.

## 0.1.0 — 2026-09-06

- First release: SSO login, tunnel through a privileged helper, split DNS,
  split tunneling, pause, supervisor, SwiftBar plugin.
