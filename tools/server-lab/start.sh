#!/bin/sh
set -eu
# Only synthetic lab credentials; the container never receives user secrets.
printf '%s\n%s\n' 'lab-password' 'lab-password' | ocpasswd -c /tmp/ocpasswd lab-user
exec ocserv -f -c /lab/ocserv.conf
