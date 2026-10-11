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
By default, the runner removes uppercase and lowercase HTTP/HTTPS/ALL/NO_PROXY
variables from the VPN process environment. User-mode OpenConnect may otherwise
use an upstream proxy that the sudo helper does not inherit. For a separate
proxy-mode comparison, use `--mode proxy --inherit-proxy-env`; this explicitly
allows the existing proxy environment and is not equivalent to a direct tunnel
test. Neither variant changes system proxy settings. The network-free
`tools/macos-vpn-test-selftest.py` checks the environment passed to the CLI.
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
- Proxy profiles initially passed HTTPS and remote DNS on both gateways, and
  cleaned up their listening ports. Those runs inherited a local upstream proxy,
  so they were not an equal-path comparison with the system tunnel. Both gateways
  subsequently failed in proxy mode with that environment removed (SOCKS request
  failure, curl exit 97) and passed again when inheritance was explicitly enabled.
  A socket inspection confirmed a direct connection to the Germany gateway
  during its failing run. The Linux container control
  also passed on France the same day, using a separate container network path.
  These results do not establish a helper defect or a regression.
- A scoped packet-header capture on France showed a successful TCP handshake
  and bidirectional TLS traffic, followed by unacknowledged small packets and
  unanswered new connection attempts. Checksums were valid. Disabling ECN on
  the first test socket did not resolve the stall; a later TCP_NOOPT probe also
  timed out. These were per-socket tests, not changes to macOS TCP settings.
  The exact reason the direct network path stalls remains unresolved.

## Installed macOS helper against controlled ocserv (opt-in)

```sh
python3 tools/macos-ocserv-test.py --live
python3 tools/macos-ocserv-test.py --live --tls 1.3
```

This manual suite connects the installed root helper/OpenConnect directly to
disposable ocserv containers published on loopback. It requires an initially
disconnected VPN, Docker images built above, the installed NOPASSWD helper and
an unused `native.lab.test` resolver. Authentication uses the production password
driver with a temporary lab CA; the verified session and certificate pin go to
the helper. This is not a profile/UI test and does not add private-CA support to
profiles. User credentials and the system trust store are not used.

The suite stops/restores the supervisor, temporarily routes only `192.0.2.1/32`
through the native utun and installs `native.lab.test` split DNS. It checks direct
VPN DNS, the macOS resolver, HTTP and certificate-verified HTTPS, comparing SHA-256
of each 1 MiB response. All checks repeat after pause/resume and reconnect with
the same session. The server HTTP log must confirm the three successful requests.
Disconnect/failure cleanup verifies restoration of baseline routes and removal
of the resolver; containers and networks are removed. `--preserve-route ADDRESS`
adds an unrelated route to the restoration checks.

Both server images and compression modes (`none`, negotiated LZS) run by default;
repeat `--image` or `--compression` to select a subset. `--tls 1.2` or `--tls 1.3`
requires that outer VPN TLS version and checks what was actually negotiated.
DTLS is disabled in this native suite; the separate Linux suite covers DTLS.
The macOS resolver is allowed up to five seconds to observe resolver-file changes;
fresh probe names avoid passing from an earlier cached answer.

On 2026-10-11, installed helper 0.8.2/OpenConnect 9.21 passed both ocserv 1.1.6
and 1.3.0, with no compression and LZS, first with the servers' default TLS 1.2
and then forced TLS 1.3: eight combinations, 24 traffic phases and 48 verified
1 MiB HTTP/HTTPS responses. Server logs confirmed the HTTP requests. The immediate
resolver check initially failed after resume; readiness checks observed recovery
in approximately 0.5–0.6 seconds. This transient is distinct from an unanswered
direct VPN DNS query. All routes/resolvers and the supervisor were restored.

The external WorldVPN stall was not reproduced on this controlled local path,
including TLS 1.3 with LZS and the same interface MTU 1378. This rules out a
blanket claim that these helper/transport combinations cannot carry traffic;
it does not identify the cause on the external path or certify every server.

## External gateway through another network (opt-in)

```sh
python3 tools/macos-path-test.py --live --ssh-via my-test-host fr1.ocservvpn.com de1.ocservvpn.com
```

Use an authorized SSH alias with TCP forwarding enabled. The test keeps the
same installed macOS helper/OpenConnect and compares direct access, access
through a temporary SSH local forward, then direct access again. Finally, a
local TCP forward without SSH controls for the loopback endpoint/SNI rewrite.
`--local-control-only` runs just that last check. No software, services or routes
are changed on the SSH host; its outgoing TCP connection provides another
network path. This tests TCP/TLS only, not DTLS or native UDP through that network.

Credentials are prompted without echo and kept in memory. For forwarded
authentication, OpenConnect's `--resolve` directs the real VPN hostname to the
local listener while normal PKI validates the hostname. The helper then uses
the verified pin for its loopback endpoint. Unexpected authentication redirects
or missing pins are rejected. Five network-free checks in
`tools/macos-path-test-selftest.py` cover that boundary and credential redaction.

The runner requires a disconnected VPN, temporarily stops the supervisor and
adds only `1.1.1.1/32`, `8.8.8.8/32` and the `example.com` resolver. Each path
gets a fresh VPN session, direct and native DNS probes, and two HTTPS trace
requests. Routes, resolver, forwarding listeners and supervisor are restored.
Any failed traffic check makes the final exit code nonzero, including when
failures are the expected result of a path comparison. An explicit proxy
environment cannot silently affect authentication or the HTTPS probes.

On 2026-10-11 both WorldVPN gateways showed the same pattern:

| Path | France | Germany |
| --- | --- | --- |
| Direct, before SSH | Both HTTPS probes timed out | Both HTTPS probes timed out |
| Through an independent VDS SSH connection | Both passed; exit 51.68.89.73 | Both passed; exit 116.203.253.222 |
| Direct, after SSH | Both HTTPS probes timed out | Both HTTPS probes timed out |
| Local TCP forward, without VDS | Both HTTPS probes timed out | Both HTTPS probes timed out |

Authentication and both DNS probes passed on every path. All tunnels used
helper 0.8.2/OpenConnect 9.21, TLS 1.3 + LZS, MTU 1378, with DTLS disabled.
The independent VDS's own egress and direct routes to both gateways were checked
before testing. The local-forward control reproduced the failure even with a
loopback helper endpoint. This demonstrates path-dependent behavior and shows
that the native helper can carry traffic to these external servers. It does
not establish which intermediate device, filtering policy, packet behavior or
server-side source-address policy causes the direct-path stall. SSH changes
both the upstream source address and the encapsulation of the first network leg.

## Provider options

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

## Explicit upstream proxy

`python3 tools/upstream-proxy-test.py` runs six local synthetic checks with the
real SSO binary: HTTP CONNECT and SOCKS5 success, refusal before gateway init,
and refusal at the WebKit stage. The `.invalid` gateway name only resolves in
the test relay. Gateway peer ports must all belong to the relay; ambient proxy
variables are cleared and `NO_PROXY=*` deliberately tests explicit precedence.
These are protocol tests, not a production SSO vendor certification.

CLI/helper self-tests cover parsing, both authentication command lines, the
helper spec, user-mode transport, forced `--no-dtls`, invalid URLs and the helper
version guard. Without the feature the added CLI checks fail (16 failures),
helper checks fail (8 failures), and the live SSO check rejects the unknown flag.

Manual external comparison, with inherited proxy variables removed:

```sh
python3 tools/macos-vpn-test.py --live --mode proxy \
  --upstream-proxy http://127.0.0.1:10808 \
  --preserve-route 192.168.188.20 fr1.ocservvpn.com de1.ocservvpn.com
```

The October 11, 2026 user-mode runs passed profile password login, remote DNS
and HTTPS on both gateways with HTTP CONNECT and SOCKS5, with the VPN gateway
as the reported exit address. They restored the supervisor and original routes
after disconnect. A native `--mode tunnel`
run additionally requires installed helper 0.8.3; an old helper is rejected
before authentication so it cannot silently ignore the upstream spec.

After installing helper 0.8.3 on October 11, 2026, the same profile workflow
also passed in native `--mode tunnel` with both HTTP CONNECT and SOCKS5:

```sh
python3 tools/macos-vpn-test.py --live --mode tunnel \
  --upstream-proxy http://127.0.0.1:10808 \
  --preserve-route 192.168.188.20 fr1.ocservvpn.com de1.ocservvpn.com
# Repeat with --upstream-proxy socks5://127.0.0.1:10808.
```

All 12 native phases passed (two gateways × two upstream protocols × connect,
resume and forced reconnect). Each phase checked utun routes, macOS resolution,
direct VPN DNS and HTTPS through the native interface. HTTPS reported the
expected gateway exit: France 51.68.89.73, Germany 116.203.253.222. The interface
MTU was 1378, SSL/LZS was connected and DTLS remained disabled, even though the
profile requested `Dtls = on`. Inherited proxy environment was cleared.
Pause removed the test routes and split DNS; resume/reconnect restored them.
Final disconnect removed the test resolver, restored baseline routes and
restarted the original supervisor. The unrelated TV-lab route was preserved.
These checks cover the tested external split-tunnel profiles; they do not
certify every gateway or proxy implementation.
