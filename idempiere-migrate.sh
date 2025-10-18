#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# iDempiere Migration Wizard (pull-from-old) + Hostname update
# ==========================================
# Adds automated hostname/FQDN update and /etc/hosts edit.
# What it does (on NEW server):
#  0) Prompts for desired hostname/FQDN and updates system hostname + /etc/hosts
#  1) Prompts for old server IP/user/(optional) password
#  2) Verifies DB export file exists on old server (default or custom path)
#  3) Stops local iDempiere
#  4) Rsyncs data folders from old -> new (with progress)
#  5) Fixes ownership/permissions
#  6) Restores DB + SyncDB (runs tolerant to errors)
#  7) Starts iDempiere
#
# Requirements on NEW server:
#  - bash, rsync, ssh, apt-get (if password auth and sshpass installation required)
#  - sshpass will be installed automatically via apt if needed
#  - run as root (or with full sudo)
#
# NOTES:
#  - The export should have been run on the OLD server:
#       cd /opt/idempiere-server/utils
#       ./RUN_DBExport.sh
# ==========================================

### Configurable defaults (change if your layout differs)
IDEMPIERE_SERVICE="idempiere"
SYNC_PATHS=(
  "/syvasoft/archive"
  "/syvasoft/attachments"
  "/syvasoft/reports"
  "/syvasoft/sql"
  "/syvasoft/store"
  "/syvasoft/idempiere-server/data"
)
# default export path (can be changed by user prompt below)
DEFAULT_EXPORT_FILE="/syvasoft/idempiere-server/data/ExpDat.dmp"
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
echo "iDempiere Migration Wizard (pull from OLD -> NEW) + Hostname update"
echo "Log: $LOGFILE"
hr

### Hostname update (NEW server)
read -rp "Enter short hostname (e.g. 'zion'): " SHORT_HOST
read -rp "Enter domain (default: syvasoft.in). Leave empty for none: " DOMAIN
DOMAIN=${DOMAIN:-syvasoft.in}
if [[ -z "$DOMAIN" ]]; then
  FQDN="$SHORT_HOST"
else
  FQDN="$SHORT_HOST.$DOMAIN"
fi
OLD_HOSTNAME="$(hostname)"

say "Updating hostname to: $FQDN (short: $SHORT_HOST)"

# Backup /etc/hosts
HOSTS_BAK="/etc/hosts.bak.$TIMESTAMP"
cp /etc/hosts "$HOSTS_BAK"
chmod 0644 "$HOSTS_BAK"

# Try to detect primary IPv4 address
PRIMARY_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"
if [[ -z "$PRIMARY_IP" ]]; then
  PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

# Build new hosts file: keep lines that do not contain old hostname or new FQDN
awk -v old="$OLD_HOSTNAME" -v newfqdn="$FQDN" '($0 !~ old) && ($0 !~ newfqdn) {print}' /etc/hosts > /tmp/hosts.new

# Add mapping. Prefer primary IP if available, fallback to 127.0.1.1
if [[ -n "$PRIMARY_IP" && "$PRIMARY_IP" != "" && "$PRIMARY_IP" != "127.0.0.1" ]]; then
  echo "$PRIMARY_IP $FQDN $SHORT_HOST" >> /tmp/hosts.new
else
  echo "127.0.1.1 $FQDN $SHORT_HOST" >> /tmp/hosts.new
fi

# Ensure localhost line exists (do not duplicate)
if ! grep -q "127.0.0.1[[:space:]].*localhost" /tmp/hosts.new; then
  echo "127.0.0.1 localhost" >> /tmp/hosts.new
fi

# Install the new hosts file
mv /tmp/hosts.new /etc/hosts
chmod 0644 /etc/hosts

# Set system hostname
hostnamectl set-hostname "$FQDN"

say "Hostname changed from '$OLD_HOSTNAME' to '$FQDN'. Backup of previous /etc/hosts saved to $HOSTS_BAK"

say "New /etc/hosts contents:"
sed -n '1,200p' /etc/hosts

# Continue with migration prompts
read -rp "Old server IP or hostname: " OLD_HOST
read -rp "Old server SSH username: " OLD_USER

# ask for export path on old server (default provided)
read -rp "Path to DB export on OLD server (default: $DEFAULT_EXPORT_FILE): " EXPORT_FILE_CHECK
EXPORT_FILE_CHECK=${EXPORT_FILE_CHECK:-$DEFAULT_EXPORT_FILE}

echo
read -rp "Use SSH key auth? (Y/n): " USE_KEY
USE_KEY=${USE_KEY:-Y}

SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
RSYNC_SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [[ "$USE_KEY" =~ ^[Nn]$ ]]; then
  # If sshpass not found, try to install via apt-get automatically
  if ! command -v sshpass >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      say "sshpass not found. Installing sshpass via apt-get (non-interactive)..."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y sshpass
      if ! command -v sshpass >/dev/null 2>&1; then
        die "sshpass installation failed. Please install sshpass or use SSH key auth."
      fi
    else
      die "sshpass not found and apt-get not available. Install sshpass or use SSH key auth."
    fi
  fi

  read -rs -p "Old server SSH password: " OLD_PASS; echo
  SSH_CMD="sshpass -p '$OLD_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  RSYNC_SSH="sshpass -p '$OLD_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
fi

# Connectivity check
say "Checking SSH connectivity to $OLD_USER@$OLD_HOST ..."
if ! eval "$SSH_CMD $OLD_USER@$OLD_HOST 'echo connected' >/dev/null 2>&1"; then
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
  rsync -ah --delete --info=progress2 -e "$RSYNC_SSH" "$OLD_USER@$OLD_HOST:$p/" "$p/"
done

# Ownership and permissions
say "Fixing ownership and permissions under /syvasoft"
chown -R idempiere:idempiere /syvasoft || true
chmod 0755 /syvasoft || true

# Restore DB + SyncDB (tolerant to errors — continue on failure)
if [[ ! -d "$UTILS_DIR" ]]; then
  die "Utils directory not found: $UTILS_DIR"
fi

say "Running RUN_DBRestore.sh (this may take a while). Output will be logged and errors will not stop the wizard."
# Run and capture output, but do not exit on non-zero
(
  set +e
  cd "$UTILS_DIR"
  ./RUN_DBRestore.sh 2>&1 | tee -a "$LOGFILE"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    say "Warning: RUN_DBRestore.sh exited with code $rc — continuing (check logs)."
  else
    say "RUN_DBRestore.sh finished successfully."
  fi
  set -e
)

say "Running RUN_SyncDB.sh (this may show errors but we will continue)."
(
  set +e
  cd "$UTILS_DIR"
  ./RUN_SyncDB.sh 2>&1 | tee -a "$LOGFILE"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    say "Warning: RUN_SyncDB.sh exited with code $rc — continuing (these errors often are non-fatal)."
  else
    say "RUN_SyncDB.sh finished successfully."
  fi
  set -e
)

# Start service
say "Starting service: $IDEMPIERE_SERVICE"
systemctl start "$IDEMPIERE_SERVICE" || true

# Final status
sleep 2
if systemctl is-active --quiet "$IDEMPIERE_SERVICE"; then
  say "✅ Migration complete. $IDEMPIERE_SERVICE is active."
else
  say "⚠️ Service not active. Showing last journal lines:"
  journalctl -u "$IDEMPIERE_SERVICE" -n 200 --no-pager | tee -a "$LOGFILE"
  say "Please inspect $LOGFILE and journal output above; continuing to finish."
fi

say "Done. Full log saved to: $LOGFILE"
