#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# iDempiere Migration Wizard (pull-from-old)
# ==========================================
# What it does (on NEW server):
#  1) Prompts for old server IP/user/(optional) password
#  2) Verifies DB export file exists on old server
#  3) Stops local iDempiere
#  4) Rsyncs data folders from old -> new (with progress)
#  5) Fixes ownership/permissions
#  6) Restores DB + SyncDB
#  7) Starts iDempiere
#
# Requirements on NEW server:
#  - bash, rsync, ssh
#  - sshpass (only if you use password auth)
#  - run as root (or with full sudo)
#
# NOTE:
#  - The export should have been run on the OLD server:
#       cd /opt/idempiere-server/utils
#       ./RUN_DBExport.sh
#  - This script *verifies* there is an ExpDat.dmp on the old server
#    under /syvasoft/idempiere-server/data (per your paths).
# ==========================================

### Configurable defaults (change if your layout differs)
IDEMPIERE_SERVICE="idempiere"
# Folder set to sync from OLD -> NEW (exactly as requested)
SYNC_PATHS=(
  "/syvasoft/archive"
  "/syvasoft/attachments"
  "/syvasoft/reports"
  "/syvasoft/sql"
  "/syvasoft/store"
  "/syvasoft/idempiere-server/data"
)
# Where we expect the export file on the OLD server (verify step)
EXPORT_FILE_CHECK="/syvasoft/idempiere-server/data/ExpDat.dmp"
UTILS_DIR="/syvasoft/idempiere-server/utils" # on NEW server

### Logging
TIMESTAMP="$(date +%F_%H-%M-%S)"
LOGFILE="/var/log/idempiere_migration_${TIMESTAMP}.log"
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 0644 "$LOGFILE"

### Root check
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

### Pretty helpers
hr() { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '='; }
say() { echo -e "\n==> $*"; echo -e "\n==> $*" >>"$LOGFILE"; }
die() { echo "ERROR: $*" | tee -a "$LOGFILE"; exit 1; }

# Capture everything to logfile too
exec > >(tee -a "$LOGFILE") 2>&1

hr
echo "iDempiere Migration Wizard (pull from OLD -> NEW)"
echo "Log: $LOGFILE"
hr

read -rp "Old server IP or hostname: " OLD_HOST
read -rp "Old server SSH username: " OLD_USER

echo
read -rp "Use SSH key auth? (Y/n): " USE_KEY
USE_KEY=${USE_KEY:-Y}

SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
RSYNC_SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [[ "$USE_KEY" =~ ^[Nn]$ ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    die "sshpass not found. Install it (e.g., apt install -y sshpass) or use SSH keys."
  fi
  read -rs -p "Old server SSH password: " OLD_PASS; echo
  SSH_CMD="sshpass -p '$OLD_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  RSYNC_SSH="sshpass -p '$OLD_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
fi

# Connectivity check
say "Checking SSH connectivity to $OLD_USER@$OLD_HOST ..."
if ! eval "$SSH_CMD $OLD_USER@$OLD_HOST 'echo connected' >/dev/null"; then
  die "Cannot SSH to $OLD_USER@$OLD_HOST. Check IP/user/auth."
fi
echo "OK."

# Verify export exists and show its size/date
say "Verifying DB export on OLD server: $EXPORT_FILE_CHECK"
if ! eval "$SSH_CMD $OLD_USER@$OLD_HOST 'test -f \"$EXPORT_FILE_CHECK\"'"; then
  echo
  echo "It looks like $EXPORT_FILE_CHECK does not exist on the OLD server."
  echo "You said you've already run the export:"
  echo "  cd /opt/idempiere-server/utils && ./RUN_DBExport.sh"
  echo
  read -rp "Continue anyway? (y/N): " CONT
  if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
    die "Please run the export on old server and re-run this wizard."
  fi
else
  eval "$SSH_CMD $OLD_USER@$OLD_HOST 'ls -lh --time-style=long-iso \"$EXPORT_FILE_CHECK\" || stat \"$EXPORT_FILE_CHECK\"'"
fi

# Stop local idempiere
say "Stopping local service: $IDEMPIERE_SERVICE"
systemctl stop "$IDEMPIERE_SERVICE" || true
systemctl is-active --quiet "$IDEMPIERE_SERVICE" && die "Service still active; stop it and retry." || echo "Stopped."

# Rsync each path
for p in "${SYNC_PATHS[@]}"; do
  say "Syncing $p  (OLD -> NEW)"
  mkdir -p "$p"
  # --info=progress2 prints a nice running progress meter
  rsync -ah --delete --info=progress2 -e "$RSYNC_SSH" "$OLD_USER@$OLD_HOST:$p/" "$p/"
done

# Ownership and permissions
say "Fixing ownership and permissions under /syvasoft"
chown -R idempiere:idempiere /syvasoft
chmod 0755 /syvasoft

# Restore DB + SyncDB
if [[ ! -d "$UTILS_DIR" ]]; then
  die "Utils directory not found: $UTILS_DIR"
fi

say "Running RUN_DBRestore.sh (this may take a while)"
( cd "$UTILS_DIR" && ./RUN_DBRestore.sh )

say "Running RUN_SyncDB.sh"
( cd "$UTILS_DIR" && ./RUN_SyncDB.sh )

# Start service
say "Starting service: $IDEMPIERE_SERVICE"
systemctl start "$IDEMPIERE_SERVICE"

# Final status
sleep 2
if systemctl is-active --quiet "$IDEMPIERE_SERVICE"; then
  say "✅ Migration complete. $IDEMPIERE_SERVICE is active."
else
  say "⚠️ Service not active. Showing last journal lines:"
  journalctl -u "$IDEMPIERE_SERVICE" -n 200 --no-pager
  die "Service failed to start. See logs above and $LOGFILE"
fi

say "Done. Full log saved to: $LOGFILE"
