#!/usr/bin/env bash
set -euo pipefail

# ==== CONFIG ====
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

SLEEP_SECONDS="${SLEEP_SECONDS:-600}"      # 10 min
LINES_PER_TICK="${LINES_PER_TICK:-100}"    # líneas por ciclo

WAZUH_OSSEC="/var/ossec/etc/ossec.conf"
WAZUH_SVC="wazuh-agent"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" ; }

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Por favor ejecutar como root (sudo)." >&2
    exit 1
  fi
}

first_run_prep() {
  mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"

  mkdir -p "$HOME_DIR"
  if [[ ! -f "$LIST_FILE" ]]; then
    log "Descargando lista de logs a $LIST_FILE"
    curl -fsSL "$LIST_URL" -o "$LIST_FILE"
  else
    log "Lista ya existe: $LIST_FILE"
  fi

  if [[ ! -f "$COLLECTED" ]]; then
    log "Creando $COLLECTED"
    touch "$COLLECTED"
    chmod 0644 "$COLLECTED"
  fi

  if ! grep -q "<location>$COLLECTED</location>" "$WAZUH_OSSEC"; then
    log "Agregando <localfile> en $WAZUH_OSSEC"
    cp -a "$WAZUH_OSSEC" "$WAZUH_OSSEC.bak.$(date +%Y%m%d%H%M%S)"
    sed -i "\#</ossec_config>#i \
<localfile>\n  <location>${COLLECTED}</location>\n  <log_format>json</log_format>\n</localfile>\n" "$WAZUH_OSSEC"
    log "Reiniciando servicio $WAZUH_SVC"
    systemctl restart "$WAZUH_SVC" || log "Aviso: no se pudo reiniciar $WAZUH_SVC (continuo)"
  else
    log "El <localfile> ya estaba configurado."
  fi

  touch "$FIRST_RUN_FLAG"
  log "Preparación inicial completada."
}

prepare_shuffle_if_needed() {
  # genera una “baraja” sin blancos y sin CR (\r)
  if [[ ! -s "$SHUF_FILE" || ! -s "$POS_FILE" ]]; then
    log "Preparando baraja aleatoria…"
    # normaliza: quita \r, elimina líneas vacías; luego baraja
    tr -d '\r' < "$LIST_FILE" | awk 'NF' | shuf > "$SHUF_FILE"
    echo "0" > "$POS_FILE"
  fi
}

append_batch() {
  prepare_shuffle_if_needed

  local total pos end count
  total=$(wc -l < "$SHUF_FILE" | tr -d ' ')
  pos=$(cat "$POS_FILE")

  if (( pos >= total )); then
    log "Fin de baraja alcanzado. Re–barajando…"
    tr -d '\r' < "$LIST_FILE" | awk 'NF' | shuf > "$SHUF_FILE"
    echo "0" > "$POS_FILE"
    pos=0
    total=$(wc -l < "$SHUF_FILE" | tr -d ' ')
  fi

  end=$(( pos + LINES_PER_TICK ))
  (( end > total )) && end=$total

  if (( end > pos )); then
    # extrae el lote, normaliza y, si hay jq, valida cada JSON
    if command -v jq >/dev/null 2>&1; then
      sed -n "$((pos+1))","$end"p "$SHUF_FILE" \
        | tr -d '\r' \
        | awk 'NF' \
        | while IFS= read -r line; do
            # valida y fuerza single-line
            parsed=$(echo "$line" | jq -c . 2>/dev/null) || continue
            printf '%s\n' "$parsed"
          done >> "$COLLECTED"
    else
      # sin jq: al menos quitamos CR y líneas vacías
      sed -n "$((pos+1))","$end"p "$SHUF_FILE" \
        | tr -d '\r' \
        | awk 'NF' >> "$COLLECTED"
    fi

    echo "$end" > "$POS_FILE"
    count=$(( end - pos ))
    log "Append de $count líneas (pos=$end/$total) → $COLLECTED"
  else
    log "No hay nuevas líneas para append."
  fi
}

run_loop() {
  trap 'log "Recibido SIGTERM, saliendo…"; exit 0' TERM INT
  [[ -f "$FIRST_RUN_FLAG" ]] || first_run_prep
  while true; do
    append_batch
    sleep "$SLEEP_SECONDS" &
    wait $!
  done
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid=$(cat "$PID_FILE")
  [[ -n "$pid" && -d "/proc/$pid" ]] && return 0 || return 1
}

start_daemon() {
  ensure_root
  if is_running; then
    echo "Ya está corriendo. PID $(cat "$PID_FILE")"
    exit 0
  fi
  # lock simple para evitar dobles instancias
  exec 9>/var/lock/wz-logfeeder.lock
  if ! flock -n 9; then
    echo "Ya hay una instancia corriendo. Saliendo."
    exit 0
  fi
  nohup "$0" run >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "Iniciado en background. PID $(cat "$PID_FILE")"
  echo "Logs: $LOG_FILE"
}

stop_daemon() {
  ensure_root
  if ! is_running; then
    echo "No está corriendo."
    exit 0
  fi
  local pid; pid=$(cat "$PID_FILE")
  kill "$pid" || true
  sleep 1
  [[ -d "/proc/$pid" ]] && kill -9 "$pid" || true
  rm -f "$PID_FILE"
  echo "Detenido."
}

status_daemon() {
  if is_running; then
    echo "RUNNING (PID $(cat "$PID_FILE"))"
  else
    echo "STOPPED"
  fi
}

case "${1:-}" in
  start)  start_daemon ;;
  stop)   stop_daemon ;;
  status) status_daemon ;;
  run)    run_loop ;;
  *)
    cat <<EOF
Uso: $0 {start|stop|status}
Variables: LINES_PER_TICK=<n> SLEEP_SECONDS=<seg>
Ejemplo: LINES_PER_TICK=300 SLEEP_SECONDS=600 sudo $0 start
EOF
    exit 1
  ;;
esac
