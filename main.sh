#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\n\033[1;31m💥 Script failed at line $LINENO\033[0m\n"' ERR

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${BLUE}INFO:${NC} $1"; }
success() { echo -e "${GREEN}✔ $1${NC}"; }

print_banner() {
cat << "EOF"

 ╔════════════════════════════════════════════════════╗
 ║         🚀 KITZONE SERVER SETUP (FINAL) 🚀        ║
 ╠════════════════════════════════════════════════════╣
 ║ Python 3.11 • PostgreSQL • Metabase • pgAdmin     ║
 ║ Code-Server (Native) • Portainer • NPM            ║
 ╚════════════════════════════════════════════════════╝

EOF
}

prompt_inputs() {
  read -p "🔐 Code-Server password: " CODE_PASS
  read -p "🗃️ PostgreSQL username: " PG_USER
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
  apt-get install -y curl gnupg unzip git nano zip ufw software-properties-common lsb-release \
    docker.io docker-compose -qq > /dev/null
  systemctl enable --now docker
  success "Base packages installed"
}

install_python_311() {
  log "Installing Python 3.11..."
  add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
  apt-get update -qq
  apt-get install -y python3.11 python3.11-venv python3.11-dev python3.11-distutils -qq > /dev/null
  update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
  update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3 1
  success "Python 3.11 installed and set as default"
}

install_code_server_local() {
  log "Installing Code-Server natively..."
  curl -fsSL https://code-server.dev/install.sh | sh
  mkdir -p ~/.config/code-server
  cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8443
auth: password
password: ${CODE_PASS}
cert: false
EOF
  systemctl enable --now code-server@root
  success "Code-Server running on port 8443"
}

create_docker_network() {
  docker network inspect kitzone-net &>/dev/null || docker network create kitzone-net
  success "Docker network 'kitzone-net' is ready"
}

deploy_postgres() {
  log "Starting PostgreSQL..."
  mkdir -p /opt/postgres/data
  docker run -d --name=postgres --network=kitzone-net \
    -e POSTGRES_USER="$PG_USER" \
    -e POSTGRES_PASSWORD="$PG_PASS" \
    -e POSTGRES_DB="$PG_DB" \
    -v /opt/postgres/data:/var/lib/postgresql/data \
    -p 5432:5432 \
    postgres:15-alpine -c 'listen_addresses=*'
  success "PostgreSQL container running"
}

deploy_metabase() {
  log "Starting Metabase..."
  docker run -d --name=metabase --network=kitzone-net \
    -p 3000:3000 \
    -e MB_DB_TYPE=postgres \
    -e MB_DB_DBNAME="$PG_DB" \
    -e MB_DB_PORT=5432 \
    -e MB_DB_USER="$PG_USER" \
    -e MB_DB_PASS="$PG_PASS" \
    -e MB_DB_HOST=postgres \
    metabase/metabase
  success "Metabase container running"
}

deploy_pgadmin() {
  log "Starting pgAdmin..."
  docker run -d --name=pgadmin --network=kitzone-net \
    -p 5050:80 \
    -e PGADMIN_DEFAULT_EMAIL="$PGADMIN_EMAIL" \
    -e PGADMIN_DEFAULT_PASSWORD="$PGADMIN_PASS" \
    dpage/pgadmin4
  success "pgAdmin container running"
}

deploy_npm() {
  log "Starting Nginx Proxy Manager..."
  mkdir -p /opt/npm/letsencrypt
  docker volume create npm-data >/dev/null || true
  docker run -d --name=npm --network=kitzone-net --restart=unless-stopped \
    -p 80:80 -p 81:81 -p 443:443 \
    -v npm-data:/data \
    -v /opt/npm/letsencrypt:/etc/letsencrypt \
    jc21/nginx-proxy-manager:latest
  success "Nginx Proxy Manager container running"
}

deploy_portainer() {
  log "Starting Portainer..."
  docker volume create portainer_data >/dev/null || true
  docker run -d --name=portainer --restart=unless-stopped \
    -p 9443:9443 -p 9000:9000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce
  success "Portainer container running"
}

save_credentials() {
  PUBLIC_IP=$(curl -s http://ipv4.icanhazip.com || echo "SERVER_IP")
  CREDS_FILE="/root/kitzone-credentials.txt"

  cat <<EOF > "$CREDS_FILE"
📋 KitZone Access Credentials
------------------------------
🌐 Public IP: $PUBLIC_IP

🔧 Code-Server
URL: http://$PUBLIC_IP:8443
Password: $CODE_PASS

🗃️ PostgreSQL
Host: 127.0.0.1
Port: 5432
Username: $PG_USER
Password: $PG_PASS
Database: $PG_DB

📊 Metabase
URL: http://$PUBLIC_IP:3000

🛠️ pgAdmin
URL: http://$PUBLIC_IP:5050
Email: $PGADMIN_EMAIL
Password: $PGADMIN_PASS

🧭 Portainer
URL: http://$PUBLIC_IP:9000 or https://$PUBLIC_IP:9443

🌐 Nginx Proxy Manager
URL: http://$PUBLIC_IP:81
Email: admin@example.com
Password: changeme

Saved: $(date)
EOF

  success "Credentials saved to $CREDS_FILE"
}

main() {
  print_banner
  prompt_inputs
  fix_hostname
  install_requirements
  install_python_311
  install_code_server_local
  create_docker_network
  deploy_postgres
  deploy_metabase
  deploy_pgadmin
  deploy_npm
  deploy_portainer
  save_credentials

  echo -e "\n🎉 ${GREEN}All services deployed successfully!${NC}"
  echo -e "🔐 Credentials: ${YELLOW}/root/kitzone-credentials.txt${NC}"
}

main
