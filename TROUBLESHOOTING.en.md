# Troubleshooting the first connection

**English** · [Русский — full guide](TROUBLESHOOTING.md)

The most common problems of a first install and sign-in. The Russian guide
covers more cases. Start with `ocbar doctor`: it checks each part separately
and usually names the cause.

```bash
ocbar doctor        # changes nothing: parts, helper version, leftovers, routes
ocbar logs -n 100   # all logs in one timeline: supervisor, sign-in, openconnect, app
```

## Sign-in

### The sign-in window waits and fills nothing

On a form it does not recognise, ocbar fills and clicks nothing — by design.
Record the form once: `ocbar learn <profile>`, "Learn the form…" in the
profile editor, or connect with `ocbar connect --teach` and tick "Remember
how I sign in" in the sign-in window. Check which rules apply and where they come from:

```bash
ocbar rules show <profile>   # "inline" = [Autofill] in the profile, "file:…", "builtin"
```

When the window gives up, `~/Library/Logs/ocbar/auth.log` records what the
page showed: title, messages, fields as filled or empty (never their values),
and buttons.

### The second factor is rejected

Compare the code ocbar would use with your authenticator app:

```bash
ocbar secret status          # source of the secret and the current code
```

If they differ, the secret is wrong. A Google Authenticator export often holds
several accounts; list them and pick one explicitly:

```bash
ocbar secret import-qr <image> --list
ocbar secret import-qr <image> --select <part of the name>
```

ocbar submits a code once per sign-in, so it never locks your account with
repeated guesses. An account that is already locked is unlocked by your
identity provider, not by ocbar.

### Signed in, but the tunnel fails with `401 Unauthorized`

A load balancer moved the sign-in to a specific node, and the session belongs
to that node. ocbar follows it and logs "the load balancer redirected to … —
the tunnel goes there too"; if that line is missing, update ocbar.

### `Server certificate verify failed: signer not found`

Not an error on its own. The gateway certificate is issued by a private CA,
and openconnect checks it against the hash from the gateway reply. If
`Connected to HTTPS` follows, everything is fine.

### The gateway says "Cisco Secure Desktop not installed on the client"

The group requires a HostScan device check. Set an executable script in the
profile, `[Connection] CsdWrapper = ~/vpn/csd-post.sh`; a starting point is
installed in `$(brew --prefix ocbar)/share/ocbar/examples/csd-wrapper.sh`.
Whether the report satisfies the policy is decided by the gateway.

## Tunnel and network

### Internal names do not resolve

```bash
ocbar dns status                       # what is in /etc/resolver and what macOS sees
dscacheutil -q host -a name <name>
```

If `dig +short @<resolver> <name>` answers but macOS does not, the zones are
not applied: see `ocbar status`. A zone set to `vpn` uses the resolver the
gateway sends, so it applies only while the tunnel is up.

### Traffic does not go through the tunnel

```bash
ocbar status                     # each network: via utunN, bypassing, or switched off
ocbar routes on 10.0.0.0/8       # switch a network back on
```

ocbar installs only the networks listed in the profile's `[Routes]`; the
list the gateway sends is ignored on purpose. Add the network to the profile
if it is missing. If `route -n get <address>` shows another interface, a
different VPN client owns that route; ocbar never removes routes it did not
create.

### The menu shows "Connecting…" for a long time

openconnect started, but the gateway did not answer CONNECT or DTLS got stuck.
The supervisor stops an attempt after 90 seconds and retries. If your network
blocks UDP, set `Dtls = off` in `[Connection]`. Details:
`ocbar logs openconnect -n 50`.

### Routes or zones are left after a crash

```bash
ocbar doctor       # lists leftovers
ocbar cleanup      # removes only what ocbar created
```

Files in `/etc/resolver` that ocbar did not create are never touched.

## Installation

### `ocbar doctor` says the helper is behind

A release changed the privileged helper. Run `sudo ocbar install` once more.

### Homebrew refuses the formula

The tap is third-party: run `brew trust ValeraGin/ocbar` before
`brew install ocbar`, after reviewing it.

## Asking for help

`ocbar report` writes one file with versions, `ocbar doctor`, the state,
profiles and log tails; hosts, addresses, logins and cookies are replaced with
placeholders. Read it before attaching — masking does not know all your
internal names. Then open an issue:
[bug report](https://github.com/ValeraGin/ocbar/issues/new?template=bug_report.yml)
or [works / does not work with my gateway](https://github.com/ValeraGin/ocbar/issues/new?template=gateway_report.yml).

| What | Where |
|---|---|
| supervisor decisions, reconnects, sleep | `~/Library/Logs/ocbar/supervisor.log` |
| what the sign-in window filled and why not | `~/Library/Logs/ocbar/auth.log` |
| openconnect output | `/var/db/ocbar/openconnect.log` |
| what the gateway sent when connecting | `/var/db/ocbar/tunnel.env` |
| verbose sign-in | `OCBAR_VERBOSE=1 ocbar connect --show` |
