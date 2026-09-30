#!/usr/bin/env bash
set -euo pipefail

# Unplugging eth0 and plugging it back in must decide network vs direct again,
# exactly like boot does — it used to need a reboot: the unplug branch deleted
# the shared (DHCP-server) profile and the decision was made only at boot, so a
# re-plugged laptop link stayed without any address.
#
# Time is simulated: `sleep` is stubbed to advance a tick counter, and a
# timeline file changes the carrier / the DHCP lease at given ticks. ip, nmcli,
# systemctl and systemd-run are stubbed and every nmcli / systemd-run call is
# recorded with the tick it happened at. Needs root (writes /run) + python3:
#   docker run --rm -v "$PWD:/gw:ro" python:3.11-slim-bookworm \
#     bash /gw/tests/functional/test_mdns_replug.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)

if [[ $(id -u) -ne 0 ]]; then
  echo "must run as root (the script writes /run/citostore-mdns.mode)" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
B="$TMP/bin"
mkdir -p "$B"

# --- stubs -------------------------------------------------------------------
cat > "$B/sleep" <<EOF
#!/bin/bash
t=\$(( \$(cat "$TMP/tick") + 1 )); echo "\$t" > "$TMP/tick"
# apply timeline events due at this tick: "<tick> carrier 0|1" / "<tick> lease <ip>|none"
while read -r at what val; do
  [[ "\$at" == "\$t" ]] || continue
  case "\$what" in
    carrier) echo "\$val" > "$TMP/carrier"
             [[ "\$val" == 0 ]] && : > "$TMP/addr" ;;
    lease)   [[ "\$val" == none ]] && : > "$TMP/addr" || echo "\$val" > "$TMP/addr" ;;
  esac
done < "$TMP/timeline"
exit 0
EOF
cat > "$B/ip" <<EOF
#!/bin/bash
if [[ "\$1" == "link" ]]; then
  if [[ "\$(cat "$TMP/carrier")" == 1 ]]; then echo "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
  else echo "2: eth0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500"; fi
  exit 0
fi
# ip -4 -o addr show dev eth0
while read -r a; do [[ -n "\$a" ]] && echo "2: eth0    inet \$a/24 brd x scope global eth0"; done < "$TMP/addr"
exit 0
EOF
cat > "$B/nmcli" <<EOF
#!/bin/bash
args="\$*"
case "\$args" in
  "-t -f NAME,DEVICE connection show --active") cat "$TMP/active"; exit 0 ;;
  "-g GENERAL.CONNECTION device show eth0")     cat "$TMP/devcon"; exit 0 ;;
  "-t -f NAME connection show")                  cat "$TMP/profiles"; exit 0 ;;
  "-g ipv4.method connection show "*)            echo auto; exit 0 ;;
esac
echo "t=\$(cat "$TMP/tick") nmcli \$args" >> "$TMP/calls"
case "\$args" in
  "connection up citostore-direct")
    [[ "\$(cat "$TMP/carrier")" == 1 ]] || exit 4
    echo "citostore-direct:eth0" > "$TMP/active"; echo citostore-direct > "$TMP/devcon"
    echo "10.10.10.1" > "$TMP/addr" ;;
  "connection down citostore-direct")
    : > "$TMP/active"; : > "$TMP/devcon" ;;
  "-w 5 connection up citostore-probe")
    echo citostore-probe > "$TMP/devcon" ;;
esac
exit 0
EOF
cat > "$B/systemctl" <<EOF
#!/bin/bash
[[ "\$1 \$2" == "is-active --quiet" ]] && { [[ -f "$TMP/wait_unit_active" ]]; exit; }
exit 0
EOF
cat > "$B/systemd-run" <<EOF
#!/bin/bash
echo "t=\$(cat "$TMP/tick") systemd-run \${*: -1}" >> "$TMP/calls"
EOF
printf '#!/bin/bash\nexit 0\n' > "$B/avahi-set-host-name"
chmod +x "$B"/*

# --- one case ------------------------------------------------------------------
# run_case <action> <carrier 0|1> <shared active 0|1> <network.json method|-> [timeline lines...]
run_case() {
  local action=$1 carrier=$2 shared=$3 method=$4; shift 4
  echo 0 > "$TMP/tick"; : > "$TMP/calls"; : > "$TMP/addr"
  echo "$carrier" > "$TMP/carrier"
  printf 'citostore-direct\nWired connection 1\n' > "$TMP/profiles"
  if [[ "$shared" == 1 ]]; then
    echo "citostore-direct:eth0" > "$TMP/active"; echo citostore-direct > "$TMP/devcon"
  else
    : > "$TMP/active"; : > "$TMP/devcon"
  fi
  rm -f "$TMP/network.json"
  [[ "$method" == "-" ]] || printf '{"interface": "eth0", "method": "%s"}' "$method" > "$TMP/network.json"
  printf '%s\n' "$@" > "$TMP/timeline"
  printf 'MDNS_ENABLED=true\nMDNS_INTERFACE=eth0\nMDNS_DIRECT_DHCP=true\nMDNS_DIRECT_SUBNET=10.10.10\nMDNS_NETWORK_WAIT_SEC=45\nNETBIOS_NAME=AOI1\n' > "$TMP/conf"
  PATH="$B:$PATH" CONF_FILE="$TMP/conf" NETWORK_STATE_FILE="$TMP/network.json" \
    timeout 20 bash "$GW/scripts/mdns-apply-mode.sh" "$action" >"$TMP/out" 2>&1 || echo "t=? EXIT $?" >> "$TMP/calls"
}
calls() { tr '\n' ';' < "$TMP/calls"; }
has_call() { grep -q -- "$1" "$TMP/calls" && echo yes || echo no; }
tick_of() { grep -- "$1" "$TMP/calls" | head -1 | sed -E 's/^t=([0-9?]+).*/\1/'; }

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

echo "=== unplug ==="
run_case down 0 1 -
check "serving DHCP, cable pulled -> DHCP server stopped" "$(has_call 'connection down citostore-direct')" yes
check "  ... shared profile kept (the next plug-in needs it)" "$(has_call 'connection delete citostore-direct')" no
check "  ... and a carrier wait is started" "$(has_call 'systemd-run carrier-wait')" yes

run_case down 0 0 -
check "DHCP client, cable pulled -> carrier wait started too" "$(has_call 'systemd-run carrier-wait')" yes

run_case down 0 1 manual
check "static IP, cable pulled -> no carrier wait (NM restores the fixed IP)" "$(has_call 'systemd-run')" no

run_case down 1 1 -
check "'down' with the cable still in (boot switching connections) -> nothing" "$(calls)" ""

touch "$TMP/wait_unit_active"
run_case down 0 0 -
check "a carrier wait already running -> no second one" "$(has_call 'systemd-run')" no
rm -f "$TMP/wait_unit_active"

run_case boot 0 0 -
check "no cable at boot -> deferred to a carrier wait" "$(has_call 'systemd-run carrier-wait')" yes

echo "=== plug back in ==="
run_case carrier-wait 0 0 - "5 carrier 1"
check "laptop plugged in (no DHCP server) -> direct mode, serving 10.10.10.1" "$(has_call 'connection up citostore-direct')" yes
check "  ... only after the full 45s probe" "$(( $(tick_of 'connection up citostore-direct') >= 5 + 45 ))" 1

run_case carrier-wait 0 0 - "5 carrier 1" "8 lease 192.168.1.77"
check "LAN plugged in (lease arrives) -> network mode, no DHCP server" "$(has_call 'connection up citostore-direct')" no

run_case carrier-wait 0 0 - "5 carrier 1" "15 carrier 0" "40 carrier 1"
check "pulled again mid-probe -> no decision on the dead link" "$(has_call 'connection up citostore-direct')" yes
check "  ... direct only after the cable came back + a full probe" "$(( $(tick_of 'connection up citostore-direct') >= 40 + 45 ))" 1

echo
if ((fail)); then echo "FAILED"; cat "$TMP/out"; exit 1; fi
echo "ALL PASSED"
