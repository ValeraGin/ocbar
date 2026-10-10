#!/bin/sh
set -eu
# Only synthetic lab credentials; the container never receives user secrets.
printf '%s\n%s\n' 'lab-password' 'lab-password' | ocpasswd -c /tmp/ocpasswd -g employees lab-user
# liboath updates the last accepted counter; the mounted fixtures stay read-only.
cp /lab/otp.db /tmp/otp.db
chmod 600 /tmp/otp.db
if [ "${LAB_TRAFFIC:-0}" = 1 ]; then
    mkdir -p /tmp/web
    printf 'ocbar-tunnel-proof\n' > /tmp/web/proof.txt
    python3 -m http.server 8080 --directory /tmp/web > /tmp/http.log 2>&1 &
    dnsmasq --keep-in-foreground --bind-dynamic --listen-address=192.0.2.1 \
        --no-resolv --no-hosts --address=/lab.test/192.0.2.1 > /tmp/dns.log 2>&1 &
fi
exec ocserv -f -c /lab/ocserv.conf
