#!/usr/bin/env bash
set -u

umask 077

DO_REPAIR=false
FIX_SERVER_PERMS=false
GENERATE_HOST_KEYS=false
FIX_USER=""
SERVICE_ACTION=""
DRY_RUN=false
ASSUME_YES=false
OUTPUT_DIR=""
FAILURES=0
ACTIONS=0
SERVICE_UNIT=""
SSHD_BIN=""
SERVER_REQUIRED=false

usage() {
  cat <<'EOF'
Usage: ssh_remote_access_repair.sh [options]

Repair actions:
  --repair                    Back up SSH configuration, repair standard server
                              permissions, create missing host keys, validate the
                              configuration, enable SSH and restart the service.
  --fix-server-permissions    Correct permissions on SSH server configuration and
                              host-key files.
  --generate-host-keys        Generate only missing OpenSSH host keys.
  --fix-user-permissions USER Correct ownership and permissions for USER's .ssh
                              directory and authorized_keys files.
  --service-action ACTION     start, restart, reload, enable, or reset-failed.

Controls:
  --dry-run                   Show intended commands without changing the system.
  --yes                       Skip the confirmation prompt.
  --output DIR                Save logs, backups, and verification output in DIR.
  -h, --help                  Show this help.

Exit codes: 0 success, 2 usage, 3 missing requirement, 4 privilege failure,
10 cancelled, 20 repair or verification failure.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repair) DO_REPAIR=true; shift ;;
    --fix-server-permissions) FIX_SERVER_PERMS=true; shift ;;
    --generate-host-keys) GENERATE_HOST_KEYS=true; shift ;;
    --fix-user-permissions)
      [ "$#" -ge 2 ] || { echo "--fix-user-permissions requires a username." >&2; exit 2; }
      FIX_USER="$2"; shift 2 ;;
    --service-action)
      [ "$#" -ge 2 ] || { echo "--service-action requires a value." >&2; exit 2; }
      SERVICE_ACTION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --output)
      [ "$#" -ge 2 ] || { echo "--output requires a directory." >&2; exit 2; }
      OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if ! $DO_REPAIR && ! $FIX_SERVER_PERMS && ! $GENERATE_HOST_KEYS && [ -z "$FIX_USER" ] && [ -z "$SERVICE_ACTION" ]; then
  echo "Choose at least one repair action." >&2
  usage
  exit 2
fi
case "$SERVICE_ACTION" in
  ''|start|restart|reload|enable|reset-failed) : ;;
  *) echo "Unsupported service action: $SERVICE_ACTION" >&2; exit 2 ;;
esac
if $DO_REPAIR && [ -n "$SERVICE_ACTION" ]; then
  echo "Use --repair or --service-action, not both." >&2
  exit 2
fi

if $DO_REPAIR || $FIX_SERVER_PERMS || $GENERATE_HOST_KEYS || [ -n "$SERVICE_ACTION" ]; then
  SERVER_REQUIRED=true
fi

if $SERVER_REQUIRED; then
  if command -v sshd >/dev/null 2>&1; then
    SSHD_BIN=$(command -v sshd)
  elif [ -x /usr/sbin/sshd ]; then
    SSHD_BIN=/usr/sbin/sshd
  else
    echo "OpenSSH server is not installed or sshd is not available." >&2
    exit 3
  fi
  command -v systemctl >/dev/null 2>&1 || { echo "systemd is required for server repair." >&2; exit 3; }
  command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is required." >&2; exit 3; }
  for candidate in sshd.service ssh.service; do
    if systemctl cat "$candidate" >/dev/null 2>&1; then
      SERVICE_UNIT="$candidate"
      break
    fi
  done
  [ -n "$SERVICE_UNIT" ] || { echo "No sshd.service or ssh.service unit was found." >&2; exit 3; }
fi

if [ -n "$FIX_USER" ]; then
  getent passwd "$FIX_USER" >/dev/null 2>&1 || { echo "User not found: $FIX_USER" >&2; exit 2; }
  UID_MIN=$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null || true)
  UID_MIN=${UID_MIN:-1000}
  FIX_UID=$(id -u "$FIX_USER")
  [ "$FIX_UID" -ge "$UID_MIN" ] || { echo "Refusing to modify system account $FIX_USER (UID $FIX_UID)." >&2; exit 2; }
fi

if ! $DRY_RUN && [ "$(id -u)" -ne 0 ]; then
  echo "Run this repair as root, for example: sudo $0 ..." >&2
  exit 4
fi

STAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-./ssh-repair-$STAMP}"
BACKUP_DIR="$OUTPUT_DIR/backup"
mkdir -p "$OUTPUT_DIR" "$BACKUP_DIR"
LOG="$OUTPUT_DIR/repair.log"
BEFORE="$OUTPUT_DIR/before.txt"
AFTER="$OUTPUT_DIR/after.txt"
: > "$LOG"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
confirm() {
  $ASSUME_YES && return 0
  read -r -p "$1 [y/N]: " answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
run_action() {
  local description="$1"; shift
  ACTIONS=$((ACTIONS + 1))
  log "$description"
  if $DRY_RUN; then
    printf 'DRY-RUN:' >> "$LOG"
    printf ' %q' "$@" >> "$LOG"
    printf '\n' >> "$LOG"
    return 0
  fi
  if "$@" >> "$LOG" 2>&1; then
    log "SUCCESS: $description"
    return 0
  fi
  FAILURES=$((FAILURES + 1))
  log "WARNING: $description failed"
  return 1
}

collect_state() {
  local destination="$1"
  {
    echo "Collected: $(date -Is)"
    if $SERVER_REQUIRED; then
      echo "Service unit: $SERVICE_UNIT"
      systemctl status "$SERVICE_UNIT" --no-pager -l 2>&1 || true
      echo
      "$SSHD_BIN" -t 2>&1 && echo "sshd configuration: valid" || echo "sshd configuration: invalid"
      echo
      "$SSHD_BIN" -T 2>/dev/null | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|authorizedkeysfile) ' || true
      echo
      stat -c '%a %U:%G %n' /etc/ssh /etc/ssh/sshd_config 2>/dev/null || true
      find /etc/ssh/sshd_config.d -maxdepth 1 -type f -printf '%m %u:%g %p\n' 2>/dev/null | sort || true
      find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key*' -printf '%m %u:%g %p\n' 2>/dev/null | sort || true
      echo
      command -v ss >/dev/null 2>&1 && ss -lntp 2>/dev/null | grep -E '(:22|sshd)' || true
      echo
      journalctl -u "$SERVICE_UNIT" -n 80 --no-pager 2>&1 || true
    fi
    if [ -n "$FIX_USER" ]; then
      USER_HOME=$(getent passwd "$FIX_USER" | cut -d: -f6)
      echo
      echo "User SSH path state:"
      stat -c '%a %U:%G %n' "$USER_HOME" "$USER_HOME/.ssh" "$USER_HOME/.ssh/authorized_keys" "$USER_HOME/.ssh/authorized_keys2" 2>/dev/null || true
    fi
  } > "$destination"
}

backup_server_config() {
  if $DRY_RUN; then
    log "DRY-RUN: back up /etc/ssh to $BACKUP_DIR/etc-ssh.tgz"
    return 0
  fi
  tar -C / -czf "$BACKUP_DIR/etc-ssh.tgz" etc/ssh >> "$LOG" 2>&1 || {
    FAILURES=$((FAILURES + 1))
    log "WARNING: unable to back up /etc/ssh; server changes were skipped."
    return 1
  }
  log "SUCCESS: backed up /etc/ssh"
}

fix_server_permissions() {
  [ -d /etc/ssh ] || { FAILURES=$((FAILURES + 1)); log "WARNING: /etc/ssh does not exist."; return 1; }
  run_action "Setting /etc/ssh ownership" chown root:root /etc/ssh || true
  run_action "Setting /etc/ssh directory permissions" chmod 755 /etc/ssh || true
  if [ -f /etc/ssh/sshd_config ]; then
    run_action "Setting sshd_config ownership" chown root:root /etc/ssh/sshd_config || true
    run_action "Setting sshd_config permissions" chmod 600 /etc/ssh/sshd_config || true
  fi
  if [ -d /etc/ssh/sshd_config.d ]; then
    run_action "Setting SSH drop-in directory ownership" chown root:root /etc/ssh/sshd_config.d || true
    run_action "Setting SSH drop-in directory permissions" chmod 755 /etc/ssh/sshd_config.d || true
    while IFS= read -r file; do
      run_action "Setting ownership on $file" chown root:root "$file" || true
      run_action "Setting permissions on $file" chmod 600 "$file" || true
    done < <(find /etc/ssh/sshd_config.d -maxdepth 1 -type f -print 2>/dev/null)
  fi
  while IFS= read -r key; do
    run_action "Setting private host-key permissions on $key" chmod 600 "$key" || true
    run_action "Setting private host-key ownership on $key" chown root:root "$key" || true
  done < <(find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key' -print 2>/dev/null)
  while IFS= read -r key; do
    run_action "Setting public host-key permissions on $key" chmod 644 "$key" || true
    run_action "Setting public host-key ownership on $key" chown root:root "$key" || true
  done < <(find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key.pub' -print 2>/dev/null)
}

fix_user_permissions() {
  local user="$1"
  local home group
  home=$(getent passwd "$user" | cut -d: -f6)
  group=$(id -gn "$user")
  [ -d "$home" ] || { FAILURES=$((FAILURES + 1)); log "WARNING: home directory does not exist: $home"; return 1; }
  if [ -L "$home/.ssh" ]; then
    FAILURES=$((FAILURES + 1)); log "WARNING: refusing symbolic-link SSH directory: $home/.ssh"; return 1
  fi
  if [ -d "$home/.ssh" ]; then
    if $DRY_RUN; then
      log "DRY-RUN: back up $home/.ssh to $BACKUP_DIR/${user}-ssh.tgz"
    else
      tar -C "$home" -czf "$BACKUP_DIR/${user}-ssh.tgz" .ssh >> "$LOG" 2>&1 || {
        FAILURES=$((FAILURES + 1)); log "WARNING: unable to back up $home/.ssh"; return 1;
      }
      log "SUCCESS: backed up $home/.ssh"
    fi
    run_action "Correcting ownership of $home/.ssh" chown -R "$user:$group" "$home/.ssh" || true
    run_action "Setting $home/.ssh permissions" chmod 700 "$home/.ssh" || true
    for authfile in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2"; do
      if [ -f "$authfile" ] && [ ! -L "$authfile" ]; then
        run_action "Setting permissions on $authfile" chmod 600 "$authfile" || true
      fi
    done
  else
    log "No .ssh directory exists for $user; no user permission changes were needed."
  fi
}

collect_state "$BEFORE"
confirm "Apply the selected SSH repair actions? Keep an existing remote session open until verification succeeds." || {
  log "Repair cancelled."
  exit 10
}

if $DO_REPAIR || $FIX_SERVER_PERMS || $GENERATE_HOST_KEYS; then
  backup_server_config || { collect_state "$AFTER"; exit 20; }
fi
if $DO_REPAIR || $FIX_SERVER_PERMS; then fix_server_permissions; fi
if $DO_REPAIR || $GENERATE_HOST_KEYS; then run_action "Generating missing OpenSSH host keys" ssh-keygen -A || true; fi
if [ -n "$FIX_USER" ]; then fix_user_permissions "$FIX_USER"; fi

CONFIG_VALID=true
if $SERVER_REQUIRED; then
  if $DRY_RUN; then
    log "DRY-RUN: $SSHD_BIN -t"
  elif ! "$SSHD_BIN" -t >> "$LOG" 2>&1; then
    CONFIG_VALID=false
    FAILURES=$((FAILURES + 1))
    log "WARNING: SSH configuration validation failed. Service changes were skipped."
  else
    log "SUCCESS: SSH configuration validation passed."
  fi
fi

if $CONFIG_VALID; then
  if $DO_REPAIR; then
    run_action "Enabling $SERVICE_UNIT" systemctl enable "$SERVICE_UNIT" || true
    run_action "Restarting $SERVICE_UNIT" systemctl restart "$SERVICE_UNIT" || true
  fi
  case "$SERVICE_ACTION" in
    start) run_action "Starting $SERVICE_UNIT" systemctl start "$SERVICE_UNIT" || true ;;
    restart) run_action "Restarting $SERVICE_UNIT" systemctl restart "$SERVICE_UNIT" || true ;;
    reload) run_action "Reloading $SERVICE_UNIT" systemctl reload "$SERVICE_UNIT" || true ;;
    enable) run_action "Enabling and starting $SERVICE_UNIT" systemctl enable --now "$SERVICE_UNIT" || true ;;
    reset-failed) run_action "Clearing failed state for $SERVICE_UNIT" systemctl reset-failed "$SERVICE_UNIT" || true ;;
  esac
fi

$DRY_RUN || sleep 2
collect_state "$AFTER"
if ! $DRY_RUN && { $DO_REPAIR || [ "$SERVICE_ACTION" = start ] || [ "$SERVICE_ACTION" = restart ] || [ "$SERVICE_ACTION" = enable ]; }; then
  systemctl is-active --quiet "$SERVICE_UNIT" || {
    FAILURES=$((FAILURES + 1))
    log "WARNING: $SERVICE_UNIT is not active after repair."
  }
fi
if $SERVER_REQUIRED && ! $DRY_RUN && ! "$SSHD_BIN" -t >> "$LOG" 2>&1; then
  FAILURES=$((FAILURES + 1))
  log "WARNING: post-repair SSH configuration validation failed."
fi

if [ "$FAILURES" -gt 0 ]; then
  log "Repair finished with $FAILURES failure(s)."
  exit 20
fi
log "Repair completed successfully. Actions performed: $ACTIONS"
exit 0
