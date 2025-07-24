#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\n\033[1;31m💥 Script failed at line $LINENO\033[0m\n"' ERR

# رنگ‌ها
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${BLUE}INFO:${NC} $1"; }
success() { echo -e "${GREEN}✔ $1${NC}"; }

# دریافت ورودی‌ها
prompt_inputs() {
  read -p "🔐 Code-Server password: " CODE_PASS
  read -p "🗃️ PostgreSQL username: " PG_USER
  read -p "🔐 PostgreSQL password: " PG_PASS
  read -p "📛 PostgreSQL database name: " PG_DB
  read -p "📧 pgAdmin email: " PGADMIN_EMAIL
  read -p "🔐 pgAdmin password: " PGADMIN_PASS
}

# نصب پکیج‌های پایه
install_base() {
  log "Installing base packages..."
  apt-get update -qq
  apt-get install -y curl gnupg unzip git nano zip ufw software-properties-common lsb-release \
    docker.io docker-compose python3-pip -qq > /dev/null
  systemctl enable --now docker
  success "Base packages installed"
}

# نصب پایتون 3.11
install_python_311() {
  log "Installing Python 3.11..."
  add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
  apt-get update -qq
  apt-get install -y python3.11 python3.11-venv python3.11-dev python3.11-distutils -qq > /dev/null
  [[ -x /usr/bin/python3.11 ]] && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
  [[ -x /usr/bin/pip3.11 ]] && update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.11 1
  success "Python 3.11 installed and set as default"
}

# نصب و اجرای code-server بدون systemd
install_code_server() {
  log "Installing code-server..."
  curl -fsSL https://code-server.dev/install.sh | sh
  mkdir -p ~/.config/code-server
  cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8443
auth: password
password: ${CODE_PASS}
cert: false
EOF
  nohup code-server &> /var/log/code-server.log &
  sleep 3
  pgrep -f code-server && success "code-server running on port 8443" || { echo -e "${RED}❌ code-server failed to start${NC}"; exit 1; }
}

# ایجاد شبکه داکر
create_docker_network() {
  docker network inspect kitzone-net &>/dev/null || docker network create kitzone-net
  success "Docker network created: kitzone-net"
}

# اجرای سرویس‌های داکر
run_container() {
  local name="$1"
  local cmd="$2"
  log "Starting $name..."
  eval "$cmd"
  sleep 3
  docker ps | grep -q "$name" && success "$name is running" || { echo -e "${RED}❌ $name failed to start${NC}"; exit 1; }
}

deploy_services() {
  run_container postgres "
    docker run -d --name=postgres --network=kitzone-net \
    -e POSTGRES_USER=\"$PG_USER\" \
    -e POSTGRES_PASSWORD=\"$PG_PASS\" \
    -e POSTGRES_DB=\"$PG_DB\" \
    -v /opt/postgres/data:/var/lib/postgresql/data \
    -p 5432:5432 postgres:15-alpine -c 'listen_addresses=*'
  "

  run_container metabase "
    docker run -d --name=metabase --network=kitzone-net \
    -p 3000:3000 \
    -e MB_DB_TYPE=postgres \
    -e MB_DB_DBNAME=\"$PG_DB\" \
    -e MB_DB_PORT=5432 \
    -e MB_DB_USER=\"$PG_USER\" \
    -e MB_DB_PASS=\"$PG_PASS\" \
    -e MB_DB_HOST=postgres \
    metabase/metabase
  "

  run_container pgadmin "
    docker run -d --name=pgadmin --network=kitzone-net \
    -p 5050:80 \
    -e PGADMIN_DEFAULT_EMAIL=\"$PGADMIN_EMAIL\" \
    -e PGADMIN_DEFAULT_PASSWORD=\"$PGADMIN_PASS\" \
    dpage/pgadmin4
  "

  run_container npm "
    docker volume create npm-data >/dev/null
    mkdir -p /opt/npm/letsencrypt
    docker run -d --name=npm --network=kitzone-net --restart=unless-stopped \
    -p 80:80 -p 81:81 -p 443:443 \
    -v npm-data:/data \
    -v /opt/npm/letsencrypt:/etc/letsencrypt \
    jc21/nginx-proxy-manager:latest
  "

  run_container portainer "
    docker volume create portainer_data >/dev/null
    docker run -d --name=portainer --restart=unless-stopped \
    -p 9443:9443 -p 9000:9000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce
  "
}

# ذخیره credentialها
save_credentials() {
  local IP=$(curl -s http://ipv4.icanhazip.com || hostname -I | awk '{print $1}')
  cat > /root/kitzone-credentials.txt <<EOF
📋 KitZone Access Credentials

🔧 Code-Server
http://$IP:8443
Password: $CODE_PASS

🗃️ PostgreSQL
Host: 127.0.0.1
User: $PG_USER
Pass: $PG_PASS
DB:   $PG_DB

📊 Metabase → http://$IP:3000
🛠️ pgAdmin → http://$IP:5050
Login: $PGADMIN_EMAIL / $PGADMIN_PASS

🧭 Portainer → http://$IP:9000 or https://$IP:9443
🌐 NPM → http://$IP:81
Login: admin@example.com / changeme

Saved: $(date)
EOF
  success "Credentials saved to /root/kitzone-credentials.txt"
}


main() {
  prompt_inputs
  install_base
  install_python_311
  install_code_server
  create_docker_network
  deploy_services
  save_credentials
  echo -e "\n${GREEN}✅ Setup complete. All services running.${NC}"
}

main
