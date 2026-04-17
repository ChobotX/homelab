#!/usr/bin/env bash
# Rotate the homelab's WireGuard private key.
# After this, paste the new pubkey printed below into the hub's peer entry and
# reload the hub's WG (`wg syncconf`).
set -euo pipefail
umask 077

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

pk=/etc/wireguard/privatekey
pub=/etc/wireguard/publickey

[ -s "$pk" ] || { echo "$pk missing — run bootstrap.sh first" >&2; exit 1; }

backup="${pk}.bak.$(date +%s)"
cp -a "$pk" "$backup"
wg genkey > "$pk"
chmod 0600 "$pk"
wg pubkey < "$pk" > "$pub"
chmod 0644 "$pub"

echo "Old key backed up at $backup"
echo
echo "New homelab WG pubkey (paste into hub's [Peer] block for homelab):"
cat "$pub"
echo
echo "Then reload WG on the hub:"
echo "  sudo wg syncconf wg0 <(sudo wg-quick strip wg0)"
echo
echo "Once the hub is updated, restart the tunnel here:"
echo "  sudo systemctl restart wg-quick@wg0"
