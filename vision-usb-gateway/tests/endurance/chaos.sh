#!/usr/bin/env bash
# Endurance chaos: reboots the board under full load every REBOOT_EVERY
# minutes and logs each one to events.log (board-monitor.sh takes a reboot
# that was not logged here as UNEXPECTED). MODE:
#   soft  systemctl reboot — what an operator or an update does; nothing that
#         the host was told is written may be lost.
#   hard  reboot -f -f — a crash with no shutdown at all: writes the host had
#         acknowledged in the last seconds may be lost or damaged (accepted:
#         the unit must come back on its own; verify-mirror.sh reports those
#         separately as "crash window").
set -uo pipefail

BOARD=${BOARD:-10.10.10.1}
OUT=${OUT:-/d/endurance-run}
REBOOT_EVERY=${REBOOT_EVERY:-240}
MODE=${MODE:-soft}

mkdir -p "$OUT"
sshb() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
      -o LogLevel=ERROR -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519" "citostore@$BOARD" "$@"
}
case "$MODE" in
  soft) cmd="sudo systemctl reboot" ;;
  hard) cmd="sudo systemctl reboot -f -f" ;;
  *) echo "MODE must be soft or hard" >&2; exit 1 ;;
esac

echo "chaos: $MODE reboot of $BOARD every ${REBOOT_EVERY} min"
while true; do
  sleep $(( REBOOT_EVERY * 60 ))
  echo "$(date -Is) REBOOT $MODE" >> "$OUT/events.log"
  sshb "$cmd" >/dev/null 2>&1 || true   # keepalive ends it once the board is gone
done
