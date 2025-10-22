#!/usr/bin/env bash
set -euo pipefail

# ===================== CONFIGURATION =====================
HOME_DIR="/home/wazuh-user"
LIST_URL="https://raw.githubusercontent.com/geercaceres/wazuh-sample-logs/main/sample%20logs%20list.txt"
LIST_FILE="$HOME_DIR/sample-logs-list.txt"
COLLECTED="$HOME_DIR/file-collected.log"

STATE_DIR="/var/lib/wz-logfeeder"
SHUF_FILE="$STATE_DIR/shuffled.list"
POS_FILE="$STATE_DIR/position"
FIRST_RUN_FLAG="$STATE_DIR/.first_run_done"

PID_FILE="/var/run/wz-logfeeder.pid"
LOG_FILE="/var/log/wz-logfeeder.log"

SLEEP_SECONDS="${SLEEP_SECONDS:-600}"      # interval between runs (10 min default)
LINES_PER_TICK="${LINES_PER_TICK:-100}"    # how many lines to append per cycle

WAZUH_OSSEC="/var/ossec/etc/ossec.conf"
WAZUH_SVC="wazuh-agent"

# ===================== LOGGING FUNCTION =====================
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" ; }

# ===================== ROOT CHECK =====================
ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

# ===================== FIRST RUN INITIALIZATION =====================
first_run_prep() {
  mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"

  # 1) Download the sample log list
  mkdir -p "$HOME_DIR"
  if [[ ! -f "$LIST_FILE" ]]; then
    log "Downloading log list to $LIST_FILE"
    curl -fsSL "$LIST_URL" -o "$LIST_FILE"
  else
    log "Log list already exists: $LIST_FILE"
  fi

  # 2) Create the collected file if missing
  if [[ ! -f "$COLLECTED" ]]; then
    log "Creating $COLLECTED"
    touch "$COLLECTED"
    chmod 0644 "$COLLECTED"
  fi

  # 3) Add <localfile> entry to ossec.conf if not present
  if ! grep -q "<location>$COLLECTED</location>" "$WAZUH_OSSEC"; then
    log "Adding <localfile> entry in $WAZUH_OSSEC"
    cp -a "$WAZUH_OSSEC" "$WAZUH_OSSEC.bak.$(date +%Y%m%d%H%M%S)"
    sed -i "\#</ossec_config>#i \
<localfile>\n  <location>${COLLECTED}</location>\n  <log_format>JSON</log_format>\n</localfile>\n" "$WAZUH_OSSEC"
    log "Restarting service $WAZUH_SVC"
    systemctl restart "$WAZUH_SVC" || log "Warning: failed to restart $WAZUH_SVC (continuing)"
  else
    log "The <localfile> entry already exists."
  fi

  touch "$FIRST_RUN_FLAG"
  log "Initial setup complete."
}

# ===================== SHUFFLE PREPARATION =====================
prepare_shuffle_if_needed() {
  # Create a shuffled copy of the log list (remove blank lines and CR)
  if [[ ! -s "$SHUF_FILE" || ! -s "$POS_FILE" ]]; then
    log "Preparing shuffled log list..."
    tr -d '\r' < "$LIST_FILE" | awk 'NF' | shuf > "$SHUF_FILE"
    echo "0" > "$POS_FILE"
  fi
}

# ===================== APPEND A BATCH OF LOGS =====================
append_batch() {
  prepare_shuffle_if_needed

  local total pos end count
  total=$(wc -l < "$SHUF_FILE" | tr -d ' ')
  pos=$(cat "$POS_FILE")

  # If all logs were consumed, reshuffle and restart
  if (( pos >= total )); then
    log "Reached end of shuffled list. Re-shuffling..."
    tr -d '\r' < "$LIST_FILE" | awk 'NF' | shuf > "$SHUF_FILE"
    echo "0" > "$POS_FILE"
    pos=0
    total=$(wc -l < "$SHUF_FILE" | tr -d ' ')
  fi

  end=$(( pos + LINES_PER_TICK ))
  (( end > total )) && end=$total

  if (( end > pos )); then
    # Extract next batch, remove blanks, validate JSON if jq available
    if command -v jq >/dev/null 2>&1; then
      sed -n "$((pos+1))","$end"p "$SHUF_FILE" \
        | tr -d '\r' \
        | awk 'NF' \
        | while IFS= read -r line; do
            parsed=$(echo "$line" | jq -c . 2>/dev/null) || continue
            printf '%s\n' "$parsed"
          done >> "$COLLECTED"
    else
      sed -n "$((pos+1))","$end"p "$SHUF_FILE" \
        | tr -d '\r' \
        | awk 'NF' >> "$COLLECTED"
    fi

    echo "$end" > "$POS_FILE"
    count=$(( end - pos ))
    log "Appended $count lines (pos=$end/$total) → $COLLECTED"
  else
    log "No new lines to append."
  fi
}

# ===================== MAIN LOOP =====================
run_loop() {
  trap 'log "Received SIGTERM, exiting..."; exit 0' TERM INT
  [[ -f "$FIRST_RUN_FLAG" ]] || first_run_prep
  while true; do
    append_batch
    sleep "$SLEEP_SECONDS" &
    wait $!
  done
}

# ===================== DAEMON MANAGEMENT =====================
is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid=$(cat "$PID_FILE")
  [[ -n "$pid" && -d "/proc/$pid" ]] && return 0 || return 1
}

start_daemon() {
  ensure_root
  if is_running; then
    echo "Already running. PID $(cat "$PID_FILE")"
    exit 0
  fi
  exec 9>/var/lock/wz-logfeeder.lock
  if ! flock -n 9; then
    echo "Another instance is already running. Exiting."
    exit 0
  fi
  nohup "$0" run >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "Started in background. PID $(cat "$PID_FILE")"
  echo "Logs: $LOG_FILE"
}

stop_daemon() {
  ensure_root
  if ! is_running; then
    echo "Not running."
    exit 0
  fi
  local pid; pid=$(cat "$PID_FILE")
  kill "$pid" || true
  sleep 1
  [[ -d "/proc/$pid" ]] && kill -9 "$pid" || true
  rm -f "$PID_FILE"
  echo "Stopped."
}

status_daemon() {
  if is_running; then
    echo "RUNNING (PID $(cat "$PID_FILE"))"
  else
    echo "STOPPED"
  fi
}

# ===================== COMMAND DISPATCH =====================
case "${1:-}" in
  start)  start_daemon ;;
  stop)   stop_daemon ;;
  status) status_daemon ;;
  run)    run_loop ;;
  *)
    cat <<EOF
Usage: $0 {start|stop|status}
Optional variables:
  LINES_PER_TICK=<n>   Number of logs appended each cycle (default 100)
  SLEEP_SECONDS=<sec>   Interval between cycles (default 600)
Example:
  LINES_PER_TICK=300 SLEEP_SECONDS=600 sudo $0 start
EOF
    exit 1
  ;;
esac
