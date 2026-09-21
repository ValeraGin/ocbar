# Changelog

All notable changes. Versions are git tags; the Homebrew formula pins each
release to its tag and commit.

## 0.17.1 — 2026-09-21

- Stray openconnect sessions no longer pile up. The helper compared the
  recorded start time of its openconnect with `ps` output that ends in
  spaces, so it never recognised its own process: `disconnect`, cancelling a
  connection and reconnecting after a network change left the old
  openconnect running and started another. Thirty minutes later the gateway
  closed the idle one for inactivity, and its disconnect script removed the
  routes and DNS zones of the working session; the supervisor restored them
  or connected again, and the cycle repeated.
- A disconnect or reconnect from an openconnect that is not the current one
  no longer touches routes, zones or the tunnel state.
- `ocbar cleanup`, `disconnect` and a new connection stop stray sessions —
  the helper's own openconnect processes that are not in its pidfile.
  Someone else's openconnect is still left alone.
- `ocbar status` and `ocbar doctor` name stray sessions (pid and start
  time); `status --short`/`--json` list them as `strays`, and the menu no
  longer calls them "someone else's tunnel".
- The new helper takes `sudo ocbar install`.

## 0.17.0 — 2026-09-21

- The command line speaks English when the system does: every message,
  notification and `ocbar help`. `OCBAR_LANG=ru|en` picks the language
  explicitly. The log and the machine-readable output (`--short`, `--json`,
  `key=value`) stay as they were.
- Reasons for refusing a two-factor code (no QR code in the image, several
  accounts in one export) come in the same language.
- The app recognises the client's hints ("sudo ocbar install", "brew install
  openconnect/ocproxy", "not installed") in both languages.
- `tools/i18n-scan.py --check` now covers the command line: a message
  without a translation fails the build.

## 0.16.0 — 2026-09-21

- The sign-in windows speak English when the system does, like the app:
  the SMS code and VPN password prompts, "Remember how I sign in", "Remember
  for the next sign-in?", the form mark-up window and the camera window.
  The log and the messages the command line reads stay as they were.
- The password prompt points to Settings → Profiles → Sign-in to save the
  password, instead of a terminal command.
- `tools/i18n-scan.py --check` covers the sign-in windows too.

## 0.15.6 — 2026-09-21

- README screenshots in both languages: `assets/` shows the English
  interface, `assets/ru/` the Russian one; `tools/screenshots.sh` retakes
  all of them. Demo profiles in the preview follow the interface language.
- The menu's own height fitting no longer applies to other windows that
  contain a menu (the preview), which cut screenshots short.

## 0.15.5 — 2026-09-21

- `ocbar app stop` returns only after the app has exited. Run right before
  `ocbar app start`, it used to leave the old process alive for a moment, so
  `start` reported "already running" and the copy in `~/Applications` stayed
  on the previous version after an upgrade.

## 0.15.4 — 2026-09-21

- `ocbar secret access` shows the Screen Recording and camera permissions as
  the sign-in helper sees them, and `ocbar://debug-access` compares them with
  what the app itself has — if they differ, the permission hint would be
  wrong.
- Releases and CI run the self-tests inside the same sandbox `brew test`
  uses, so a check that depends on this machine's permissions fails before
  a release instead of after it.

## 0.15.3 — 2026-09-21

- The Screen Recording hint appears only when the capture has no QR code at
  all. A QR code that was read but refused (several accounts, not a TOTP
  code) is reported as such, with or without the permission. This also made
  the self-test depend on the machine's permission: `brew test` failed in
  the sandbox after 0.15.2.

## 0.15.2 — 2026-09-21

- Adding a code with the camera no longer takes the first account from an
  export that holds several: it asks for an export with one account, or
  `--select <part of name>`. The camera window explains what to show when
  a code is added from scratch.
- Capturing a QR code on screen without the Screen Recording permission now
  says so, instead of "no QR code found" on a capture that shows only the
  desktop.
- Screen capture, the camera and the keychain are covered end to end
  without a person: from the editor's buttons through `ocbar` and
  `ocbar-auth` to what reaches the keychain. New `ocbar-auth --qr-png` and
  `--screen-access` for such checks.

## 0.15.1 — 2026-09-21

- Adding a code now says why it failed, in the authenticator's own words —
  for example that the QR holds several accounts — instead of a generic
  "not recognised". `ocbar secret add-totp` takes `--select <part of name>`
  for such exports.
- The result of saving a password or code stays with its profile: it no
  longer shows up under another profile, and a slow camera or screen capture
  no longer switches the editor back to the profile it started on. Password
  groups now show the result too.
- Codes saved from a QR image, the camera or a link get the same keychain
  label as `ocbar secret set-totp`.
- Self-tests cover saving the password and code: what reaches the keychain,
  that neither shows up in process arguments, parameters written to the
  profile, and the reason for a refusal. The new `ocbar-auth` flags are
  documented in `--help`.

## 0.15.0 — 2026-09-21

- Password and one-time code without the terminal. Settings → Profiles → Sign-in
  has "Save…" for the password and "Add…" for the code: capture a QR code on
  screen (drag a frame around it), use the camera, or paste an `otpauth://`
  link or the setup key. Both go to the macOS keychain.
- Once the code is set up, the row shows the current code and how long it is
  valid, so you can compare it with your authenticator app before the first
  sign-in.
- Password and code sources (KeePassXC, your own command) moved to Advanced;
  the keychain is the default.
- CLI: `ocbar secret set-password <profile> --stdin` and `ocbar secret add-totp
  <profile> --screen|--camera|--stdin`.

## 0.14.1 — 2026-09-21

- Fixed a crash when opening Diagnostics and logs: a number passed into a
  translated string with a placeholder brought the app down. Translated
  strings now take any value, and the self-test covers it.
- The whole "Advanced" row in the profile editor is clickable, not just the
  small disclosure triangle.

## 0.14.0 — 2026-09-20

- The app speaks English when the system does: menu, settings, wizard,
  notifications, warnings and units (2h 14m, 1.4 MB/s, 41 ms). Russian stays
  the development language, so an untranslated string shows up in Russian
  rather than as a key.
- `tools/i18n-scan.py` collects the UI strings and fails the build when one
  has no translation; it runs in CI and before every release.
- The CLI is still Russian-only.

## 0.13.1 — 2026-09-20

- State files are written whole (temp file, then rename), so a reader never
  catches a half-written value.
- `ocbar state [--json]` shows the runtime state in one place: profile,
  auto-connect policy, access check, flags, disabled networks and zones.
- The self-test fails if a state file is introduced inline instead of being
  declared with the others at the top of the CLI.

## 0.13.0 — 2026-09-20

- The client has the final word on a profile: `ocbar profile-check <file>`
  says whether it will load, and the editor (and the first-run wizard) refuse
  to save when it will not, quoting the client's own reason.
- The editor no longer lets you save a profile with an out-of-range `Mtu` or a
  `Dtls` other than on/off — the client refuses to load those, so the profile
  would simply not connect.
- `ocbar-app --selftest` compares the editor's verdict with the client's on a
  set of profiles, so the two rule sets cannot drift apart unnoticed.

## 0.12.1 — 2026-09-20

- Internal: the CLI is 4431 → 3655 lines. The self-test and the Python parts
  (merged logs, report redaction, password-group login) moved out of
  `bin/ocbar` into `libexec/`, where the linter and the tests can see them.
  Behaviour is unchanged.

## 0.12.0 — 2026-09-20

- `ocbar status --json` prints the whole state as typed JSON: lists as lists,
  numbers as numbers. The menu bar app reads that instead of parsing
  `key=value` lines, so a "|" in a profile name or a new field can no longer
  shift columns. `--short` stays for scripts and the SwiftBar plugin.

## 0.11.1 — 2026-09-20

- No more jumping when the menu changes height: the height is not animated any
  more, the window is resized once, and intermediate frames are held back until
  the redraw is done (SwiftUI lays the new page out 22 points too tall for a
  moment). Verified frame by frame on the real menu: 523 → 649 → 523 with no
  intermediate height.

## 0.11.0 — 2026-09-20

- The menu window now shrinks back. macOS grows the menu-bar window to fit the
  content but never shrinks it, so after the Networks and DNS page the window
  stayed tall and the content hung below the icon with empty space above.
  ocbar measures its content and resizes the window itself, keeping the top
  edge in place.
- Checking this needs the real menu-bar window, so the app can now drive it:
  `open "ocbar://debug-menu?token=<notify token>"` opens the menu, switches to
  Networks and DNS and back, and writes the heights and a verdict to the app
  log.

## 0.10.5 — 2026-09-20

- The self-test now measures the menu itself: it switches to Networks and DNS
  and back and checks that the page is taller, that going back restores the
  height, and that the menu never exceeds the screen. Both earlier regressions
  fail this check.
- Removed the menu-window top anchor and its logging: the log showed macOS
  keeps the top itself, and the real cause was the height measurement.

## 0.10.4 — 2026-09-20

- The menu takes the height of its content and scrolls only when the content
  is taller than the screen (ViewThatFits instead of measuring inside the
  scroll view). Measuring inside the scroll made the height grow-only, and
  then the Networks and DNS page came out cramped.

## 0.10.3 — 2026-09-20

- The menu shrinks back after the Networks and DNS page: its height was
  measured inside the scroll view, which stretched the content, so the height
  only ever grew. The window stayed tall and the content looked detached from
  the icon.

## 0.10.2 — 2026-09-20

- Keeps the menu under its icon in more cases: the anchor is taken when the
  window is actually shown, and the window is corrected after moves as well as
  resizes. Menu window geometry is written to the app log for now, while the
  remaining drift is being tracked down.

## 0.10.1 — 2026-09-20

- The menu stays attached to its menu-bar icon when its height changes
  (Networks and DNS page, warnings, pause). AppKit kept the bottom edge in
  place on resize, so a shorter menu drifted down from the icon; now the top
  edge is kept.

## 0.10.0 — 2026-09-20

- The menu no longer lists profiles: usually there is one. It shows the
  profile that is connected or was used last, with its address, and "Other
  profile…" when there are several.
- Settings → Profiles has "Connect" / "Disconnect" for the selected profile;
  switching away from a live session asks first.

## 0.9.2 — 2026-09-19

Fixes from a design review of every screen:

- The menu makes trouble visible: "No connection · reconnecting", "Paused"
  and "Sign-in needed" are coloured and bold; network counters say "not
  applied" while paused and name what they count ("networks 2/3 · DNS 2/3").
- Switching profiles on a live session asks in its own block with "Cancel" and
  "Switch", instead of a small note inside the scrolling list.
- "Disconnect" is a calm button with red text; the status stays the focus.
- Proxy commands wrap instead of being cut in the middle; the proxy page is
  called "SOCKS proxy"; disabled networks stay readable.
- Profile fields look like editable fields; "Profile has no errors" instead of
  "Check passed"; missing secrets are explained in plain words.
- Mode cards have equal height; General uses clearer wording; the wizard says
  "System component installed" when it is; the SMS window no longer shows the
  gateway's raw prompt.

## 0.9.1 — 2026-09-19

- The menu scrolls when it is taller than the screen: with many profiles, the
  switch question and warnings, "Quit" used to be cut off.
- Settings no longer show the sidebar toggle in the title bar; the sidebar is
  the navigation and does not hide.

## 0.9.0 — 2026-09-19

- The first-run wizard is a paged assistant: steps at the top (System
  component → Profile → First sign-in), one screen per step, and Back / Later /
  Continue at the bottom. The profile step asks how to sign in (SSO or password
  and SMS code) and imports `.ocbar` and Cisco `.xml` profiles.

## 0.8.1 — 2026-09-19

- Profiles show the full connection address with its group
  (`vpn.example.com/employees`), in the menu and in Settings: profiles of one
  gateway differ only by the group. In the menu the address is the second
  line, the description moved to the tooltip, and password groups get a small
  "password + SMS" badge.

## 0.8.0 — 2026-09-19

- `ocbar logs` and the new "All" tab in the Logs window show every log as one
  timeline, with the source on each line: supervisor, openconnect, proxy,
  sign-in and app. `-f` follows, `-n` sets the length, sources can be listed.
  The Logs window also gained a "Sign-in" tab for `auth.log`.
- openconnect lines carry a timestamp (`--timestamp`), and so do the helper's
  own lines in the openconnect log. The tunnel log needs the updated helper:
  run `sudo ocbar install` once.

## 0.7.1 — 2026-09-19

- The sign-in window fills the login even when the profile's rules only
  mention the password. Rules recorded while the identity provider remembered
  the login had no username line, so after a full sign-out the form stopped at
  an empty login field.
- Password groups ask for the password in a secure window when the profile's
  source has none, instead of giving up before the SMS step.

## 0.7.0 — 2026-09-19

- Settings in the style of macOS System Settings: sections with icons in a
  sidebar, the profile list as the middle column, and the profile editor split
  into Connection, Mode and Networks & DNS. Grouped forms with one short note
  per group instead of paragraphs under every control. The Mode tab moved into
  the profile, where the setting lives.
- The editor chooses how to sign in: SSO in a browser window, or password and
  SMS code.
- New app icon: two linked rings on blue, the same mark as in the menu.

## 0.6.0 — 2026-09-19

- Password groups (`Auth = password`: login, password and a code from SMS)
  connect through ocbar: the password comes from the profile's source, the
  SMS code is asked in a small "Code from SMS" window (or on the terminal),
  and the session is obtained with `openconnect --authenticate` as the user.
  Auto-connect still leaves them to a human.
- The menu shows the connection domain under each profile name.
- Menu buttons light up under the pointer.

## 0.5.1 — 2026-09-19

- The menu scrolls the profile list to the selected profile, so with many
  profiles the current one is visible right away.
- `ocbar-app --stage --live` shows real profiles again (0.4.8 gave it the demo
  ones meant for screenshots).

## 0.5.0 — 2026-09-19

- New menu, in the style of macOS Control Center: a status card with one
  action button instead of the switch (Connect, Disconnect, Sign in, Cancel,
  Resume), traffic, profiles as a list like the Wi-Fi menu, and "Networks and
  DNS" as a second page with network and zone toggles and connection details.
  Warnings are separate banners, each with its next step.
- System colours (blue, green, orange, red) across the app.

## 0.4.8 — 2026-09-18

- Builds with Command Line Tools 27 without Xcode: the macOS 27 SDK needs the
  SwiftUI macro plugin that only Xcode ships, so `make-app.sh` falls back to
  the previous SDK from the same Command Line Tools.
- `ocbar-app --stage` renders windows with demo profiles instead of reading
  `~/.config/ocbar`, so screenshots never show real servers or logins.

## 0.4.7 — 2026-09-17

- "Do not connect on this network": the supervisor skips auto-connect in
  networks you mark (home, office). The network is recognised by the router
  MAC, so no location permission is needed. In Settings → General or
  `ocbar autoconnect skip-here`.

## 0.4.6 — 2026-09-17

- `ocbar import profile.xml` reads the server list from a Cisco AnyConnect
  XML profile and creates a profile per server (addresses and groups only).
- README: how to drive ocbar from Shortcuts and other automation.

## 0.4.5 — 2026-09-17

- The supervisor re-checks access every five minutes, not only right after
  connecting: the menu shows whether the resource from `[Health] Check` still
  answers, and says so when a live tunnel stops giving access.
- Errors that need a command you have to run yourself (`sudo ocbar install`,
  `brew install openconnect`) offer to copy it.

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
