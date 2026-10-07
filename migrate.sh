#!/bin/bash
# ============================================================
# Zimbra Migration Script
# Version: 1.3.0
# Last Modified: 2026-10-07
# Note: curl cannot set start time
# ============================================================
SCRIPT_VERSION="1.3.0"

export ACTION=$1
export DOMAIN=${2,,}
export USERNAME=$(whoami)
export BASE_DIR="${BASE_DIR:-/opt/zimbra/backup}"
export BACKUP_DIR="$BASE_DIR/$DOMAIN"
export LOG_FILE="${LOG_FILE:-/opt/zimbra/log/zimbramigration.log}"
export ZIMBRA_ADMIN_USER="${ZIMBRA_ADMIN_USER:-}"
export ZIMBRA_ADMIN_PASSWORD="${ZIMBRA_ADMIN_PASSWORD:-}"
export ZIMBRA_HOST="${ZIMBRA_HOST:-localhost}"
# Number of accounts processed in parallel (1 = sequential)
export JOBS="${JOBS:-1}"
# Temporary password for `zmprov ca`, replaced by the original hash right after
export TMP_PASSWORD="${TMP_PASSWORD:-CHANGEme2025}"

# Subdirectory constants (single source of truth)
DIR_ADMIN="admin.txt"
DIR_EMAILS="emails.txt"
DIR_DISTLIST="distributionlist.txt"
DIR_DISTLIST_MEMBERS="distributionlist_members"
DIR_USERPASS="userpass"
DIR_USERDATA="userdata"
DIR_MAILBOX="mailbox"
DIR_ALIAS="alias"
DIR_FORWARD="forward"
DIR_SIGNATURE="signature"
DIR_FILTER="filter"
DIR_DELTA="mailbox/delta"
export DIR_ADMIN DIR_EMAILS DIR_DISTLIST DIR_DISTLIST_MEMBERS DIR_USERPASS DIR_USERDATA \
    DIR_MAILBOX DIR_ALIAS DIR_FORWARD DIR_SIGNATURE DIR_FILTER DIR_DELTA

# Account attributes fetched with a single `zmprov -l ga` call per account during backup
export ACCOUNT_ATTRS="userPassword cn sn givenName displayName zimbraMailAlias zimbraMailForwardingAddress zimbraSignatureName zimbraPrefMailSignatureHTML zimbraMailSieveScript"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

log() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

version() {
    echo "xzimbramigration.sh v$SCRIPT_VERSION"
}

usage() {
    echo "Usage: $0 <action> <domain>"
    echo "Actions:"
    echo "  backup <domain>"
    echo "  restore <domain>"
    echo "  backup-delta <domain>"
    echo "  restore-delta <domain>"
    echo "  version"
    echo "Environment:"
    echo "  JOBS=<n>        accounts processed in parallel (default: 1)"
    echo "  ZIMBRA_HOST, ZIMBRA_ADMIN_USER, ZIMBRA_ADMIN_PASSWORD (curl method)"
    echo "  BASE_DIR, LOG_FILE, TMP_PASSWORD"
    echo "Example: $0 backup contoh.com"
    echo "Example: JOBS=4 $0 restore contoh.com"
    exit 1
}

elapsed() {
    printf '%dm%02ds' $((SECONDS / 60)) $((SECONDS % 60))
}

# Ask a y/n question; returns 0 for y, 1 for n (re-prompts on invalid input, "n" on EOF)
ask_yn() {
    local answer
    echo "$1 (y/n)"
    while read -r answer; do
        case "${answer,,}" in
            y) return 0 ;;
            n) return 1 ;;
            *) echo "Invalid input. Please enter 'y' for yes or 'n' for no" ;;
        esac
    done
    return 1
}

prompt_admin_credentials() {
    if [ -z "$ZIMBRA_ADMIN_USER" ]; then
        echo "Enter Zimbra Admin Username:"
        read -r ZIMBRA_ADMIN_USER
    fi
    if [ -z "$ZIMBRA_ADMIN_PASSWORD" ]; then
        echo "Enter Zimbra Admin Password:"
        read -rs ZIMBRA_ADMIN_PASSWORD
        echo ""
    fi
    if [ -z "$ZIMBRA_ADMIN_USER" ] || [ -z "$ZIMBRA_ADMIN_PASSWORD" ]; then
        echo "Zimbra Admin username and password are required for curl method"
        exit 1
    fi
}

# Prompt for the mailbox transfer method ($1 = backup|restore); sets MAILBOX_METHOD
select_method() {
    echo "Select mailbox $1 method:"
    echo "1) zmmailbox"
    echo "2) curl"
    if [ "$1" == "backup" ]; then
        echo "Note: curl cannot set start time"
    fi
    echo "Choose method (1/2 or zmmailbox/curl) [default: 1]:"
    read -r MAILBOX_METHOD
    case "${MAILBOX_METHOD,,}" in
        ""|1|zmmailbox)
            MAILBOX_METHOD="zmmailbox"
            ;;
        2|curl)
            MAILBOX_METHOD="curl"
            prompt_admin_credentials
            ;;
        *)
            echo "Invalid $1 method. Please enter '1'/'zmmailbox' or '2'/'curl'"
            exit 1
            ;;
    esac
    export MAILBOX_METHOD
}

# curl with admin credentials passed through a config fd, keeping the password out of `ps`
zcurl() {
    local user=${ZIMBRA_ADMIN_USER//\\/\\\\} pass=${ZIMBRA_ADMIN_PASSWORD//\\/\\\\}
    user=${user//\"/\\\"}
    pass=${pass//\"/\\\"}
    curl -sSfk -K <(printf 'user = "%s:%s"\n' "$user" "$pass") "$@"
}

# Print the first value of attribute $1 from an "attr: value" file $2
get_attr() {
    sed -n "s/^$1: //p" "$2" 2>/dev/null | head -n 1
}

domain_exists() {
    zmprov gad | grep -ixF "$DOMAIN" > /dev/null
}

# Report and keep the failure list of the current phase, or remove it when empty
report_failures() {
    if [ -s "$FAILED_FILE" ]; then
        log "WARNING: $1 failed for $(wc -l < "$FAILED_FILE" | tr -d ' ') account(s), listed in $FAILED_FILE"
    else
        rm -f "$FAILED_FILE"
    fi
}

# Run function $1 once per non-empty line of file $2 (extra args passed through),
# JOBS items at a time
run_each() {
    local func=$1 list=$2 item
    shift 2
    if [ "$JOBS" -gt 1 ]; then
        export -f "$func" log zcurl get_attr
        grep -v '^[[:space:]]*$' "$list" | tr '\n' '\0' |
            xargs -0 -P "$JOBS" -I{} "$BASH" -c '"$0" "$@"' "$func" {} "$@"
    else
        # fd 3 keeps zmprov/zmmailbox from consuming the list on stdin
        while IFS= read -r item <&3; do
            [ -n "$item" ] && "$func" "$item" "$@"
        done 3< "$list"
    fi
}

# ------------------------------------------------------------
# Per-item workers (also run in parallel through run_each)
# ------------------------------------------------------------

# Export one mailbox as tgz: export_mailbox <email> <dest_dir> [start_ms]
export_mailbox() {
    local email=$1 dest="$2/$1.tgz" query="/?fmt=tgz${3:+&start=$3}" rc
    if [ "$MAILBOX_METHOD" == "curl" ]; then
        # Note: curl cannot set start time
        zcurl "https://$ZIMBRA_HOST:7071/service/home/$email$query" -o "$dest.part"
    else
        zmmailbox -z -m "$email" getRestURL "$query" > "$dest.part"
    fi
    rc=$?
    if [ $rc -eq 0 ] && mv -f "$dest.part" "$dest"; then
        log "Mailbox downloaded for .... $email"
    else
        rm -f "$dest.part"
        echo "$email" >> "$FAILED_FILE"
        log "ERROR: Mailbox download failed for .... $email"
    fi
}

# Import one mailbox tgz: import_mailbox <email> <src_dir>
import_mailbox() {
    local email=$1 src="$2/$1.tgz" rc
    if [ ! -s "$src" ]; then
        log "WARNING: No mailbox archive for .... $email, skipped"
        return
    fi
    if [ "$MAILBOX_METHOD" == "curl" ]; then
        zcurl --data-binary "@$src" "https://$ZIMBRA_HOST:7071/service/home/$email/?fmt=tgz&resolve=skip"
    else
        zmmailbox -z -m "$email" postRestURL "/?fmt=tgz&resolve=skip" "$src"
    fi
    rc=$?
    if [ $rc -eq 0 ]; then
        log "$email -- finished"
    else
        echo "$email" >> "$FAILED_FILE"
        log "ERROR: Mailbox restore failed for .... $email"
    fi
}

# Back up password, user data, alias, forwarding, signature and filter of one account
# from a single `zmprov -l ga` call, keeping the per-file layout of earlier versions
backup_account() {
    local email=$1
    # shellcheck disable=SC2086
    zmprov -l ga "$email" $ACCOUNT_ATTRS | awk \
        -v shadow="$BACKUP_DIR/$DIR_USERPASS/$email.shadow" \
        -v userdata="$BACKUP_DIR/$DIR_USERDATA/$email.txt" \
        -v alias="$BACKUP_DIR/$DIR_ALIAS/$email.txt" \
        -v forward="$BACKUP_DIR/$DIR_FORWARD/$email.txt" \
        -v signame="$BACKUP_DIR/$DIR_SIGNATURE/$email.name" \
        -v sightml="$BACKUP_DIR/$DIR_SIGNATURE/$email.signature" \
        -v filter="$BACKUP_DIR/$DIR_FILTER/$email.filter" '
        BEGIN {
            file["userPassword"] = shadow
            file["cn"] = file["sn"] = file["givenName"] = file["displayName"] = userdata
            file["zimbraMailAlias"] = alias
            file["zimbraMailForwardingAddress"] = forward
            file["zimbraSignatureName"] = signame
            file["zimbraPrefMailSignatureHTML"] = sightml
            file["zimbraMailSieveScript"] = filter
            multi["zimbraPrefMailSignatureHTML"] = multi["zimbraMailSieveScript"] = 1
            # Always create every file, even when the attribute is not set
            for (a in file) printf "" > file[a]
        }
        /^# name / { next }
        match($0, /^[A-Za-z]+: /) && (substr($0, 1, RLENGTH - 2) in file) {
            cur = substr($0, 1, RLENGTH - 2)
            value = substr($0, RLENGTH + 1)
            if (cur in multi) {
                val[cur] = value
            } else {
                print (file[cur] == userdata ? $0 : value) > file[cur]
            }
            next
        }
        # Continuation lines of multi-line values (HTML signature, sieve script)
        cur in multi { val[cur] = val[cur] "\n" $0 }
        END {
            for (a in val) {
                sub(/\n+$/, "", val[a])
                print val[a] > file[a]
            }
        }'
    log "Account data downloaded for .... $email"
}

backup_dl_members() {
    zmprov gdlm "$1" > "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS/$1.txt"
    log "Distribution list members downloaded for .... $1"
}

# Create one account with its original name fields and password hash
restore_account() {
    local email=$1 data="$BACKUP_DIR/$DIR_USERDATA/$1.txt" cn sn given display shadow args
    cn=$(get_attr cn "$data")
    sn=$(get_attr sn "$data")
    given=$(get_attr givenName "$data")
    display=$(get_attr displayName "$data")
    args=(cn "${cn:-$given}" displayName "${display:-$cn}" givenName "${given:-$cn}")
    if [ -n "$sn" ]; then
        args+=(sn "$sn")
    fi
    zmprov ca "$email" "$TMP_PASSWORD" "${args[@]}"
    shadow=$(cat "$BACKUP_DIR/$DIR_USERPASS/$email.shadow" 2>/dev/null)
    if [ -n "$shadow" ]; then
        zmprov ma "$email" userPassword "$shadow"
    else
        log "WARNING: No password hash for $email, temporary password kept"
    fi
    log "User account restored for .... $email"
}

# Restore aliases, signature, filter and forwarding addresses of one account
restore_account_settings() {
    local email=$1 alias fwd signame sightml filter sigid settings=() forwards=()
    if [ -f "$BACKUP_DIR/$DIR_ALIAS/$email.txt" ]; then
        for alias in $(grep '@' "$BACKUP_DIR/$DIR_ALIAS/$email.txt"); do
            zmprov aaa "$email" "$alias"
            log "$email HAS ALIAS $alias --- Restored"
        done
    fi

    signame=$(cat "$BACKUP_DIR/$DIR_SIGNATURE/$email.name" 2>/dev/null)
    sightml=$(cat "$BACKUP_DIR/$DIR_SIGNATURE/$email.signature" 2>/dev/null)
    filter=$(cat "$BACKUP_DIR/$DIR_FILTER/$email.filter" 2>/dev/null)
    if [ -f "$BACKUP_DIR/$DIR_FORWARD/$email.txt" ]; then
        mapfile -t forwards < <(grep '@' "$BACKUP_DIR/$DIR_FORWARD/$email.txt")
    fi

    # One `zmprov ma` for everything; fall back to separate calls so one bad value
    # does not block the others
    if [ -n "$signame$sightml" ]; then
        settings+=(zimbraSignatureName "$signame" zimbraPrefMailSignatureHTML "$sightml")
    fi
    if [ -n "$filter" ]; then
        settings+=(zimbraMailSieveScript "$filter")
    fi
    for fwd in "${forwards[@]}"; do
        settings+=(+zimbraMailForwardingAddress "$fwd")
    done
    if [ ${#settings[@]} -gt 0 ] && ! zmprov ma "$email" "${settings[@]}"; then
        log "WARNING: Combined settings update failed for $email, retrying one by one"
        if [ -n "$signame$sightml" ]; then
            zmprov ma "$email" zimbraSignatureName "$signame" zimbraPrefMailSignatureHTML "$sightml"
        fi
        if [ -n "$filter" ]; then
            zmprov ma "$email" zimbraMailSieveScript "$filter"
        fi
        for fwd in "${forwards[@]}"; do
            zmprov ma "$email" +zimbraMailForwardingAddress "$fwd"
        done
    fi

    if [ -n "$signame$sightml" ]; then
        sigid=$(zmprov ga "$email" zimbraSignatureId | sed -n 's/^zimbraSignatureId: //p')
        if [ -n "$sigid" ]; then
            zmprov ma "$email" zimbraPrefDefaultSignatureId "$sigid" zimbraPrefForwardReplySignatureId "$sigid"
        fi
    fi
    log "Settings restored for .... $email (forwards: ${#forwards[@]}, signature: $([ -n "$signame$sightml" ] && echo yes || echo no), filter: $([ -n "$filter" ] && echo yes || echo no))"
}

restore_dl() {
    zmprov cdl "$1"
    log "Distribution list restored for .... $1"
}

restore_dl_members() {
    local list=$1 members=() member
    mapfile -t members < <(grep -v '#' "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS/$list.txt" 2>/dev/null | grep '@')
    if [ ${#members[@]} -gt 0 ] && ! zmprov adlm "$list" "${members[@]}"; then
        log "WARNING: Bulk member add failed for $list, retrying one by one"
        for member in "${members[@]}"; do
            zmprov adlm "$list" "$member"
        done
    fi
    log "${#members[@]} member(s) added to list $list"
}

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------

backup() {
    log "[v$SCRIPT_VERSION] Starting backup for $DOMAIN"
    log "Verifying domain $DOMAIN"
    if ! domain_exists; then
        log "Domain $DOMAIN not found"
        exit 1
    fi
    log "Domain $DOMAIN found"
    select_method backup
    if ask_yn "Do you want to compress the backup files after backup process?"; then
        COMPRESS="y"
    else
        COMPRESS="n"
    fi
    echo ""
    log "Backup $DOMAIN (jobs: $JOBS)"

    mkdir -p "$BACKUP_DIR"/{"$DIR_USERPASS","$DIR_USERDATA","$DIR_MAILBOX","$DIR_ALIAS","$DIR_FORWARD","$DIR_SIGNATURE","$DIR_FILTER"}

    # Save script version and start time used for this backup
    {
        echo "$SCRIPT_VERSION"
        date "+%Y-%m-%d %H:%M:%S"
        date "+%s"
    } > "$BACKUP_DIR/backup_version.txt"

    log "Get all admin account"
    zmprov -l sa "(&(objectClass=zimbraAccount)(zimbraIsAdminAccount=TRUE)(|(mail=*@$DOMAIN)(zimbraMailAlias=*@$DOMAIN)))" > "$BACKUP_DIR/$DIR_ADMIN"
    log "Get all emails account"
    zmprov -l sa "(&(objectClass=zimbraAccount)(mail=*@$DOMAIN))" > "$BACKUP_DIR/$DIR_EMAILS"
    log "Found $(grep -c '@' "$BACKUP_DIR/$DIR_EMAILS") account(s)"

    log "Get all distribution list"
    zmprov gadl | awk -F@ -v d="$DOMAIN" 'tolower($2) == d' > "$BACKUP_DIR/$DIR_DISTLIST"
    if [ -s "$BACKUP_DIR/$DIR_DISTLIST" ]; then
        mkdir -p "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS"
        run_each backup_dl_members "$BACKUP_DIR/$DIR_DISTLIST"
    fi

    log "Get all account data (password, user data, alias, forwarding, signature, filter)"
    run_each backup_account "$BACKUP_DIR/$DIR_EMAILS"

    log "Get all mailbox"
    export FAILED_FILE="$BACKUP_DIR/failed_mailbox_backup.txt"
    : > "$FAILED_FILE"
    run_each export_mailbox "$BACKUP_DIR/$DIR_EMAILS" "$BACKUP_DIR/$DIR_MAILBOX"
    report_failures "Mailbox backup"

    if [ "$COMPRESS" == "y" ]; then
        log "Compressing backup files"
        tar -C "$BASE_DIR" -czf "$BASE_DIR/$DOMAIN-backup.tar.gz" "$DOMAIN"
        log "Backup files compressed to $BASE_DIR/$DOMAIN-backup.tar.gz"
    fi
    log "Backup $DOMAIN completed in $(elapsed)"
}

restore() {
    log "[v$SCRIPT_VERSION] Starting restore for $DOMAIN"
    if [ ! -d "$BACKUP_DIR" ]; then
        log "Backup directory $BACKUP_DIR not found"
        echo "Please extract the backup files to $BASE_DIR/"
        exit 1
    fi
    if [ ! -s "$BACKUP_DIR/$DIR_EMAILS" ]; then
        log "Account list $BACKUP_DIR/$DIR_EMAILS not found or empty"
        exit 1
    fi

    # Version check
    if [ -f "$BACKUP_DIR/backup_version.txt" ]; then
        BACKUP_VER=$(sed -n '1p' "$BACKUP_DIR/backup_version.txt")
        BACKUP_DATE=$(sed -n '2p' "$BACKUP_DIR/backup_version.txt")
        BACKUP_EPOCH=$(sed -n '3p' "$BACKUP_DIR/backup_version.txt")
        echo "Backup was created with script v$BACKUP_VER on $BACKUP_DATE"
        echo "Backup epoch timestamp: $BACKUP_EPOCH (use this for backup-delta)"
        echo "Current script version: v$SCRIPT_VERSION"
    else
        echo "WARNING: No version info found in backup. Backup may have been created with an older script version."
    fi

    log "Verifying domain $DOMAIN"
    if ! domain_exists; then
        log "Domain $DOMAIN not found"
        if ! ask_yn "Do you want to create domain $DOMAIN?"; then
            log "Domain $DOMAIN not found and not created"
            exit 1
        fi
        if ! zmprov cd "$DOMAIN"; then
            log "Failed to create domain $DOMAIN"
            exit 1
        fi
        log "Domain $DOMAIN created"
    fi
    log "Domain $DOMAIN found"
    select_method restore

    log "Restoring $DOMAIN (jobs: $JOBS)"

    log "Restoring user account"
    run_each restore_account "$BACKUP_DIR/$DIR_EMAILS"
    log "Restore User Account Completed"

    log "Restoring mailbox"
    export FAILED_FILE="$BACKUP_DIR/failed_mailbox_restore.txt"
    : > "$FAILED_FILE"
    run_each import_mailbox "$BACKUP_DIR/$DIR_EMAILS" "$BACKUP_DIR/$DIR_MAILBOX"
    report_failures "Mailbox restore"
    log "Restore Mailbox Completed"

    log "Restoring alias, signature, filter and forwarding address"
    run_each restore_account_settings "$BACKUP_DIR/$DIR_EMAILS"
    log "Restore Alias, Signature, Filter and Forwarding Address Completed"

    if [ -s "$BACKUP_DIR/$DIR_DISTLIST" ]; then
        log "Restoring distribution list"
        run_each restore_dl "$BACKUP_DIR/$DIR_DISTLIST"
        # Members are added after all lists exist so nested lists resolve
        log "Restoring distribution list members"
        run_each restore_dl_members "$BACKUP_DIR/$DIR_DISTLIST"
        log "Restore Distribution List Completed"
    fi

    log "Restore $DOMAIN completed in $(elapsed)"
    if ask_yn "Do you want to delete the backup files?"; then
        rm -rf "$BACKUP_DIR"
        log "Backup files deleted"
    fi
    log "All restore process for $DOMAIN completed"
}

backup-delta() {
    local default_epoch
    log "[v$SCRIPT_VERSION] Starting delta backup for $DOMAIN"
    echo "Note: curl cannot set start time. Delta backup uses zmmailbox."
    if [ ! -s "$BACKUP_DIR/$DIR_EMAILS" ]; then
        log "Account list $BACKUP_DIR/$DIR_EMAILS not found. Run a full backup first"
        exit 1
    fi
    default_epoch=$(sed -n '3p' "$BACKUP_DIR/backup_version.txt" 2>/dev/null)
    echo "Please enter the start time as epoch (seconds or milliseconds)"
    echo "Example: 1754913600"
    echo "Get epoch time from https://www.epochconverter.com/"
    if [ -n "$default_epoch" ]; then
        echo "Press Enter to use the full backup start time: $default_epoch ($(sed -n '2p' "$BACKUP_DIR/backup_version.txt"))"
    fi
    read -r EPOCH_TIME
    EPOCH_TIME=${EPOCH_TIME:-$default_epoch}
    if [[ ! "$EPOCH_TIME" =~ ^[0-9]+$ ]]; then
        log "A numeric epoch time is required"
        exit 1
    fi
    # The REST `start` parameter is in milliseconds; convert seconds input
    if [ ${#EPOCH_TIME} -le 10 ]; then
        EPOCH_TIME="${EPOCH_TIME}000"
    fi
    log "Delta start time (ms): $EPOCH_TIME (jobs: $JOBS)"

    export MAILBOX_METHOD="zmmailbox"
    log "Get all mailbox"
    mkdir -p "$BACKUP_DIR/$DIR_DELTA"
    export FAILED_FILE="$BACKUP_DIR/failed_mailbox_delta.txt"
    : > "$FAILED_FILE"
    run_each export_mailbox "$BACKUP_DIR/$DIR_EMAILS" "$BACKUP_DIR/$DIR_DELTA" "$EPOCH_TIME"
    report_failures "Mailbox delta backup"
    log "Backup Mailbox Delta Completed"

    log "Compressing delta backup files"
    tar -C "$BASE_DIR" -czf "$BASE_DIR/$DOMAIN-backup-delta.tar.gz" "$DOMAIN/$DIR_DELTA"
    log "Delta backup files compressed to $BASE_DIR/$DOMAIN-backup-delta.tar.gz in $(elapsed)"
    echo "Please copy and extract the delta backup files to the target server $BASE_DIR/"
    echo "Then run: $0 restore-delta $DOMAIN"
    exit 0
}

restore-delta() {
    local accounts="$BACKUP_DIR/$DIR_EMAILS"
    log "[v$SCRIPT_VERSION] Starting delta restore for $DOMAIN"
    if [ ! -d "$BACKUP_DIR/$DIR_DELTA" ]; then
        log "Delta backup directory $BACKUP_DIR/$DIR_DELTA not found"
        echo "Please extract the delta backup files to $BASE_DIR/"
        exit 1
    fi
    # The delta archive has no account list; derive it if the full backup was deleted
    if [ ! -s "$accounts" ]; then
        accounts="$BACKUP_DIR/$DIR_DELTA/accounts.txt"
        find "$BACKUP_DIR/$DIR_DELTA" -maxdepth 1 -name '*.tgz' -exec basename {} .tgz \; > "$accounts"
        log "Account list derived from delta archives: $(grep -c '@' "$accounts") account(s)"
    fi

    select_method restore

    log "Restoring mailbox (jobs: $JOBS)"
    export FAILED_FILE="$BACKUP_DIR/failed_mailbox_delta_restore.txt"
    : > "$FAILED_FILE"
    run_each import_mailbox "$accounts" "$BACKUP_DIR/$DIR_DELTA"
    report_failures "Mailbox delta restore"
    log "Restore Mailbox Delta Completed in $(elapsed)"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

if [ "$ACTION" == "version" ] || [ "$ACTION" == "--version" ] || [ "$ACTION" == "-v" ]; then
    version
    exit 0
fi

if [ "$USERNAME" != "zimbra" ]; then
    echo "Run this script as zimbra user"
    exit 1
fi

if [ -z "$ACTION" ] || [ -z "$DOMAIN" ]; then
    usage
fi

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid JOBS value '$JOBS', using 1"
    JOBS=1
fi

exec > >(tee -a "$LOG_FILE") 2>&1

case "$ACTION" in
    backup)
        backup
        ;;
    restore)
        restore
        ;;
    backup-delta)
        backup-delta
        ;;
    restore-delta)
        restore-delta
        ;;
    *)
        usage
        ;;
esac
