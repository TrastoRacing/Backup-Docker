#!/bin/bash
# =============================================================================
# Autor:     Antonio Sancho (Trastotech)
#
# backup_docker.sh — (Producción: don-robot)
#
# Timer systemd (ver backup-docker.service + backup-docker.timer):
#   OnCalendar=*-*-* 04:00:00
#
# Modo simulación (no toca nada real):
#   backup_docker.sh --dry-run
#
# =============================================================================
set -euo pipefail

# ─── DEPENDENCIAS ────────────────────────────────────────────────────────────
for CMD in docker jq flock tar sha256sum; do
  if ! command -v "$CMD" > /dev/null 2>&1; then
    echo "[ERROR] Falta la dependencia crítica: ${CMD}. Instálala antes de continuar." >&2
    exit 1
  fi
done

# ─── ARGUMENTOS ──────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"

for ARG in "$@"; do
  case "$ARG" in
    --dry-run|-d) DRY_RUN="true" ;;
    --help|-h)
      echo "Uso: $(basename "$0") [--dry-run|-d]"
      exit 0
      ;;
    *)
      echo "Argumento desconocido: ${ARG}" >&2
      echo "Uso: $(basename "$0") [--dry-run|-d]" >&2
      exit 1
      ;;
  esac
done

# ─── LOCK — evita ejecuciones solapadas (timer + manual, o dos ejecuciones) ─
LOCK_FILE="/var/run/backup_docker.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Ya hay una ejecución en curso (${LOCK_FILE}). Abortando." >&2
  exit 1
fi

# ─── CONFIGURACIÓN ───────────────────────────────────────────────────────────
BACKUP_BASE="/var/backups/docker"
BACKUP_DATE=$(date +%F)
BACKUP_TIME=$(date +%H%M%S)
RETENTION_DAYS=7
MIN_FREE_GB=10
ALPINE_IMG="alpine:3.20"

if [ "$DRY_RUN" = "true" ]; then
  BACKUP_DIR="/tmp/backup_dryrun_${BACKUP_DATE}_${BACKUP_TIME}"
  LOG_FILE="/tmp/backup_dryrun_${BACKUP_DATE}_${BACKUP_TIME}.log"
else
  BACKUP_DIR="${BACKUP_BASE}/backup_${BACKUP_DATE}_${BACKUP_TIME}"
  LOG_DIR="/var/log/docker-backup"
  LOG_FILE="${LOG_DIR}/backup_${BACKUP_DATE}_${BACKUP_TIME}.log"
fi

# Contenedores con base de datos embebida propia → parada breve durante el
# backup para evitar corrupción por escritura concurrente.
SQLITE_CONTAINERS=(
  "pocket-id-pocket-id-1"
  "wgdashboard"
  "bytestash-bytestash-1"
  "crowdsec"
  "duplicati"
)

# Volúmenes excluidos por patrón (substring)
#  - nextcloud_aio_ : Nextcloud AIO se respalda con su propia herramienta (Borg)
EXCLUDE_VOLUME_PATTERNS=(
  "nextcloud_aio_"
)

EXCLUDE_VOLUME_EXACT=(
  "arcane-agent_arcane-data"
  "komodo-periphery-osv_keys"
)

# Stacks con backup completo (compose + datos)
STACKS_FULL=(
  "beszel-agent"
  "bytestash"
  "code-server"
  "docker-controller-bot"
  "komodo"
  "komodo-periphery-osv"
  "newt"
  "pangolin"
  "pangolin-cli-osv"
  "pocket-id"
  "wgdashboard"
)

# Stacks con backup mínimo (solo compose + .env, sin datos)
STACKS_CONFIG_ONLY=(
  "duplicati"
  "nextcloud-aio-mastercontainer"
)

# Override de directorio: stacks cuya label working_dir no es fiable
declare -A STACK_DIR_OVERRIDE=(
  ["beszel-agent"]="/opt/stacks/beszel-agent"
)

# Bind mounts adicionales fuera del directorio de trabajo del stack.
# Múltiples rutas por stack se separan con ":" (ej: "/ruta/a:/ruta/b").
declare -A STACK_EXTRA_PATHS=(
  ["komodo"]="/etc/komodo"
  ["duplicati"]="/opt/stacks/duplicati/config:/opt/stacks/duplicati/scripts"
)

# ─── INIT DIRECTORIOS ────────────────────────────────────────────────────────
mkdir -p "${BACKUP_DIR}"/{volumes,compose,inspect,networks,manifest}
[ "$DRY_RUN" = "false" ] && mkdir -p "$LOG_DIR"

# ─── FUNCIONES BASE ──────────────────────────────────────────────────────────
log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
log_ok()    { log "  [OK]      $*"; }
log_warn()  { log "  [WARN]    $*"; }
log_error() { log "  [ERROR]   $*"; }
log_dry()   { log "  [DRY-RUN] $*"; }
log_sep()   { log "=========================================================="; }

container_running() {
  docker ps --format "{{.Names}}" | grep -q "^${1}$"
}

is_anonymous_volume() {
  local V="$1"
  [ "${#V}" -eq 64 ] && [[ "$V" =~ ^[a-f0-9]+$ ]]
}

is_excluded_volume() {
  local VOL="$1"
  local E
  for E in "${EXCLUDE_VOLUME_EXACT[@]+"${EXCLUDE_VOLUME_EXACT[@]}"}"; do
    [ "$VOL" = "$E" ] && return 0
  done
  for E in "${EXCLUDE_VOLUME_PATTERNS[@]+"${EXCLUDE_VOLUME_PATTERNS[@]}"}"; do
    [[ "$VOL" == *"$E"* ]] && return 0
  done
  return 1
}

verify_archive() {
  local ARCHIVE="$1"
  tar tzf "$ARCHIVE" > /dev/null 2>&1
}

check_disk_space() {
  local AVAILABLE_GB
  mkdir -p "$BACKUP_BASE"
  AVAILABLE_GB=$(df -BG "$BACKUP_BASE" 2>/dev/null | awk 'NR==2{gsub("G",""); print $4}')

  if ! [[ "$AVAILABLE_GB" =~ ^[0-9]+$ ]]; then
    log_error "No se pudo determinar el espacio disponible en disco."
    [ "$DRY_RUN" = "false" ] && exit 1
    return 0
  fi

  if [ "$AVAILABLE_GB" -lt "$MIN_FREE_GB" ]; then
    log_error "Espacio insuficiente: ${AVAILABLE_GB}GB disponibles, mínimo ${MIN_FREE_GB}GB requeridos"
    [ "$DRY_RUN" = "false" ] && exit 1
    log_warn "DRY-RUN: en producción el script abortaría aquí."
    return 0
  fi
  log "Espacio disponible en disco: ${AVAILABLE_GB}GB"
}

cleanup_old_backups() {
  log "Limpiando backups con más de ${RETENTION_DAYS} días..."
  find "$BACKUP_BASE" -maxdepth 1 -name "backup_*" -type d -mtime +"${RETENTION_DAYS}" \
    -exec rm -rf {} + 2>/dev/null || true
  find "$LOG_DIR" -maxdepth 1 -name "backup_*.log" -mtime +"${RETENTION_DAYS}" \
    -exec rm -f {} + 2>/dev/null || true
  log_ok "Limpieza completada."
}

get_stack_dir() {
  local PROJECT="$1"

  if [ -n "${STACK_DIR_OVERRIDE[$PROJECT]:-}" ]; then
    echo "${STACK_DIR_OVERRIDE[$PROJECT]}"
    return 0
  fi

  local CID
  CID=$(docker ps -a --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.ID}}' | head -1)
  [ -z "$CID" ] && return 1

  local DIR
  DIR=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CID" 2>/dev/null)
  [[ "$DIR" != /* ]] && return 1

  echo "$DIR"
}

find_compose_file_in_dir() {
  local DIR="$1"
  local NAME
  for NAME in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    if [ -f "${DIR}/${NAME}" ]; then
      echo "${DIR}/${NAME}"
      return 0
    fi
  done
  return 1
}

backup_stack_full() {
  local PROJECT="$1"
  local STACK_DIR
  STACK_DIR=$(get_stack_dir "$PROJECT") || true
  if [ -z "${STACK_DIR:-}" ] || [ ! -d "$STACK_DIR" ]; then
    log_warn "Stack ${PROJECT}: directorio no localizado — omitido."
    STACK_ERR=$(( STACK_ERR + 1 ))
    return 1
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_dry "tar czf ${PROJECT}.tar.gz  ← ${STACK_DIR}"
    return 0
  fi

  local ARCHIVE="${BACKUP_DIR}/compose/${PROJECT}.tar.gz"
  local TAR_EXIT
  set +e
  tar --exclude="*.sock" -czf "$ARCHIVE" -C "$STACK_DIR" . > /dev/null 2>&1
  TAR_EXIT=$?
  set -e

  if [ "$TAR_EXIT" -eq 0 ] || [ "$TAR_EXIT" -eq 1 ]; then
    if verify_archive "$ARCHIVE"; then
      log_ok "Stack completo: ${PROJECT} — $(du -sh "$ARCHIVE" | cut -f1)"
    else
      log_error "Archivo corrupto tras creación: ${PROJECT}.tar.gz"
      STACK_ERR=$(( STACK_ERR + 1 ))
      return 1
    fi
  else
    log_error "Fallo crítico respaldando stack: ${PROJECT} (exit ${TAR_EXIT})"
    STACK_ERR=$(( STACK_ERR + 1 ))
    return 1
  fi
}

backup_stack_extra_paths() {
  local PROJECT="$1"
  local PATHS="${STACK_EXTRA_PATHS[$PROJECT]:-}"
  [ -z "$PATHS" ] && return 0

  local EXTRA_PATHS_ARRAY
  IFS=':' read -ra EXTRA_PATHS_ARRAY <<< "$PATHS"

  local P
  for P in "${EXTRA_PATHS_ARRAY[@]}"; do
    if [ ! -d "$P" ]; then
      log_warn "Ruta extra ${P} de ${PROJECT} no existe — omitida."
      continue
    fi

    local SAFE_NAME
    SAFE_NAME=$(echo "$P" | sed 's#^/##; s#/#-#g')

    if [ "$DRY_RUN" = "true" ]; then
      log_dry "tar czf ${PROJECT}__extra_${SAFE_NAME}.tar.gz  ← ${P} (bind mount externo)"
      continue
    fi

    local ARCHIVE="${BACKUP_DIR}/compose/${PROJECT}__extra_${SAFE_NAME}.tar.gz"
    local TAR_EXIT
    set +e
    tar --exclude="*.sock" -czf "$ARCHIVE" -C "$(dirname "$P")" "$(basename "$P")" > /dev/null 2>&1
    TAR_EXIT=$?
    set -e

    if { [ "$TAR_EXIT" -eq 0 ] || [ "$TAR_EXIT" -eq 1 ]; } && verify_archive "$ARCHIVE"; then
      log_ok "Bind mount extra: ${PROJECT} ← ${P} — $(du -sh "$ARCHIVE" | cut -f1)"
    else
      log_error "Fallo respaldando bind mount extra ${P} de ${PROJECT} (exit ${TAR_EXIT})"
      STACK_ERR=$(( STACK_ERR + 1 ))
    fi
  done
}

backup_stack_config_only() {
  local PROJECT="$1"
  local STACK_DIR
  STACK_DIR=$(get_stack_dir "$PROJECT") || true
  if [ -z "${STACK_DIR:-}" ] || [ ! -d "$STACK_DIR" ]; then
    log_warn "Stack ${PROJECT}: directorio no localizado — omitido."
    STACK_ERR=$(( STACK_ERR + 1 ))
    return 1
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_dry "cp compose+.env de ${PROJECT}  ← ${STACK_DIR}"
    return 0
  fi

  local COMPOSE_FILE
  COMPOSE_FILE=$(find_compose_file_in_dir "$STACK_DIR") || true

  if [ -z "${COMPOSE_FILE:-}" ]; then
    log_error "Stack ${PROJECT}: no se encontró un fichero Compose."
    STACK_ERR=$(( STACK_ERR + 1 ))
    return 1
  fi

  local DEST="${BACKUP_DIR}/compose/${PROJECT}"
  mkdir -p "$DEST"

  if ! cp -a "$COMPOSE_FILE" "$DEST/"; then
    log_error "Stack ${PROJECT}: no se pudo copiar $(basename "$COMPOSE_FILE")."
    STACK_ERR=$(( STACK_ERR + 1 ))
    return 1
  fi

  if [ -f "${STACK_DIR}/.env" ] && ! cp -a "${STACK_DIR}/.env" "$DEST/"; then
    log_error "Stack ${PROJECT}: no se pudo copiar .env."
    STACK_ERR=$(( STACK_ERR + 1 ))
    return 1
  fi

  log_ok "Solo compose+.env: ${PROJECT}"
}

STOPPED_CONTAINERS=()
STACK_ERR=0

cleanup_trap() {
  local EXIT_CODE=$?
  if [ "${#STOPPED_CONTAINERS[@]}" -gt 0 ]; then
    log ""
    log "[TRAP] Salida inesperada — reiniciando contenedores parados..."
    local C
    for C in "${STOPPED_CONTAINERS[@]}"; do
      if [ "$DRY_RUN" = "true" ]; then
        log_dry "docker start ${C}"
      elif docker start "$C" > /dev/null 2>&1; then
        log_ok "${C} reiniciado por trap."
      else
        log_error "${C} NO pudo reiniciarse — INTERVENCIÓN MANUAL REQUERIDA"
        STACK_ERR=$(( STACK_ERR + 1 ))
      fi
    done
  fi
  if [ "$EXIT_CODE" -ne 0 ]; then
    log_error "Script terminado con errores (exit code: ${EXIT_CODE})"
  fi
}
trap cleanup_trap EXIT

stop_container() {
  local NAME="$1"
  if ! container_running "$NAME"; then
    log_warn "${NAME} no está corriendo — omitido."
    return 0
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log_dry "docker stop -t 60 ${NAME}  (se pararía brevemente para backup seguro)"
    STOPPED_CONTAINERS+=("$NAME")
    return 0
  fi
  log "  Parando ${NAME} (timeout 60s)..."
  if docker stop -t 60 "$NAME" > /dev/null 2>&1; then
    STOPPED_CONTAINERS+=("$NAME")
    log_ok "${NAME} parado."
  else
    log_error "No se pudo parar ${NAME}. Abortando para no respaldar datos potencialmente inconsistentes."
    return 1
  fi
}

restart_stopped_containers() {
  [ "${#STOPPED_CONTAINERS[@]}" -eq 0 ] && return 0
  log "Reiniciando contenedores SQLite/BoltDB..."
  local C
  for C in "${STOPPED_CONTAINERS[@]}"; do
    if [ "$DRY_RUN" = "true" ]; then
      log_dry "docker start ${C}  (se reiniciaría)"
    elif docker start "$C" > /dev/null 2>&1; then
      log_ok "${C} reiniciado."
    else
      log_error "${C} NO pudo reiniciarse — INTERVENCIÓN MANUAL REQUERIDA"
      STACK_ERR=$(( STACK_ERR + 1 ))
    fi
  done
  STOPPED_CONTAINERS=()
}

# ─── INICIO ──────────────────────────────────────────────────────────────────
log_sep
if [ "$DRY_RUN" = "true" ]; then
  log "=== [DRY-RUN] BACKUP DOCKER — $(hostname) — ${BACKUP_DATE} ${BACKUP_TIME} ==="
  log "    MODO SIMULACIÓN — no se modifica nada en producción"
else
  log "=== BACKUP DOCKER — $(hostname) — ${BACKUP_DATE} ${BACKUP_TIME} ==="
fi
log "    Script: $0 | Usuario: $(id -un) | PID: $$"
log_sep
check_disk_space

log ""
log "--- [0/4] Manifiesto de estado ------------------------------------------"

MANIFEST_FILE="${BACKUP_DIR}/manifest/manifest_${BACKUP_DATE}.json"
VOL_INDEX="${BACKUP_DIR}/manifest/volume_index_${BACKUP_DATE}.txt"
BIND_INDEX="${BACKUP_DIR}/manifest/bind_index_${BACKUP_DATE}.txt"

CONTAINER_IDS=$(docker ps -a -q)
if [ -n "$CONTAINER_IDS" ]; then
  CONTAINERS_JSON=$(docker inspect $CONTAINER_IDS 2>/dev/null | jq '
    [.[] | {
      name: (.Name | ltrimstr("/")),
      status: .State.Status,
      image: .Config.Image,
      image_digest: .Image,
      restart_policy: .HostConfig.RestartPolicy.Name,
      networks: (.NetworkSettings.Networks // {} | keys),
      ports: (.NetworkSettings.Ports // {} | keys),
      volumes: [.Mounts[]? | select(.Type=="volume") | {name: .Name, mount: .Destination}],
      binds: [.Mounts[]? | select(.Type=="bind") | {source: .Source, mount: .Destination}]
    }]
  ')
else
  CONTAINERS_JSON="[]"
fi

jq -n \
  --arg date "$BACKUP_DATE" \
  --arg host "$(hostname)" \
  --arg time "$BACKUP_TIME" \
  --argjson containers "$CONTAINERS_JSON" \
  '{backup_date: $date, backup_host: $host, backup_time: $time, containers: $containers}' \
  > "$MANIFEST_FILE"

{
  echo "# ÍNDICE VOLUMEN → CONTENEDOR → MOUNTPOINT"
  echo "# Generado: ${BACKUP_DATE} ${BACKUP_TIME}"
  echo "# Formato: VOLUMEN | CONTENEDOR | MOUNTPOINT"
  echo ""
  jq -r '.containers[] | .name as $n | .volumes[]? | "\(.name) | \($n) | \(.mount)"' "$MANIFEST_FILE"
} > "$VOL_INDEX"

{
  echo "# ÍNDICE BIND MOUNT (HOST) → CONTENEDOR → MOUNTPOINT"
  echo "# Generado: ${BACKUP_DATE} ${BACKUP_TIME}"
  echo "# Formato: RUTA_HOST | CONTENEDOR | MOUNTPOINT"
  echo "# Usar para auditar bind mounts fuera de /opt/stacks/<proyecto>/"
  echo ""
  jq -r '.containers[] | .name as $n | .binds[]? | "\(.source) | \($n) | \(.mount)"' "$MANIFEST_FILE"
} > "$BIND_INDEX"

jq -r '.containers[] | "  \(.name) → \(.image)"' "$MANIFEST_FILE" | while IFS= read -r LINE; do
  log "$LINE"
done

log_ok "manifest_${BACKUP_DATE}.json"
log_ok "volume_index_${BACKUP_DATE}.txt"
log_ok "bind_index_${BACKUP_DATE}.txt"

log ""
log "--- [1/4] Backup redes Docker custom ------------------------------------"

RECREATE_NET="${BACKUP_DIR}/networks/recreate_networks.sh"
echo "#!/bin/bash" > "$RECREATE_NET"
echo "# Recrear redes Docker custom — backup: ${BACKUP_DATE}" >> "$RECREATE_NET"
echo "" >> "$RECREATE_NET"

NET_COUNT=0
while IFS= read -r NET_ID; do
  NET_NAME=$(docker network inspect --format '{{.Name}}'     "$NET_ID" 2>/dev/null || true)
  NET_DRIVER=$(docker network inspect --format '{{.Driver}}' "$NET_ID" 2>/dev/null || true)

  [[ "$NET_NAME" =~ ^(bridge|host|none)$ ]] && continue

  docker network inspect "$NET_ID" > "${BACKUP_DIR}/networks/${NET_NAME}.json" 2>/dev/null || true

  SUBNET=$(docker network inspect \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET_ID" 2>/dev/null || true)

  if [ -n "${SUBNET:-}" ]; then
    echo "docker network create --driver ${NET_DRIVER} --subnet ${SUBNET} ${NET_NAME} 2>/dev/null || echo \"Red ${NET_NAME} ya existe\"" >> "$RECREATE_NET"
  else
    echo "docker network create --driver ${NET_DRIVER} ${NET_NAME} 2>/dev/null || echo \"Red ${NET_NAME} ya existe\"" >> "$RECREATE_NET"
  fi

  NET_COUNT=$(( NET_COUNT + 1 ))
  log_ok "Red: ${NET_NAME} (${NET_DRIVER})"
done < <(docker network ls -q)

chmod +x "$RECREATE_NET"
log_ok "Redes exportadas: ${NET_COUNT}"

log ""
log "--- [2/4] Parando contenedores SQLite/BoltDB ----------------------------"
for CONTAINER in "${SQLITE_CONTAINERS[@]}"; do
  stop_container "$CONTAINER"
done

log ""
log "--- [3/4] Backup volúmenes ----------------------------------------------"
VOL_OK=0
VOL_ERR=0

if [ "$DRY_RUN" = "false" ]; then
  docker image inspect "$ALPINE_IMG" > /dev/null 2>&1 || docker pull "$ALPINE_IMG" > /dev/null 2>&1
fi

while IFS= read -r VOLUME; do
  if is_anonymous_volume "$VOLUME"; then
    log "  -> Omitiendo volumen anónimo: ${VOLUME:0:12}..."
    continue
  fi
  if is_excluded_volume "$VOLUME"; then
    log "  -> Omitiendo volumen excluido: ${VOLUME}"
    continue
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_dry "docker run ${ALPINE_IMG} tar czf ${VOLUME}_${BACKUP_DATE}.tar.gz  ← ${VOLUME}"
    VOL_OK=$(( VOL_OK + 1 ))
    continue
  fi

  log "  Respaldando: ${VOLUME}"
  OUTFILE="${BACKUP_DIR}/volumes/${VOLUME}_${BACKUP_DATE}.tar.gz"

  if docker run --rm --read-only --network=none --tmpfs /tmp:rw,size=64m \
      -v "${VOLUME}:/data:ro" \
      -v "${BACKUP_DIR}/volumes:/backup" \
      "$ALPINE_IMG" \
      tar czf "/backup/${VOLUME}_${BACKUP_DATE}.tar.gz" -C /data . \
      2>/dev/null && verify_archive "$OUTFILE"; then
    VOL_OK=$(( VOL_OK + 1 ))
    log_ok "${VOLUME} — $(du -sh "$OUTFILE" | cut -f1)"
  else
    VOL_ERR=$(( VOL_ERR + 1 ))
    log_error "Fallo al respaldar volumen: ${VOLUME}"
  fi
done < <(docker volume ls -q)

log "  Volúmenes: ${VOL_OK} [OK] | ${VOL_ERR} [ERROR]"

log ""
log "--- [4/4] Backup selectivo de stacks (compose) --------------------------"

for PROJECT in "${STACKS_FULL[@]}"; do
  backup_stack_full "$PROJECT" || true
  backup_stack_extra_paths "$PROJECT"
done

for PROJECT in "${STACKS_CONFIG_ONLY[@]}"; do
  backup_stack_config_only "$PROJECT" || true
  backup_stack_extra_paths "$PROJECT"
done

log ""
restart_stopped_containers

log ""
log "--- [4b] Metadatos docker inspect ----------------------------------------"
INSPECT_OK=0
while IFS= read -r ID; do
  INAME=$(docker inspect --format '{{.Name}}' "$ID" 2>/dev/null | tr -d '/' || echo "$ID")
  if [ "$DRY_RUN" = "true" ]; then
    log_dry "docker inspect ${INAME} → ${BACKUP_DIR}/inspect/${INAME}.json"
    INSPECT_OK=$(( INSPECT_OK + 1 ))
  else
    if docker inspect "$ID" > "${BACKUP_DIR}/inspect/${INAME}.json" 2>/dev/null; then
      INSPECT_OK=$(( INSPECT_OK + 1 ))
    else
      log_error "inspect falló para ${INAME}"
      STACK_ERR=$(( STACK_ERR + 1 ))
    fi
  fi
done < <(docker ps -a -q)
log_ok "Inspect: ${INSPECT_OK} contenedores respaldados"

if [ "$DRY_RUN" = "false" ]; then
  CHECKSUMS_FILE="${BACKUP_DIR}/manifest/checksums_${BACKUP_DATE}.sha256"
  if find "${BACKUP_DIR}/volumes" "${BACKUP_DIR}/compose" -name "*.tar.gz" -exec sha256sum {} + > "$CHECKSUMS_FILE" 2>/dev/null; then
    log_ok "Checksums SHA256 generados: checksums_${BACKUP_DATE}.sha256"
  else
    log_error "Fallo al generar los checksums SHA256"
    STACK_ERR=$(( STACK_ERR + 1 ))
  fi
fi

log ""
log "--- Limpieza retención (${RETENTION_DAYS} días) -------------------------"
if [ "$DRY_RUN" = "true" ]; then
  log_dry "Limpieza de retención omitida en modo simulación."
elif [ "$VOL_ERR" -eq 0 ] && [ "$STACK_ERR" -eq 0 ]; then
  cleanup_old_backups
else
  log_warn "Se detectaron errores (VOL_ERR=${VOL_ERR}, STACK_ERR=${STACK_ERR}) — se omite la limpieza para preservar histórico."
fi

TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
log ""
log_sep
if [ "$DRY_RUN" = "true" ]; then
  log "=== [DRY-RUN] SIMULACIÓN COMPLETADA ==="
  log "  Ningún dato de producción fue modificado."
  log "  Manifiesto, redes y bind_index generados con datos REALES en: ${BACKUP_DIR}"
else
  log "=== BACKUP COMPLETADO ==="
  log "  Tamaño total : ${TOTAL_SIZE}"
  log "  Directorio   : ${BACKUP_DIR}"
  log "  Volúmenes    : ${VOL_OK} OK | ${VOL_ERR} errores"
  log "  Stacks       : ${STACK_ERR} errores"
  log "  Redes        : ${NET_COUNT}"
  log "  Inspect      : ${INSPECT_OK} contenedores"
  log ""
  log "  Backups retenidos:"
  while IFS= read -r DIR; do
    log "    · ${DIR##*/}  ($(du -sh "$DIR" | cut -f1))"
  done < <(find "$BACKUP_BASE" -maxdepth 1 -name "backup_*" -type d | sort)
fi
log_sep
# ─── CONTROL DE SALIDA PARA SYSTEMD ──────────────────────────────────────────
if [ "$DRY_RUN" = "true" ]; then
  exit 0
elif [ "$VOL_ERR" -gt 0 ] || [ "$STACK_ERR" -gt 0 ]; then
  log_error "El backup terminó con errores. Enviando exit 1 a systemd para marcar el servicio como FAILED."
  exit 1
else
  exit 0
fi
