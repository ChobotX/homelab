# Adding a new WireGuard peer

The hub is managed outside this repo — peer add is a hub-side change.

## Add a new client (laptop, phone, another server)

### On the client

Generate keypair:
```bash
wg genkey | tee client_private.key | wg pubkey > client_public.key
```
Or use the WireGuard mobile app's "Generate from scratch" option.

Client config (`wg0.conf`):
```
[Interface]
PrivateKey = <client private key>
Address = 10.8.0.X/32       # pick a free IP in the hub's subnet
DNS = 10.8.0.1              # if hub runs DNS, otherwise omit

[Peer]
PublicKey = <hub public key>
Endpoint = hub.example.com:51820
AllowedIPs = 10.8.0.0/24    # only VPN subnet, NOT 0.0.0.0/0
PersistentKeepalive = 25
```

### On the hub

```bash
sudo tee -a /etc/wireguard/wg0.conf <<'EOF'

[Peer]
# <descriptive name — who/what this peer is>
PublicKey = <client public key>
AllowedIPs = 10.8.0.X/32
EOF

sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
sudo wg show
```

## Rotating the homelab WG key

On the homelab:
```bash
sudo /opt/homelab/scripts/rotate-wg-key.sh
```
Paste the new pubkey (printed by the script) into the homelab's `[Peer]` entry on the hub, reload the hub's WG as above, then restart the tunnel locally.

## Removing a peer

Delete the `[Peer]` block on the hub, then `wg syncconf` as above.
