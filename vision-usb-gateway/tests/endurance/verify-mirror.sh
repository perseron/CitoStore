#!/usr/bin/env bash
# End-of-run (or any-time) integrity check of an endurance run.
#
# USB AOI (writer.csv): every file must have reached the sync DB. Retention
# deletes the oldest files from the mirror but keeps their DB rows (raw_path
# blanked), so "captured" = a DB row for its path; retention must also have
# deleted strictly oldest-first (no blanked row copied after the oldest file
# still on the mirror). A random sample of the files still there must match
# the writer's SHA256, with its bydate link on the same inode.
#
# Ethernet AOI (ftp-writer.csv): every upload the server accepted must be in
# ingest/, unless it is older than the oldest file still on the mirror (then
# retention took it, in turn). A sample is hash-checked too.
#
# Not counted as missing: files written in the last GRACE seconds (the sync's
# stability gate), and with MODE=hard reboots (events.log) the CRASH seconds
# before each crash — those writes were acknowledged but not on disk yet
# (accepted; reported separately). All host timestamps are compared on the
# host clock; the board's clock offset is measured and applied.
set -euo pipefail

BOARD=${BOARD:-10.10.10.1}
OUT=${OUT:-/d/endurance-run}
SAMPLE=${SAMPLE:-200}
GRACE=${GRACE:-180}
CRASH=${CRASH:-60}
NOW=$(date +%s)

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8
          -o LogLevel=ERROR -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519")
for f in writer.csv ftp-writer.csv events.log; do
  [[ -f "$OUT/$f" ]] || : > "$OUT/$f"
done
scp -q "${SSH_OPTS[@]}" "$OUT/writer.csv" "$OUT/ftp-writer.csv" "$OUT/events.log" "citostore@$BOARD:/tmp/"
ssh "${SSH_OPTS[@]}" "citostore@$BOARD" sudo GRACE="$GRACE" SAMPLE="$SAMPLE" NOW="$NOW" CRASH="$CRASH" python3 - <<'PY'
import csv, hashlib, os, random, re, sqlite3, sys, time
from datetime import datetime

M = "/srv/vision_mirror"
grace, sample_n, crash = int(os.environ["GRACE"]), int(os.environ["SAMPLE"]), int(os.environ["CRASH"])
host_now = int(os.environ["NOW"])
skew = time.time() - host_now          # board clock minus host clock (ssh delay included)

def host_ts(s):
    # PowerShell "o" has 7 fractional digits; Python takes 6.
    return datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", s.strip())).timestamp()

def rows(name):
    with open(f"/tmp/{name}", newline="") as f:
        return list(csv.DictReader(f)) if os.path.getsize(f"/tmp/{name}") else []

crashes = []
for line in open("/tmp/events.log"):
    parts = line.split()
    if len(parts) >= 3 and parts[1] == "REBOOT" and parts[2] == "hard":
        crashes.append(host_ts(parts[0]))
in_crash = lambda t: any(c - crash <= t <= c + 5 for c in crashes)

# The oldest arrival still on the mirror (board clock): raw/ by mtime,
# ingest/data by ctime — retention's own order.
oldest = float("inf")
def walk(top, ctime):
    global oldest
    stack = [top]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                    elif e.is_file(follow_symlinks=False):
                        st = e.stat(follow_symlinks=False)
                        oldest = min(oldest, st.st_ctime if ctime else st.st_mtime)
        except OSError:
            pass
walk(f"{M}/raw", False)
walk(f"{M}/ingest/data", True)

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

fail = False
print(f"board clock offset {skew:+.0f}s; oldest file on the mirror: "
      f"{datetime.fromtimestamp(oldest) if oldest != float('inf') else 'none'} (board clock)")

# --- USB AOI ---
w = rows("writer.csv")
db = sqlite3.connect(f"file:{M}/.state/vision.db?mode=ro", uri=True, timeout=30)
known = {}
for src, rawp, byd, synced in db.execute("SELECT source_path, raw_path, bydate_path, synced_at FROM synced_files"):
    known[src] = (rawp, byd, synced)
missing, fresh, crashed, on_mirror, deleted = [], 0, 0, [], []
for r in w:
    rel, t = r["relpath"].replace("\\", "/"), host_ts(r["ts"])
    if rel in known:
        rawp, byd, synced = known[rel]
        (on_mirror if rawp else deleted).append((r, rawp, byd, synced))
    elif t > host_now - grace:
        fresh += 1
    elif in_crash(t):
        crashed += 1
    else:
        missing.append(rel)
late_deletes = [d for d in deleted if (d[3] or 0) > oldest + 120]
# Every file the DB places on the mirror must be there (a cheap stat each);
# the content is checked on a sample below.
missing += [rawp for _, rawp, _, _ in on_mirror if not os.path.exists(rawp)]
bad, damaged = [], 0
for r, rawp, byd, _ in random.sample(on_mirror, min(sample_n, len(on_mirror))):
    try:
        if sha(rawp) != r["sha256"] or (byd and os.stat(byd).st_ino != os.stat(rawp).st_ino):
            if in_crash(host_ts(r["ts"])):
                damaged += 1          # written in the seconds before a crash: accepted
            else:
                bad.append(rawp)
    except OSError as e:
        bad.append(f"{rawp} ({e.strerror})")
print(f"USB AOI: written {len(w)}  captured {len(on_mirror) + len(deleted)} "
      f"(on the mirror {len(on_mirror)}, deleted by retention {len(deleted)})  MISSING {len(missing)}  "
      f"too fresh {fresh}  crash window {crashed}")
print(f"  hash+bydate sample: {min(sample_n, len(on_mirror))} checked, {len(bad)} bad"
      f"{f', {damaged} damaged in a crash window' if damaged else ''};  deleted out of order: {len(late_deletes)}")
for x in missing[:10]: print("  missing:", x)
for x in bad[:10]: print("  BAD:", x)
for d in late_deletes[:5]: print("  deleted although newer than the oldest kept:", d[0]["relpath"])
fail |= bool(missing or bad or late_deletes)

# --- Ethernet AOI ---
fw = rows("ftp-writer.csv")
present, missing, fresh, crashed, gone, bad = [], [], 0, 0, 0, []
for r in fw:
    p, t = f"{M}/ingest/{r['relpath']}", host_ts(r["ts"])
    if os.path.exists(p):
        present.append((r, p))
    elif t + skew <= oldest + 30:
        # Not newer than the oldest file kept: retention took it in turn
        # (30 s: the clock offset is measured over ssh, the ts taken after STOR).
        gone += 1
    elif t > host_now - grace:
        fresh += 1
    elif in_crash(t):
        crashed += 1
    else:
        missing.append(r["relpath"])
for r, p in random.sample(present, min(sample_n, len(present))):
    if sha(p) != r["sha256"]:
        bad.append(p)
print(f"Ethernet AOI: uploaded {len(fw)}  on the mirror {len(present)}  deleted by retention {gone}  "
      f"MISSING {len(missing)}  too fresh {fresh}  crash window {crashed}")
print(f"  hash sample: {min(sample_n, len(present))} checked, {len(bad)} bad")
for x in missing[:10]: print("  missing:", x)
for x in bad[:10]: print("  BAD:", x)
fail |= bool(missing or bad)

print("VERIFY", "FAILED" if fail else "PASSED")
sys.exit(1 if fail else 0)
PY
