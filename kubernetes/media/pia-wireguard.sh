#!/usr/bin/env bash
# Registers a WireGuard key with PIA and stores the gluetun settings in OpenBao (kv/media/qbittorrent).
# gluetun has no native PIA WireGuard support: it runs as the `custom` provider with this config, and
# uses its native PIA port forwarding (needs the PIA login + SERVER_NAMES = the server's cn).
#
# Run it again to change region/server, or when the tunnel stops handshaking (PIA can drop a key left unused).
#   PIA_REGION=nl_amsterdam kubernetes/media/pia-wireguard.sh     # regions with port forwarding: README media notes
# Prompts for the PIA account login (p1234567, not the x… SOCKS login), its password and an OpenBao token
# (bao.fgdou.ovh, user menu → Copy token). Nothing secret is printed.
set -euo pipefail
REGION=${PIA_REGION:-nl_amsterdam}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

read -rp "PIA username (p…): " PIA_USER
read -rsp "PIA password: " PIA_PASS; echo
read -rsp "OpenBao token: " BAO_TOKEN; echo
export PIA_USER PIA_PASS

curl -fsS -m 20 -o "$tmp/ca.crt" https://raw.githubusercontent.com/pia-foss/manual-connections/master/ca.rsa.4096.crt
token=$(curl -fsS -m 20 -X POST --form-string "username=$PIA_USER" --form-string "password=$PIA_PASS" \
  https://www.privateinternetaccess.com/api/client/v2/token | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["token"])')

read -r WG_IP WG_CN < <(curl -fsS -m 20 https://serverlist.piaservers.net/vpninfo/servers/v6 | head -1 | python3 -I -c '
import json, random, sys
r = [r for r in json.load(sys.stdin)["regions"] if r["id"] == sys.argv[1]]
if not r or not r[0]["port_forward"]: sys.exit("region %s unknown or without port forwarding" % sys.argv[1])
s = random.choice(r[0]["servers"]["wg"]); print(s["ip"], s["cn"])' "$REGION")
echo "region $REGION, server $WG_CN ($WG_IP)"

PRIV=$(wg genkey); export PRIV WG_CN
curl -fsS -m 20 -G --connect-to "$WG_CN::$WG_IP:" --cacert "$tmp/ca.crt" \
  --data-urlencode "pt=$token" --data-urlencode "pubkey=$(wg pubkey <<<"$PRIV")" "https://$WG_CN:1337/addKey" \
| python3 -I -c '
import json, os, sys
r = json.load(sys.stdin)
if r.get("status") != "OK": sys.exit("addKey failed: %s" % r.get("status"))
json.dump({
  "WIREGUARD_PRIVATE_KEY": os.environ["PRIV"],
  "WIREGUARD_PUBLIC_KEY": r["server_key"],
  "WIREGUARD_ADDRESSES": r["peer_ip"] + "/32",
  "VPN_ENDPOINT_IP": r["server_ip"],
  "VPN_ENDPOINT_PORT": str(r["server_port"]),
  "SERVER_NAMES": os.environ["WG_CN"],
  "VPN_PORT_FORWARDING_USERNAME": os.environ["PIA_USER"],
  "VPN_PORT_FORWARDING_PASSWORD": os.environ["PIA_PASS"],
}, open(sys.argv[1], "w"))' "$tmp/kv.json"

{ printf '%s\n' "$BAO_TOKEN"; cat "$tmp/kv.json"; } \
| kubectl -n openbao exec -i openbao-0 -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; bao kv put kv/media/qbittorrent - >/dev/null && echo "kv/media/qbittorrent written"'

if kubectl -n media get externalsecret qbittorrent >/dev/null 2>&1; then
  kubectl -n media annotate externalsecret qbittorrent force-sync="$(date +%s)" --overwrite >/dev/null
  echo "ExternalSecret refreshed; restart: kubectl -n media rollout restart deploy/qbittorrent"
fi
