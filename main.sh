#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\n\033[1;31m💥 Script failed at line $LINENO\033[0m\n"' ERR

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${BLUE}INFO:${NC} $1"; }
success() { echo -e "${GREEN}✔ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✖ $1${NC}"; }

print_banner() {
cat << "EOF"

 ╔════════════════════════════════════════════════════╗
 ║         🚀 KITZONE SERVER SETUP v4.2 🚀           ║
 ╠════════════════════════════════════════════════════╣
 ║ PostgreSQL • Metabase • pgAdmin • Code-Server     ║
 ║ Nginx Proxy Manager • Netdata • 🔒                 ║
 ╚════════════════════════════════════════════════════╝

EOF
}

prompt_inputs() {
  read -p "🔐 Code-Server password: " CODE_PASS
  read -p "🗃️ PostgreSQL username (e.g. kitzone): " PG_USER
  read -p "🔐 PostgreSQL password: " PG_PASS
  read -p "📛 PostgreSQL database name: " PG_DB
  read -p "📧 pgAdmin email: " PGADMIN_EMAIL
  read -p "🔐 pgAdmin password: " PGADMIN_PASS
}

fix_hostname() {
  local h=$(hostname)
  grep -q "$h" /etc/hosts || echo "127.0.0.1 $h" >> /etc/hosts
}

install_requirements() {
  log "Installing base packages..."
  apt-get update -qq
  apt-get install -y curl gnupg lsb-release unzip git nano zip ufw docker.io docker-compose -qq > /dev/null
  systemctl enable --now docker
  success "Base packages installed"
}

create_docker_network() {
  docker network inspect kitzone-net &>/dev/null || docker network create kitzone-net
  success "Docker network created"
}

deploy_postgres() {
  log "Deploying PostgreSQL..."
  mkdir -p /opt/postgres/data
  docker run -d --name=postgres --network=kitzone-net \
    -e POSTGRES_USER="$PG_USER" \
    -e POSTGRES_PASSWORD="$PG_PASS" \
    -e POSTGRES_DB="$PG_DB" \
    -v /opt/postgres/data:/var/lib/postgresql/data \
    -p 5432:5432 \
    postgres:15-alpine \
    -c 'listen_addresses=*'
  success "PostgreSQL ready"
}

deploy_metabase() {
  log "Deploying Metabase..."
  docker run -d --name=metabase --network=kitzone-net \
    -p 3000:3000 \
    -e MB_DB_TYPE=postgres \
    -e MB_DB_DBNAME="$PG_DB" \
    -e MB_DB_PORT=5432 \
    -e MB_DB_USER="$PG_USER" \
    -e MB_DB_PASS="$PG_PASS" \
    -e MB_DB_HOST=postgres \
    metabase/metabase
  success "Metabase ready"
}

deploy_pgadmin() {
  log "Deploying pgAdmin..."
  docker run -d --name=pgadmin --network=kitzone-net \
    -p 5050:80 \
    -e PGADMIN_DEFAULT_EMAIL="$PGADMIN_EMAIL" \
    -e PGADMIN_DEFAULT_PASSWORD="$PGADMIN_PASS" \
    dpage/pgadmin4
  success "pgAdmin ready"
}

deploy_code_server() {
  log "Deploying Code-Server with full / access..."
  docker run -d --name=code-server --network=kitzone-net \
    -p 8443:8443 \
    -e PASSWORD="$CODE_PASS" \
    -u root \
    -v /:/home/coder/project \
    linuxserver/code-server
  success "Code-Server ready"
}

deploy_netdata() {
  log "Deploying Netdata..."
  docker run -d --name=netdata \
    --network=host \
    --cap-add SYS_PTRACE \
    --security-opt apparmor=unconfined \
    -v /proc:/host/proc:ro \
    -v /sys:/host/sys:ro \
    -v /etc/os-release:/host/etc/os-release:ro \
    netdata/netdata
  success "Netdata running"
}

deploy_npm() {
  log "Deploying Nginx Proxy Manager..."
  mkdir -p /opt/npm/letsencrypt
  docker volume create npm-data >/dev/null || true
  docker run -d --name=npm --network=kitzone-net --restart=unless-stopped \
    -p 80:80 -p 81:81 -p 443:443 \
    -v npm-data:/data \
    -v /opt/npm/letsencrypt:/etc/letsencrypt \
    jc21/nginx-proxy-manager:latest
  success "Nginx Proxy Manager ready"
}

save_credentials() {
  cat <<EOF > /root/kitzone-credentials.txt
📋 KitZone Access Credentials
------------------------------
🌐 Host: $(curl -s ifconfig.me)

🔧 Code-Server
URL: http://<IP>:8443
Password: $CODE_PASS

🗃️ PostgreSQL
Host: 127.0.0.1
Port: 5432
Username: $PG_USER
Password: $PG_PASS
Database: $PG_DB

📊 Metabase
URL: http://<IP>:3000

🛠️ pgAdmin
URL: http://<IP>:5050
Email: $PGADMIN_EMAIL
Password: $PGADMIN_PASS

🌐 Nginx Proxy Manager
URL: http://<IP>:81
Email: admin@example.com
Password: changeme

Saved: $(date)
EOF
  success "Credentials saved to /root/kitzone-credentials.txt"
}

main() {
  print_banner
  prompt_inputs
  fix_hostname
  install_requirements
  create_docker_network
  deploy_postgres
  deploy_metabase
  deploy_pgadmin
  deploy_code_server
  deploy_netdata
  deploy_npm
  save_credentials
  echo -e "\n🎉 ${GREEN}All services deployed successfully!${NC}"
  echo -e "🔐 See your credentials in: ${YELLOW}/root/kitzone-credentials.txt${NC}"
}

main
