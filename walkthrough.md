# Zimbra Migration Script Walkthrough

## Mailbox Backup & Restore Methods

### Methods Supported
- **`zmmailbox`**: Native Zimbra CLI tool executed as the `zimbra` system user. Supports delta synchronization using start epoch timestamps.
- **`curl`**: REST API call over HTTPS (port 7071) authenticated with admin credentials.

> [!NOTE]
> `curl` cannot set start time on mailbox exports. For delta backups filtering by start timestamp, `zmmailbox` must be used.

### Variables Added
- `ZIMBRA_ADMIN_USER`: Zimbra administrator username (e.g. `admin@domain.com`).
- `ZIMBRA_ADMIN_PASSWORD`: Zimbra administrator password (hidden input via `read -s`).
- `ZIMBRA_HOST`: Zimbra host (defaults to `localhost`).
