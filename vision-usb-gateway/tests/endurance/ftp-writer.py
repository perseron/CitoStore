"""Endurance writer for the Ethernet AOI: uploads unique files to the unit's eth1
address, FTP and SFTP in turn, and records every upload the server accepted
(name, SHA256, path under ingest/) in ftp-writer.csv for verify-mirror.sh.

Like the AOI it never stops on an error (the unit rebooting, the link down):
it logs to alerts.log (throttled), drops the connections, waits, reconnects.

    python ftp-writer.py --host 192.168.2.250 [--interval 5] [--size-kb 1024]
"""
import argparse
import datetime as dt
import ftplib
import hashlib
import io
import os
import time
import uuid

import paramiko


def append(path: str, line: str) -> None:
    # Shared with the monitor (wc -l) and the other writer (alerts.log).
    for _ in range(5):
        try:
            with open(path, "a", encoding="ascii", newline="\n") as f:
                f.write(line + "\n")
            return
        except OSError:
            time.sleep(0.2)


class Uploader:
    def __init__(self, host: str, user: str, password: str):
        self.host, self.user, self.password = host, user, password
        self.ftp = None
        self.sftp = None
        self.transport = None

    def close(self) -> None:
        for closer in (lambda: self.ftp.close(), lambda: self.sftp.close(), lambda: self.transport.close()):
            try:
                closer()
            except Exception:
                pass
        self.ftp = self.sftp = self.transport = None

    def put_ftp(self, rel: str, data: bytes) -> None:
        if self.ftp is None:
            self.ftp = ftplib.FTP(self.host, timeout=20)
            self.ftp.login(self.user, self.password)
        self.ftp.cwd("/data")              # the FTP root is ingest/, uploads go to data/
        *dirs, name = rel.split("/")
        for d in dirs:
            try:
                self.ftp.cwd(d)
            except ftplib.error_perm:
                self.ftp.mkd(d)
                self.ftp.cwd(d)
        self.ftp.storbinary(f"STOR {name}", io.BytesIO(data))

    def put_sftp(self, rel: str, data: bytes) -> None:
        if self.sftp is None:
            self.transport = paramiko.Transport((self.host, 22))
            self.transport.banner_timeout = 20
            self.transport.connect(username=self.user, password=self.password)
            self.sftp = paramiko.SFTPClient.from_transport(self.transport)
            self.sftp.get_channel().settimeout(20)
        # The SFTP session starts in data/ (ForceCommand internal-sftp -d /data).
        *dirs, _ = rel.split("/")
        path = ""
        for d in dirs:
            path = f"{path}/{d}" if path else d
            try:
                self.sftp.stat(path)
            except IOError:
                self.sftp.mkdir(path)
        self.sftp.putfo(io.BytesIO(data), rel)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", default="aoiftp")
    ap.add_argument("--password", default="citostore")
    ap.add_argument("--interval", type=float, default=5.0, help="seconds between uploads")
    ap.add_argument("--size-kb", type=int, default=1024)
    ap.add_argument("--hours", type=float, default=0, help="0 = until stopped")
    ap.add_argument("--out", default=r"D:\endurance-run")
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    csv_path = os.path.join(a.out, "ftp-writer.csv")
    alerts = os.path.join(a.out, "alerts.log")
    werrs = os.path.join(a.out, "write-errors.log")
    if not os.path.exists(csv_path):
        append(csv_path, "ts,name,sha256,bytes,proto,relpath")
    up = Uploader(a.host, a.user, a.password)
    body = bytearray(os.urandom(a.size_kb * 1024))
    deadline = time.time() + a.hours * 3600 if a.hours else float("inf")
    i, fails, fail_since, alerted = 0, 0, 0.0, 0.0
    print(f"ftp-writer: {a.host} one {a.size_kb} KB file every {a.interval}s (FTP/SFTP in turn), log: {csv_path}")
    while time.time() < deadline:
        i += 1
        proto = "ftp" if i % 2 else "sftp"
        now = dt.datetime.now()
        name = f"EP_{now:%Y%m%d_%H%M%S}_{i:06d}.bmp"
        rel = f"EP/{now:%Y-%m-%d}/{proto.upper()}/{name}"
        body[:64] = f"{name}|{uuid.uuid4()}".ljust(64)[:64].encode()
        data = bytes(body)
        try:
            (up.put_ftp if proto == "ftp" else up.put_sftp)(rel, data)
            append(csv_path, f"{dt.datetime.now().astimezone().isoformat()},{name},"
                             f"{hashlib.sha256(data).hexdigest()},{len(data)},{proto},data/{rel}")
            fails = 0
        except Exception as exc:  # noqa: BLE001 - the AOI never stops
            # Expected during a reboot (the AOI retries): write-errors.log, one
            # line per streak. ALERT only for an outage of 5 min (then every 10).
            fails += 1
            stamp = dt.datetime.now().astimezone().isoformat()
            if fails == 1:
                fail_since = alerted = time.time()
                append(werrs, f"{stamp} ftp-writer: {proto} upload failed for {name}: {type(exc).__name__}: {exc}")
            elif time.time() - alerted >= (300 if alerted == fail_since else 600):
                alerted = time.time()
                append(alerts, f"{stamp} ALERT ftp-writer: no upload accepted for {time.time() - fail_since:.0f}s "
                               f"({fails} attempts): {type(exc).__name__}: {exc}")
            up.close()
            time.sleep(5)
        time.sleep(a.interval)
    up.close()
    print(f"ftp-writer: done ({i} uploads attempted)")


if __name__ == "__main__":
    main()
