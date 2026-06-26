#!/usr/bin/env bash
set -u

TARGET=""
PORT=22
REMOTE_USER=""
HOURS=24
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage: ssh_remote_access_troubleshooter.sh [--target HOST] [--port N] [--user NAME] [--hours N] [--output DIR]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --port) PORT="${2:-22}"; shift 2 ;;
    --user) REMOTE_USER="${2:-}"; shift 2 ;;
    --hours) HOURS="${2:-24}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "--port must be numeric" >&2; exit 2; }
[[ "$HOURS" =~ ^[0-9]+$ ]] || { echo "--hours must be numeric" >&2; exit 2; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./ssh-troubleshooting-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/ssh-report.txt"
CSV="$OUTPUT_DIR/permission-findings.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
: > "$REPORT"
: > "$ERRORS"

echo 'path,owner,group,mode,status' > "$CSV"

section() {
  local title="$1"
  shift
  {
    printf '\n===== %s =====\n' "$title"
    "$@"
  } >> "$REPORT" 2>> "$ERRORS" || true
}

have() { command -v "$1" >/dev/null 2>&1; }

record_permission() {
  local path="$1"
  local expected_regex="$2"
  local owner group mode status

  [[ -e "$path" ]] || return 0
  owner="$(stat -c '%U' "$path")"
  group="$(stat -c '%G' "$path")"
  mode="$(stat -c '%a' "$path")"
  status="OK"
  [[ ! "$mode" =~ $expected_regex ]] && status="REVIEW"
  printf '"%s","%s","%s","%s","%s"\n' "$path" "$owner" "$group" "$mode" "$status" >> "$CSV"
}

section "Collection metadata" bash -c 'date -Is; hostname -f 2>/dev/null || hostname; id'
section "OpenSSH versions" bash -c 'ssh -V 2>&1 || true; sshd -V 2>&1 || true'

SSHD_SERVICE=""
if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
  SSHD_SERVICE="ssh"
elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
  SSHD_SERVICE="sshd"
fi

if [[ -n "$SSHD_SERVICE" ]]; then
  section "SSH service status" systemctl status "$SSHD_SERVICE" --no-pager -l
  section "SSH service journal" journalctl -u "$SSHD_SERVICE" --since "$HOURS hours ago" --no-pager -n 500
else
  printf '\n===== SSH service status =====\nNo ssh.service or sshd.service unit was detected.\n' >> "$REPORT"
fi

if have sshd; then
  section "Effective sshd configuration" sshd -T
  section "Selected security settings" bash -c "sshd -T 2>/dev/null | grep -Ei '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|maxauthtries|allowusers|allowgroups|denyusers|denygroups|authenticationmethods|usepam)' || true"
fi

section "Listening sockets" bash -c "ss -ltnp 2>/dev/null | grep -E '(:${PORT}[[:space:]]|sshd)' || true"
section "Authentication failures" bash -c "journalctl --since '$HOURS hours ago' --no-pager 2>/dev/null | grep -Ei 'failed password|authentication failure|invalid user|maximum authentication attempts|connection closed' | tail -n 500 || true"

if have ufw; then section "UFW firewall" ufw status verbose; fi
if have firewall-cmd; then section "firewalld" bash -c 'firewall-cmd --state; firewall-cmd --get-active-zones; firewall-cmd --list-all'; fi
if have nft; then section "nftables" nft list ruleset; fi

record_permission /etc/ssh/sshd_config '^(600|640|644)$'
record_permission /etc/ssh '^(700|755)$'
for key in /etc/ssh/ssh_host_*_key; do
  [[ -e "$key" ]] && record_permission "$key" '^600$'
done

while IFS=: read -r _user _ uid _ _ home shell; do
  [[ "$uid" -lt 1000 && "$uid" -ne 0 ]] && continue
  [[ "$shell" =~ (nologin|false)$ ]] && continue
  [[ -d "$home/.ssh" ]] && record_permission "$home/.ssh" '^700$'
  [[ -f "$home/.ssh/authorized_keys" ]] && record_permission "$home/.ssh/authorized_keys" '^(600|640)$'
done < /etc/passwd

TARGET_TCP=false
TARGET_DNS=false
HOST_KEY_COUNT=0
if [[ -n "$TARGET" ]]; then
  section "Target DNS resolution" getent ahosts "$TARGET"
  getent hosts "$TARGET" >/dev/null 2>&1 && TARGET_DNS=true

  section "Route to target" ip route get "$TARGET"
  if have nc; then
    section "Target TCP test" nc -vz -w 5 "$TARGET" "$PORT"
    nc -z -w 5 "$TARGET" "$PORT" >/dev/null 2>&1 && TARGET_TCP=true
  elif have timeout; then
    if timeout 5 bash -c "</dev/tcp/$TARGET/$PORT" >/dev/null 2>&1; then
      TARGET_TCP=true
    fi
  fi

  if have ssh-keyscan; then
    section "Remote host keys" ssh-keyscan -T 5 -p "$PORT" "$TARGET"
    HOST_KEY_COUNT="$(ssh-keyscan -T 5 -p "$PORT" "$TARGET" 2>/dev/null | grep -vc '^#' || true)"
  fi

  if have ssh; then
    destination="$TARGET"
    [[ -n "$REMOTE_USER" ]] && destination="$REMOTE_USER@$TARGET"
    section "Effective SSH client configuration" ssh -G -p "$PORT" "$destination"
  fi
fi

PERMISSION_WARNINGS="$(awk -F, 'NR>1 && $5 ~ /REVIEW/ {c++} END {print c+0}' "$CSV")"
SERVICE_ACTIVE=false
if [[ -n "$SSHD_SERVICE" ]] && systemctl is-active --quiet "$SSHD_SERVICE"; then
  SERVICE_ACTIVE=true
fi

cat > "$JSON" <<EOF
{
  "collected_at": "$(date -Is)",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "ssh_service": "${SSHD_SERVICE:-not-detected}",
  "ssh_service_active": $SERVICE_ACTIVE,
  "permission_findings_for_review": ${PERMISSION_WARNINGS:-0},
  "target": "${TARGET}",
  "target_port": $PORT,
  "target_dns_resolved": $TARGET_DNS,
  "target_tcp_reachable": $TARGET_TCP,
  "remote_host_keys_found": ${HOST_KEY_COUNT:-0}
}
EOF

printf '\nSSH troubleshooting completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
