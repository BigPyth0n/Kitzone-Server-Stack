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
  ║         🚀 KITZONE SERVER SETUP v2.0 🚀           ║
  ╠════════════════════════════════════════════════════╣
  ║  PostgreSQL • Metabase • Grafana • pgAdmin • NPM   ║
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
    log_info "Installing prerequisites and essential tools..."
    apt-get update -y
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        unzip \
        git \
        python3-pip \
        nano \
        tmux \
        tree \
        htop \
        ncdu \
        jq \
        lsof \
        neofetch \
        zip \
        unzip \
        rsync \
        net-tools \
        software-properties-common \
        bash-completion
    log_success "All essential packages installed."
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_success "Docker is already installed."
        return
    fi
    log_info "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker && systemctl start docker
    log_success "Docker installed and running."
}

cleanup_docker() {
    log_warning "Performing full Docker cleanup..."
    docker stop $(docker ps -q) 2>/dev/null || true
    docker rm -f $(docker ps -aq) 2>/dev/null || true
    docker rmi -f $(docker images -q) 2>/dev/null || true
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    docker network prune -f >/dev/null || true
    log_success "Docker cleanup complete."
}

create_docker_network() {
    log_info "Creating Docker network 'kitzone-net'..."
    docker network create kitzone-net >/dev/null || true
    log_success "Docker network 'kitzone-net' created or already exists."
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
    log_info "Deploying Code-Server with ROOT access..."
    get_code_server_password
    mkdir -p ~/projects
    docker run -d --name=code-server --network=kitzone-net --restart=unless-stopped \
      -p 8443:8443 \
      -e PASSWORD="$CODE_SERVER_PASSWORD" \
      -e TZ=Asia/Tehran \
      -u root \
      -v /:/host_root \
      -v ~/projects:/home/coder/projects \
      linuxserver/code-server:latest
    log_success "Code-Server deployed with root privileges."
}

get_postgres_credentials() {
    if [ -z "$POSTGRES_PASSWORD" ]; then
        echo -e "${YELLOW}Set a password for PostgreSQL admin user:${NC}"
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
    log_info "Deploying PostgreSQL database..."
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
    log_success "PostgreSQL deployed with external access enabled."
    echo "POSTGRES_HOST=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print $i; exit}}')" > /root/postgres-credentials.txt
    echo "POSTGRES_PORT=5432" >> /root/postgres-credentials.txt
    echo "POSTGRES_DB=$POSTGRES_DB" >> /root/postgres-credentials.txt
    echo "POSTGRES_USER=$POSTGRES_USER" >> /root/postgres-credentials.txt
    echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" >> /root/postgres-credentials.txt
    chmod 600 /root/postgres-credentials.txt
}

install_metabase() {
    log_info "Deploying Metabase (Business Intelligence)..."
    mkdir -p /opt/metabase/data
    chmod 700 /opt/metabase/data
    METABASE_PASSWORD=$(date +%s | sha256sum | base64 | head -c 16)
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
    log_success "Metabase deployed and connected to PostgreSQL."
}

install_grafana() {
    log_info "Deploying Grafana (Monitoring & Analytics)..."
    GRAFANA_PASSWORD=$(date +%s | sha256sum | base64 | head -c 16)
    docker run -d --name=grafana --network=kitzone-net --restart=unless-stopped \
      -p 3001:3000 \
      -e GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_PASSWORD \
      -v /opt/grafana/data:/var/lib/grafana \
      grafana/grafana:latest
    log_success "Grafana deployed with auto-generated password."
}

install_pgadmin() {
    log_info "Deploying pgAdmin (PostgreSQL Administration)..."
    PGADMIN_PASSWORD=$(date +%s | sha256sum | base64 | head -c 16)
    docker run -d --name=pgadmin --network=kitzone-net --restart=unless-stopped \
      -p 5050:80 \
      -e PGADMIN_DEFAULT_EMAIL=admin@kitzone.online \
      -e PGADMIN_DEFAULT_PASSWORD=$PGADMIN_PASSWORD \
      -v /opt/pgadmin/data:/var/lib/pgadmin \
      dpage/pgadmin4:latest
    log_success "pgAdmin deployed with auto-generated credentials."
}

install_npm() {
    log_info "Deploying Nginx Proxy Manager..."
    mkdir -p /opt/npm/letsencrypt
    docker volume create npm-data >/dev/null || true
    docker run -d --name=npm --network=kitzone-net --restart=unless-stopped \
      -p 80:80 -p 81:81 -p 443:443 \
      -v npm-data:/data \
      -v /opt/npm/letsencrypt:/etc/letsencrypt \
      jc21/nginx-proxy-manager:latest
    log_success "Nginx Proxy Manager deployed."
}

install_portainer() {
    log_info "Deploying Portainer..."
    docker volume create portainer_data >/dev/null || true
    docker run -d --name=portainer --network=kitzone-net --restart=unless-stopped \
      -p 9000:9000 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest
    log_success "Portainer deployed."
}

configure_firewall() {
    log_info "Configuring firewall for external access..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 5432/tcp
    ufw allow 8443/tcp
    ufw allow 3000/tcp
    ufw allow 3001/tcp
    ufw allow 5050/tcp
    ufw allow 9000/tcp
    ufw allow 81/tcp
    ufw --force enable
    ufw reload
    log_success "Firewall configured with required ports open."
}

final_summary() {
    IP=$(hostname -I | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print $i; exit}}')
    OUTPUT="/root/kitzone-info.txt"

    {
    echo "==================== KITZONE SERVER SUMMARY ===================="
    echo ""
    echo "PostgreSQL Database:"
    echo "  Host: $IP"
    echo "  Port: 5432"
    echo "  Database: $POSTGRES_DB"
    echo "  User: $POSTGRES_USER"
    echo "  Password: $POSTGRES_PASSWORD"
    echo ""
    echo "Metabase:     http://$IP:3000"
    echo "Grafana:      http://$IP:3001  | admin / $GRAFANA_PASSWORD"
    echo "pgAdmin:      http://$IP:5050  | admin@kitzone.online / $PGADMIN_PASSWORD"
    echo "Code-Server:  https://$IP:8443 | root / $CODE_SERVER_PASSWORD"
    echo "Portainer:    http://$IP:9000"
    echo "Nginx Proxy Manager: http://$IP:81 | admin@example.com / changeme"
    echo ""
    echo "==============================================================="
    } > "$OUTPUT"

    log_success "Deployment summary saved to: $OUTPUT"
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
    install_grafana
    install_pgadmin
    install_npm
    install_portainer
    configure_firewall
    docker restart portainer
    final_summary
}

main
