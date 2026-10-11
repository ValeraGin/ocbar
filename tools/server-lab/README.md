# Server compatibility lab

The supported protocol is AnyConnect. OpenConnect supports other protocols,
but ocbar currently selects `--protocol=anyconnect`; these tests make no claims
about GlobalProtect, Fortinet, Pulse, OpenVPN or WireGuard.

## Three independent layers

| Suite | What runs | What it verifies |
| --- | --- | --- |
| `tools/gateway-matrix-test.py` | Real ocbar-auth + WebKit against synthetic HTTPS gateways | SSO, custom cookie names, opaque round-trip, nested certificate hash, GET/POST/final-reply redirects (including host changes), client-certificate fallback, protocol/server/TLS errors |
| `tools/hostscan-sequence-test.py` | Real ocbar-auth + external wrapper against a synthetic HTTPS gateway | Report submission, waiting, original HostScan token, wrapper failures, paths with spaces, non-default port |
| `tools/ocserv-integration-test.py` | Production password driver + real OpenConnect + real ocserv | Stored/manual password, wrong password then cancellation, initial cancellation, untrusted server certificate, groups, password + TOTP, client certificate, isolated CSTP and DTLS tunnels with HTTP and DNS |

The first two are protocol fixtures, **not certified emulations of Cisco
firmware**. The third uses actual servers and a second disposable container
as a VPN client. It obtains a session through the production password driver,
passes the cookie to OpenConnect over stdin, checks that the route uses its TUN
interface, fetches an HTTP resource, and queries the DNS address supplied by
ocserv. None of these tests starts the host VPN. Separate cases force CSTP over
TLS and require DTLS establishment before HTTP/DNS traffic; TLS fallback cannot
pass the DTLS case. Helper routing tests remain in
`tools/helper-selftest.sh`.

The ocserv runner supplies `--cafile` directly to OpenConnect and exercises
`ocbar-pwauth.py`, not the complete profile-to-tunnel workflow. The current
profile/CLI does not expose a CA file, `--authgroup` or a client certificate.
Those configurations are therefore not declared supported through profiles by
this suite. Groups are tested both with explicit selection and with the expected
refusal when selection is missing. TOTP checks a real code and cancellation;
certificate authentication checks presence and absence of a client certificate.
The tunnel uses a minimal Linux route script, not the production macOS helper.
The complete profile-to-tunnel workflow and macOS split DNS are covered by the
separate opt-in live test below, not by this container suite. DTLS remains a
coverage gap on the external gateways tested so far.

All credentials are synthetic. The scripts do not load personal profiles or
Keychain entries. TLS fixtures bind only to loopback and use temporary
certificates; accepting those self-signed certificates is limited to the test
command. The SSO fixture uses a fresh cookie name and token on every run and
requires its own SSO endpoint to be visited, so old WebKit cookies cannot make
a case pass. Autofill is disabled. Existing browser sessions are not erased.

## Local HTTPS matrix (macOS)

```sh
swift build -c release --package-path auth
python3 tools/gateway-matrix-test.py
python3 tools/hostscan-sequence-test.py
```

To reproduce one case or test an older binary:

```sh
python3 tools/gateway-matrix-test.py --case reply-redirect --client /path/to/ocbar-auth
```

A redirect on the final auth reply must change `post_url` to the endpoint that
issued the session. This case detected a real client bug: previously the
client returned the endpoint from init even after following a later redirect.
The fixture also requires POST and its authentication body to reach that node.

## Real ocserv (macOS or Linux with Docker and OpenConnect)

```sh
docker build -t ocbar-test-ocserv:bookworm tools/server-lab
python3 tools/ocserv-integration-test.py --image ocbar-test-ocserv:bookworm

docker build --build-arg BASE=debian:trixie-slim -t ocbar-test-ocserv:trixie tools/server-lab
python3 tools/ocserv-integration-test.py --image ocbar-test-ocserv:trixie
```

Use `--openconnect /absolute/path/to/openconnect` if it is not on PATH.
Use `--mode password`, `--mode groups`, `--mode otp` or `--mode certificate`
to run one part (repeat the flag to combine parts). The default runs all 13
scenarios per server; `password` includes both container tunnel tests.
The runner publishes a random port on `127.0.0.1`, creates a disposable account,
trusts only its generated lab certificate and removes its containers and Docker
network in `finally`. The server and tunnel client get NET_ADMIN and a TUN device;
neither is privileged
and cannot modify host routes. Image build needs Debian package repositories.
Images are cached for later runs, containers are disposable.

Both Debian variants run in Linux CI; the TLS/WebKit matrix runs in macOS CI.
On 2026-10-10 the packaged versions tested were ocserv **1.1.6** (Bookworm)
and **1.3.0** (Trixie). Package revisions can change; each run prints the actual
server version. Configuration follows the
[ocserv manual](https://www.infradead.org/ocserv/manual.html).

## External checks

External accounts belong in local profiles and a secret store, never fixtures
or CI. Use a separate lab account and a scoped route to a test resource.
A successful authentication is not proof of a working tunnel: additionally
check the assigned interface, route, DNS and actual request through it.

For an authorized account, run the opt-in external test manually:

```sh
python3 tools/external-vpn-test.py de1.ocservvpn.com fr1.ocservvpn.com
```

It prompts for credentials without echo. `--credentials-stdin` accepts a JSON
object with `username` and `password` from a secret-store pipeline. Credentials
stay in process memory and container stdin; do not put them in shell arguments
or files. The test authenticates through the production driver on the host,
then independently authenticates and starts OpenConnect in a disposable Linux
container. Only routes to `1.1.1.1` and VPN-supplied DNS servers are added there.
It verifies HTTPS against Cloudflare's public trace endpoint with normal TLS
validation and resolves `example.com` through VPN DNS. Host routes are untouched.
The image must include `ca-certificates`; the route script applies the MTU
supplied by the VPN. Container failure makes the command exit nonzero.

On 2026-10-10, an authorized WorldVPN trial passed authentication on macOS and
Linux, routed HTTPS, and VPN DNS on `de1.ocservvpn.com` and `fr1.ocservvpn.com`.
The observed exit addresses matched the provider's published gateway addresses.
MTU was 1472; retaining the interface default of 1500 had caused HTTPS handshake
timeouts. Both runs used TLS for traffic; DTLS establishment was not observed.
This still does not test the macOS production helper or system DNS changes.
The external service is not part of unattended CI and trial credentials are
not retained in this repository.

## Live macOS profile checks (opt-in)

```sh
python3 tools/macos-vpn-test.py --live de1.ocservvpn.com fr1.ocservvpn.com
python3 tools/macos-vpn-test.py --live --mode proxy de1.ocservvpn.com fr1.ocservvpn.com
```

Unlike the container suites, tunnel mode changes live host routes and split
DNS. It requires ocbar to be disconnected, the installed NOPASSWD helper,
and an unused `/etc/resolver/example.com`. It temporarily stops the supervisor,
uses disposable profiles/config/user-state, adds only two host routes and one
resolver, then verifies removal and restores the supervisor. Personal profiles
are not edited. Credentials are prompted without echo and remain in memory.

The test checks route/interface MTU, native macOS name resolution, direct VPN
DNS, HTTPS, pause/resume, reconnect without another login, and disconnect
cleanup. HTTPS failures are recorded while the control checks continue, and
produce a nonzero final exit status. Proxy mode checks HTTPS by IP, remote
name resolution plus HTTPS, closed SOCKS port after disconnect, and unchanged
system routes/DNS. It never enables the system proxy.

`--dtls off` and `--mtu 1300` allow transport comparisons in tunnel mode.
`--preserve-route ADDRESS` adds an unrelated route to the before/after checks.
These tests are manual, not part of unattended CI.

Observed on the test Mac on 2026-10-11 (OpenConnect 9.21, helper 0.8.2):

- WorldVPN Germany/France: profile login, route installation, interface MTU,
  macOS split-DNS resolution and direct VPN DNS passed.
- HTTPS through the system tunnel timed out. Disabling DTLS and lowering the
  profile base MTU to 1300 or 1000 did not resolve the France failure; disabling
  DTLS also did not resolve the Germany failure. The gateway did not advertise
  a DTLS address, so these were TLS connections.
- France: pause, resume, reconnect and disconnect restored/removed routes and
  split DNS correctly, including after failed HTTPS probes.
- Germany: pause/resume and final cleanup passed. After a completed reconnect,
  DNS was unreliable: the native resolver timed out in one run and a direct
  query to the VPN DNS timed out in another. The test now waits for a new
  completed reconnect recorded by the helper, not a fixed two-second delay.
- Proxy profiles passed HTTPS and remote DNS on both gateways, and cleaned up
  their listening ports. The Linux container control also passed on France
  the same day. The cause of the system-tunnel HTTPS failure remains unresolved;
  these results do not establish a regression or identify the faulty component.

Services researched on 2026-10-10:

- [WorldVPN setup](https://www.worldvpn.net/how-to-setup-vpn) explicitly lists
  OpenConnect. Its [24-hour trial](https://www.worldvpn.net/free-trial) sends
  credentials by email and uses shared IPs. Two gateways passed the external
  checks above. The free app allowance is a separate
  offer and is not evidence that third-party clients can use it.
- [Cisco DevNet Sandbox](https://developer.cisco.com/docs/sandbox/first-reservation-guide/)
  provides AnyConnect access to reservation labs. An account and reservation
  are required; it is not an anonymous public VPN. The
  [FAQ](https://developer.cisco.com/docs/sandbox/faqs/) says the service is free
  and that the formal IVT program is not supported.

Public provider addresses alone are insufficient for a full test. The trial
was requested separately with the user's authorization; these test scripts do
not register accounts or purchase subscriptions. For a repeatable internet-hosted lab, deploy the same ocserv config on
a separately rented Linux VM with proper credentials and a trusted certificate;
the disposable local lab configuration is not a production deployment template.
