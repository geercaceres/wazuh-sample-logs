#!/usr/bin/env bash
set -euo pipefail

# =================== CONFIG ===================
HOME_DIR="/home/wazuh-user"
LIST_URL="https://raw.githubusercontent.com/geercaceres/wazuh-sample-logs/main/sample%20logs%20list.txt"
LIST_FILE="$HOME_DIR/sample-logs-list.txt"   # renombrado sin espacios
COLLECTED="$HOME_DIR/file-collected.log"

STATE_DIR="/var/lib/wz-logfeeder"
SHUF_FILE="$STATE_DIR/shuffled.list"
POS_FILE="$STATE_DIR/position"
FIRST_RUN_FLAG="$STATE_DIR/.first_run_done"

PID_FILE="/var/run/wz-logfeeder.pid"
LOG_FILE="/var/log/wz-logfeeder.log"

# Ajustables
SLEEP_SECONDS="${SLEEP_SECONDS:-600}"         # 10 min
LINES_PER_TICK="${LINES_PER_TICK:-100}"       # líneas por ciclo

# Wazuh
WAZUH_OSSEC="/var/ossec/etc/ossec.conf"
WAZUH_SVC="wazuh-agent"

# =================== FUNCIONES ===================
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

  # 1) Descargar lista
  mkdir -p "$HOME_DIR"
  if [[ ! -f "$LIST_FILE" ]]; then
    log "Descargando lista de logs a $LIST_FILE"
    curl -fsSL "$LIST_URL" -o "$LIST_FILE"
  else
    log "Lista ya existe: $LIST_FILE"
  fi

  # 2) Crear archivo de salida
  if [[ ! -f "$COLLECTED" ]]; then
    log "Creando $COLLECTED"
    touch "$COLLECTED"
    chmod 0644 "$COLLECTED"
  fi

  # 3) Insertar <localfile> si falta
  if ! grep -q "<location>$COLLECTED</location>" "$WAZUH_OSSEC"; then
    log "Agregando <localfile> en $WAZUH_OSSEC"
    cp -a "$WAZUH_OSSEC" "$WAZUH_OSSEC.bak.$(date +%Y%m%d%H%M%S)"
    sed -i "\#</ossec_config>#i \
<localfile>\n  <location>${COLLECTED}</location>\n  <log_format>json</log_format>\n</localfile>\n" "$WAZUH_OSSEC"

    # 4) Reiniciar agente
    log "Reiniciando servicio $WAZUH_SVC"
    systemctl restart "$WAZUH_SVC" || log "Aviso: no se pudo reiniciar $WAZUH_SVC (continuo)"
  else
    log "El <localfile> ya estaba configurado."
  fi

  touch "$FIRST_RUN_FLAG"
  log "Preparación inicial completada."
}

prepare_shuffle_if_needed() {
  if [[ ! -s "$SHUF_FILE" || ! -s "$POS_FILE" ]]; then
    log "Preparando baraja aleatoria…"
    awk 'NF' "$LIST_FILE" | shuf > "$SHUF_FILE"
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
    awk 'NF' "$LIST_FILE" | shuf > "$SHUF_FILE"
    echo "0" > "$POS_FILE"
    pos=0
    total=$(wc -l < "$SHUF_FILE" | tr -d ' ')
  fi

  end=$(( pos + LINES_PER_TICK ))
  if (( end > total )); then end=$total; fi

  if (( end > pos )); then
    # Añadir líneas, garantizando salto de línea entre entradas
    sed -n "$((pos+1))","$end"p "$SHUF_FILE" | sed 's/$/\n/' >> "$COLLECTED"
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
  # Arranca en background llamándose a sí mismo con 'run'
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
  if [[ -d "/proc/$pid" ]]; then
    kill -9 "$pid" || true
  fi
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

# =================== DISPATCH ===================
case "${1:-}" in
  start)  start_daemon ;;
  stop)   stop_daemon ;;
  status) status_daemon ;;
  run)    run_loop ;;     # uso interno
  *)
    cat <<EOF
Uso: $0 {start|stop|status}
Variables opcionales: LINES_PER_TICK=<n> SLEEP_SECONDS=<seg>
Ejemplo: LINES_PER_TICK=300 SLEEP_SECONDS=600 sudo $0 start
EOF
    exit 1
  ;;
esac
