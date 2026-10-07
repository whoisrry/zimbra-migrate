#!/bin/bash
# ============================================================
# Zimbra Migration Script
# Version: 1.4.0
# Last Modified: 2026-10-08
# Note: curl cannot set start time
# ============================================================
SCRIPT_VERSION="1.4.0"

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

# Account attributes fetched with `zmprov -l ga` during backup
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
    echo "  backup <domain>         (asks scope: 1) accounts  2) mailbox  3) all)"
    echo "  restore <domain>        (asks scope: 1) accounts  2) mailbox  3) all)"
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

count_accounts() {
    grep -c '@' "$1" 2>/dev/null || true
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

# Prompt for what to process ($1 = backup|restore); sets SCOPE to accounts|mailbox|all
select_scope() {
    echo "Select $1 scope:"
    echo "1) accounts  - accounts, passwords, aliases, forwarding, signatures, filters, distribution lists (no mailbox)"
    echo "2) mailbox   - mailbox content only"
    echo "3) all       - accounts and mailbox"
    echo "Choose scope (1/2/3 or accounts/mailbox/all) [default: 3]:"
    read -r SCOPE
    case "${SCOPE,,}" in
        1|accounts) SCOPE="accounts" ;;
        2|mailbox) SCOPE="mailbox" ;;
        ""|3|all) SCOPE="all" ;;
        *)
            echo "Invalid scope. Please enter '1'/'accounts', '2'/'mailbox' or '3'/'all'"
            exit 1
            ;;
    esac
}

# True when the selected scope includes $1 (accounts|mailbox)
in_scope() {
    [ "$SCOPE" == "all" ] || [ "$SCOPE" == "$1" ]
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

# Quote a value for a zmprov batch command line
zq() {
    local v=${1//\\/\\\\}
    printf '"%s"' "${v//\"/\\\"}"
}

domain_exists() {
    zmprov gad | grep -ixF "$DOMAIN" > /dev/null
}

list_domain_accounts() {
    zmprov -l sa "(&(objectClass=zimbraAccount)(mail=*@$DOMAIN))"
}

# Write script version, start date and start epoch (seconds) to $1
write_version() {
    {
        echo "$SCRIPT_VERSION"
        date "+%Y-%m-%d %H:%M:%S"
        date "+%s"
    } > "$1"
}

print_version_info() {
    if [ -f "$1" ]; then
        echo "Backup was created with script v$(sed -n '1p' "$1") on $(sed -n '2p' "$1")"
        echo "Backup epoch timestamp: $(sed -n '3p' "$1") (use this for backup-delta)"
        echo "Current script version: v$SCRIPT_VERSION"
    else
        echo "WARNING: No version info found in backup. Backup may have been created with an older script version."
    fi
}

# Print a file listing the accounts to process: emails.txt, or one derived from the
# *.tgz archives in $1 when emails.txt is missing
account_list() {
    if [ -s "$BACKUP_DIR/$DIR_EMAILS" ]; then
        echo "$BACKUP_DIR/$DIR_EMAILS"
    else
        find "$1" -maxdepth 1 -name '*.tgz' | sed 's#.*/##; s/\.tgz$//' > "$WORK_DIR/archive_accounts"
        echo "$WORK_DIR/archive_accounts"
    fi
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
        export -f "$func" log zcurl get_attr split_account_attrs
        grep -v '^[[:space:]]*$' "$list" | tr '\n' '\0' |
            xargs -0 -P "$JOBS" -I{} "$BASH" -c '"$0" "$@"' "$func" {} "$@"
    else
        # fd 3 keeps zmprov/zmmailbox from consuming the list on stdin
        while IFS= read -r item <&3; do
            [ -n "$item" ] && "$func" "$item" "$@"
        done 3< "$list"
    fi
}

# Run each command file "$WORK_DIR/<name>.<n>" in its own zmprov batch session
# (one JVM for many commands, sessions in parallel); output goes to function $2.
# Remaining args are zmprov options (e.g. -l)
zmprov_batch() {
    local name=$1 consumer=$2 f
    shift 2
    for f in "$WORK_DIR/$name".[0-9]*; do
        [ -s "$f" ] || continue
        zmprov "$@" < "$f" | "$consumer" &
    done
    wait
}

# Batch output consumer that only logs errors
batch_errors() {
    local line
    while IFS= read -r line; do
        case "$line" in
            *ERROR*) log "zmprov: ${line#prov> }" ;;
        esac
    done
}

# ------------------------------------------------------------
# Per-item workers
# ------------------------------------------------------------

# Split `zmprov ga` output (one or many accounts, each starting with "# name <account>")
# into the per-account backup files
split_account_attrs() {
    awk -v d="$BACKUP_DIR" -v up="$DIR_USERPASS" -v ud="$DIR_USERDATA" -v al="$DIR_ALIAS" \
        -v fw="$DIR_FORWARD" -v sg="$DIR_SIGNATURE" -v fl="$DIR_FILTER" '
        function flush(   a) {
            for (a in val) {
                sub(/\n+$/, "", val[a])
                print val[a] > file[a]
            }
            for (a in file) close(file[a])
            split("", val)
            cur = ""
        }
        function start(u,   a) {
            flush()
            userdata = d "/" ud "/" u ".txt"
            file["userPassword"] = d "/" up "/" u ".shadow"
            file["cn"] = file["sn"] = file["givenName"] = file["displayName"] = userdata
            file["zimbraMailAlias"] = d "/" al "/" u ".txt"
            file["zimbraMailForwardingAddress"] = d "/" fw "/" u ".txt"
            file["zimbraSignatureName"] = d "/" sg "/" u ".name"
            file["zimbraPrefMailSignatureHTML"] = d "/" sg "/" u ".signature"
            file["zimbraMailSieveScript"] = d "/" fl "/" u ".filter"
            # Always create every file, even when the attribute is not set
            for (a in file) printf "" > file[a]
        }
        BEGIN { multi["zimbraPrefMailSignatureHTML"] = multi["zimbraMailSieveScript"] = 1 }
        { sub(/^(prov> )+/, "") }
        /^# name / { start($3); next }
        /^ERROR: / { cur = ""; next }
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
        END { flush() }'
}

# Split `zmprov gdlm` output (one or many lists) into per-list member files
split_dl_members() {
    awk -v dir="$BACKUP_DIR/$DIR_DISTLIST_MEMBERS" '
        { sub(/^(prov> )+/, "") }
        /^# distributionList / {
            if (out != "") close(out)
            out = dir "/" $3 ".txt"
        }
        out != "" { print > out }'
}

# Fallback: back up one account with its own `zmprov` call
backup_account() {
    # shellcheck disable=SC2086
    zmprov -l ga "$1" $ACCOUNT_ATTRS | split_account_attrs
    log "Account data downloaded for .... $1"
}

# Fallback: back up one distribution list with its own `zmprov` call
backup_dl_members() {
    zmprov gdlm "$1" > "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS/$1.txt"
    log "Distribution list members downloaded for .... $1"
}

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

# Fallback: create one account with its original name fields and password hash
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

# Restore aliases, signature, filter and forwarding addresses of one account.
# With $2 = "multiline" only the signature and filter are restored (the rest is
# done by the batch session)
restore_account_settings() {
    local email=$1 only_multiline=$2 alias fwd signame sightml filter sigid settings=() forwards=()
    if [ -z "$only_multiline" ]; then
        if [ -f "$BACKUP_DIR/$DIR_ALIAS/$email.txt" ]; then
            for alias in $(grep '@' "$BACKUP_DIR/$DIR_ALIAS/$email.txt"); do
                zmprov aaa "$email" "$alias"
                log "$email HAS ALIAS $alias --- Restored"
            done
        fi
        if [ -f "$BACKUP_DIR/$DIR_FORWARD/$email.txt" ]; then
            mapfile -t forwards < <(grep '@' "$BACKUP_DIR/$DIR_FORWARD/$email.txt")
        fi
    fi

    signame=$(cat "$BACKUP_DIR/$DIR_SIGNATURE/$email.name" 2>/dev/null)
    sightml=$(cat "$BACKUP_DIR/$DIR_SIGNATURE/$email.signature" 2>/dev/null)
    filter=$(cat "$BACKUP_DIR/$DIR_FILTER/$email.filter" 2>/dev/null)

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
    log "Settings restored for .... $email (signature: $([ -n "$signame$sightml" ] && echo yes || echo no), filter: $([ -n "$filter" ] && echo yes || echo no))"
}

# ------------------------------------------------------------
# Phases
# ------------------------------------------------------------

# Accounts phase of backup: everything except mailbox content, using zmprov batch
# sessions instead of one zmprov process per account
backup_accounts() {
    local total missing
    log "Backup accounts (no mailbox)"
    write_version "$BACKUP_DIR/backup_version.txt"
    rm -rf "${BACKUP_DIR:?}"/{"$DIR_USERPASS","$DIR_USERDATA","$DIR_ALIAS","$DIR_FORWARD","$DIR_SIGNATURE","$DIR_FILTER","$DIR_DISTLIST_MEMBERS"}
    mkdir -p "$BACKUP_DIR"/{"$DIR_USERPASS","$DIR_USERDATA","$DIR_ALIAS","$DIR_FORWARD","$DIR_SIGNATURE","$DIR_FILTER"}

    log "Get all admin account"
    zmprov -l sa "(&(objectClass=zimbraAccount)(zimbraIsAdminAccount=TRUE)(|(mail=*@$DOMAIN)(zimbraMailAlias=*@$DOMAIN)))" > "$BACKUP_DIR/$DIR_ADMIN"

    log "Get all distribution list"
    zmprov gadl | awk -F@ -v d="$DOMAIN" 'tolower($2) == d' > "$BACKUP_DIR/$DIR_DISTLIST"
    if [ -s "$BACKUP_DIR/$DIR_DISTLIST" ]; then
        mkdir -p "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS"
        awk '{ print "gdlm " $0 }' "$BACKUP_DIR/$DIR_DISTLIST" > "$WORK_DIR/gdlm.0"
        zmprov_batch gdlm split_dl_members -l
        while IFS= read -r list; do
            [ -f "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS/$list.txt" ] || echo "$list"
        done < "$BACKUP_DIR/$DIR_DISTLIST" > "$WORK_DIR/dl_missing"
        if [ -s "$WORK_DIR/dl_missing" ]; then
            log "Retrying $(wc -l < "$WORK_DIR/dl_missing" | tr -d ' ') distribution list(s) one by one"
            run_each backup_dl_members "$WORK_DIR/dl_missing"
        fi
        log "Distribution list members downloaded for $(wc -l < "$BACKUP_DIR/$DIR_DISTLIST" | tr -d ' ') list(s)"
    fi

    total=$(count_accounts "$BACKUP_DIR/$DIR_EMAILS")
    log "Get all account data (password, user data, alias, forwarding, signature, filter) for $total account(s)"
    awk -v n="$JOBS" -v p="$WORK_DIR/ga" -v attrs="$ACCOUNT_ATTRS" \
        '/@/ { print "ga " $0 " " attrs > (p "." (NR % n)) }' "$BACKUP_DIR/$DIR_EMAILS"
    zmprov_batch ga split_account_attrs -l

    while IFS= read -r email; do
        [ -f "$BACKUP_DIR/$DIR_USERDATA/$email.txt" ] || echo "$email"
    done < <(grep '@' "$BACKUP_DIR/$DIR_EMAILS") > "$WORK_DIR/ga_missing"
    missing=$(count_accounts "$WORK_DIR/ga_missing")
    if [ "$missing" -gt 0 ]; then
        log "WARNING: $missing account(s) missing from batch output, retrying one by one"
        run_each backup_account "$WORK_DIR/ga_missing"
    fi
    log "Account data downloaded for $(find "$BACKUP_DIR/$DIR_USERDATA" -name '*.txt' | wc -l | tr -d ' ') of $total account(s)"
}

# Mailbox phase of backup
backup_mailboxes() {
    log "Get all mailbox"
    mkdir -p "$BACKUP_DIR/$DIR_MAILBOX"
    write_version "$BACKUP_DIR/$DIR_MAILBOX/backup_version.txt"
    export FAILED_FILE="$BACKUP_DIR/failed_mailbox_backup.txt"
    : > "$FAILED_FILE"
    run_each export_mailbox "$BACKUP_DIR/$DIR_EMAILS" "$BACKUP_DIR/$DIR_MAILBOX"
    report_failures "Mailbox backup"
    log "Backup Mailbox Completed"
}

# Accounts phase of restore: accounts, passwords, aliases, forwarding and distribution
# lists through zmprov batch sessions; signature and filter (multi-line values) per account
restore_accounts() {
    local i=0 email data cn sn given display shadow line missing
    log "Preparing account commands"
    : > "$WORK_DIR/multiline"
    while IFS= read -r email <&3; do
        [[ "$email" == *@* ]] || continue
        data="$BACKUP_DIR/$DIR_USERDATA/$email.txt"
        cn=$(get_attr cn "$data")
        sn=$(get_attr sn "$data")
        given=$(get_attr givenName "$data")
        display=$(get_attr displayName "$data")
        shadow=$(cat "$BACKUP_DIR/$DIR_USERPASS/$email.shadow" 2>/dev/null)
        line="ca $email $(zq "$TMP_PASSWORD") cn $(zq "${cn:-$given}") displayName $(zq "${display:-$cn}") givenName $(zq "${given:-$cn}")"
        if [ -n "$sn" ]; then
            line+=" sn $(zq "$sn")"
        fi
        if [ -z "$shadow" ]; then
            log "WARNING: No password hash for $email, temporary password kept"
        fi
        # All commands of one account go to the same session so `ca` runs first
        {
            echo "$line"
            if [ -n "$shadow" ]; then
                echo "ma $email userPassword $(zq "$shadow")"
            fi
            awk -v e="$email" '/@/ { print "aaa", e, $1 }' "$BACKUP_DIR/$DIR_ALIAS/$email.txt" 2>/dev/null
            awk -v e="$email" '/@/ { print "ma", e, "+zimbraMailForwardingAddress", $1 }' "$BACKUP_DIR/$DIR_FORWARD/$email.txt" 2>/dev/null
        } >> "$WORK_DIR/accounts.$((i % JOBS))"
        if [ -s "$BACKUP_DIR/$DIR_SIGNATURE/$email.name" ] || [ -s "$BACKUP_DIR/$DIR_SIGNATURE/$email.signature" ] \
            || [ -s "$BACKUP_DIR/$DIR_FILTER/$email.filter" ]; then
            echo "$email" >> "$WORK_DIR/multiline"
        fi
        i=$((i + 1))
    done 3< "$BACKUP_DIR/$DIR_EMAILS"

    log "Restoring $i account(s) with password, alias and forwarding address"
    zmprov_batch accounts batch_errors

    # Accounts the batch could not create are retried with the per-account path
    list_domain_accounts | sort > "$WORK_DIR/existing"
    grep '@' "$BACKUP_DIR/$DIR_EMAILS" | sort | comm -23 - "$WORK_DIR/existing" > "$WORK_DIR/missing"
    missing=$(count_accounts "$WORK_DIR/missing")
    if [ "$missing" -gt 0 ]; then
        log "WARNING: $missing account(s) not created by batch, retrying one by one"
        run_each restore_account "$WORK_DIR/missing"
        run_each restore_account_settings "$WORK_DIR/missing"
    fi
    log "Restore User Account Completed"

    grep -vxF -f "$WORK_DIR/missing" "$WORK_DIR/multiline" > "$WORK_DIR/multiline_todo"
    if [ -s "$WORK_DIR/multiline_todo" ]; then
        log "Restoring signature and filter for $(count_accounts "$WORK_DIR/multiline_todo") account(s)"
        run_each restore_account_settings "$WORK_DIR/multiline_todo" multiline
        log "Restore Signature and Filter Completed"
    fi

    if [ -s "$BACKUP_DIR/$DIR_DISTLIST" ]; then
        log "Restoring distribution list"
        # Lists are created before members are added so nested lists resolve
        {
            awk '{ print "cdl " $0 }' "$BACKUP_DIR/$DIR_DISTLIST"
            while IFS= read -r list; do
                grep -v '#' "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS/$list.txt" 2>/dev/null |
                    awk -v l="$list" '/@/ { print "adlm", l, $1 }'
            done < "$BACKUP_DIR/$DIR_DISTLIST"
        } > "$WORK_DIR/dl.0"
        zmprov_batch dl batch_errors
        log "Restore Distribution List Completed ($(wc -l < "$BACKUP_DIR/$DIR_DISTLIST" | tr -d ' ') list(s))"
    fi
}

# Mailbox phase of restore
restore_mailboxes() {
    local accounts
    accounts=$(account_list "$BACKUP_DIR/$DIR_MAILBOX")
    log "Restoring mailbox for $(count_accounts "$accounts") account(s)"
    export FAILED_FILE="$BACKUP_DIR/failed_mailbox_restore.txt"
    : > "$FAILED_FILE"
    run_each import_mailbox "$accounts" "$BACKUP_DIR/$DIR_MAILBOX"
    report_failures "Mailbox restore"
    log "Restore Mailbox Completed"
}

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------

backup() {
    local archive
    log "[v$SCRIPT_VERSION] Starting backup for $DOMAIN"
    log "Verifying domain $DOMAIN"
    if ! domain_exists; then
        log "Domain $DOMAIN not found"
        exit 1
    fi
    log "Domain $DOMAIN found"
    select_scope backup
    if in_scope mailbox; then
        select_method backup
    fi
    if ask_yn "Do you want to compress the backup files after backup process?"; then
        COMPRESS="y"
    else
        COMPRESS="n"
    fi
    echo ""
    log "Backup $DOMAIN (scope: $SCOPE, jobs: $JOBS)"
    mkdir -p "$BACKUP_DIR"

    log "Get all emails account"
    list_domain_accounts > "$BACKUP_DIR/$DIR_EMAILS"
    log "Found $(count_accounts "$BACKUP_DIR/$DIR_EMAILS") account(s)"

    if in_scope accounts; then
        backup_accounts
    fi
    if in_scope mailbox; then
        backup_mailboxes
    fi

    if [ "$COMPRESS" == "y" ]; then
        log "Compressing backup files"
        case "$SCOPE" in
            accounts)
                archive="$BASE_DIR/$DOMAIN-accounts.tar.gz"
                tar -C "$BASE_DIR" -czf "$archive" --exclude="$DOMAIN/$DIR_MAILBOX" "$DOMAIN"
                ;;
            mailbox)
                # Mailbox archives are already gzip, so the outer tar is not compressed again
                archive="$BASE_DIR/$DOMAIN-mailbox.tar"
                tar -C "$BASE_DIR" -cf "$archive" --exclude="$DOMAIN/$DIR_DELTA" "$DOMAIN/$DIR_MAILBOX" "$DOMAIN/$DIR_EMAILS"
                ;;
            all)
                archive="$BASE_DIR/$DOMAIN-backup.tar.gz"
                tar -C "$BASE_DIR" -czf "$archive" "$DOMAIN"
                ;;
        esac
        log "Backup files compressed to $archive"
    fi
    log "Backup $DOMAIN ($SCOPE) completed in $(elapsed)"
    if [ "$SCOPE" == "accounts" ]; then
        echo "Next: restore the accounts on the target, then run backup again with scope 2 (mailbox)"
    fi
}

restore() {
    log "[v$SCRIPT_VERSION] Starting restore for $DOMAIN"
    if [ ! -d "$BACKUP_DIR" ]; then
        log "Backup directory $BACKUP_DIR not found"
        echo "Please extract the backup files to $BASE_DIR/"
        exit 1
    fi
    select_scope restore

    if in_scope accounts; then
        if [ ! -s "$BACKUP_DIR/$DIR_EMAILS" ] || [ ! -d "$BACKUP_DIR/$DIR_USERDATA" ]; then
            log "Account backup not found in $BACKUP_DIR (emails.txt / userdata). Run backup with scope 1 (accounts) or 3 (all) first"
            exit 1
        fi
        print_version_info "$BACKUP_DIR/backup_version.txt"

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
    fi

    if in_scope mailbox; then
        if [ ! -d "$BACKUP_DIR/$DIR_MAILBOX" ]; then
            log "Mailbox backup directory $BACKUP_DIR/$DIR_MAILBOX not found"
            echo "Please extract the mailbox backup files to $BASE_DIR/"
            exit 1
        fi
        print_version_info "$BACKUP_DIR/$DIR_MAILBOX/backup_version.txt"
        select_method restore
    fi

    log "Restoring $DOMAIN (scope: $SCOPE, jobs: $JOBS)"
    if in_scope accounts; then
        restore_accounts
    fi
    if in_scope mailbox; then
        restore_mailboxes
    fi
    log "Restore $DOMAIN ($SCOPE) completed in $(elapsed)"

    if [ "$SCOPE" == "accounts" ]; then
        echo "Next: run backup with scope 2 (mailbox) on the source, then restore with scope 2 here"
        return
    fi
    if ask_yn "Do you want to delete the backup files?"; then
        rm -rf "$BACKUP_DIR"
        log "Backup files deleted"
    fi
    log "All restore process for $DOMAIN completed"
}

backup-delta() {
    local version_file default_epoch
    log "[v$SCRIPT_VERSION] Starting delta backup for $DOMAIN"
    echo "Note: curl cannot set start time. Delta backup uses zmmailbox."
    if [ ! -s "$BACKUP_DIR/$DIR_EMAILS" ]; then
        log "Account list $BACKUP_DIR/$DIR_EMAILS not found. Run a full backup first"
        exit 1
    fi
    # Prefer the mailbox backup start time; accounts may have been backed up earlier
    version_file="$BACKUP_DIR/$DIR_MAILBOX/backup_version.txt"
    if [ ! -f "$version_file" ]; then
        version_file="$BACKUP_DIR/backup_version.txt"
    fi
    default_epoch=$(sed -n '3p' "$version_file" 2>/dev/null)
    echo "Please enter the start time as epoch (seconds or milliseconds)"
    echo "Example: 1754913600"
    echo "Get epoch time from https://www.epochconverter.com/"
    if [ -n "$default_epoch" ]; then
        echo "Press Enter to use the mailbox backup start time: $default_epoch ($(sed -n '2p' "$version_file"))"
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
    local accounts
    log "[v$SCRIPT_VERSION] Starting delta restore for $DOMAIN"
    if [ ! -d "$BACKUP_DIR/$DIR_DELTA" ]; then
        log "Delta backup directory $BACKUP_DIR/$DIR_DELTA not found"
        echo "Please extract the delta backup files to $BASE_DIR/"
        exit 1
    fi
    # The delta archive has no account list; it is derived if the full backup was deleted
    accounts=$(account_list "$BACKUP_DIR/$DIR_DELTA")

    select_method restore

    log "Restoring mailbox for $(count_accounts "$accounts") account(s) (jobs: $JOBS)"
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

WORK_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT

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
