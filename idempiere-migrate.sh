#!/usr/bin/env bash
# re-exec under bash if somehow launched with sh/dash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

# ==========================================
# iDempiere Migration Wizard (pull-from-old) + Hostname update
# - Re-exec to ensure bash
# - Checks remote paths before rsync
# - Tolerant DB restore/sync and rsync errors
# ==========================================

IDEMPIERE_SERVICE="idempiere"

# list of paths to sync (local target paths)
SYNC_PATHS=(
  "/syvasoft/archive"
  "/syvasoft/attachments"
  "/syvasoft/reports"
  "/syvasoft/sql"
  "/syvasoft/store"
  "/syvasoft/idempiere-server/data"
)

DEFAULT_EXPORT_FILE="/syvasoft/idempiere-server/data/ExpDat.dmp"
UTILS_DIR="/syvasoft/idempiere-server/utils"   # local utils dir on NEW server

TIMESTAMP="$(date +%F_%H-%M-%S)"
LOGFILE="/var/log/idempiere_migration_${TIMESTAMP}.log"
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 0644 "$LOGFILE"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

hr() { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '='; }
say() { echo -e "\n==> $*"; echo -e "\n==> $*" >>"$LOGFILE"; }
die() { echo "ERROR: $*" | tee -a "$LOGFILE"; exit 1; }

# send all output to logfile + console
exec > >(tee -a "$LOGFILE") 2>&1

hr
echo "iDempiere Migration Wizard (pull from OLD -> NEW) + Hostname update"
echo "Log: $LOGFILE"
hr

#### Hostname update
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

HOSTS_BAK="/etc/hosts.bak.$TIMESTAMP"
cp /etc/hosts "$HOSTS_BAK"
chmod 0644 "$HOSTS_BAK"

PRIMARY_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"
if [[ -z "$PRIMARY_IP" ]]; then
  PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

awk -v old="$OLD_HOSTNAME" -v newfqdn="$FQDN" '($0 !~ old) && ($0 !~ newfqdn) {print}' /etc/hosts > /tmp/hosts.new

if [[ -n "$PRIMARY_IP" && "$PRIMARY_IP" != "127.0.0.1" ]]; then
  echo "$PRIMARY_IP $FQDN $SHORT_HOST" >> /tmp/hosts.new
else
  echo "127.0.1.1 $FQDN $SHORT_HOST" >> /tmp/hosts.new
fi

if ! grep -q "127.0.0.1[[:space:]].*localhost" /tmp/hosts.new; then
  echo "127.0.0.1 localhost" >> /tmp/hosts.new
fi

mv /tmp/hosts.new /etc/hosts
chmod 0644 /etc/hosts
hostnamectl set-hostname "$FQDN"

say "Hostname changed from '$OLD_HOSTNAME' to '$FQDN'. Backup of previous /etc/hosts saved to $HOSTS_BAK"
say "New /etc/hosts contents:"
sed -n '1,200p' /etc/hosts

#### Connection + export path
read -rp "Old server IP or hostname: " OLD_HOST
read -rp "Old server SSH username: " OLD_USER
read -rp "Path to DB export on OLD server (default: $DEFAULT_EXPORT_FILE): " EXPORT_FILE_CHECK
EXPORT_FILE_CHECK=${EXPORT_FILE_CHECK:-$DEFAULT_EXPORT_FILE}

echo
read -rp "Use SSH key auth? (Y/n): " USE_KEY
USE_KEY=${USE_KEY:-Y}

SSH_CMD_BASE="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
RSYNC_RSH_BASE="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

SSH_CMD_EVAL="$SSH_CMD_BASE"
RSYNC_RSH="$RSYNC_RSH_BASE"

if [[ "$USE_KEY" =~ ^[Nn]$ ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      say "sshpass not found. Installing sshpass via apt-get..."
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
  # escape single quotes
  ESC_OLD_PASS="${OLD_PASS//\'/\'\"\'\"\'}"
  SSH_CMD_EVAL="sshpass -p '$ESC_OLD_PASS' $SSH_CMD_BASE"
  RSYNC_RSH="sshpass -p '$ESC_OLD_PASS' $RSYNC_RSH_BASE"
fi

say "Checking SSH connectivity to $OLD_USER@$OLD_HOST ..."
if ! eval "$SSH_CMD_EVAL $OLD_USER@$OLD_HOST 'echo connected' >/dev/null 2>&1"; then
  die "Cannot SSH to $OLD_USER@$OLD_HOST. Check IP/user/auth."
fi
echo "OK."

say "Verifying DB export on OLD server: $EXPORT_FILE_CHECK"
if ! eval "$SSH_CMD_EVAL $OLD_USER@$OLD_HOST 'test -f \"$EXPORT_FILE_CHECK\"'"; then
  echo
  echo "It looks like $EXPORT_FILE_CHECK does not exist on the OLD server."
  echo "You said you've already run the export: cd /opt/idempiere-server/utils && ./RUN_DBExport.sh"
  echo
  read -rp "Continue anyway? (y/N): " CONT
  if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
    die "Please run the export on old server and re-run this wizard."
  fi
else
  eval "$SSH_CMD_EVAL $OLD_USER@$OLD_HOST 'ls -lh --time-style=long-iso \"$EXPORT_FILE_CHECK\" || stat \"$EXPORT_FILE_CHECK\"'"
fi

say "Stopping local service: $IDEMPIERE_SERVICE"
systemctl stop "$IDEMPIERE_SERVICE" || true
systemctl is-active --quiet "$IDEMPIERE_SERVICE" && die "Service still active; stop it and retry." || echo "Stopped."

say "Beginning sync of configured paths. For any missing remote path you'll be prompted to provide an alternate or skip."

for remote_local_path in "${SYNC_PATHS[@]}"; do
  remote_p="$remote_local_path"   # default remote path equals local path

  # check directory exists on remote
  if ! eval "$SSH_CMD_EVAL $OLD_USER@$OLD_HOST 'test -d \"$remote_p\"' >/dev/null 2>&1; then
    say "Remote path not found: $remote_p"
    read -rp "Enter alternative remote path to sync to local '$remote_local_path' (leave empty to skip): " alt_remote
    if [[ -z "$alt_remote" ]]; then
      say "Skipping sync for $remote_local_path"
      continue
    fi
    remote_p="$alt_remote"
    if ! eval "$SSH_CMD_EVAL $OLD_USER@$OLD_HOST 'test -d \"$remote_p\"' >/dev/null 2>&1; then
      say "Provided alternative '$remote_p' does not exist on old server. Skipping."
      continue
    fi
  fi

  say "Syncing remote:$remote_p  -->  local:$remote_local_path"
  mkdir -p "$remote_local_path"
  (
    set +e
    RSYNC_CMD="rsync -ah --delete --info=progress2 -e \"$RSYNC_RSH\" \"$OLD_USER@$OLD_HOST:$remote_p/\" \"$remote_local_path/\""
    say "Running: $RSYNC_CMD"
    eval "$RSYNC_CMD" 2>&1 | tee -a "$LOGFILE"
    rc=${PIPESTATUS[0]:-0}
    if [[ $rc -ne 0 ]]; then
      say "Warning: rsync for $remote_p exited with code $rc. Continuing."
    else
      say "rsync for $remote_p finished successfully."
    fi
    set -e
  )
done

say "Fixing ownership and permissions under /syvasoft"
chown -R idempiere:idempiere /syvasoft || true
chmod 0755 /syvasoft || true

if [[ ! -d "$UTILS_DIR" ]]; then
  die "Utils directory not found: $UTILS_DIR"
fi

say "Running RUN_DBRestore.sh (logged). Errors will not abort migration."
(
  set +e
  cd "$UTILS_DIR"
  ./RUN_DBRestore.sh 2>&1 | tee -a "$LOGFILE"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    say "Warning: RUN_DBRestore.sh exited with code $rc — continuing."
  else
    say "RUN_DBRestore.sh finished successfully."
  fi
  set -e
)

say "Running RUN_SyncDB.sh (logged). Errors will not abort migration."
(
  set +e
  cd "$UTILS_DIR"
  ./RUN_SyncDB.sh 2>&1 | tee -a "$LOGFILE"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    say "Warning: RUN_SyncDB.sh exited with code $rc — continuing."
  else
    say "RUN_SyncDB.sh finished successfully."
  fi
  set -e
)

say "Starting service: $IDEMPIERE_SERVICE"
systemctl start "$IDEMPIERE_SERVICE" || true

sleep 2
if systemctl is-active --quiet "$IDEMPIERE_SERVICE"; then
  say "✅ Migration complete. $IDEMPIERE_SERVICE is active."
else
  say "⚠️ Service not active. Last journal lines appended to log:"
  journalctl -u "$IDEMPIERE_SERVICE" -n 200 --no-pager | tee -a "$LOGFILE"
  say "Please inspect $LOGFILE and journal output above."
fi

say "Done. Full log saved to: $LOGFILE"
