#!/bin/sh
set -eu
# Run as root from Certbot's deploy hook. Keep the private key readable only by Caddy.
lineage=${RENEWED_LINEAGE:-/etc/letsencrypt/live/47.129.137.212}
install -d -o root -g caddy -m 750 /etc/caddy/tls
install -o root -g caddy -m 640 "$lineage/fullchain.pem" /etc/caddy/tls/fullchain.pem
install -o root -g caddy -m 640 "$lineage/privkey.pem" /etc/caddy/tls/privkey.pem
systemctl reload caddy
