#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "\n\033[1;31m💥 Script failed at line $LINENO\033[0m\n"' ERR

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log()       { echo -e "${BLUE}INFO:${NC} $1"; }
success()   { echo -e "${GREEN}✔ $1${NC}"; }
warn()      { echo -e "${YELLOW}⚠ $1${NC}"; }
error()     { echo -e "${RED}✖ $1${NC}"; }

print_banner() {
cat << "EOF"

 ╔════════════════════════════════════════════════════╗
 ║         🚀 KITZONE SERVER SETUP v3.1 🚀           ║
 ╠════════════════════════════════════════════════════╣
 ║   PostgreSQL • Metabase • pgAdmin • Code-Server   ║
 ║              + Netdata Monitoring                 ║
 ╚════════════════════════════════════════════════════╝

EOF
}

fix_hostname() {
    local h=$(hostname)
    grep -q "$h" /etc/hosts || echo "127.0.0.1 $h" >> /etc/hosts
}

install_requirements() {
    log "Installing base packages..."
    apt-get update -qq
    apt-get install -y curl gnupg lsb-release unzip git nano zip ufw > /dev/null
    success "Base packages installed"
}

install_docker() {
    if command -v docker &>/dev/null; then
        success "Docker already installed"
        return
    fi
    log "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null
    systemctl enable --now docker
    success "Docker installed"
}

create_docker_network() {
    docker network inspect kitzone-net &>/dev/null || docker network create kitzone-net
    success "Docker network created"
}

deploy_postgres() {
    log "Deploying PostgreSQL..."
    mkdir -p /opt/postgres/data
    POSTGRES_PASSWORD="postgrespass"
    POSTGRES_USER="kitzone"
    POSTGRES_DB="kitzonedb"
    docker run -d --name=postgres --network=kitzone-net \
      -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
      -e POSTGRES_USER=$POSTGRES_USER \
      -e POSTGRES_DB=$POSTGRES_DB \
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
      -e MB_DB_DBNAME=kitzonedb \
      -e MB_DB_PORT=5432 \
      -e MB_DB_USER=kitzone \
      -e MB_DB_PASS=postgrespass \
      -e MB_DB_HOST=postgres \
      metabase/metabase
    success "Metabase ready"
}

deploy_pgadmin() {
    log "Deploying pgAdmin..."
    docker run -d --name=pgadmin --network=kitzone-net \
      -p 5050:80 \
      -e PGADMIN_DEFAULT_EMAIL=admin@kitzone.local \
      -e PGADMIN_DEFAULT_PASSWORD=admin123 \
      dpage/pgadmin4
    success "pgAdmin ready"
}

deploy_code_server() {
    log "Deploying Code-Server..."
    mkdir -p /root/codezone
    docker run -d --name=code-server --network=kitzone-net \
      -p 8443:8443 \
      -e PASSWORD="kitzonepass" \
      -u root \
      -v /root/codezone:/home/coder/project \
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

configure_firewall() {
    log "Configuring UFW..."
    ufw allow 80,443,5432,8443,3000,5050,19999/tcp > /dev/null
    ufw --force enable
    success "UFW active"
}

show_summary() {
    IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}================ SERVER READY =================${NC}"
    echo -e "${YELLOW}PostgreSQL:${NC}     Host=$IP  User=kitzone  Pass=postgrespass"
    echo -e "${YELLOW}Metabase:${NC}       http://$IP:3000"
    echo -e "${YELLOW}pgAdmin:${NC}        http://$IP:5050"
    echo -e "${YELLOW}Code-Server:${NC}    https://$IP:8443"
    echo -e "${YELLOW}Netdata:${NC}        http://$IP:19999"
    echo -e "${GREEN}==============================================${NC}"
}

main() {
    print_banner
    fix_hostname
    install_requirements
    install_docker
    create_docker_network
    deploy_postgres
    deploy_metabase
    deploy_pgadmin
    deploy_code_server
    deploy_netdata
    configure_firewall
    show_summary
}

main
