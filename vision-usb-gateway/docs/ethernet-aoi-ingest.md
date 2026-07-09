# Ethernet AOI ingest (FTP/SFTP on eth1)

Besides the USB-gadget path (for a host that writes to a USB drive), a unit can
accept files from an **Ethernet AOI** that pushes them directly over **FTP or
SFTP** onto the NVMe &mdash; NAS-like, no USB. This runs on the board's **second
Ethernet (eth1)**, kept isolated from the eth0 management/SMB side, consistent
with the project's separated-channels design.

```
Win98 AOI   ── USB gadget ──►  usb_0 ─ snapshot+sync ─►  mirror ─┐
                                                                 ├─► SMB (eth0)
Ethernet AOI ── eth1 (isolated) ── FTP/SFTP ──► ingest/data/ ────┘
```

## How it works

- **eth1**: a static IP on an isolated subnet (default `192.168.100.1/24`). The
  AOI connects to it.
- **FTP** (`vsftpd`) and **SFTP** (OpenSSH `internal-sftp`) both accept the same
  local user (`aoiftp`), **chrooted** to the ingest directory; the AOI writes
  into `data/`.
- Files land under `INGEST_DIR/data` on the NVMe mirror, are **served over the
  existing SMB share** (`\\<unit>\vision_mirror\ingest\data`), and are covered by
  **mirror retention** (oldest-first) so the NVMe never fills.
- Config-driven and **overlay-safe**: eth1, vsftpd, and the SFTP jail are
  re-applied from the config on every boot; the ingest password is a secret on
  the NVMe (`.state/ftp.creds`), never in the shell-sourced config.

## Configure it (WebUI)

**Ethernet AOI (FTP/SFTP ingest)** section:

- eth1: enabled, address, prefix, gateway (leave gateway empty when isolated).
- Ingest: enabled; FTP enabled; SFTP enabled; the FTP/SFTP user.
- **Set Ingest Password** (applied immediately + persisted for reboots).

Save with the main **Save + Apply**. The AOI then connects to eth1's IP with the
`aoiftp` user and password, and uploads via FTP or SFTP.

## Config keys

| Key | Meaning |
|-----|---------|
| `ETH1_ENABLED`, `ETH1_ADDRESS`, `ETH1_PREFIX`, `ETH1_GATEWAY` | eth1 static network |
| `INGEST_ENABLED` | master switch for the ingest path |
| `FTP_ENABLED`, `SFTP_ENABLED` | enable each protocol |
| `FTP_USER` | the ingest login (default `aoiftp`) |
| `INGEST_DIR` | ingest root on the NVMe (default `/srv/vision_mirror/ingest`) |
| `FTP_BIND_INTERFACE` | interface to bind FTP to (default `eth1`) |
| `FTP_PASV_MIN_PORT` / `FTP_PASV_MAX_PORT` | FTP passive port range |

The password is set via the WebUI (or `.state/ftp.creds`), not a config key.

## Notes

- vsftpd is baked into the base image (`00_prereqs`) so it survives the
  read-only overlay; enabling it later only writes config, not packages.
- The `aoiftp` user has a `nologin` shell and is jailed to `INGEST_DIR`; it can
  only read/write its `data/` directory over FTP/SFTP.
