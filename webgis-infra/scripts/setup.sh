#!/bin/bash
# ============================================================
# setup.sh — Configuração inicial do servidor WebGIS
# Testado em: Ubuntu 22.04 LTS (Vultr São Paulo)
# Execução: sudo bash setup.sh
# ============================================================

set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══ $1 ══${NC}"; }

# ── Verificações iniciais ─────────────────────────────────
[[ $EUID -ne 0 ]] && error "Execute como root: sudo bash setup.sh"

section "1. Atualização do sistema"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git unzip htop \
    ufw fail2ban \
    ca-certificates gnupg lsb-release \
    rclone                          # Para backup Backblaze B2
log "Sistema atualizado"

section "2. Instalação do Docker"
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "${SUDO_USER:-ubuntu}"
    log "Docker instalado"
else
    log "Docker já instalado: $(docker --version)"
fi

# Docker Compose v2 (plugin)
if ! docker compose version &>/dev/null; then
    mkdir -p /usr/local/lib/docker/cli-plugins
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    log "Docker Compose instalado: ${COMPOSE_VERSION}"
else
    log "Docker Compose já instalado: $(docker compose version)"
fi

section "3. Firewall (UFW)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH — porta padrão (troque para segurança)
ufw allow 22/tcp comment "SSH"

# HTTP/HTTPS
ufw allow 80/tcp  comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
ufw allow 443/udp comment "HTTPS/HTTP3"

# Bloquear acesso direto aos serviços internos
# (tudo passa pelo Caddy)
ufw --force enable
log "Firewall configurado"

section "4. Fail2ban (proteção SSH)"
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configurado"

section "5. Limites do sistema para Docker/PostGIS"
cat >> /etc/sysctl.conf << 'EOF'

# WebGIS — Performance
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
fs.file-max = 1000000

# PostgreSQL — memória compartilhada
kernel.shmmax = 8589934592
kernel.shmall = 2097152
EOF

sysctl -p -q
log "Parâmetros do kernel configurados"

# Limites de arquivos abertos
cat >> /etc/security/limits.conf << 'EOF'
*    soft nofile 65536
*    hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
log "Limites de arquivo configurados"

section "6. Diretório do projeto"
PROJECT_DIR="/opt/webgis"
mkdir -p "${PROJECT_DIR}"

# Copiar arquivos do projeto (se executado do diretório de deploy)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../docker-compose.yml" ]]; then
    cp -r "${SCRIPT_DIR}/.." "${PROJECT_DIR}/"
    log "Arquivos copiados para ${PROJECT_DIR}"
else
    warn "Execute 'git clone' do seu repositório em ${PROJECT_DIR}"
fi

section "7. Configuração do .env"
if [[ ! -f "${PROJECT_DIR}/.env" ]]; then
    if [[ -f "${PROJECT_DIR}/.env.example" ]]; then
        cp "${PROJECT_DIR}/.env.example" "${PROJECT_DIR}/.env"
        warn "Configure o arquivo ${PROJECT_DIR}/.env antes de continuar!"
        warn "Campos obrigatórios: POSTGRES_PASSWORD, DOMAIN, LETSENCRYPT_EMAIL"
    fi
fi

section "8. Rclone — Configuração Backblaze B2"
if [[ ! -f "/root/.config/rclone/rclone.conf" ]]; then
    warn "Configure o rclone para Backblaze B2:"
    echo "  rclone config"
    echo "  → Escolha: n (new remote)"
    echo "  → Nome: backblaze"
    echo "  → Tipo: b2"
    echo "  → Insira Account ID e Application Key do Backblaze"
fi

section "9. Cron de backup automático"
BACKUP_SCRIPT="${PROJECT_DIR}/scripts/backup.sh"
if [[ -f "$BACKUP_SCRIPT" ]]; then
    chmod +x "$BACKUP_SCRIPT"
    # Backup diário às 2h da manhã (horário de Brasília = UTC-3)
    (crontab -l 2>/dev/null; echo "0 5 * * * $BACKUP_SCRIPT >> /var/log/webgis-backup.log 2>&1") | crontab -
    log "Cron de backup configurado (diário às 2h Brasília)"
fi

section "10. Systemd service para auto-start"
cat > /etc/systemd/system/webgis.service << EOF
[Unit]
Description=WebGIS Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable webgis
log "Serviço systemd criado e habilitado"

section "✅ Setup concluído!"
echo ""
echo -e "${GREEN}Próximos passos:${NC}"
echo "  1. Edite ${PROJECT_DIR}/.env com suas configurações"
echo "  2. Configure o rclone: rclone config"
echo "  3. Inicie o stack: cd ${PROJECT_DIR} && docker compose up -d"
echo "  4. Aponte seu domínio para o IP deste servidor"
echo "  5. Configure o Cloudflare na frente (CDN gratuito)"
echo ""
echo -e "${YELLOW}IP deste servidor:${NC} $(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo ""
