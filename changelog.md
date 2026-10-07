# Changelog

## [1.4.0] - 2026-10-08

### feat
- `backup` and `restore` ask for a scope: `1) accounts` (accounts, passwords, aliases, forwarding, signatures, filters, distribution lists, no mailbox), `2) mailbox` (mailbox content only) or `3) all` (default, same as before). Accounts can be migrated first and mailboxes later.
- accounts-only backup is archived as `<domain>-accounts.tar.gz` (mailbox directory excluded).
- mailbox-only backup is archived as `<domain>-mailbox.tar` without gzip, because the mailbox `.tgz` files are already compressed.
- mailbox backup writes its own start time to `mailbox/backup_version.txt`; `backup-delta` uses it as the default epoch.
- mailbox restore derives the account list from the `.tgz` archives when `emails.txt` is missing.
- each backup refreshes `emails.txt`, so a mailbox backup includes accounts created after the accounts backup.

### perf
- backup account data and distribution list members through `zmprov` batch sessions (one JVM for all accounts) instead of one `zmprov` process per account.
- restore accounts, passwords, aliases, forwarding addresses, distribution lists and members through `zmprov` batch sessions. Only accounts that have a signature or filter (multi-line values) still need their own `zmprov` calls.
- with `JOBS=N`, accounts are split across `N` batch sessions running in parallel.

### fix
- accounts missing from batch output are retried one by one: on backup, accounts without output files; on restore, accounts not found on the target after the batch.

## [1.3.0] - 2026-10-07

### perf
- fetch all account data (password, user data, alias, forwarding, signature, filter) with a single `zmprov -l ga` call per account instead of seven separate `zmprov` calls; backup file layout is unchanged.
- restore signature, filter and forwarding addresses with a single `zmprov ma` per account (falls back to one call per setting if the combined update fails).
- add distribution list members with one `zmprov adlm` call per list (falls back to one call per member on failure).
- add `JOBS` environment variable to process accounts in parallel for every per-account phase (default `1`, sequential).

### feat
- record failed mailbox transfers in `failed_mailbox_<phase>.txt` inside the backup directory and print a summary.
- timestamp every log line and print the elapsed time of each action.
- `backup-delta` offers the full backup start time (from `backup_version.txt`) as the default epoch and accepts seconds or milliseconds.
- `restore-delta` derives the account list from the delta archives when `emails.txt` is missing (e.g. after the full backup was deleted).
- `restore` continues after creating a missing domain instead of exiting.
- `BASE_DIR`, `LOG_FILE` and `TMP_PASSWORD` can be overridden through environment variables.
- back up and restore `sn` (surname).

### fix
- delta backup passed epoch seconds to the `start` parameter, which Zimbra reads as milliseconds, so every "delta" was a full export; seconds are now converted.
- domain and distribution list lookups used substring `grep`, so `contoh.com` also matched `bcontoh.com`; matches are now exact.
- restore set `cn` to the given name instead of the original common name.
- restored names kept a leading space and were truncated at the first `:`.
- failed mailbox downloads left partial `.tgz` files behind; downloads now go to a `.part` file and are only kept on success (`curl` now uses `--fail`).
- restore skips accounts with no mailbox archive instead of posting an empty file.
- passwords containing `\` were mangled by `read` without `-r`.
- the log redirect ran before the user check, producing `tee` permission errors for non-`zimbra` users.

### security
- `curl` credentials are passed through a config file descriptor instead of `-u`, so the admin password no longer appears in `ps` output.
- removed fixed temporary files under `/tmp` (`/tmp/signature`, `/tmp/name`, `/tmp/filter`, `/tmp/firmaid`).

### refactor
- deduplicate method selection, y/n prompts and usage output into helper functions.
- quote all variables and use `tar -C` instead of `cd`.

## [1.2.0] - 2026-09-04

### feat
- add `ZIMBRA_ADMIN_USER` and `ZIMBRA_ADMIN_PASSWORD` credentials input for curl authentication.
- add backup method selection supporting `zmmailbox` and `curl`.
- add restore method selection supporting `zmmailbox` and `curl`.
- add notice and comments documenting that `curl` cannot set start time (requires `zmmailbox` for delta backup).
