# Zimbra Migration Script

`migrate.sh` migrates a whole Zimbra domain from one server to another: accounts, password hashes, mailboxes, aliases, forwarding addresses, signatures, mail filters and distribution lists. It also supports delta (incremental) mailbox sync to shorten the cutover window.

## Requirements

- Run as the `zimbra` user on both the source and the target server.
- Bash 4.2 or newer (standard on any supported Zimbra OS).
- Enough free space under the backup directory (default `/opt/zimbra/backup`) for all mailboxes of the domain.
- For the `curl` method: a Zimbra admin account and access to the admin port `7071`.

## Usage

```bash
./migrate.sh <action> <domain>
```

| Action          | Runs on | Description                                                          |
| --------------- | ------- | -------------------------------------------------------------------- |
| `backup`        | source  | Full backup of the domain to `$BASE_DIR/<domain>`                    |
| `restore`       | target  | Recreate accounts, mailboxes, settings and distribution lists        |
| `backup-delta`  | source  | Export only mail received since a given time (requires a full backup)|
| `restore-delta` | target  | Import the delta mailboxes                                           |
| `version`       | any     | Print the script version (`-v`, `--version` also work)               |

### Environment variables

| Variable                | Default                              | Description                                                   |
| ----------------------- | ------------------------------------ | ------------------------------------------------------------- |
| `JOBS`                  | `1`                                  | Accounts processed in parallel                                |
| `ZIMBRA_HOST`           | `localhost`                          | Host for the `curl` method                                    |
| `ZIMBRA_ADMIN_USER`     | prompted                             | Admin user for the `curl` method                              |
| `ZIMBRA_ADMIN_PASSWORD` | prompted (hidden)                    | Admin password for the `curl` method                          |
| `BASE_DIR`              | `/opt/zimbra/backup`                 | Backup root directory                                         |
| `LOG_FILE`              | `/opt/zimbra/log/zimbramigration.log`| Log file (all output is appended)                             |
| `TMP_PASSWORD`          | `CHANGEme2025`                       | Initial password for new accounts, replaced by the backed-up hash |

## Quick start

```bash
# Source server
su - zimbra
JOBS=4 ./migrate.sh backup contoh.com          # answer: method, compress (y)
scp /opt/zimbra/backup/contoh.com-backup.tar.gz zimbra@target:/opt/zimbra/backup/

# Target server
su - zimbra
tar -C /opt/zimbra/backup -xzf /opt/zimbra/backup/contoh.com-backup.tar.gz
JOBS=4 ./migrate.sh restore contoh.com

# At cutover (after switching MX), sync mail received since the full backup
./migrate.sh backup-delta contoh.com           # source; Enter = full backup start time
tar -C /opt/zimbra/backup -xzf contoh.com-backup-delta.tar.gz   # target
./migrate.sh restore-delta contoh.com          # target
```

See [walkthrough.md](walkthrough.md) for a step-by-step migration guide, and [changelog.md](changelog.md) for version history.

## Notes

- `curl` cannot set a start time, so `backup-delta` always uses `zmmailbox`.
- Failed mailbox transfers are listed in `failed_mailbox_<phase>.txt` inside the backup directory.
- Start with `JOBS=2`–`4` and watch server load; mailbox export/import is I/O and CPU heavy on the mailbox server.
- Admin rights are not restored automatically. Admin accounts are listed in `admin.txt`; re-grant them with `zmprov ma <user> zimbraIsAdminAccount TRUE`.
