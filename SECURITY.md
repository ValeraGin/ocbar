# Security

## Reporting a vulnerability

Please report privately through GitHub:
**Security → Report a vulnerability** on this repository. Do not open a
public issue for anything that could give local privilege escalation or leak
credentials. This is a single-maintainer project; reports are handled on a best-effort basis.

## Threat model

ocbar installs a root helper that the logged-in admin user may run without a
password. That is the main attack surface, and it is kept narrow.

**The helper** (`/usr/local/libexec/ocbar-helper`, `root:wheel 755`):

- is the only command in `/etc/sudoers.d/ocbar`, for the `admin` group;
- accepts a fixed set of subcommands; every argument is validated as a whole
  value (no newlines or control characters);
- keeps state in `/var/db/ocbar` and refuses to run if that directory, its
  parents, `/usr/local/libexec/ocbar` or `/etc/resolver` are not root-owned
  or are group/world-writable;
- runs a root-owned copy of `openconnect` and checks the SHA-256 of it and of
  every linked library against a manifest written at install time;
- only removes what it created: its own `/etc/resolver` files, routes through
  its own `utun`, its own SOCKS settings; signals only a process that really
  is `openconnect`;
- refuses `--dry-run` as root; `--dry-run` never writes system state.

**Known residual risk.** `openconnect`'s shared libraries stay in the
Homebrew prefix, which is writable by the user. The hash check catches an
accidental change after `brew upgrade openconnect` (run
`sudo ocbar install --trust` then), not a local attacker who already runs code
as that user and wins a race. Such an attacker can, however, already ask the
user for their password.

**Credentials.** Passwords and TOTP secrets come from the Keychain, KeePassXC
or a user command and are passed via environment and stdin, never via
command-line arguments. The session cookie reaches `openconnect` on stdin.

**Login window.** Autofill fills only over HTTPS on hosts of the login chain
that the gateway started (or `IdpHosts` from the profile), checks the host
again inside the page script, which runs in an isolated JavaScript world, and
limits password fills to two and TOTP to one per login. The session cookie is
accepted only from the exact gateway host.

**The menu bar app** has no privileges. It accepts `ocbar://notify` URLs only
with a random per-launch token stored in a `0600` file.

## Self-tests

`ocbar selftest`, `tools/helper-selftest.sh`, `ocbar-auth --selftest`,
`ocbar-auth --learn-selftest` and `ocbar-app --selftest` cover these rules and
run in CI.
