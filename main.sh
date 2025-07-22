#!/usr/bin/env bash
set -e
set -o pipefail
trap 'echo -e "\n\033[1;31m💥 Script failed at line $LINENO\033[0m\n"' ERR

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}INFO: $1${NC}"; }
log_success() { echo -e "${GREEN}SUCCESS: $1${NC}"; }
log_warning() { echo -e "${YELLOW}WARNING: $1${NC}"; }
log_error() { echo -e "${RED}ERROR: $1${NC}"; }

print_banner() {
cat << "EOF"

  ╔════════════════════════════════════════════════════╗
  ║         🚀 KITZONE SERVER SETUP v3.0 🚀           ║
  ╠════════════════════════════════════════════════════╣
  ║     PostgreSQL • Metabase • pgAdmin • Netdata     ║
  ╚════════════════════════════════════════════════════╝

EOF
}

fix_hostname_resolution() {
    local HOSTNAME=$(hostname)
    if ! grep -q "$HOSTNAME" /etc/hosts; then
        echo "127.0.0.1 $HOSTNAME" >> /etc/hosts
    fi
}

install_prerequisites() {
    log_info "Installing prerequisites..."
    apt-get update -y
    apt-get install -y \
        curl gnupg lsb-release unzip git nano htop ncdu jq lsof neofetch zip rsync \
        net-tools software-properties-common bash-completion
    log_success "Base packages installed."
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_success "Docker already installed."
        return
    fi
    log_info "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker && systemctl start docker
    log_success "Docker installed."
}

cleanup_docker() {
    log_warning "Cleaning up Docker..."
    docker stop $(docker ps -q) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker rmi -f $(docker images -q) 2>/dev/null || true
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    docker network prune -f >/dev/null || true
    log_success "Docker cleanup done."
}

create_docker_network() {
    docker network create kitzone-net >/dev/null || true
    log_success "Docker network 'kitzone-net' created."
}

get_code_server_password() {
    if [ -z "$CODE_SERVER_PASSWORD" ]; then
        echo -e "${YELLOW}Set a password for Code-Server:${NC}"
        read -sp "Password: " CODE_SERVER_PASSWORD
        echo
        if [ -z "$CODE_SERVER_PASSWORD" ]; then
            log_error "Password cannot be empty!"
            exit 1
        fi
    fi
}

install_code_server() {
    log_info "Deploying Code-Server..."
    get_code_server_password
    mkdir -p /root/codezone
    chmod 700 /root/codezone
    docker run -d --name=code-server --network=kitzone-net --restart=unless-stopped \
        -p 8443:8443 \
        -e PASSWORD="$CODE_SERVER_PASSWORD" \
        -e TZ=Asia/Tehran \
        -u root \
        -v /root/codezone:/home/coder/projects \
        linuxserver/code-server:latest
    log_success "Code-Server ready."
}

get_postgres_credentials() {
    if [ -z "$POSTGRES_PASSWORD" ]; then
        echo -e "${YELLOW}Set a password for PostgreSQL:${NC}"
        read -sp "Password: " POSTGRES_PASSWORD
        echo
        if [ -z "$POSTGRES_PASSWORD" ]; then
            log_error "PostgreSQL password cannot be empty!"
            exit 1
        fi
    fi
    RANDOM_SUFFIX=$(date +%s | sha256sum | base64 | head -c 8)
    POSTGRES_DB="kitzonedb_${RANDOM_SUFFIX}"
    POSTGRES_USER="kitzoneuser_${RANDOM_SUFFIX}"
}

install_postgres() {
    log_info "Deploying PostgreSQL..."
    get_postgres_credentials
    mkdir -p /opt/postgres/data
    chmod 700 /opt/postgres/data
    docker run -d --name=postgres --network=kitzone-net --restart=unless-stopped \
        -e POSTGRES_DB=$POSTGRES_DB \
        -e POSTGRES_USER=$POSTGRES_USER \
        -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
        -e TZ=Asia/Tehran \
        -v /opt/postgres/data:/var/lib/postgresql/data \
        -p 5432:5432 \
        postgres:15-alpine \
        -c 'listen_addresses=*'
    {
        echo "POSTGRES_HOST=$(hostname -I | awk '{print $1}')"
        echo "POSTGRES_PORT=5432"
        echo "POSTGRES_DB=$POSTGRES_DB"
        echo "POSTGRES_USER=$POSTGRES_USER"
        echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
    } > /root/postgres-credentials.txt
    chmod 600 /root/postgres-credentials.txt
    log_success "PostgreSQL ready."
}

install_metabase() {
    log_info "Deploying Metabase..."
    mkdir -p /opt/metabase/data
    chmod 700 /opt/metabase/data
    docker run -d --name=metabase --network=kitzone-net --restart=unless-stopped \
        -p 3000:3000 \
        -e MB_DB_TYPE=postgres \
        -e MB_DB_DBNAME=$POSTGRES_DB \
        -e MB_DB_PORT=5432 \
        -e MB_DB_USER=$POSTGRES_USER \
        -e MB_DB_PASS=$POSTGRES_PASSWORD \
        -e MB_DB_HOST=postgres \
        -v /opt/metabase/data:/metabase-data \
        metabase/metabase:latest
    log_success "Metabase ready."
}

install_pgadmin() {
    log_info "Deploying pgAdmin..."
    PGADMIN_PASSWORD=$(date +%s | sha256sum | base64 | head -c 16)
    docker run -d --name=pgadmin --network=kitzone-net --restart=unless-stopped \
        -p 5050:80 \
        -e PGADMIN_DEFAULT_EMAIL=admin@kitzone.online \
        -e PGADMIN_DEFAULT_PASSWORD=$PGADMIN_PASSWORD \
        -v /opt/pgadmin/data:/var/lib/pgadmin \
        dpage/pgadmin4:latest
    log_success "pgAdmin ready."
}

install_netdata() {
    log_info "Deploying Netdata (Monitor)..."
    docker run -d --name=netdata --restart=unless-stopped \
        -p 19999:19999 \
        -v /etc/passwd:/host/etc/passwd:ro \
        -v /etc/group:/host/etc/group:ro \
        -v /proc:/host/proc:ro \
        -v /sys:/host/sys:ro \
        -v /etc/os-release:/host/etc/os-release:ro \
        --cap-add=SYS_PTRACE \
        --security-opt apparmor=unconfined \
        netdata/netdata
    log_success "Netdata running."
}

configure_firewall() {
    log_info "Configuring firewall..."
    ufw allow 80,443,5432,8443,3000,5050,19999/tcp
    ufw --force enable
    ufw reload
    log_success "Firewall rules set."
}

final_summary() {
    IP=$(hostname -I | awk '{print $1}')
    OUTPUT="/root/kitzone-info.txt"
    {
    echo "==================== KITZONE SERVER SUMMARY ===================="
    echo ""
    echo "PostgreSQL:"
    echo "  Host: $IP"
    echo "  DB: $POSTGRES_DB"
    echo "  User: $POSTGRES_USER"
    echo "  Pass: $POSTGRES_PASSWORD"
    echo ""
    echo "Metabase:     http://$IP:3000"
    echo "pgAdmin:      http://$IP:5050"
    echo "Code-Server:  https://$IP:8443"
    echo "Netdata:      http://$IP:19999"
    echo ""
    echo "==============================================================="
    } > "$OUTPUT"
    log_success "Info saved to $OUTPUT"
    cat "$OUTPUT"
}

main() {
    print_banner
    fix_hostname_resolution
    install_prerequisites
    install_docker
    cleanup_docker
    create_docker_network
    install_code_server
    install_postgres
    install_metabase
    install_pgadmin
    install_netdata
    configure_firewall
    final_summary
}

main
