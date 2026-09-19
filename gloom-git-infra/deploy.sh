#!/usr/bin/env bash
set -euo pipefail

# Gloom Git Infrastructure Deploy Script
# Single-command deployment for Gitea + Nginx stack

set -o errexit
set -o nounset
set -o pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="gloom-git"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly UID_GID="1000:1000"
readonly DATA_DIRS=("data" "config" "logs" "tmp" "certs" "logs/nginx")

# Colors for output
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        error "Docker is not installed"
        exit 1
    fi

    if ! command -v docker compose &> /dev/null; then
        error "Docker Compose plugin not available"
        exit 1
    fi

    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        error "docker-compose.yml not found at ${COMPOSE_FILE}"
        exit 1
    fi

    success "Prerequisites OK"
}

# Create directory structure
create_directories() {
    info "Creating directory structure..."

    for dir in "${DATA_DIRS[@]}"; do
        mkdir -p "${SCRIPT_DIR}/${dir}"
    done

    # Ensure certs directory exists for Let's Encrypt
    mkdir -p "${SCRIPT_DIR}/certs/live/git.gloom-dev.local"
    mkdir -p "/var/www/certbot"

    success "Directories created"
}

# Fix permissions for rootless containers
fix_permissions() {
    info "Setting permissions for rootless containers (UID/GID 1000)..."

    local dirs=("data" "config" "logs" "tmp" "logs/nginx")

    for dir in "${dirs[@]}"; do
        if [[ -d "${SCRIPT_DIR}/${dir}" ]]; then
            chown -R 1000:1000 "${SCRIPT_DIR}/${dir}" 2>/dev/null || true
        fi
    done

    # Ensure certs directory is readable
    chmod -R 755 "${SCRIPT_DIR}/certs" 2>/dev/null || true
    chmod 755 "/var/www/certbot" 2>/dev/null || true

    success "Permissions set"
}

# Validate docker-compose.yml syntax
validate_compose() {
    info "Validating docker-compose.yml..."

    if ! docker compose -f "${COMPOSE_FILE}" config > /dev/null 2>&1; then
        error "docker-compose.yml validation failed"
        docker compose -f "${COMPOSE_FILE}" config
        exit 1
    fi

    success "docker-compose.yml is valid"
}

# Pull latest images
pull_images() {
    info "Pulling latest images..."
    docker compose -f "${COMPOSE_FILE}" pull --quiet
    success "Images pulled"
}

# Start services
start_services() {
    info "Starting services..."

    docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

    # Wait for health checks
    info "Waiting for services to be healthy..."
    local max_attempts=30
    local attempt=0

    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if docker compose -f "${COMPOSE_FILE}" ps --format json | grep -q '"Health": "healthy"'; then
            success "Services are healthy"
            return 0
        fi

        sleep 2
        ((attempt++))
    done

    warn "Health checks timed out, checking container status..."
    docker compose -f "${COMPOSE_FILE}" ps
    return 1
}

# Show status
show_status() {
    info "Service Status:"
    docker compose -f "${COMPOSE_FILE}" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

    echo ""
    info "Access URLs:"
    echo "  - Gitea Web:     https://git.gloom-dev.local"
    echo "  - Gitea SSH:     ssh://git@git.gloom-dev.local:2222"
    echo "  - Nginx HTTP:    http://git.gloom-dev.local (redirects to HTTPS)"
    echo "  - Nginx HTTPS:   https://git.gloom-dev.local"
}

# Cleanup function for traps
cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        error "Deployment failed with exit code ${exit_code}"
        docker compose -f "${COMPOSE_FILE}" logs --tail=50
    fi
}

# Main deployment function
main() {
    trap cleanup EXIT

    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           GLOOM GIT INFRASTRUCTURE DEPLOYMENT                 ║"
    echo "║              Gitea + Nginx + SQLite3 (Rootless)              ║"
    echo "╚═════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_prerequisites
    create_directories
    fix_permissions
    validate_compose
    pull_images
    start_services
    show_status

    success "Deployment completed successfully!"
}

# Execute main
main "$@"