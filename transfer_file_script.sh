#!/bin/bash

# === Strict Mode ===
set -uo pipefail   # keep u and o, but not -e here because we want manual error handling
IFS=$'\n\t'

# === Configuration Section ===
SOURCE_DIR="/BSS_App_Data/bss-nfs-log/bkp_dir"
DEST_USER="svc_bss_user@safaricomet.net"
DEST_HOST="10.3.174.26"
DEST_DIR="/bss_db_data/DC2_LOGS/bkp_dir"
LOG_FILE="/home/pamrw/NOC_SCRIPT/logs/backup_transfer.log"
DAYS_OLD=5

# Email details
RECIPIENT="kibrom.legesse@partner.safaricom.et,L16DNOC.Support@safaricom.et"
EMAIL_SENDER="bss@safaricom.et"
SMTP_SERVER="10.3.124.25:25"
SUBJECT_PREFIX="[Backup Transfer] $(hostname)"

# === Utility Function ===
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# Ensure log file exists
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo "$(timestamp) - Starting backup transfer job" | tee -a "$LOG_FILE"

# === Email Prep Section ===
HTML_FILE=$(mktemp)
{
    echo "<html><body>"
    echo "<h3>$(timestamp) Backup Transfer Report</h3>"
    echo "<hr>"
} > "$HTML_FILE"

FAILURES=0
SUCCESSES=0
UPDATES=0
SKIPPED=0
DELETE_FAILS=0
TOTAL_SCANNED=0

# === Always send report on exit ===
send_report() {
    {
        echo "<hr>"
        echo "<p>Completed at: $(timestamp)</p>"
        echo "<p><b>Total files scanned:</b> $TOTAL_SCANNED</p>"
        echo "<p><b>New files copied:</b> $SUCCESSES</p>"
        echo "<p><b>Updated files:</b> $UPDATES</p>"
        echo "<p><b>Skipped (identical):</b> $SKIPPED</p>"
        echo "<p><b>Failed transfers:</b> $FAILURES</p>"
        echo "<p><b>Copied/Updated but could not delete local:</b> $DELETE_FAILS</p>"
        echo "</body></html>"
    } >> "$HTML_FILE"

    SUBJECT="${SUBJECT_PREFIX} - ${SUCCESSES} New / ${UPDATES} Updated / ${SKIPPED} Skipped / ${FAILURES} Failed / ${DELETE_FAILS} Delete-Failed / ${TOTAL_SCANNED} Scanned"

    /home/anpin.abraham@safaricomet.net/scripts/SendEmail \
        -f "$EMAIL_SENDER" \
        -t "$RECIPIENT" \
        -s "$SMTP_SERVER" \
        -u "$SUBJECT" \
        -o message-file="$HTML_FILE"

    if [ $? -eq 0 ]; then
        echo "$(timestamp) - Email sent successfully to $RECIPIENT" >> email_log.log
    else
        echo "$(timestamp) - ERROR: Failed to send email" >> email_log.log
    fi

    rm -f "$HTML_FILE"
}

# Trap EXIT to always send report (even on errors)
trap 'echo "$(timestamp) - Script exited at line $LINENO. Exit code $?." | tee -a "$LOG_FILE"; send_report' EXIT

# === File Transfer Function ===
process_file() {
    zipfile="$1"
    ((TOTAL_SCANNED++))
    rel_path="${zipfile#$SOURCE_DIR/}"
    rel_dir=$(dirname "$rel_path")
    remote_dir="$DEST_DIR/$rel_dir"

    msg="$(timestamp) Processing: $zipfile → $DEST_USER@$DEST_HOST:$remote_dir"
    echo "$msg" | tee -a "$LOG_FILE"
    echo "<p>$msg</p>" >> "$HTML_FILE"

    RSYNC_OUT=$(rsync -avzi \
        --rsync-path="mkdir -p '$remote_dir' && rsync" \
        "$zipfile" "$DEST_USER@$DEST_HOST:$remote_dir/" 2>&1)
    RSYNC_RET=$?

    echo "$RSYNC_OUT" >> "$LOG_FILE"

    if [ $RSYNC_RET -eq 0 ]; then
        if echo "$RSYNC_OUT" | grep -q "<f+++++++++"; then
            msg="$(timestamp) ✅ Copied new file: $zipfile"
            ((SUCCESSES++))
        elif echo "$RSYNC_OUT" | grep -q "<f"; then
            msg="$(timestamp) 🔄 Updated existing file: $zipfile"
            ((UPDATES++))
        elif echo "$RSYNC_OUT" | grep -q "\.f"; then
            msg="$(timestamp) ℹ Skipped (identical): $zipfile"
            ((SKIPPED++))
        else
            msg="$(timestamp) ℹ Rsync reported no actionable changes: $zipfile"
            ((SKIPPED++))
        fi

        echo "$msg" | tee -a "$LOG_FILE"
        echo "<p>$msg</p>" >> "$HTML_FILE"

        # Only delete if copied or updated
        if [[ "$msg" == *"✅"* || "$msg" == *"🔄"* ]]; then
            if sudo rm -f "$zipfile" 2>>"$LOG_FILE"; then
                :
            else
                msg="$(timestamp) ⚠ Copied/Updated but could not delete: $zipfile"
                echo "$msg" | tee -a "$LOG_FILE"
                echo "<p>$msg</p>" >> "$HTML_FILE"
                ((DELETE_FAILS++))
            fi
        fi
    else
        msg="$(timestamp) ❌ Transfer failed for: $zipfile"
        echo "$msg" | tee -a "$LOG_FILE"
        echo "<p>$msg</p>" >> "$HTML_FILE"
        ((FAILURES++))
    fi
}

# === Find and Process Files (safe while-read loop) ===
# Temporarily disable exit-on-error and pipefail so find permission errors don’t abort
set +eo pipefail
while IFS= read -r -d '' file; do
    process_file "$file"
done < <(find "$SOURCE_DIR" -type f -name "*.zip" -mtime +"$DAYS_OLD" -print0 2>>"$LOG_FILE")
set -eo pipefail
