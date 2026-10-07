# Zimbra Migration Script Walkthrough

## Migration Flow

1. **Full backup (source)**: `JOBS=4 ./migrate.sh backup contoh.com`
   - Verifies the domain exists (exact match).
   - Asks for the mailbox method and whether to compress.
   - Writes `backup_version.txt` (script version, start date, start epoch).
   - Exports account lists, distribution lists, account data and mailboxes.
2. **Transfer**: copy `contoh.com-backup.tar.gz` to the target and extract it into `/opt/zimbra/backup/`.
3. **Restore (target)**: `JOBS=4 ./migrate.sh restore contoh.com`
   - Offers to create the domain if it is missing, then continues.
   - Restores in phases: accounts → mailboxes → alias/signature/filter/forwarding → distribution lists → list members.
   - Asks whether to delete the backup directory at the end.
4. **Cutover**: switch MX/DNS to the target server.
5. **Delta backup (source)**: `./migrate.sh backup-delta contoh.com`
   - Press Enter to use the full backup start time, or type an epoch in seconds or milliseconds.
6. **Delta restore (target)**: extract `contoh.com-backup-delta.tar.gz` into `/opt/zimbra/backup/`, then `./migrate.sh restore-delta contoh.com`.

## Mailbox Backup & Restore Methods

### Methods Supported
- **`zmmailbox`**: Native Zimbra CLI tool executed as the `zimbra` system user. Supports delta synchronization using start epoch timestamps.
- **`curl`**: REST API call over HTTPS (port 7071) authenticated with admin credentials. Credentials are passed through a config file descriptor, so the password is not visible in `ps`.

> [!NOTE]
> `curl` cannot set start time on mailbox exports. For delta backups filtering by start timestamp, `zmmailbox` must be used.

> [!IMPORTANT]
> The REST `start` parameter is in **milliseconds**. Since v1.3.0 `backup-delta` converts a seconds value (10 digits or fewer) automatically. Before v1.3.0 a seconds value was read as a 1970 timestamp, so the delta contained the whole mailbox.

### Variables
- `ZIMBRA_ADMIN_USER`: Zimbra administrator username (e.g. `admin@domain.com`).
- `ZIMBRA_ADMIN_PASSWORD`: Zimbra administrator password (hidden input via `read -rs`).
- `ZIMBRA_HOST`: Zimbra host (defaults to `localhost`).
- `JOBS`: number of accounts processed in parallel (defaults to `1`).
- `BASE_DIR`, `LOG_FILE`, `TMP_PASSWORD`: backup root, log file and initial account password.

## Performance

### Fewer `zmprov` calls
Each `zmprov` call starts a JVM (roughly 1–2 s), so the call count dominates the time spent outside mailbox transfers.

| Phase                          | v1.2.0 calls per account | v1.3.0 calls per account |
| ------------------------------ | ------------------------ | ------------------------ |
| Backup account data            | 7                        | 1                        |
| Restore signature/filter/forward | 6 + 1 per forward      | 3                        |
| Restore distribution list members | 1 per member          | 1 per list               |

The backup uses one `zmprov -l ga <account> <attributes...>` call and splits the output with `awk` into the same files as before (`userpass/`, `userdata/`, `alias/`, `forward/`, `signature/`, `filter/`), so v1.3.0 can restore v1.2.0 backups and the other way around.

### Parallel processing
With `JOBS=N`, every per-account phase (account data, mailbox export/import, account creation, settings, distribution lists) runs `N` accounts at a time through `xargs -P`. Phases still run in order, so all accounts exist before mailboxes are imported, and all lists exist before members are added.

## Error Handling

- Mailbox exports are written to `<account>.tgz.part` and renamed only on success, so a failed export never leaves a file that looks valid.
- Failed accounts are appended to `failed_mailbox_backup.txt`, `failed_mailbox_restore.txt`, `failed_mailbox_delta.txt` or `failed_mailbox_delta_restore.txt` in the backup directory, and a summary is logged at the end of the phase. The file is removed when nothing failed.
- If the combined `zmprov ma` for signature/filter/forwarding fails, each setting is retried separately.
- If a bulk `zmprov adlm` fails, each member is retried separately.

## Backup Directory Layout

```
/opt/zimbra/backup/<domain>/
├── backup_version.txt          # version, start date, start epoch (seconds)
├── admin.txt                   # admin accounts (not restored automatically)
├── emails.txt                  # all accounts of the domain
├── distributionlist.txt
├── distributionlist_members/<list>.txt
├── userpass/<account>.shadow   # password hash
├── userdata/<account>.txt      # cn, sn, givenName, displayName
├── alias/<account>.txt
├── forward/<account>.txt
├── signature/<account>.name
├── signature/<account>.signature
├── filter/<account>.filter
├── mailbox/<account>.tgz
├── mailbox/delta/<account>.tgz
└── failed_mailbox_*.txt        # only when transfers failed
```
