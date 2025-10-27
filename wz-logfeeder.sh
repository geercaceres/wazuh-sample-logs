#!/usr/bin/env bash
set -euo pipefail

# ===================== CONFIGURATION =====================
HOME_DIR="/home/wazuh-user"

# Remote log lists in your GitHub repository
STD_LIST_URL="https://raw.githubusercontent.com/geercaceres/wazuh-sample-logs/main/sample-logs-list.txt"
JSON_LIST_URL="https://raw.githubusercontent.com/geercaceres/wazuh-sample-logs/main/json-sample-logs-list.txt"

# Local copies of the lists
STD_LIST_FILE="$HOME_DIR/sample-logs-list.txt"
JSON_LIST_FILE="$HOME_DIR/json-sample-logs-list.txt"

# Local files where logs will be appended
STD_COLLECTED="$HOME_DIR/file-collected.log"
JSON_COLLECTED="$HOME_DIR/json-file-collected.log"

# State tracking directories (one per feed)
STATE_DIR_BASE="/var/lib/wz-logfeeder"
STD_STATE_DIR="$STATE_DIR_BASE/std"
JSON_STATE_DIR="$STATE_DIR_BASE/json"

STD_SHUF_FILE="$STD_STATE_DIR/shuffled.list"
STD_POS_FILE="$STD_STATE_DIR/position"

JSON_SHUF_FILE="$JSON_STATE_DIR/shuffled.list"
JSON_POS_FILE="$JSON_STATE_DIR/position"

FIRST_RUN_FLAG="$STATE_DIR_BASE/.first_run_done"

PID_FILE="/var/run/wz-logfeeder.pid"
LOG_FILE="/var/log/wz-logfeeder.log"

SLEEP_SECONDS="${SLEEP_SECONDS:-600}"      # interval between cycles (default: 10 minutes)
LINES_PER_TICK="${LINES_PER_TICK:-100}"    # number of lines appended per feed each cycle

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

# ===================== HELPERS: DOWNLOAD & PREPARATION =====================
download_if_missing() {
  local url="$1" file="$2"
  mkdir -p "$(dirname "$file")"

  if [[ ! -f "$file" ]]; then
    log "Downloading log list $url -> $file"
    if ! curl -A "Mozilla/5.0" -fsSL "$url" -o "$file"; then
      log "WARNING: failed to download $url (rate limit or network). Creating empty placeholder $file so feeder can still run."
      : > "$file"
    fi
  else
    log "Log list already exists: $file"
  fi
}

init_collected_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log "Creating $file"
    touch "$file"
    chmod 0644 "$file"
  fi
}

init_state_dir() {
  local dir="$1"
  mkdir -p "$dir"
}

# ===================== OSSEC.CONF MODIFICATION =====================
ensure_localfile_entry() {
  local logfile="$1"
  local format="$2"   # "json" or "syslog"

  if ! grep -q "<location>$logfile</location>" "$WAZUH_OSSEC"; then
    log "Adding <localfile> entry for $logfile ($format) in $WAZUH_OSSEC"
    cp -a "$WAZUH_OSSEC" "$WAZUH_OSSEC.bak.$(date +%Y%m%d%H%M%S)"
    sed -i "\#</ossec_config>#i \
<localfile>\n  <location>${logfile}</location>\n  <log_format>${format}</log_format>\n</localfile>\n" "$WAZUH_OSSEC"
  else
    log "Localfile entry for $logfile ($format) already exists in $WAZUH_OSSEC"
  fi
}

# ===================== FIRST RUN INITIALIZATION =====================
first_run_prep() {
  mkdir -p "$STATE_DIR_BASE" "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"

  # Download both lists if missing
  download_if_missing "$STD_LIST_URL" "$STD_LIST_FILE"
  download_if_missing "$JSON_LIST_URL" "$JSON_LIST_FILE"

  # Create destination log files
  init_collected_file "$STD_COLLECTED"
  init_collected_file "$JSON_COLLECTED"

  # Prepare state directories
  init_state_dir "$STD_STATE_DIR"
  init_state_dir "$JSON_STATE_DIR"

  # Add both log sources to ossec.conf
  #   - standard logs => syslog
  #   - json logs     => json
  ensure_localfile_entry "$STD_COLLECTED" "syslog"
  ensure_localfile_entry "$JSON_COLLECTED" "json"

  # Restart wazuh-agent to pick up the new <localfile> entries
  log "Restarting service $WAZUH_SVC"
  systemctl restart "$WAZUH_SVC" || log "Warning: failed to restart $WAZUH_SVC (continuing)"

  touch "$FIRST_RUN_FLAG"
  log "Initial setup complete."
}

# ===================== SHUFFLE PREPARATION (PER FEED) =====================
prepare_shuffle_if_needed() {
  local list_file="$1"
  local shuf_file="$2"
  local pos_file="$3"

  if [[ ! -s "$shuf_file" || ! -s "$pos_file" ]]; then
    log "Preparing shuffled list for $list_file -> $shuf_file"
    tr -d '\r' < "$list_file" | awk 'NF' | shuf > "$shuf_file"
    echo "0" > "$pos_file"
  fi
}

# ===================== APPEND BATCH (GENERIC FUNCTION) =====================
# feed_type: "std" or "json"
append_batch_generic() {
  local feed_type="$1"

  local LIST_FILE SHUF_FILE POS_FILE DEST_FILE DO_JSON_VALIDATE
  case "$feed_type" in
    std)
      LIST_FILE="$STD_LIST_FILE"
      SHUF_FILE="$STD_SHUF_FILE"
      POS_FILE="$STD_POS_FILE"
      DEST_FILE="$STD_COLLECTED"
      DO_JSON_VALIDATE="no"
      ;;
    json)
      LIST_FILE="$JSON_LIST_FILE"
      SHUF_FILE="$JSON_SHUF_FILE"
      POS_FILE="$JSON_POS_FILE"
      DEST_FILE="$JSON_COLLECTED"
      DO_JSON_VALIDATE="yes"
      ;;
    *)
      log "append_batch_generic: unknown feed '$feed_type'"
      return
      ;;
  esac

  prepare_shuffle_if_needed "$LIST_FILE" "$SHUF_FILE" "$POS_FILE"

  local total pos end count
  total=$(wc -l < "$SHUF_FILE" | tr -d ' ')
  pos=$(cat "$POS_FILE")

  # Reshuffle when all logs are consumed
  if (( pos >= total )); then
    log "[$feed_type] Reached end of shuffled list. Re-shuffling..."
    tr -d '\r' < "$LIST_FILE" | awk 'NF' | shuf > "$SHUF_FILE"
    echo "0" > "$POS_FILE"
    pos=0
    total=$(wc -l < "$SHUF_FILE" | tr -d ' ')
  fi

  end=$(( pos + LINES_PER_TICK ))
  (( end > total )) && end=$total

  if (( end > pos )); then
    if [[ "$DO_JSON_VALIDATE" == "yes" && $(command -v jq >/dev/null 2>&1; echo $?) -eq 0 ]]; then
      # Validate JSON lines before writing
      sed -n "$((pos+1))","$end"p "$SHUF_FILE" \
        | tr -d '\r' \
        | awk 'NF' \
        | while IFS= read -r line; do
            parsed=$(echo "$line" | jq -c . 2>/dev/null) || continue
            printf '%s\n' "$parsed"
          done >> "$DEST_FILE"
    else
      # Append raw lines (for syslog-style or if jq is not installed)
      sed -n "$((pos+1))","$end"p "$SHUF_FILE" \
        | tr -d '\r' \
        | awk 'NF' >> "$DEST_FILE"
    fi

    echo "$end" > "$POS_FILE"
    count=$(( end - pos ))
    log "[$feed_type] Appended $count lines (pos=$end/$total) → $DEST_FILE"
  else
    log "[$feed_type] No new lines to append."
  fi
}

# ===================== MAIN LOOP =====================
run_loop() {
  trap 'log "Received SIGTERM, exiting..."; exit 0' TERM INT
  [[ -f "$FIRST_RUN_FLAG" ]] || first_run_prep
  while true; do
    # Feed standard (syslog-style) logs first
    append_batch_generic "std"
    # Then feed JSON logs
    append_batch_generic "json"
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
  LINES_PER_TICK=<n>    Number of logs appended each cycle per feed (default 100)
  SLEEP_SECONDS=<sec>   Interval between cycles (default 600)
Example:
  LINES_PER_TICK=300 SLEEP_SECONDS=600 sudo $0 start
EOF
    exit 1
  ;;
esac
