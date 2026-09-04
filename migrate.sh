#!/bin/bash
# ============================================================
# Zimbra Migration Script
# Version: 1.1.1
# Last Modified: 2026-07-08
# ============================================================
SCRIPT_VERSION="1.1.1"

export ACTION=$1
export DOMAIN=$2
export USERNAME=$(whoami)
export BASE_DIR="/opt/zimbra/backup"
export BACKUP_DIR="$BASE_DIR/$DOMAIN"
export LOG_FILE="/opt/zimbra/log/zimbramigration.log"

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

exec > >(tee -a "$LOG_FILE") 2>&1

version() {
    echo "xzimbramigration.sh v$SCRIPT_VERSION"
}

if [ "$ACTION" == "version" ] || [ "$ACTION" == "--version" ] || [ "$ACTION" == "-v" ]; then
    version
    exit 0
fi

if [ "$USERNAME" != "zimbra" ]; then
    echo "Run this script as zimbra user"
    exit 1
fi

if [ -z "$ACTION" ]; then
    echo "Usage: $0 <action>"
    echo "Actions:"
    echo "  backup <domain>"
    echo "  restore <domain>"
    echo "  backup-delta <domain>"
    echo "  restore-delta <domain>"
    echo "  version"
    echo "Example: $0 backup contoh.com"
    echo "Example: $0 restore contoh.com"
    exit 1
fi

if [ -z "$DOMAIN" ] && [ "$ACTION" != "version" ]; then
    echo "Usage: $0 <action> <domain>"
    echo "Example: $0 backup contoh.com"
    echo "Example: $0 restore contoh.com"
    exit 1
fi

backup() {
    echo "[v$SCRIPT_VERSION] Starting backup for $DOMAIN"
    echo "Verifying domain $DOMAIN"
    zmprov gad | grep $DOMAIN > /dev/null
    if [ $? -ne 0 ]; then
        echo "Domain $DOMAIN not found"
        exit 1
    fi
    echo "Domain $DOMAIN found"
    echo "Do you want to compress the backup files after backup process? (y/n)"
    read COMPRESS
    if [[ ! "$COMPRESS" =~ ^[yn]$ ]]; then
        echo "Invalid input. Please enter 'y' for yes or 'n' for no"
        exit 1
    fi
    echo ""
    echo "Backup $DOMAIN"

    # Save script version used for this backup
    echo "$SCRIPT_VERSION" > "$BACKUP_DIR/backup_version.txt"
    date "+%Y-%m-%d %H:%M:%S" >> "$BACKUP_DIR/backup_version.txt"
    date "+%s" >> "$BACKUP_DIR/backup_version.txt"

    echo "Get all admin account"
    zmprov -l sa "(&(objectClass=zimbraAccount)(zimbraIsAdminAccount=TRUE)(|(mail=*@$DOMAIN)(zimbraMailAlias=*@$DOMAIN)))" > "$BACKUP_DIR/$DIR_ADMIN"
    echo "Get all emails account"
    zmprov -l sa "(&(objectClass=zimbraAccount)(mail=*@$DOMAIN))" > "$BACKUP_DIR/$DIR_EMAILS"
    echo "Get all distribution list"
    zmprov gadl | grep $DOMAIN > "$BACKUP_DIR/$DIR_DISTLIST"
    if [ -s "$BACKUP_DIR/$DIR_DISTLIST" ]; then
        mkdir -p "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS"
        for i in $(cat "$BACKUP_DIR/$DIR_DISTLIST"); do
            zmprov gdlm $i > "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS/$i.txt"
            echo "Distribution list members downloaded for .... $i"
        done
    fi
    echo "Get all user password"
    mkdir -p "$BACKUP_DIR/$DIR_USERPASS"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmprov -l ga $i userPassword | grep userPassword: | awk '{ print $2}' > "$BACKUP_DIR/$DIR_USERPASS/$i.shadow"
        echo "User password downloaded for .... $i"
    done
    echo "Get all user data"
    mkdir -p "$BACKUP_DIR/$DIR_USERDATA"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmprov ga $i | grep -i "Name:\|cn:" | grep -v "zimbraPortalName:" > "$BACKUP_DIR/$DIR_USERDATA/$i.txt"
        echo "User data downloaded for .... $i"
    done
    echo "Get all mailbox"
    mkdir -p "$BACKUP_DIR/$DIR_MAILBOX"
    for email in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmmailbox -z -m $email getRestURL '/?fmt=tgz' > "$BACKUP_DIR/$DIR_MAILBOX/$email.tgz"
        #for delta to re sync mailbox
        #use this instead
        #zmmailbox -z -m $email getRestURL '/?fmt=tgz&start=1754413200000' > "$BACKUP_DIR/$DIR_MAILBOX/$email.tgz"
        #it uses epoch time
        echo "Mailbox downloaded for .... $email"
    done
    echo "Get all alias"
    mkdir -p "$BACKUP_DIR/$DIR_ALIAS"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmprov ga $i | grep zimbraMailAlias | awk '{print $2}' > "$BACKUP_DIR/$DIR_ALIAS/$i.txt"
        echo "Alias downloaded for .... $i"
    done
    echo "Get all forwarding address"
    mkdir -p "$BACKUP_DIR/$DIR_FORWARD"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmprov ga $i | grep 'zimbraMailForwardingAddress:' | awk '{print $2}' > "$BACKUP_DIR/$DIR_FORWARD/$i.txt"
        echo "Forwarding address downloaded for .... $i"
    done
    echo "Get all signature"
    mkdir -p "$BACKUP_DIR/$DIR_SIGNATURE"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmprov ga $i zimbraPrefMailSignatureHTML > /tmp/signature
        sed -i -e "1d" /tmp/signature
        sed 's/zimbraPrefMailSignatureHTML: //g' /tmp/signature > "$BACKUP_DIR/$DIR_SIGNATURE/$i.signature"
        rm -rf /tmp/signature
        zmprov ga $i zimbraSignatureName > /tmp/name
        sed -i -e "1d" /tmp/name
        sed 's/zimbraSignatureName: //g' /tmp/name > "$BACKUP_DIR/$DIR_SIGNATURE/$i.name"
        rm -rf /tmp/name
        echo "Signature downloaded for .... $i"
    done
    echo "Get all Filters"
    mkdir -p "$BACKUP_DIR/$DIR_FILTER"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmprov ga $i zimbraMailSieveScript > /tmp/filter
        sed -i -e "1d" /tmp/filter
        sed 's/zimbraMailSieveScript: //g' /tmp/filter > "$BACKUP_DIR/$DIR_FILTER/$i.filter"
        rm -f /tmp/filter
        echo "Filter  downloaded for .... $i"
    done
    if [ "$COMPRESS" == "y" ]; then
        echo "Compressing backup files"
        cd "$BASE_DIR"
        tar -czvf "$DOMAIN-backup.tar.gz" "$DOMAIN"
        echo "Backup files compressed"
    fi
    echo "Backup $DOMAIN completed"
}

restore() {
    echo "[v$SCRIPT_VERSION] Starting restore for $DOMAIN"
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "Backup directory $BACKUP_DIR not found"
        echo "Please extract the backup files to $BASE_DIR/"
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

    echo "Verifying domain $DOMAIN"
    zmprov gad | grep $DOMAIN > /dev/null
    if [ $? -ne 0 ]; then
        echo "Domain $DOMAIN not found"
        echo "Do you want to create domain $DOMAIN? (y/n)"
        read CREATE_DOMAIN
        if [[ ! "$CREATE_DOMAIN" =~ ^[yn]$ ]]; then
            echo "Invalid input. Please enter 'y' for yes or 'n' for no"
            echo "Please run this script again"
            exit 1
        fi
        if [ "$CREATE_DOMAIN" == "y" ]; then
            zmprov cd $DOMAIN
            echo "Domain $DOMAIN created"
        else
            echo "Domain $DOMAIN not found and not created"
            exit 1
        fi
        echo "Please run this script again"
        exit 1
    fi
    echo "Domain $DOMAIN found"
    echo "Restoring $DOMAIN"

    USERPASS="$BACKUP_DIR/$DIR_USERPASS"
    USERDATA="$BACKUP_DIR/$DIR_USERDATA"
    USERS="$BACKUP_DIR/$DIR_EMAILS"

    echo "Restoring user account"
    for i in $(cat "$USERS"); do
        commonName=$(grep "cn:" "$USERDATA/$i.txt" | cut -d ":" -f2)
        givenName=$(grep "givenName:" "$USERDATA/$i.txt" | cut -d ":" -f2)
        displayName=$(grep "displayName:" "$USERDATA/$i.txt" | cut -d ":" -f2)
        if [ -z "$givenName" ]; then
            givenName=$commonName
        fi
        if [ -z "$displayName" ]; then
            displayName=$commonName
        fi
        shadowpass=$(cat "$USERPASS/$i.shadow")
        tmpPass="CHANGEme2025"
        zmprov ca $i $tmpPass cn "$givenName" displayName "$displayName" givenName "$givenName"
        zmprov ma $i userPassword "$shadowpass"
        echo "User account restored for .... $i"
    done
    echo "Restore User Account Completed"

    echo "Restoring mailbox"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmmailbox -z -m $i postRestURL "/?fmt=tgz&resolve=skip" "$BACKUP_DIR/$DIR_MAILBOX/$i.tgz"
        echo "$i -- finished "
    done
    echo "Restore Mailbox Completed"

    echo "Restoring alias"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        if [ -f "$BACKUP_DIR/$DIR_ALIAS/$i.txt" ]; then
            for j in $(grep '@' "$BACKUP_DIR/$DIR_ALIAS/$i.txt"); do
                zmprov aaa $i $j
                echo "$i HAS ALIAS $j --- Restored"
            done
        fi
    done
    echo "Restore Alias Completed"

    echo "Restoring signature"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmprov ma $i zimbraSignatureName "$(cat "$BACKUP_DIR/$DIR_SIGNATURE/$i.name")"
        zmprov ma $i zimbraPrefMailSignatureHTML "$(cat "$BACKUP_DIR/$DIR_SIGNATURE/$i.signature")"
        zmprov ga $i zimbraSignatureId > /tmp/firmaid
        sed -i -e "1d" /tmp/firmaid
        firmaid=$(sed 's/zimbraSignatureId: //g' /tmp/firmaid)
        zmprov ma $i zimbraPrefDefaultSignatureId "$firmaid"
        zmprov ma $i zimbraPrefForwardReplySignatureId "$firmaid"
        rm -rf /tmp/firmaid
        echo "Signature for $i done!"
    done
    echo "Restore Signature Completed"

    echo "Restoring filter"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmprov ma $i zimbraMailSieveScript "$(cat "$BACKUP_DIR/$DIR_FILTER/$i.filter")"
        echo "Filter Restore for account ... $i"
    done
    echo "Restore Filter Completed"

    echo "Restoring forwarding address"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        if [ -f "$BACKUP_DIR/$DIR_FORWARD/$i.txt" ]; then
            for j in $(grep '@' "$BACKUP_DIR/$DIR_FORWARD/$i.txt"); do
                zmprov ma $i +zimbraMailForwardingAddress $j
                echo "$i email forwarded to $j address"
            done
        fi
    done
    echo "Restore Forwarding Address Completed"

    if [ -s "$BACKUP_DIR/$DIR_DISTLIST" ]; then
        echo "Restoring distribution list"
        for i in $(cat "$BACKUP_DIR/$DIR_DISTLIST"); do
            zmprov cdl $i
            echo "Distribution list restored for .... $i"
        done
    fi

    if [ -s "$BACKUP_DIR/$DIR_DISTLIST" ]; then
        echo "Restoring distribution list members"
        for i in $(cat "$BACKUP_DIR/$DIR_DISTLIST"); do
            for j in $(grep -v '#' "$BACKUP_DIR/$DIR_DISTLIST_MEMBERS/$i.txt" | grep '@'); do
                zmprov adlm $i $j
                echo " $j member has been added to list $i"
            done
        done
        echo "Restore Distribution List Completed"
    fi

    echo "Restore $DOMAIN Completed. Do you want to delete the backup files? (y/n)"
    read DELETE_BACKUP
    if [[ ! "$DELETE_BACKUP" =~ ^[yn]$ ]]; then
        echo "Invalid input. Please enter 'y' for yes or 'n' for no"
        read DELETE_BACKUP
        if [[ ! "$DELETE_BACKUP" =~ ^[yn]$ ]]; then
            echo "Invalid input again. Assuming no"
            DELETE_BACKUP="n"
        fi
    fi
    if [ "$DELETE_BACKUP" == "y" ]; then
        rm -rf "$BACKUP_DIR"
        echo "Backup files deleted"
    fi
    echo "All restore process for $DOMAIN completed"
}

backup-delta() {
    echo "[v$SCRIPT_VERSION] Starting delta backup for $DOMAIN"
    echo "Please enter the epoch time"
    echo "Example: 1754913600"
    echo "Get epoch time from https://www.epochconverter.com/"
    read EPOCH_TIME
    if [ -z "$EPOCH_TIME" ]; then
        echo "Epoch time is required"
        exit 1
    fi
    echo "Get all mailbox"
    mkdir -p "$BACKUP_DIR/$DIR_DELTA"
    for email in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmmailbox -z -m $email getRestURL "/?fmt=tgz&start=$EPOCH_TIME" > "$BACKUP_DIR/$DIR_DELTA/$email.tgz"
        echo "Mailbox downloaded for .... $email"
    done
    echo "Backup Mailbox Delta Completed"
    echo "Compressing delta backup files"
    cd "$BASE_DIR"
    tar -czvf "$DOMAIN-backup-delta.tar.gz" "$DOMAIN/$DIR_DELTA"
    echo "Delta backup files compressed"
    echo "Please copy and extract the delta backup files to the target server $BASE_DIR/$DOMAIN/$DIR_DELTA/"
    echo "Please run this script again"
    exit 0
}

restore-delta() {
    echo "[v$SCRIPT_VERSION] Starting delta restore for $DOMAIN"
    if [ ! -d "$BACKUP_DIR/$DIR_DELTA" ]; then
        echo "Delta backup directory $BACKUP_DIR/$DIR_DELTA not found"
        echo "Please extract the delta backup files to $BASE_DIR/$DOMAIN/$DIR_DELTA/"
        exit 1
    fi
    echo "Restoring mailbox"
    for i in $(cat "$BACKUP_DIR/$DIR_EMAILS"); do
        zmmailbox -z -m $i postRestURL "/?fmt=tgz&resolve=skip" "$BACKUP_DIR/$DIR_DELTA/$i.tgz"
        echo "$i -- finished "
    done
    echo "Restore Mailbox Delta Completed"
}


case "$ACTION" in
    backup)
        mkdir -p "$BACKUP_DIR"
        backup "$DOMAIN"
        ;;
    restore)
        restore "$DOMAIN"
        ;;
    backup-delta)
        backup-delta "$DOMAIN"
        ;;
    restore-delta)
        restore-delta "$DOMAIN"
        ;;
    *)
        echo "Usage: $0 <action>"
        echo "Actions:"
        echo "  backup <domain>"
        echo "  restore <domain>"
        echo "  backup-delta <domain>"
        echo "  restore-delta <domain>"
        echo "  version"
        echo "Example: $0 backup contoh.com"
        echo "Example: $0 restore contoh.com"
        exit 1
        ;;
esac
