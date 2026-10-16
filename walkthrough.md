# Zimbra Migration Script Walkthrough

## Migration Flow

Large domains (hundreds of users) are best migrated in two stages: accounts first, then mailboxes. Accounts take seconds to minutes. Mailboxes can take hours and can be copied while users keep working on the source server.

`backup` and `restore` both ask for a scope:

```
Select backup scope:
1) accounts  - accounts, passwords, aliases, forwarding, signatures, filters, distribution lists (no mailbox)
2) mailbox   - mailbox content only
3) all       - accounts and mailbox
Choose scope (1/2/3 or accounts/mailbox/all) [default: 3]:
```

### Stage 1: accounts
1. **Source**: `JOBS=4 ./migrate.sh backup contoh.com` → scope `1`.
   - Verifies the domain exists (exact match).
   - Writes `backup_version.txt`, `emails.txt`, `admin.txt`, distribution lists and the per-account files.
   - With compression: `contoh.com-accounts.tar.gz` (the `mailbox/` directory is excluded).
2. **Transfer**: copy the archive and extract it into `/opt/zimbra/backup/` on the target.
3. **Target**: `JOBS=4 ./migrate.sh restore contoh.com` → scope `1`.
   - Offers to create the domain if it is missing.
   - Creates accounts with the original password hash, aliases, forwarding, signatures, filters, distribution lists and members.
   - Does not ask to delete the backup, because the mailbox stage still needs the backup directory.

### Stage 2: mailboxes
4. **Source**: `JOBS=4 ./migrate.sh backup contoh.com` → scope `2`, then the method (`zmmailbox` or `curl`).
   - Refreshes `emails.txt` and writes `mailbox/backup_version.txt` with the mailbox backup start time.
   - With compression: `contoh.com-mailbox.tar` (not gzip again; the `.tgz` files are already compressed).
5. **Transfer**: copy and extract with `tar -C /opt/zimbra/backup -xf contoh.com-mailbox.tar`.
6. **Target**: `JOBS=4 ./migrate.sh restore contoh.com` → scope `2`.
   - Imports every `mailbox/<account>.tgz`. If `emails.txt` is missing, the account list comes from the archive file names.
   - Asks whether to delete the backup directory at the end.

### Stage 3: cutover
7. Switch MX/DNS to the target server.
8. **Source**: `./migrate.sh backup-delta contoh.com`. Press Enter to use the mailbox backup start time, or type an epoch in seconds or milliseconds.
9. **Target**: extract `contoh.com-backup-delta.tar.gz` into `/opt/zimbra/backup/`, then `./migrate.sh restore-delta contoh.com`.

Scope `3` (all) runs both stages in one go, the same as versions before 1.4.0.

### Whole server (`--all`)
Replace the domain with `--all` in any step above, for example `JOBS=4 ./migrate.sh backup --all`.

- **Backup** lists every domain with `zmprov -l gad` and checks each domain's type in one batch session. Local domains go to `domains.txt`. Alias domains go to `alias_domains.txt` with their catch-all target, for example `alias.com @contoh.com`. Each local domain is then backed up into its own `<domain>/` directory, exactly as a single-domain backup. The prompts are asked once.
- **Archives** hold all domains plus both list files: `all-domains-accounts.tar.gz`, `all-domains-mailbox.tar`, `all-domains-backup.tar.gz`, `all-domains-backup-delta.tar.gz`. Extract them into `/opt/zimbra/backup/` on the target.
- **Restore** reads `domains.txt` (or every `*.*` directory when it is missing) and runs in this order:
  1. creates all missing domains and alias domains after one confirmation
  2. restores accounts, passwords, aliases, forwarding, signatures and filters for every domain
  3. creates distribution lists and members for every domain
  4. imports mailboxes for every domain

  Steps 1–3 run for all domains before the next step starts, so an alias or list member in another domain already exists when it is added.
- **Delta**: `backup-delta --all` asks for the start time once. Pressing Enter uses each domain's own mailbox backup start time. `restore-delta --all` skips domains without a `mailbox/delta/` directory.

Server-level configuration is not migrated: COS, global/server config, domain attributes other than alias domains, certificates and DKIM. Set it up on the target first.

### System accounts
GAL sync (`galsync*`), spam/ham training and virus quarantine accounts are not migrated: backup excludes accounts with `zimbraIsSystemResource` or `zimbraIsSystemAccount` set, and restore skips `galsync*` entries found in older backups. Recreate the GAL sync account on the target:

```bash
zmgsautil createAccount -a galsync@contoh.com -n InternalGAL --domain contoh.com -s $(zmhostname) -t zimbra -f _InternalGAL
```

## Mailbox Backup & Restore Methods

### Methods Supported
- **`zmmailbox`**: Native Zimbra CLI tool executed as the `zimbra` system user. Supports delta synchronization using start epoch timestamps.
- **`curl`**: REST API call over HTTPS (port 7071) authenticated with admin credentials. Credentials are passed through a config file descriptor, so the password is not visible in `ps`.

The method is only asked when the scope includes mailboxes.

> [!NOTE]
> `curl` cannot set start time on mailbox exports. For delta backups filtering by start timestamp, `zmmailbox` must be used.

> [!IMPORTANT]
> The REST `start` parameter is in **milliseconds**. Since v1.3.0 `backup-delta` converts a seconds value (10 digits or fewer) automatically.

### Variables
- `ZIMBRA_ADMIN_USER`: Zimbra administrator username (e.g. `admin@domain.com`).
- `ZIMBRA_ADMIN_PASSWORD`: Zimbra administrator password (hidden input via `read -rs`).
- `ZIMBRA_HOST`: Zimbra host (defaults to `localhost`).
- `JOBS`: number of accounts processed in parallel (defaults to `1`).
- `BASE_DIR`, `LOG_FILE`, `TMP_PASSWORD`: backup root, log file and initial account password.

## Performance

### zmprov batch sessions
Each `zmprov` process starts a JVM (roughly 1–2 s). With 400 accounts, one process per command adds up to tens of minutes of startup time alone. The accounts stage instead writes the commands to a file and runs it in a single `zmprov` session (`zmprov -f <commands>`), which runs all of them in one JVM.

> [!WARNING]
> Batch files must be passed with `-f`. `zmprov < commands` opens the interactive `prov>` shell, which reads the terminal instead of stdin and hangs (fixed in v1.4.1).

| Step                                      | v1.2.0 (per account)    | v1.4.0                                   |
| ----------------------------------------- | ----------------------- | ---------------------------------------- |
| Backup account data                       | 7 `zmprov` processes    | 1 batch session for all accounts         |
| Backup distribution list members          | 1 process per list      | 1 batch session for all lists            |
| Restore account + password + alias + forwarding | 2 + aliases + forwards | 1 batch session for all accounts   |
| Restore signature + filter                | 6 processes             | 3 processes, only for accounts that have one |
| Restore distribution lists + members      | 1 per list + 1 per member | 1 batch session                        |

The signature and sieve filter are restored per account because their multi-line values do not fit on a batch command line.

The backup output is split with `awk` into the same files as before (`userpass/`, `userdata/`, `alias/`, `forward/`, `signature/`, `filter/`), so backups from older versions restore with v1.4.0 and the other way around.

### Parallel processing
With `JOBS=N`:
- the accounts stage splits the accounts across `N` batch sessions. All commands for an account stay in the same session, so `ca` runs before `ma`/`aaa` for that account.
- mailbox export/import and the per-account fallbacks run `N` accounts at a time through `xargs -P`.

Steps still run in order: accounts → signature/filter → distribution lists → members, and mailboxes only after accounts.

## Signatures and Filters

**What is migrated**
- **Signatures**: every signature of an account, in HTML (`zimbraPrefMailSignatureHTML`) and plain text (`zimbraPrefMailSignature`). Zimbra keeps the first signature on the account entry and any others as separate entries, so the backup reads them with `zmprov gsig`.
- **Signature choice**: the default and reply/forward signatures. Signature ids change on the target, so they are mapped by signature name.
- **Filters**: incoming (`zimbraMailSieveScript`) and outgoing (`zimbraMailOutgoingSieveScript`).

**Backup check**: after the account data is backed up, LDAP is searched for accounts that have a filter or signature. Any of those without one in the backup is fetched again on its own. The log shows both counts, which should match:

```
Filters backed up for 120 account(s) (LDAP: 120), signatures for 340 account(s) (LDAP: 340)
```

**Restore check**: after restoring, the filters and signatures of each account are read back from the target in one batch session and compared with the backup. Whitespace is ignored, and extra signatures on the target are allowed. Accounts that differ are restored again (`csig`, or `msig` when the signature exists) and checked again, up to two retries. Any account that still differs is listed in `failed_settings.txt`. The check runs after the accounts stage and again after mailbox import.

**Repairing an earlier migration** (v1.5.0 and older did not back up plain-text or additional signatures):
1. Source: `./migrate.sh backup <domain|--all>` → scope `1`.
2. Copy the archive and extract it on the target.
3. Target: `./migrate.sh restore <domain|--all>` → scope `4` (settings). Accounts and mailboxes are not touched. Only missing or different signatures and filters are written, then verified.

Scope `4` also works with an older backup, but it can only restore what that backup contains: filters and the first HTML signature.

## Error Handling

- **Batch backup**: an account without output files after the batch is backed up again with its own `zmprov -l ga`. A distribution list without a member file is retried with its own `zmprov gdlm`.
- **Batch restore**: batch `ERROR` lines are logged as `zmprov: ...`. After the batch, the accounts on the target are compared with `emails.txt`. Missing accounts are created again one by one, with their aliases, forwarding, signature and filter.
- **Mailbox export**: data is written to `<account>.tgz.part` and renamed only on success, so a failed export never leaves a file that looks valid.
- **Failed mailbox transfers** are written to `failed_mailbox_backup.txt`, `failed_mailbox_restore.txt`, `failed_mailbox_delta.txt` or `failed_mailbox_delta_restore.txt` in the backup directory, and a summary is logged. The file is removed when nothing failed.
- Filters and signatures are restored with separate calls, so a rejected filter does not block the signatures. Accounts that still differ after two retries are listed in `failed_settings.txt`. Backup misses are listed in `failed_settings_backup.txt`.

## Backup Directory Layout

```
/opt/zimbra/backup/
├── domains.txt                 # --all only: local domains in the backup
└── alias_domains.txt           # --all only: "<alias domain> @<target domain>"

/opt/zimbra/backup/<domain>/
├── backup_version.txt          # accounts backup: version, start date, start epoch (seconds)
├── admin.txt                   # admin accounts (not restored automatically)
├── emails.txt                  # all accounts of the domain
├── distributionlist.txt
├── distributionlist_members/<list>.txt
├── userpass/<account>.shadow   # password hash
├── userdata/<account>.txt      # cn, sn, givenName, displayName
├── alias/<account>.txt
├── forward/<account>.txt
├── signature/<account>.name        # account-level signature (older backups use only these)
├── signature/<account>.signature
├── signature/<account>.text
├── signature/<account>.sigcount    # number of signatures from zmprov gsig
├── signature/<account>.sig<N>.name / .html / .text / .id
├── signature/<account>.defaults    # default and reply/forward signature ids
├── filter/<account>.filter         # incoming filter
├── filter/<account>.outgoing       # outgoing filter
├── mailbox/backup_version.txt  # mailbox backup start time (default for backup-delta)
├── mailbox/<account>.tgz
├── mailbox/delta/<account>.tgz
└── failed_mailbox_*.txt        # only when transfers failed
```
