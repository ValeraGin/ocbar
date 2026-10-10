#!/bin/sh
set -eu
case "$reason" in
    connect)
        ip address add "$INTERNAL_IP4_ADDRESS/24" dev "$TUNDEV"
        ip link set "$TUNDEV" up
        printf '%s' "$INTERNAL_IP4_DNS" > /tmp/tunnel-dns
        touch /tmp/tunnel-ready
        ;;
    disconnect) rm -f /tmp/tunnel-ready ;;
esac
