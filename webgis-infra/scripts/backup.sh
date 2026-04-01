#!/bin/bash
# ============================================================
# backup.sh — Backup automático WebGIS → Backblaze B2
# Ferramentas: pg_dump + rclone
# Custo: GRÁTIS até 10GB (Backblaze B2 free tier)
#        US$6/TB/mês acima de 10GB
# ============================================================

set -euo pipefail

# ── Configurações ─────────────────────────────────────────
BACKUP_DIR="/tmp/webgis-backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/webgis_${TIMESTAMP}.sql.gz"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Carrega variáveis de ambiente
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# Variáveis obrigatórias
: "${POSTGRES_DB:=webgis}"
: "${POSTGRES_USER:=webgis}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD não definida}"
: "${B2_BUCKET:=webgis-backups}"          # Bucket no Backblaze B2
: "${BACKUP_RETENTION_DAYS:=7}"           # Manter últimos 7 dias
: "${RCLONE_REMOTE:=backblaze}"           # Nome do remote rclone

# ── Funções ───────────────────────────────────────────────
log()   { echo "${LOG_PREFIX} [INFO] $1"; }
error() { echo "${LOG_PREFIX} [ERROR] $1" >&2; exit 1; }

notify_error() {
    # Envie alertas por webhook (Slack/Discord/Telegram) se configurado
    if [[ -n "${ALERT_WEBHOOK_URL:-}" ]]; then
        curl -s -X POST "$ALERT_WEBHOOK_URL" \
            -H 'Content-type: application/json' \
            -d "{\"text\": \"⚠️ Falha no backup WebGIS: $1\"}" || true
    fi
}

# ── Verificações ──────────────────────────────────────────
command -v rclone &>/dev/null || error "rclone não encontrado. Execute: apt install rclone"
command -v docker &>/dev/null || error "docker não encontrado"

mkdir -p "$BACKUP_DIR"

# ── 1. Dump do PostgreSQL ─────────────────────────────────
log "Iniciando backup do PostgreSQL..."

# Executa pg_dump dentro do container, comprime com gzip
docker exec webgis_postgis \
    pg_dump \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        --format=custom \
        --compress=9 \
        --no-password \
    2>/dev/null \
    | gzip -9 > "$BACKUP_FILE" \
    || { notify_error "pg_dump falhou"; error "pg_dump falhou"; }

BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
log "Backup criado: ${BACKUP_FILE} (${BACKUP_SIZE})"

# ── 2. Verificar integridade do backup ────────────────────
log "Verificando integridade..."
if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
    notify_error "Arquivo de backup corrompido"
    error "Arquivo de backup corrompido: ${BACKUP_FILE}"
fi
log "Integridade verificada ✓"

# ── 3. Upload para Backblaze B2 ───────────────────────────
log "Enviando para Backblaze B2 (${RCLONE_REMOTE}:${B2_BUCKET})..."

# Organiza por data: backups/2026/01/webgis_20260101_020000.sql.gz
REMOTE_PATH="${RCLONE_REMOTE}:${B2_BUCKET}/$(date +%Y/%m)/$(basename "$BACKUP_FILE")"

rclone copy \
    "$BACKUP_FILE" \
    "${RCLONE_REMOTE}:${B2_BUCKET}/$(date +%Y/%m)/" \
    --progress \
    --retries 3 \
    --low-level-retries 10 \
    || { notify_error "Upload para B2 falhou"; error "rclone upload falhou"; }

log "Upload concluído para: ${REMOTE_PATH}"

# ── 4. Limpeza local ──────────────────────────────────────
rm -f "$BACKUP_FILE"
log "Arquivo local removido"

# ── 5. Rotação de backups remotos ─────────────────────────
log "Removendo backups com mais de ${BACKUP_RETENTION_DAYS} dias..."

# Lista e remove arquivos antigos no B2
rclone delete \
    "${RCLONE_REMOTE}:${B2_BUCKET}" \
    --min-age "${BACKUP_RETENTION_DAYS}d" \
    --include "*.sql.gz" \
    2>/dev/null || warn "Nenhum backup antigo para remover"

# ── 6. Relatório final ────────────────────────────────────
REMOTE_SIZE=$(rclone size "${RCLONE_REMOTE}:${B2_BUCKET}" --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d[\"bytes\"]/1024/1024:.1f}MB')" 2>/dev/null || echo "N/A")

log "════════════════════════════════"
log "Backup concluído com sucesso!"
log "  Arquivo:    $(basename "$BACKUP_FILE")"
log "  Tamanho:    ${BACKUP_SIZE}"
log "  Destino:    ${REMOTE_PATH}"
log "  Total B2:   ${REMOTE_SIZE}"
log "  Retenção:   ${BACKUP_RETENTION_DAYS} dias"
log "════════════════════════════════"
