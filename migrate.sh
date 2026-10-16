#!/bin/bash
# ============================================================
# Zimbra Migration Script
# Version: 1.6.0
# Last Modified: 2026-10-17
# Note: curl cannot set start time
# ============================================================
SCRIPT_VERSION="1.6.0"

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
export ACCOUNT_ATTRS="userPassword cn sn givenName displayName zimbraMailAlias zimbraMailForwardingAddress zimbraSignatureName zimbraPrefMailSignatureHTML zimbraPrefMailSignature zimbraPrefDefaultSignatureId zimbraPrefForwardReplySignatureId zimbraMailSieveScript zimbraMailOutgoingSieveScript"
# Attributes read back from the target to verify filters and signatures after restore
export SETTINGS_ATTRS="zimbraSignatureName zimbraPrefMailSignatureHTML zimbraPrefMailSignature zimbraMailSieveScript zimbraMailOutgoingSieveScript"

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
    echo "Usage: $0 <action> <domain|--all>"
    echo "Actions:"
    echo "  backup <domain|--all>         (asks scope: 1) accounts  2) mailbox  3) all)"
    echo "  restore <domain|--all>        (asks scope: 1) accounts  2) mailbox  3) all)"
    echo "  backup-delta <domain|--all>"
    echo "  restore-delta <domain|--all>"
    echo "  version"
    echo "  --all processes every domain of the server"
    echo "  restore scope 4) settings re-applies and verifies signatures and filters only"
    echo "Environment:"
    echo "  JOBS=<n>        accounts processed in parallel (default: 1)"
    echo "  ZIMBRA_HOST, ZIMBRA_ADMIN_USER, ZIMBRA_ADMIN_PASSWORD (curl method)"
    echo "  BASE_DIR, LOG_FILE, TMP_PASSWORD"
    echo "Example: $0 backup contoh.com"
    echo "Example: JOBS=4 $0 restore contoh.com"
    echo "Example: JOBS=4 $0 backup --all"
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

# Prompt for what to process ($1 = backup|restore); sets SCOPE to
# accounts|mailbox|all, or settings (restore only)
select_scope() {
    local choices="1/2/3 or accounts/mailbox/all"
    echo "Select $1 scope:"
    echo "1) accounts  - accounts, passwords, aliases, forwarding, signatures, filters, distribution lists (no mailbox)"
    echo "2) mailbox   - mailbox content only"
    echo "3) all       - accounts and mailbox"
    if [ "$1" == "restore" ]; then
        echo "4) settings  - signatures and filters only: re-applied to existing accounts and verified"
        choices="1/2/3/4 or accounts/mailbox/all/settings"
    fi
    echo "Choose scope ($choices) [default: 3]:"
    read -r SCOPE
    case "${SCOPE,,}" in
        1|accounts) SCOPE="accounts" ;;
        2|mailbox) SCOPE="mailbox" ;;
        ""|3|all) SCOPE="all" ;;
        4|settings) [ "$1" == "restore" ] && SCOPE="settings" ;;
    esac
    case "$SCOPE" in
        accounts|mailbox|all|settings) ;;
        *)
            echo "Invalid scope. Please enter $choices"
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

# User accounts of the domain, without system accounts (GAL sync, spam/ham, quarantine)
list_domain_accounts() {
    zmprov -l sa "(&(objectClass=zimbraAccount)(mail=*@$DOMAIN)(!(zimbraIsSystemResource=TRUE))(!(zimbraIsSystemAccount=TRUE)))"
}

# Switch the current domain: BACKUP_DIR and a fresh per-domain WORK_DIR
set_domain() {
    DOMAIN=$1
    BACKUP_DIR="$BASE_DIR/$DOMAIN"
    WORK_DIR="$WORK_ROOT/$DOMAIN"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
}

# Find all domains of this server: local domains go to DOMAINS and $BASE_DIR/domains.txt,
# alias domains (with their catch-all target) to $BASE_DIR/alias_domains.txt
discover_domains() {
    log "Get all domains"
    zmprov -l gad | grep . > "$WORK_DIR/all_domains"
    awk '{ print "gd " $0 " zimbraDomainType zimbraMailCatchAllForwardingAddress" }' \
        "$WORK_DIR/all_domains" > "$WORK_DIR/gd.0"
    zmprov_batch gd cat -l | awk '
        { sub(/^(prov> )+/, "") }
        /^# name / { d = $3 }
        /^zimbraDomainType: alias/ { alias[d] = 1 }
        /^zimbraMailCatchAllForwardingAddress: / { target[d] = $2 }
        END { for (d in alias) print d, target[d] }' > "$BASE_DIR/alias_domains.txt"
    awk 'FILENAME == ARGV[1] { alias[$1]; next } !($1 in alias)' \
        "$BASE_DIR/alias_domains.txt" "$WORK_DIR/all_domains" > "$BASE_DIR/domains.txt"
    mapfile -t DOMAINS < "$BASE_DIR/domains.txt"
    log "Found ${#DOMAINS[@]} domain(s): ${DOMAINS[*]}"
    if [ -s "$BASE_DIR/alias_domains.txt" ]; then
        log "Alias domain(s), recreated on restore without accounts: $(awk '{ printf "%s ", $1 }' "$BASE_DIR/alias_domains.txt")"
    fi
}

# Domains of a whole-server backup: domains.txt, or every subdirectory that looks
# like a domain when domains.txt is missing
load_backup_domains() {
    if [ -s "$BASE_DIR/domains.txt" ]; then
        mapfile -t DOMAINS < <(grep . "$BASE_DIR/domains.txt")
    else
        mapfile -t DOMAINS < <(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.*' -exec basename {} \; | sort)
    fi
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        log "No domain backups found in $BASE_DIR"
        exit 1
    fi
    log "Domain(s) in backup: ${DOMAINS[*]}"
}

# Archive the backup of all DOMAINS for the selected scope into one file
compress_backup() {
    local d archive tar_opts="-czf" paths=() excludes=()
    for d in "${DOMAINS[@]}"; do
        case "$SCOPE" in
            accounts)
                paths+=("$d")
                excludes+=("--exclude=$d/$DIR_MAILBOX")
                ;;
            mailbox)
                paths+=("$d/$DIR_MAILBOX" "$d/$DIR_EMAILS")
                excludes+=("--exclude=$d/$DIR_DELTA")
                ;;
            all)
                paths+=("$d")
                ;;
        esac
    done
    case "$SCOPE" in
        accounts) archive="$BASE_DIR/$ARCHIVE_PREFIX-accounts.tar.gz" ;;
        mailbox)
            # Mailbox archives are already gzip, so the outer tar is not compressed again
            archive="$BASE_DIR/$ARCHIVE_PREFIX-mailbox.tar"
            tar_opts="-cf"
            ;;
        all) archive="$BASE_DIR/$ARCHIVE_PREFIX-backup.tar.gz" ;;
    esac
    if [ -n "$ALL_DOMAINS" ]; then
        paths+=(domains.txt alias_domains.txt)
    fi
    log "Compressing backup files"
    tar -C "$BASE_DIR" "$tar_opts" "$archive" "${excludes[@]}" "${paths[@]}"
    log "Backup files compressed to $archive"
}

# Version file whose start time is the default for backup-delta of domain $1
delta_version_file() {
    if [ -f "$BASE_DIR/$1/$DIR_MAILBOX/backup_version.txt" ]; then
        echo "$BASE_DIR/$1/$DIR_MAILBOX/backup_version.txt"
    else
        echo "$BASE_DIR/$1/backup_version.txt"
    fi
}

# Write script version, start date and start epoch (seconds) to $1
write_version() {
    {
        echo "$SCRIPT_VERSION"
        date "+%Y-%m-%d %H:%M:%S"
        date "+%s"
    } > "$1"
}

# print_version_info <version_file> <label>
print_version_info() {
    if [ -f "$1" ]; then
        echo "$2 backup was created with script v$(sed -n '1p' "$1") on $(sed -n '2p' "$1")"
        echo "$2 backup epoch timestamp: $(sed -n '3p' "$1") (use this for backup-delta)"
        echo "Current script version: v$SCRIPT_VERSION"
    else
        echo "WARNING: No version info found in backup. Backup may have been created with an older script version."
    fi
}

# Print a file listing the accounts to restore: emails.txt, or one derived from the
# *.tgz archives in $1 when emails.txt is missing. GAL sync accounts are skipped
# (backups made before v1.4.1 include them); recreate them on the target with zmgsautil
account_list() {
    if [ -s "$BACKUP_DIR/$DIR_EMAILS" ]; then
        cat "$BACKUP_DIR/$DIR_EMAILS"
    else
        find "$1" -maxdepth 1 -name '*.tgz' | sed 's#.*/##; s/\.tgz$//'
    fi | grep '@' | grep -vi '^galsync[^@]*@' > "$WORK_DIR/accounts"
    echo "$WORK_DIR/accounts"
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
        export -f "$func" log zcurl get_attr split_account_dump restore_signatures sig_id_names
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
# Remaining args are zmprov options (e.g. -l).
# `-f` is required: without it zmprov opens its interactive shell, which reads the
# terminal instead of stdin and hangs
zmprov_batch() {
    local name=$1 consumer=$2 f pids=()
    shift 2
    for f in "$WORK_DIR/$name".[0-9]*; do
        [ -s "$f" ] || continue
        zmprov "$@" -f "$f" < /dev/null | "$consumer" &
        pids+=($!)
    done
    # Wait for these sessions only, not the `tee` log process substitution
    if [ ${#pids[@]} -gt 0 ]; then
        wait "${pids[@]}"
    fi
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

# Split `zmprov ga` and `zmprov gsig` output into per-account backup files under $1.
# $2 lists the accounts: a "# name <account>" header starts an account, any other
# "# name <signature>" header (from gsig) starts the next signature of that account
split_account_dump() {
    awk -v d="$1" -v list="$2" -v up="$DIR_USERPASS" -v ud="$DIR_USERDATA" -v al="$DIR_ALIAS" \
        -v fw="$DIR_FORWARD" -v sg="$DIR_SIGNATURE" -v fl="$DIR_FILTER" '
        function aspec(k, dir, ext, mode) { adir[k] = dir; aext[k] = ext; amode[k] = mode }
        function sspec(k, ext, mode) { sext[k] = ext; smode[k] = mode }
        function emit(path, text) { print text > path; opened[path] = 1 }
        function touch(path) { printf "" > path; opened[path] = 1 }
        function flushval() {
            if (cur != "") {
                sub(/\n+$/, "", buf)
                emit(curpath, buf)
            }
            cur = ""
        }
        function finish(   path) {
            flushval()
            if (u != "") emit(d "/" sg "/" u ".sigcount", n)
            for (path in opened) close(path)
            split("", opened)
            u = ""
        }
        function start(name,   k) {
            finish()
            u = name
            n = 0
            # Every account-level file exists, even when the attribute is not set
            for (k in adir) touch(d "/" adir[k] "/" u aext[k])
        }
        BEGIN {
            while ((getline line < list) > 0) acct[tolower(line)] = 1
            # mode: v = value only, l = whole "attr: value" line, m = multi-line value
            aspec("userPassword", up, ".shadow", "v")
            aspec("cn", ud, ".txt", "l"); aspec("sn", ud, ".txt", "l")
            aspec("givenName", ud, ".txt", "l"); aspec("displayName", ud, ".txt", "l")
            aspec("zimbraMailAlias", al, ".txt", "v")
            aspec("zimbraMailForwardingAddress", fw, ".txt", "v")
            aspec("zimbraSignatureName", sg, ".name", "v")
            aspec("zimbraPrefMailSignatureHTML", sg, ".signature", "m")
            aspec("zimbraPrefMailSignature", sg, ".text", "m")
            aspec("zimbraPrefDefaultSignatureId", sg, ".defaults", "l")
            aspec("zimbraPrefForwardReplySignatureId", sg, ".defaults", "l")
            aspec("zimbraMailSieveScript", fl, ".filter", "m")
            aspec("zimbraMailOutgoingSieveScript", fl, ".outgoing", "m")
            sspec("zimbraSignatureName", "name", "v")
            sspec("zimbraSignatureId", "id", "v")
            sspec("zimbraPrefMailSignatureHTML", "html", "m")
            sspec("zimbraPrefMailSignature", "text", "m")
        }
        { sub(/^(prov> )+/, "") }
        /^# name / {
            name = substr($0, 8)
            if (tolower(name) in acct) {
                start(name)
            } else if (u != "") {
                flushval()
                n++
            }
            next
        }
        /^ERROR: / { flushval(); next }
        # Attribute line. Unknown zimbra* attributes end the previous multi-line value
        # and are ignored
        /^(userPassword|cn|sn|givenName|displayName|zimbra[A-Za-z]*): / {
            if (u == "") next
            flushval()
            k = substr($0, 1, index($0, ":") - 1)
            value = substr($0, length(k) + 3)
            if (n == 0 && (k in amode)) {
                mode = amode[k]
                path = d "/" adir[k] "/" u aext[k]
            } else if (n > 0 && (k in smode)) {
                mode = smode[k]
                path = d "/" sg "/" u ".sig" n "." sext[k]
            } else {
                next
            }
            if (mode == "m") {
                cur = k
                curpath = path
                buf = value
            } else {
                emit(path, mode == "l" ? $0 : value)
            }
            next
        }
        # Continuation lines of multi-line values (signatures, sieve scripts)
        cur != "" { buf = buf "\n" $0 }
        END { finish() }'
}

# Batch output consumers for split_account_dump
split_backup_dump() {
    split_account_dump "$BACKUP_DIR" "$BACKUP_DIR/$DIR_EMAILS"
}

split_target_dump() {
    split_account_dump "$WORK_DIR/target" "$WORK_DIR/check_list"
}

# Print "<id><TAB><name>" for each signature in `zmprov gsig` output
sig_id_names() {
    awk '{ sub(/^(prov> )+/, "") }
        /^# name / { if (id != "") print id "\t" name; id = ""; name = "" }
        /^zimbraSignatureId: / { id = $2 }
        /^zimbraSignatureName: / { name = substr($0, 22) }
        END { if (id != "") print id "\t" name }'
}

# True when backup tree $1 holds at least one signature for account $2
has_signature_backup() {
    local count
    count=$(cat "$1/$DIR_SIGNATURE/$2.sigcount" 2>/dev/null)
    [ "${count:-0}" -gt 0 ] || [ -s "$1/$DIR_SIGNATURE/$2.signature" ] || [ -s "$1/$DIR_SIGNATURE/$2.text" ]
}

# One line per filter and signature of account $2 in backup tree $1, with whitespace-
# insensitive checksums: "filter <sum>", "outgoing <sum>", "sig <name> <html> <text>".
# Backups without per-signature files fall back to the account-level signature
settings_lines() {
    local dir=$1 email=$2 f base
    for f in filter outgoing; do
        if [ -s "$dir/$DIR_FILTER/$email.$f" ]; then
            echo "$f $(tr -d '[:space:]' < "$dir/$DIR_FILTER/$email.$f" | cksum)"
        fi
    done
    if compgen -G "$dir/$DIR_SIGNATURE/$email.sig*.name" > /dev/null; then
        for f in "$dir/$DIR_SIGNATURE/$email".sig*.name; do
            base=${f%.name}
            sig_line "$(cat "$f")" "$base.html" "$base.text"
        done
    elif has_signature_backup "$dir" "$email"; then
        sig_line "$(cat "$dir/$DIR_SIGNATURE/$email.name" 2>/dev/null)" \
            "$dir/$DIR_SIGNATURE/$email.signature" "$dir/$DIR_SIGNATURE/$email.text"
    fi
}

sig_line() {
    echo "sig ${1:-Signature} $(tr -d '[:space:]' 2>/dev/null < "$2" | cksum) $(tr -d '[:space:]' 2>/dev/null < "$3" | cksum)"
}

# True when every filter and signature of account $1 in the backup is on the target
# ($WORK_DIR/target); extra signatures on the target are ignored
settings_match() {
    settings_lines "$WORK_DIR/target" "$1" > "$WORK_DIR/target_lines"
    ! settings_lines "$BACKUP_DIR" "$1" | grep -vxF -f "$WORK_DIR/target_lines" | grep -q .
}

# Read the current filters and signatures of the accounts in $1 into $WORK_DIR/target
collect_target_settings() {
    rm -rf "$WORK_DIR/target" "$WORK_DIR"/check.[0-9]*
    mkdir -p "$WORK_DIR/target"/{"$DIR_USERPASS","$DIR_USERDATA","$DIR_ALIAS","$DIR_FORWARD","$DIR_SIGNATURE","$DIR_FILTER"}
    cp "$1" "$WORK_DIR/check_list"
    awk -v n="$JOBS" -v p="$WORK_DIR/check" -v attrs="$SETTINGS_ATTRS" \
        '/@/ { c = p "." (NR % n); print "ga " $0 " " attrs > c; print "gsig " $0 > c }' "$1"
    zmprov_batch check split_target_dump -l
}

# Make filters and signatures on this server match the backup for the accounts in $1:
# compare, restore the accounts that differ, compare again, report what still differs
sync_settings() {
    local list=$1 email pass wanted="$WORK_DIR/settings_wanted" todo="$WORK_DIR/settings_todo"
    while IFS= read -r email; do
        [ -n "$(settings_lines "$BACKUP_DIR" "$email")" ] && echo "$email"
    done < <(grep '@' "$list") > "$wanted"
    if [ ! -s "$wanted" ]; then
        log "No signatures or filters in the backup of $DOMAIN"
        return
    fi
    cp "$wanted" "$todo"
    for pass in 1 2 3; do
        collect_target_settings "$todo"
        while IFS= read -r email; do
            settings_match "$email" || echo "$email"
        done < "$todo" > "$todo.next"
        mv "$todo.next" "$todo"
        if [ ! -s "$todo" ]; then
            log "Signatures and filters verified for $(count_accounts "$wanted") account(s)"
            rm -f "$BACKUP_DIR/failed_settings.txt"
            return
        fi
        if [ $pass -eq 3 ]; then
            break
        fi
        log "Restoring signatures and filters for $(count_accounts "$todo") account(s)"
        run_each restore_account_settings "$todo" multiline
    done
    cp "$todo" "$BACKUP_DIR/failed_settings.txt"
    log "WARNING: Signatures/filters still differ from the backup for $(count_accounts "$todo") account(s), listed in $BACKUP_DIR/failed_settings.txt"
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

# Fallback: back up one account (attributes and signatures) without a batch session
backup_account() {
    # shellcheck disable=SC2086
    { zmprov -l ga "$1" $ACCOUNT_ATTRS; zmprov -l gsig "$1"; } | split_account_dump "$BACKUP_DIR" "$BACKUP_DIR/$DIR_EMAILS"
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

# Restore aliases, forwarding addresses, filters and signatures of one account.
# With $2 = "multiline" only filters and signatures are restored (aliases and
# forwarding are done by the batch session)
restore_account_settings() {
    local email=$1 only_multiline=$2 alias fwd filter outgoing args=()
    if [ -z "$only_multiline" ]; then
        if [ -f "$BACKUP_DIR/$DIR_ALIAS/$email.txt" ]; then
            for alias in $(grep '@' "$BACKUP_DIR/$DIR_ALIAS/$email.txt"); do
                zmprov aaa "$email" "$alias"
                log "$email HAS ALIAS $alias --- Restored"
            done
        fi
        if [ -f "$BACKUP_DIR/$DIR_FORWARD/$email.txt" ]; then
            for fwd in $(grep '@' "$BACKUP_DIR/$DIR_FORWARD/$email.txt"); do
                zmprov ma "$email" +zimbraMailForwardingAddress "$fwd"
            done
        fi
    fi

    filter=$(cat "$BACKUP_DIR/$DIR_FILTER/$email.filter" 2>/dev/null)
    outgoing=$(cat "$BACKUP_DIR/$DIR_FILTER/$email.outgoing" 2>/dev/null)
    if [ -n "$filter" ]; then
        args+=(zimbraMailSieveScript "$filter")
    fi
    if [ -n "$outgoing" ]; then
        args+=(zimbraMailOutgoingSieveScript "$outgoing")
    fi
    if [ ${#args[@]} -gt 0 ] && ! zmprov ma "$email" "${args[@]}"; then
        log "ERROR: Filter restore failed for .... $email"
    fi

    restore_signatures "$email"
    log "Settings restored for .... $email (filter: $([ -n "$filter$outgoing" ] && echo yes || echo no))"
}

# Recreate the signatures of one account and its default/reply signature choice.
# Backups from v1.6.0 hold every signature (zmprov gsig); older ones only the
# account-level signature
restore_signatures() {
    local email=$1 sigdir="$BACKUP_DIR/$DIR_SIGNATURE" f base name html text id attr old_id new_id sid sname args
    local -A old_names new_ids
    if compgen -G "$sigdir/$email.sig*.name" > /dev/null; then
        for f in "$sigdir/$email".sig*.name; do
            base=${f%.name}
            name=$(cat "$f")
            [ -n "$name" ] || continue
            html=$(cat "$base.html" 2>/dev/null)
            text=$(cat "$base.text" 2>/dev/null)
            id=$(cat "$base.id" 2>/dev/null)
            if [ -n "$id" ]; then
                old_names[$id]=$name
            fi
            args=()
            if [ -n "$html" ]; then
                args+=(zimbraPrefMailSignatureHTML "$html")
            fi
            if [ -n "$text" ]; then
                args+=(zimbraPrefMailSignature "$text")
            fi
            # Update the signature when it already exists (re-run, or restored by an
            # older version); an empty value clears the other format
            if ! zmprov csig "$email" "$name" "${args[@]}" > /dev/null 2>&1; then
                zmprov msig "$email" "$name" zimbraPrefMailSignatureHTML "$html" zimbraPrefMailSignature "$text" ||
                    log "ERROR: Signature '$name' restore failed for .... $email"
            fi
        done

        # Signature ids change on the target: map old id -> name -> new id
        if [ -s "$sigdir/$email.defaults" ]; then
            while IFS=$'\t' read -r sid sname; do
                [ -n "$sname" ] && new_ids[$sname]=$sid
            done < <(zmprov -l gsig "$email" | sig_id_names)
            args=()
            for attr in zimbraPrefDefaultSignatureId zimbraPrefForwardReplySignatureId; do
                old_id=$(get_attr "$attr" "$sigdir/$email.defaults")
                [ -n "$old_id" ] && [ -n "${old_names[$old_id]+set}" ] || continue
                new_id=${new_ids[${old_names[$old_id]}]}
                if [ -n "$new_id" ]; then
                    args+=("$attr" "$new_id")
                fi
            done
            if [ ${#args[@]} -gt 0 ]; then
                zmprov ma "$email" "${args[@]}"
            fi
        fi
        return
    fi

    # Older backup: the account-level signature only
    name=$(cat "$sigdir/$email.name" 2>/dev/null)
    html=$(cat "$sigdir/$email.signature" 2>/dev/null)
    text=$(cat "$sigdir/$email.text" 2>/dev/null)
    if [ -z "$html$text" ]; then
        return
    fi
    args=(zimbraSignatureName "${name:-Signature}")
    if [ -n "$html" ]; then
        args+=(zimbraPrefMailSignatureHTML "$html")
    fi
    if [ -n "$text" ]; then
        args+=(zimbraPrefMailSignature "$text")
    fi
    zmprov ma "$email" "${args[@]}"
    id=$(zmprov ga "$email" zimbraSignatureId | sed -n 's/^zimbraSignatureId: //p')
    if [ -n "$id" ]; then
        zmprov ma "$email" zimbraPrefDefaultSignatureId "$id" zimbraPrefForwardReplySignatureId "$id"
    fi
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
    # All lists of the server are fetched once per run and filtered per domain
    if [ ! -f "$WORK_ROOT/all_dls" ]; then
        zmprov gadl > "$WORK_ROOT/all_dls"
    fi
    awk -F@ -v d="$DOMAIN" 'tolower($2) == d' "$WORK_ROOT/all_dls" > "$BACKUP_DIR/$DIR_DISTLIST"
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
    # ga and gsig of one account stay in the same session, in that order
    awk -v n="$JOBS" -v p="$WORK_DIR/ga" -v attrs="$ACCOUNT_ATTRS" \
        '/@/ { c = p "." (NR % n); print "ga " $0 " " attrs > c; print "gsig " $0 > c }' "$BACKUP_DIR/$DIR_EMAILS"
    zmprov_batch ga split_backup_dump -l

    while IFS= read -r email; do
        [ -f "$BACKUP_DIR/$DIR_USERDATA/$email.txt" ] && [ -f "$BACKUP_DIR/$DIR_SIGNATURE/$email.sigcount" ] ||
            echo "$email"
    done < <(grep '@' "$BACKUP_DIR/$DIR_EMAILS") > "$WORK_DIR/ga_missing"
    missing=$(count_accounts "$WORK_DIR/ga_missing")
    if [ "$missing" -gt 0 ]; then
        log "WARNING: $missing account(s) missing from batch output, retrying one by one"
        run_each backup_account "$WORK_DIR/ga_missing"
    fi
    log "Account data downloaded for $(find "$BACKUP_DIR/$DIR_USERDATA" -name '*.txt' | wc -l | tr -d ' ') of $total account(s)"
    check_backup_settings
}

# Cross-check against LDAP that every account with a filter or signature has it in the
# backup; accounts that do not are fetched again one by one
check_backup_settings() {
    local base="(&(objectClass=zimbraAccount)(mail=*@$DOMAIN)(!(zimbraIsSystemResource=TRUE))(!(zimbraIsSystemAccount=TRUE))"
    local email pass filters signatures
    zmprov -l sa "$base(|(zimbraMailSieveScript=*)(zimbraMailOutgoingSieveScript=*)))" > "$WORK_DIR/has_filter"
    zmprov -l sa "$base(|(zimbraPrefMailSignatureHTML=*)(zimbraPrefMailSignature=*)))" > "$WORK_DIR/has_signature"
    for pass in 1 2; do
        {
            while IFS= read -r email; do
                [ -s "$BACKUP_DIR/$DIR_FILTER/$email.filter" ] || [ -s "$BACKUP_DIR/$DIR_FILTER/$email.outgoing" ] ||
                    echo "$email"
            done < "$WORK_DIR/has_filter"
            while IFS= read -r email; do
                has_signature_backup "$BACKUP_DIR" "$email" || echo "$email"
            done < "$WORK_DIR/has_signature"
        } | sort -u > "$WORK_DIR/settings_missing"
        if [ ! -s "$WORK_DIR/settings_missing" ] || [ $pass -eq 2 ]; then
            break
        fi
        log "WARNING: Filters/signatures missing from the backup for $(count_accounts "$WORK_DIR/settings_missing") account(s), fetching them one by one"
        run_each backup_account "$WORK_DIR/settings_missing"
    done
    if [ -s "$WORK_DIR/settings_missing" ]; then
        cp "$WORK_DIR/settings_missing" "$BACKUP_DIR/failed_settings_backup.txt"
        log "ERROR: Filters/signatures could not be backed up for $(count_accounts "$WORK_DIR/settings_missing") account(s), listed in $BACKUP_DIR/failed_settings_backup.txt"
    else
        rm -f "$BACKUP_DIR/failed_settings_backup.txt"
    fi
    filters=$(find "$BACKUP_DIR/$DIR_FILTER" -type f -size +0 | sed 's#.*/##; s/\.[a-z]*$//' | sort -u | grep -c '@')
    signatures=0
    while IFS= read -r email; do
        if has_signature_backup "$BACKUP_DIR" "$email"; then
            signatures=$((signatures + 1))
        fi
    done < <(grep '@' "$BACKUP_DIR/$DIR_EMAILS")
    log "Filters backed up for $filters account(s) (LDAP: $(count_accounts "$WORK_DIR/has_filter")), signatures for $signatures account(s) (LDAP: $(count_accounts "$WORK_DIR/has_signature"))"
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

# Accounts phase of restore: accounts, passwords, aliases and forwarding through zmprov
# batch sessions; signature and filter (multi-line values) per account
restore_accounts() {
    local i=0 email data cn sn given display shadow line missing accounts
    accounts=$(account_list "$BACKUP_DIR/$DIR_MAILBOX")
    log "Preparing account commands"
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
        i=$((i + 1))
    done 3< "$accounts"

    log "Restoring $i account(s) with password, alias and forwarding address"
    zmprov_batch accounts batch_errors

    # Accounts the batch could not create are retried with the per-account path
    list_domain_accounts | sort > "$WORK_DIR/existing"
    sort "$accounts" | comm -23 - "$WORK_DIR/existing" > "$WORK_DIR/missing"
    missing=$(count_accounts "$WORK_DIR/missing")
    if [ "$missing" -gt 0 ]; then
        log "WARNING: $missing account(s) not created by batch, retrying one by one"
        run_each restore_account "$WORK_DIR/missing"
        run_each restore_account_settings "$WORK_DIR/missing"
    fi
    log "Restore User Account Completed"

    log "Restoring signatures and filters"
    sync_settings "$accounts"
}

# Distribution lists and members of the current domain, run after the accounts of
# every domain exist
restore_dls() {
    if [ -s "$BACKUP_DIR/$DIR_DISTLIST" ]; then
        log "Restoring distribution list for $DOMAIN"
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

    # The import must not leave filters or signatures behind; re-check when the
    # account backup is present
    if [ -d "$BACKUP_DIR/$DIR_SIGNATURE" ]; then
        log "Re-checking signatures and filters after mailbox import"
        sync_settings "$accounts"
    fi
}

# Restore scope "settings": re-apply and verify signatures and filters of existing accounts
restore_settings() {
    local d
    for d in "${DOMAINS[@]}"; do
        if [ ! -f "$BASE_DIR/$d/$DIR_EMAILS" ] || [ ! -d "$BASE_DIR/$d/$DIR_SIGNATURE" ]; then
            log "Account backup not found in $BASE_DIR/$d (emails.txt / signature). Run backup with scope 1 (accounts) or 3 (all) first"
            exit 1
        fi
    done
    log "Restoring signatures and filters for $TARGET_LABEL (jobs: $JOBS)"
    for d in "${DOMAINS[@]}"; do
        set_domain "$d"
        log "==== Domain $DOMAIN: signatures and filters"
        sync_settings "$(account_list "$BACKUP_DIR/$DIR_MAILBOX")"
    done
    log "Restore $TARGET_LABEL (settings) completed in $(elapsed)"
}

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------

backup() {
    local d
    log "[v$SCRIPT_VERSION] Starting backup for $TARGET_LABEL"
    mkdir -p "$BASE_DIR"
    if [ -n "$ALL_DOMAINS" ]; then
        discover_domains
        if [ ${#DOMAINS[@]} -eq 0 ]; then
            log "No domains found on this server"
            exit 1
        fi
    else
        log "Verifying domain $DOMAIN"
        if ! domain_exists; then
            log "Domain $DOMAIN not found"
            exit 1
        fi
        log "Domain $DOMAIN found"
        DOMAINS=("$DOMAIN")
    fi
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
    log "Backup $TARGET_LABEL (scope: $SCOPE, jobs: $JOBS)"

    for d in "${DOMAINS[@]}"; do
        set_domain "$d"
        log "==== Domain $DOMAIN"
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
    done

    if [ "$COMPRESS" == "y" ]; then
        compress_backup
    fi
    log "Backup $TARGET_LABEL ($SCOPE) completed in $(elapsed)"
    if [ "$SCOPE" == "accounts" ]; then
        echo "Next: restore the accounts on the target, then run backup again with scope 2 (mailbox)"
    fi
}

restore() {
    local d missing_domains=() alias target
    log "[v$SCRIPT_VERSION] Starting restore for $TARGET_LABEL"
    if [ -n "$ALL_DOMAINS" ]; then
        load_backup_domains
    else
        if [ ! -d "$BACKUP_DIR" ]; then
            log "Backup directory $BACKUP_DIR not found"
            echo "Please extract the backup files to $BASE_DIR/"
            exit 1
        fi
        DOMAINS=("$DOMAIN")
    fi
    select_scope restore
    if [ "$SCOPE" == "settings" ]; then
        restore_settings
        return
    fi

    if in_scope accounts; then
        for d in "${DOMAINS[@]}"; do
            if [ ! -f "$BASE_DIR/$d/$DIR_EMAILS" ] || [ ! -d "$BASE_DIR/$d/$DIR_USERDATA" ]; then
                log "Account backup not found in $BASE_DIR/$d (emails.txt / userdata). Run backup with scope 1 (accounts) or 3 (all) first"
                exit 1
            fi
            print_version_info "$BASE_DIR/$d/backup_version.txt" "$d accounts"
        done

        # Every domain (and alias domain) is created before any account, so aliases and
        # list members that point to another domain resolve
        log "Verifying domains"
        zmprov gad > "$WORK_DIR/existing_domains"
        for d in "${DOMAINS[@]}"; do
            grep -ixF "$d" "$WORK_DIR/existing_domains" > /dev/null || missing_domains+=("$d")
        done
        if [ -n "$ALL_DOMAINS" ] && [ -s "$BASE_DIR/alias_domains.txt" ]; then
            while read -r alias target; do
                grep -ixF "$alias" "$WORK_DIR/existing_domains" > /dev/null || missing_domains+=("$alias (alias of ${target#@})")
            done < "$BASE_DIR/alias_domains.txt"
        fi
        if [ ${#missing_domains[@]} -gt 0 ]; then
            log "Domain(s) not found: ${missing_domains[*]}"
            if ! ask_yn "Do you want to create ${#missing_domains[@]} missing domain(s)?"; then
                log "Missing domain(s) not created"
                exit 1
            fi
            for d in "${DOMAINS[@]}"; do
                grep -ixF "$d" "$WORK_DIR/existing_domains" > /dev/null && continue
                if ! zmprov cd "$d"; then
                    log "Failed to create domain $d"
                    exit 1
                fi
                log "Domain $d created"
            done
            if [ -n "$ALL_DOMAINS" ] && [ -s "$BASE_DIR/alias_domains.txt" ]; then
                while read -r alias target; do
                    grep -ixF "$alias" "$WORK_DIR/existing_domains" > /dev/null && continue
                    zmprov cd "$alias" zimbraDomainType alias zimbraMailCatchAllAddress "@$alias" \
                        zimbraMailCatchAllForwardingAddress "$target" &&
                        log "Alias domain $alias created (forwards to $target)"
                done < "$BASE_DIR/alias_domains.txt"
            fi
        else
            log "All domain(s) found"
        fi
    fi

    if in_scope mailbox; then
        for d in "${DOMAINS[@]}"; do
            if [ ! -d "$BASE_DIR/$d/$DIR_MAILBOX" ]; then
                log "Mailbox backup directory $BASE_DIR/$d/$DIR_MAILBOX not found"
                echo "Please extract the mailbox backup files to $BASE_DIR/"
                exit 1
            fi
            print_version_info "$BASE_DIR/$d/$DIR_MAILBOX/backup_version.txt" "$d mailbox"
        done
        select_method restore
    fi

    log "Restoring $TARGET_LABEL (scope: $SCOPE, jobs: $JOBS)"
    if in_scope accounts; then
        for d in "${DOMAINS[@]}"; do
            set_domain "$d"
            log "==== Domain $DOMAIN: accounts"
            restore_accounts
        done
        # Lists after all accounts of all domains, so cross-domain members exist
        for d in "${DOMAINS[@]}"; do
            set_domain "$d"
            restore_dls
        done
    fi
    if in_scope mailbox; then
        for d in "${DOMAINS[@]}"; do
            set_domain "$d"
            log "==== Domain $DOMAIN: mailbox"
            restore_mailboxes
        done
    fi
    log "Restore $TARGET_LABEL ($SCOPE) completed in $(elapsed)"

    if [ "$SCOPE" == "accounts" ]; then
        echo "Next: run backup with scope 2 (mailbox) on the source, then restore with scope 2 here"
        return
    fi
    if ask_yn "Do you want to delete the backup files?"; then
        for d in "${DOMAINS[@]}"; do
            rm -rf "${BASE_DIR:?}/$d"
        done
        if [ -n "$ALL_DOMAINS" ]; then
            rm -f "$BASE_DIR/domains.txt" "$BASE_DIR/alias_domains.txt"
        fi
        log "Backup files deleted"
    fi
    log "All restore process for $TARGET_LABEL completed"
}

backup-delta() {
    local d input epoch version_file paths=()
    log "[v$SCRIPT_VERSION] Starting delta backup for $TARGET_LABEL"
    echo "Note: curl cannot set start time. Delta backup uses zmmailbox."
    if [ -n "$ALL_DOMAINS" ]; then
        load_backup_domains
    else
        DOMAINS=("$DOMAIN")
    fi
    for d in "${DOMAINS[@]}"; do
        if [ ! -f "$BASE_DIR/$d/$DIR_EMAILS" ]; then
            log "Account list $BASE_DIR/$d/$DIR_EMAILS not found. Run a full backup first"
            exit 1
        fi
    done

    echo "Please enter the start time as epoch (seconds or milliseconds)"
    echo "Example: 1754913600"
    echo "Get epoch time from https://www.epochconverter.com/"
    if [ -n "$ALL_DOMAINS" ]; then
        echo "Press Enter to use each domain's mailbox backup start time"
    else
        version_file=$(delta_version_file "$DOMAIN")
        if [ -n "$(sed -n '3p' "$version_file" 2>/dev/null)" ]; then
            echo "Press Enter to use the mailbox backup start time: $(sed -n '3p' "$version_file") ($(sed -n '2p' "$version_file"))"
        fi
    fi
    read -r input
    if [ -n "$input" ] && [[ ! "$input" =~ ^[0-9]+$ ]]; then
        log "A numeric epoch time is required"
        exit 1
    fi

    export MAILBOX_METHOD="zmmailbox"
    for d in "${DOMAINS[@]}"; do
        set_domain "$d"
        epoch=${input:-$(sed -n '3p' "$(delta_version_file "$d")" 2>/dev/null)}
        if [ -z "$epoch" ]; then
            log "WARNING: No start time for $d (no mailbox backup found), skipped"
            continue
        fi
        # The REST `start` parameter is in milliseconds; convert seconds input
        if [ ${#epoch} -le 10 ]; then
            epoch="${epoch}000"
        fi
        log "==== Domain $DOMAIN: delta start time (ms): $epoch (jobs: $JOBS)"
        mkdir -p "$BACKUP_DIR/$DIR_DELTA"
        export FAILED_FILE="$BACKUP_DIR/failed_mailbox_delta.txt"
        : > "$FAILED_FILE"
        run_each export_mailbox "$BACKUP_DIR/$DIR_EMAILS" "$BACKUP_DIR/$DIR_DELTA" "$epoch"
        report_failures "Mailbox delta backup"
        paths+=("$d/$DIR_DELTA")
    done
    log "Backup Mailbox Delta Completed"

    if [ ${#paths[@]} -gt 0 ]; then
        if [ -n "$ALL_DOMAINS" ]; then
            paths+=(domains.txt)
        fi
        log "Compressing delta backup files"
        tar -C "$BASE_DIR" -czf "$BASE_DIR/$ARCHIVE_PREFIX-backup-delta.tar.gz" "${paths[@]}"
        log "Delta backup files compressed to $BASE_DIR/$ARCHIVE_PREFIX-backup-delta.tar.gz in $(elapsed)"
        echo "Please copy and extract the delta backup files to the target server $BASE_DIR/"
        echo "Then run: $0 restore-delta $DOMAIN_ARG"
    fi
    exit 0
}

restore-delta() {
    local d accounts restored=()
    log "[v$SCRIPT_VERSION] Starting delta restore for $TARGET_LABEL"
    if [ -n "$ALL_DOMAINS" ]; then
        load_backup_domains
    else
        DOMAINS=("$DOMAIN")
    fi
    for d in "${DOMAINS[@]}"; do
        if [ -d "$BASE_DIR/$d/$DIR_DELTA" ]; then
            restored+=("$d")
        elif [ -n "$ALL_DOMAINS" ]; then
            log "WARNING: No delta backup for $d, skipped"
        else
            log "Delta backup directory $BASE_DIR/$d/$DIR_DELTA not found"
            echo "Please extract the delta backup files to $BASE_DIR/"
            exit 1
        fi
    done
    if [ ${#restored[@]} -eq 0 ]; then
        log "No delta backups found in $BASE_DIR"
        exit 1
    fi

    select_method restore

    for d in "${restored[@]}"; do
        set_domain "$d"
        # The delta archive has no account list; it is derived if the full backup was deleted
        accounts=$(account_list "$BACKUP_DIR/$DIR_DELTA")
        log "==== Domain $DOMAIN: restoring delta mailbox for $(count_accounts "$accounts") account(s) (jobs: $JOBS)"
        export FAILED_FILE="$BACKUP_DIR/failed_mailbox_delta_restore.txt"
        : > "$FAILED_FILE"
        run_each import_mailbox "$accounts" "$BACKUP_DIR/$DIR_DELTA"
        report_failures "Mailbox delta restore"
    done
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

# `--all` processes every domain of the server instead of one
ALL_DOMAINS=""
DOMAIN_ARG=$DOMAIN
ARCHIVE_PREFIX=$DOMAIN
TARGET_LABEL=$DOMAIN
if [ "$DOMAIN" == "--all" ]; then
    ALL_DOMAINS=1
    ARCHIVE_PREFIX="all-domains"
    TARGET_LABEL="all domains"
fi
DOMAINS=()

if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid JOBS value '$JOBS', using 1"
    JOBS=1
fi

exec > >(tee -a "$LOG_FILE") 2>&1

# One scratch directory per domain under WORK_ROOT (see set_domain)
WORK_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK_ROOT"' EXIT
WORK_DIR="$WORK_ROOT/main"
mkdir -p "$WORK_DIR"

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
