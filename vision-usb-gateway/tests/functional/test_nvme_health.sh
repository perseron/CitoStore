#!/usr/bin/env bash
set -euo pipefail

# nvme-health.sh judges the NVMe's SMART log and feeds the health banner
# (nvme_health_issues -> vision-monitor). Before, nothing judged it: the
# drive's own failure flags and spare blocks were never read, the wear level
# was looked up under the wrong key, and the verdict lived only in the WebUI's
# status text. nvme-cli is stubbed with the JSON a WD SN850X gave on the unit
# (nvme-cli 2.4: big counters as "2,752,848" strings). Root + python3:
#   docker run --rm -v "$PWD:/gw:ro" python:3.11-slim-bookworm bash /gw/tests/functional/test_nvme_health.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GW=$(cd "$SCRIPT_DIR/../.." && pwd)
[[ $(id -u) -eq 0 ]] || { echo "run as root (in a container)" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"

HEALTHY='{"critical_warning":0,"temperature":303,"avail_spare":100,"spare_thresh":10,"percent_used":0,
"data_units_read":"2,752,848","data_units_written":"6,226,522","power_on_hours":"20","unsafe_shutdowns":"119",
"media_errors":"0","num_err_log_entries":"0"}'
cat > "$TMP/nvme" <<EOF
#!/bin/bash
case "\$1" in
  list) [[ -f $TMP/no_device ]] && { echo '{"Devices":[]}'; exit 0; }
        echo '{"Devices":[{"DevicePath":"/dev/nvme0n1","ModelNumber":"WD_BLACK SN850X 1000GB"}]}' ;;
  smart-log) [[ -f $TMP/smart_fails ]] && exit 1; cat $TMP/smart.json ;;
  id-ctrl) echo '{"wctemp":363,"cctemp":367}' ;;
esac
EOF
chmod +x "$TMP/nvme"

run() {  # <smart json, or "-" to keep>  -> runs nvme-health.sh
  [[ "$1" == "-" ]] || printf '%s' "$1" > "$TMP/smart.json"
  NVME_CLI=$TMP/nvme NVME_STATE_DIR=$TMP/state NVME_RUN_OUT=$TMP/nvme.json NVME_ISSUES_OUT=$TMP/nvme.issues \
    bash "$GW/scripts/nvme-health.sh"
}
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]))' "$TMP/nvme.json" "$1"; }
with() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d.update(json.loads(sys.argv[2])); print(json.dumps(d))' "$HEALTHY" "$1"; }

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; fail=1; fi; }

echo "=== verdicts ==="
run "$HEALTHY"
check "healthy drive -> ok, no issues" "$(field health):$(wc -l < "$TMP/nvme.issues")" "ok:0"
check "  ... raw log kept for the WebUI" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["smart"]["percent_used"])' "$TMP/nvme.json")" 0
check "  ... and on the NVMe" "$(test -s "$TMP/state/nvme.json" && echo yes)" yes
check "  ... the drive's own temperature limits (90/94 C)" "$(field limits)" "{'warn_c': 90, 'crit_c': 94}"
run "$(with '{"critical_warning": 4}')"
check "reliability degraded flag -> error" "$(cat "$TMP/nvme.issues")" "error|NVMe reports: reliability degraded (media or internal errors) - replace the SSD"
run "$(with '{"critical_warning": 8}')"
check "read-only flag -> error" "$(field health):$(grep -c READ-ONLY "$TMP/nvme.issues")" "error:1"
run "$(with '{"avail_spare": 9}')"
check "spare at/below its threshold -> error" "$(cat "$TMP/nvme.issues")" "error|NVMe spare blocks used up (9% left, minimum 10%) - replace the SSD"
run "$(with '{"critical_warning": 1, "avail_spare": 5}')"
check "  ... flagged by the drive too: reported once" "$(wc -l < "$TMP/nvme.issues")" 1
run "$(with '{"percent_used": 92}')"
check "wear 92% -> warn" "$(cat "$TMP/nvme.issues")" "warn|NVMe wear 92% of its rated write endurance - plan to replace the SSD"
run "$(with '{"percent_used": 105}')"
check "wear past 100% -> warn" "$(field health):$(grep -c 'used up (105%)' "$TMP/nvme.issues")" "warn:1"
run "$(with '{"media_errors": "3"}')"
check "media errors -> warn" "$(cat "$TMP/nvme.issues")" "warn|NVMe has 3 unrecovered media error(s) - data was unreadable; plan to replace the SSD"
run "$(with '{"temperature": 365}')"
check "above the drive's warning temperature -> warn" "$(cat "$TMP/nvme.issues")" "warn|NVMe at 92 C, above its warning limit (90 C) - check cooling"
run "$(with '{"temperature": 368}')"
check "above its critical temperature -> error" "$(field health)" "error"
run "$(with '{"temperature": 343}')"
check "70 C is normal for this drive -> ok" "$(field health)" "ok"
run "$(with '{"unsafe_shutdowns": "5,000", "num_err_log_entries": "12"}')"
check "power cuts and error-log entries alone -> ok (counters)" "$(field health)" "ok"

echo "=== no SMART at all ==="
touch "$TMP/smart_fails"; run -
check "SMART log unreadable -> error" "$(cat "$TMP/nvme.issues")" "error|NVMe: SMART log could not be read"
rm -f "$TMP/smart_fails"; touch "$TMP/no_device"; run -
check "no NVMe device -> error" "$(field health):$(cat "$TMP/nvme.issues")" "error:error|NVMe: no NVMe device found"
rm -f "$TMP/no_device"

echo "=== into the health banner (nvme_health_issues) ==="
# shellcheck source=/dev/null
source <(tr -d '\r' < "$GW/scripts/common.sh")
run "$(with '{"percent_used": 92}')"
check "fresh verdict passed on" "$(NVME_ISSUES_FILE=$TMP/nvme.issues nvme_health_issues)" \
  "warn|NVMe wear 92% of its rated write endurance - plan to replace the SSD"
touch -d '-45 min' "$TMP/nvme.issues"
check "verdict 45 min old -> said so, last verdict kept" "$(NVME_ISSUES_FILE=$TMP/nvme.issues nvme_health_issues | head -1)" \
  "warn|NVMe SMART last read 45 min ago"
check "none yet, 1 min after boot -> nothing" \
  "$(NVME_ISSUES_FILE=$TMP/none NVME_HEALTH_MAX_AGE_SEC=999999 nvme_health_issues)" ""
check "none, long after boot -> said so" \
  "$(NVME_ISSUES_FILE=$TMP/none NVME_HEALTH_MAX_AGE_SEC=0 nvme_health_issues)" "warn|NVMe SMART has not been read since boot"

echo
if ((fail)); then echo "FAILED"; exit 1; fi
echo "ALL PASSED"
