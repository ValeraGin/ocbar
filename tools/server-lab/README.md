# Server compatibility lab

The supported protocol is AnyConnect. OpenConnect supports other protocols,
but ocbar currently selects `--protocol=anyconnect`; these tests make no claims
about GlobalProtect, Fortinet, Pulse, OpenVPN or WireGuard.

## Three independent layers

| Suite | What runs | What it verifies |
| --- | --- | --- |
| `tools/gateway-matrix-test.py` | Real ocbar-auth + WebKit against synthetic HTTPS gateways | SSO, custom cookie names, opaque round-trip, nested certificate hash, GET/POST/final-reply redirects (including host changes), client-certificate fallback, protocol/server/TLS errors |
| `tools/hostscan-sequence-test.py` | Real ocbar-auth + external wrapper against a synthetic HTTPS gateway | Report submission, waiting, original HostScan token, wrapper failures, paths with spaces, non-default port |
| `tools/ocserv-integration-test.py` | Production password driver + real OpenConnect + real ocserv | Stored/manual password, wrong password then cancellation, initial cancellation, untrusted server certificate, groups, password + TOTP, client certificate, isolated CSTP tunnel with HTTP and DNS |

The first two are protocol fixtures, **not certified emulations of Cisco
firmware**. The third uses actual servers and a second disposable container
as a VPN client. It obtains a session through the production password driver,
passes the cookie to OpenConnect over stdin, checks that the route uses its TUN
interface, fetches an HTTP resource, and queries the DNS address supplied by
ocserv. None of these tests starts the host VPN. DTLS is disabled in the tunnel
test; it verifies CSTP over TLS. Helper routing tests remain in
`tools/helper-selftest.sh`.

The ocserv runner supplies `--cafile` directly to OpenConnect and exercises
`ocbar-pwauth.py`, not the complete profile-to-tunnel workflow. The current
profile/CLI does not expose a CA file, `--authgroup` or a client certificate.
Those configurations are therefore not declared supported through profiles by
this suite. Groups are tested both with explicit selection and with the expected
refusal when selection is missing. TOTP checks a real code and cancellation;
certificate authentication checks presence and absence of a client certificate.
The tunnel uses a minimal Linux route script, not the production macOS helper.
System DNS configuration on macOS, DTLS, and the complete profile-to-tunnel
workflow remain separate coverage gaps.

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
to run one part (repeat the flag to combine parts). The default runs all 12
scenarios per server; `password` includes the container tunnel test.
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

Candidate services researched on 2026-10-10 (not yet tested with ocbar):

- [WorldVPN setup](https://www.worldvpn.net/how-to-setup-vpn) explicitly lists
  OpenConnect. Its [24-hour trial](https://www.worldvpn.net/free-trial) sends
  credentials by email and uses shared IPs. Unauthenticated init probes to
  two published gateways on 2026-10-10 reached a username form; successful
  sign-in and tunnel traffic have not been verified. The free app allowance is a separate
  offer and is not evidence that third-party clients can use it.
- [Cisco DevNet Sandbox](https://developer.cisco.com/docs/sandbox/first-reservation-guide/)
  provides AnyConnect access to reservation labs. An account and reservation
  are required; it is not an anonymous public VPN. The
  [FAQ](https://developer.cisco.com/docs/sandbox/faqs/) says the service is free
  and that the formal IVT program is not supported.

Public provider addresses alone are insufficient for a full test. No account
has been registered, no trial requested and no subscription purchased by these
scripts. For a repeatable internet-hosted lab, deploy the same ocserv config on
a separately rented Linux VM with proper credentials and a trusted certificate;
the disposable local lab configuration is not a production deployment template.
