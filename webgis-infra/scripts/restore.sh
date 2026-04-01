#!/bin/bash
# ============================================================
# restore.sh — Restauração do banco WebGIS do Backblaze B2
# Uso: bash restore.sh [nome_do_arquivo.sql.gz]
#      (sem argumento: lista backups disponíveis)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${POSTGRES_DB:=webgis}"
: "${POSTGRES_USER:=webgis}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD não definida}"
: "${B2_BUCKET:=webgis-backups}"
: "${RCLONE_REMOTE:=backblaze}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── Listar backups disponíveis ────────────────────────────
if [[ $# -eq 0 ]]; then
    echo "Backups disponíveis no Backblaze B2:"
    echo ""
    rclone ls "${RCLONE_REMOTE}:${B2_BUCKET}" --include "*.sql.gz" | sort -r | head -20
    echo ""
    echo "Uso: bash restore.sh 2026/01/webgis_20260101_020000.sql.gz"
    exit 0
fi

BACKUP_PATH="$1"
LOCAL_FILE="/tmp/restore_$(basename "$BACKUP_PATH")"

# ── Confirmação de segurança ──────────────────────────────
warn "ATENÇÃO: Esta operação sobrescreverá o banco '${POSTGRES_DB}'!"
read -p "Digite 'CONFIRMAR' para prosseguir: " CONFIRM
[[ "$CONFIRM" != "CONFIRMAR" ]] && err "Operação cancelada"

# ── Download do backup ────────────────────────────────────
log "Baixando backup do Backblaze B2..."
rclone copy \
    "${RCLONE_REMOTE}:${B2_BUCKET}/${BACKUP_PATH}" \
    "$(dirname "$LOCAL_FILE")/" \
    --progress

[[ ! -f "$LOCAL_FILE" ]] && err "Arquivo não encontrado: ${BACKUP_PATH}"
log "Download concluído: ${LOCAL_FILE}"

# ── Restauração ───────────────────────────────────────────
log "Restaurando banco de dados..."

# Para conexões ativas
docker exec webgis_postgis psql -U "$POSTGRES_USER" -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${POSTGRES_DB}' AND pid <> pg_backend_pid();" \
    postgres 2>/dev/null || true

# Drop e recria o banco
docker exec webgis_postgis psql -U "$POSTGRES_USER" -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};" postgres
docker exec webgis_postgis psql -U "$POSTGRES_USER" -c "CREATE DATABASE ${POSTGRES_DB};" postgres

# Restaura
zcat "$LOCAL_FILE" | docker exec -i webgis_postgis \
    pg_restore \
        -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" \
        --no-password \
        --format=custom \
        --verbose \
        2>&1 | tail -20

rm -f "$LOCAL_FILE"
log "Restauração concluída com sucesso!"
log "Banco '${POSTGRES_DB}' restaurado de: ${BACKUP_PATH}"
