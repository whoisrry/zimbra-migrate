# Zimbra Migration Script

`migrate.sh` migrates a whole Zimbra domain from one server to another: accounts, password hashes, mailboxes, aliases, forwarding addresses, signatures, mail filters and distribution lists. Accounts and mailboxes can be migrated separately (accounts first, mailboxes later), and delta (incremental) mailbox sync shortens the cutover window.

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
| `backup`        | source  | Backup of the domain to `$BASE_DIR/<domain>` (asks for scope)        |
| `restore`       | target  | Restore from `$BASE_DIR/<domain>` (asks for scope)                   |
| `backup-delta`  | source  | Export only mail received since a given time (requires a mailbox backup) |
| `restore-delta` | target  | Import the delta mailboxes                                           |
| `version`       | any     | Print the script version (`-v`, `--version` also work)               |

### Scope (backup and restore)

| Option        | Includes                                                                                  | Archive                      |
| ------------- | ----------------------------------------------------------------------------------------- | ---------------------------- |
| `1) accounts` | accounts, password hashes, names, aliases, forwarding, signatures, filters, distribution lists | `<domain>-accounts.tar.gz` |
| `2) mailbox`  | mailbox content only                                                                      | `<domain>-mailbox.tar`       |
| `3) all`      | both (default)                                                                            | `<domain>-backup.tar.gz`     |

Restore mailboxes only after the accounts exist on the target.

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

## Quick start: accounts first, mailboxes later

```bash
# 1. Accounts (fast, no mailbox)
# source
JOBS=4 ./migrate.sh backup contoh.com            # scope 1, compress y
scp /opt/zimbra/backup/contoh.com-accounts.tar.gz zimbra@target:/opt/zimbra/backup/
# target
tar -C /opt/zimbra/backup -xzf /opt/zimbra/backup/contoh.com-accounts.tar.gz
JOBS=4 ./migrate.sh restore contoh.com           # scope 1

# 2. Mailboxes
# source
JOBS=4 ./migrate.sh backup contoh.com            # scope 2
scp /opt/zimbra/backup/contoh.com-mailbox.tar zimbra@target:/opt/zimbra/backup/
# target
tar -C /opt/zimbra/backup -xf /opt/zimbra/backup/contoh.com-mailbox.tar
JOBS=4 ./migrate.sh restore contoh.com           # scope 2

# 3. At cutover (after switching MX), sync mail received since the mailbox backup
./migrate.sh backup-delta contoh.com             # source; Enter = mailbox backup start time
tar -C /opt/zimbra/backup -xzf contoh.com-backup-delta.tar.gz   # target
./migrate.sh restore-delta contoh.com            # target
```

See [walkthrough.md](walkthrough.md) for a step-by-step migration guide, and [changelog.md](changelog.md) for version history.

## Notes

- `curl` cannot set a start time, so `backup-delta` always uses `zmmailbox`.
- Failed mailbox transfers are listed in `failed_mailbox_<phase>.txt` inside the backup directory.
- Start with `JOBS=2`–`4` and watch server load; mailbox export/import is I/O and CPU heavy on the mailbox server.
- Admin rights are not restored automatically. Admin accounts are listed in `admin.txt`; re-grant them with `zmprov ma <user> zimbraIsAdminAccount TRUE`.
- System accounts (GAL sync, spam/ham, quarantine) are not migrated. Recreate GAL sync on the target with `zmgsautil createAccount` (see walkthrough.md).
