# Mirror FTP (read-only, eth0)

A second, independent protocol onto the **same mirror data** the `[vision_mirror]`
SMB share exposes, for clients on the main LAN where SMB isn't reliable enough.
Read-only; it cannot write to or delete anything in the mirror.

```
mirror (NVMe) ──┬─► SMB share (eth0, [vision_mirror])
                └─► Mirror FTP (eth0, vsftpd-mirror.service)
```

## How it works

- A second, independent `vsftpd` instance (`vsftpd-mirror.service`,
  `/etc/vsftpd-mirror.conf`) bound to `MIRROR_FTP_BIND_INTERFACE` (default
  `eth0`) — separate from the Ethernet-AOI ingest FTP on eth1
  (`docs/ethernet-aoi-ingest.md`); different interface, config file, systemd
  unit, and login list, so neither can ever see the other's users.
- `chroot_local_user=YES` + `local_root=$MIRROR_MOUNT`, `write_enable=NO`.
- `.state` (secrets: FTP/NAS creds, WebUI secret, Samba passdb) is hidden from
  listings (`hide_file={.state}`) and, more importantly, blocked from direct
  access by its own `0700` permission — the same defense-in-depth as the SMB
  share's `veto files`.
- Config-driven and **overlay-safe**: re-applied from `/etc/vision-gw.conf` on
  every boot by `install/80_configure_mirror_ftp.sh`, called from
  `apply-shadow-config.sh`.

## Authentication — shared with SMB, by design

Mirror FTP does **not** have its own user or password. It authenticates as
`SMB_USER` (default `smbuser`) using the **same password** as the SMB share.
This was a deliberate simplification: the mirror holds manufacturing images,
not sensitive data, so a second credential to configure and remember was pure
friction. (Trade-off worth knowing: FTP without TLS sends the password in
clear text on the wire, so anyone who can sniff the LAN during an FTP login
learns the same password that also grants SMB access — acceptable here given
the data, but a reason to keep this off an untrusted network segment.)

Two mechanisms make one WebUI password field drive both protocols, and both
are needed because Samba and PAM keep entirely separate credential stores:

1. Saving the SMB password (`POST /api/password/smb`) sets Samba's own
   `passdb.tdb` (`smbpasswd`) **and** the account's real Unix password
   (`chpasswd`), which is what vsftpd's PAM check (`pam_service_name=vsftpd`)
   actually reads.
2. The Unix/`/etc/shadow` copy lives on the **overlay root** and does not
   survive a reboot, unlike `passdb.tdb` (bind-mounted onto the NVMe by
   `50_configure_samba.sh`). So the plaintext is also persisted to
   `.state/smb_unix.creds` (`0600`, NVMe — same pattern as the ingest FTP's
   `ftp.creds`), and `80_configure_mirror_ftp.sh` re-applies it via `chpasswd`
   on every boot.

`SMB_USER`'s Unix home directory is also pointed at `$MIRROR_MOUNT` (not the
account's real home, which `50_configure_samba.sh` never creates) — vsftpd
`chdir()`s there before `chroot_local_user`/`local_root` take over, and would
otherwise fail login outright with `500 OOPS: cannot change directory`. Same
fix already used for the ingest FTP user in `70_configure_ingest.sh`.

## Configure it (WebUI)

**Mirror FTP (eth0, read-only)** section, directly below the SMB section:

- Mirror FTP enabled (default off).
- Bind interface (default `eth0`).
- Password: set/changed in the **SMB section above** — there is no separate
  password field here by design.

Save with the section's own **Save + Apply**.

## Config keys

| Key | Meaning |
|-----|---------|
| `MIRROR_FTP_ENABLED` | master switch (default `false`) |
| `MIRROR_FTP_BIND_INTERFACE` | interface to bind to (default `eth0`) |
| `MIRROR_FTP_PASV_MIN_PORT` / `MIRROR_FTP_PASV_MAX_PORT` | FTP passive port range (default `30021`-`30040`) |

`SMB_USER` (already used by the SMB share) is reused as the FTP login; there
is no `MIRROR_FTP_USER` key.

## Notes

- vsftpd is baked into the base image, same as the ingest FTP — enabling this
  later only writes config, not packages.
- Verified end-to-end (2026-07-21): FTP login, directory listing with `.state`
  hidden, write rejected (`550`), `.state` direct access rejected, and the
  shared credential surviving both a config-only redeploy and a full
  from-golden-image reflash.
