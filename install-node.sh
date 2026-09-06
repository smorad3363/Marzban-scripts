#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${MARZBAN_SCRIPTS_REPO:-smorad3363/Marzban-scripts}"
BRANCH="${MARZBAN_SCRIPTS_BRANCH:-master}"
NODE_SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/marzban-node.sh"
INSTALL_ROOT="${MARZBAN_NODE_INSTALL_ROOT:-/opt}"
DATA_ROOT="${MARZBAN_NODE_DATA_ROOT:-/var/lib}"
DEFAULT_PORT_START="${MARZBAN_NODE_PORT_START:-62050}"
NODE_IMAGE="${MARZBAN_NODE_IMAGE:-gozargah/marzban-node:latest}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
reset='\033[0m'

info() { printf '%b%s%b\n' "$blue" "$*" "$reset"; }
ok() { printf '%b%s%b\n' "$green" "$*" "$reset"; }
warn() { printf '%b%s%b\n' "$yellow" "$*" "$reset"; }
die() { printf '%bError: %s%b\n' "$red" "$*" "$reset" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "This installer must be run as root."
command -v curl >/dev/null 2>&1 || die "curl is required. Install curl and run again."

install_docker_if_needed() {
    if command -v docker >/dev/null 2>&1; then
        return
    fi
    info "Docker was not found; installing Docker with the official installer..."
    curl -fsSL https://get.docker.com | sh
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die "Docker Compose is not available."
    fi
}

instance_exists() {
    local name="$1"
    [[ -e "${INSTALL_ROOT}/${name}" || -e "${DATA_ROOT}/${name}" || -e "/usr/local/bin/${name}" ]]
}

next_instance_name() {
    local candidate="marzban-node"
    local n=2
    if ! instance_exists "$candidate"; then
        printf '%s\n' "$candidate"
        return
    fi
    while :; do
        candidate="marzban-node${n}"
        if ! instance_exists "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
        n=$((n + 1))
    done
}

reserved_ports() {
    local file
    shopt -s nullglob
    for file in "${INSTALL_ROOT}"/*/docker-compose.yml; do
        awk '
            /^[[:space:]]*(SERVICE_PORT|XRAY_API_PORT):/ {
                value=$0
                sub(/^[^:]+:[[:space:]]*/, "", value)
                gsub(/["[:space:]]/, "", value)
                if (value ~ /^[0-9]+$/) print value
            }
        ' "$file" 2>/dev/null || true
    done
    shopt -u nullglob
}

listening_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntu 2>/dev/null | awk '{print $5}' | sed -nE 's/.*:([0-9]+)$/\1/p'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | awk 'NR>2 {print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p'
    fi
}

port_in_use() {
    local wanted="$1"
    { listening_ports; reserved_ports; } | grep -qx "$wanted"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

next_free_pair() {
    local first="$DEFAULT_PORT_START"
    if (( first % 2 != 0 )); then
        first=$((first + 1))
    fi
    while (( first < 65535 )); do
        if ! port_in_use "$first" && ! port_in_use "$((first + 1))"; then
            printf '%s %s\n' "$first" "$((first + 1))"
            return
        fi
        first=$((first + 2))
    done
    die "Could not find a free service/API port pair."
}

prompt_instance_name() {
    local suggested
    suggested="$(next_instance_name)"
    while :; do
        read -r -p "Node instance name [${suggested}]: " INSTANCE_NAME
        INSTANCE_NAME="${INSTANCE_NAME:-$suggested}"
        if [[ ! "$INSTANCE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then
            warn "Use only letters, numbers, dot, underscore or dash (max 64 chars)."
            continue
        fi
        if instance_exists "$INSTANCE_NAME"; then
            warn "Instance '${INSTANCE_NAME}' already exists. Choose another name to avoid overwriting it."
            continue
        fi
        break
    done
}

prompt_port() {
    local label="$1"
    local suggested="$2"
    local other="${3:-}"
    local value
    while :; do
        read -r -p "${label} [${suggested}]: " value
        value="${value:-$suggested}"
        if ! valid_port "$value"; then
            warn "Invalid port. Enter a number between 1 and 65535."
            continue
        fi
        if [[ -n "$other" && "$value" == "$other" ]]; then
            warn "Service port and Xray API port must be different."
            continue
        fi
        if port_in_use "$value"; then
            warn "Port ${value} is already listening or reserved by another installed node. Choose another port."
            continue
        fi
        printf '%s\n' "$value"
        return
    done
}

save_certificate() {
    local cert_file="$1"
    : > "$cert_file"
    printf '\nPaste the Client Certificate from the Marzban panel.\n'
    printf 'Press ENTER on an empty line after the certificate.\n\n'
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        printf '%s\n' "$line" >> "$cert_file"
    done
    [[ -s "$cert_file" ]] || die "Client certificate cannot be empty."
    chmod 600 "$cert_file"
}

prompt_protocol() {
    local answer
    read -r -p "Use REST protocol? [Y/n]: " answer
    if [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; then
        SERVICE_PROTOCOL="rest"
    else
        SERVICE_PROTOCOL=""
    fi
}

install_management_command() {
    local target="/usr/local/bin/${INSTANCE_NAME}"
    info "Installing node management command: ${target}"
    curl -fsSL "$NODE_SCRIPT_URL" -o "$target"
    chmod 755 "$target"
}

write_compose() {
    local app_dir="$1"
    local data_dir="$2"
    local compose_file="${app_dir}/docker-compose.yml"

    cat > "$compose_file" <<EOF
services:
  marzban-node:
    container_name: ${INSTANCE_NAME}
    image: ${NODE_IMAGE}
    restart: always
    network_mode: host
    environment:
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/cert.pem"
      SERVICE_PORT: "${SERVICE_PORT}"
      XRAY_API_PORT: "${XRAY_API_PORT}"
EOF

    if [[ -n "$SERVICE_PROTOCOL" ]]; then
        cat >> "$compose_file" <<EOF
      SERVICE_PROTOCOL: "${SERVICE_PROTOCOL}"
EOF
    fi

    cat >> "$compose_file" <<EOF
    volumes:
      - ${data_dir}:/var/lib/marzban
      - ${data_dir}:/var/lib/marzban-node
EOF

    chmod 600 "$compose_file"
}

main() {
    install_docker_if_needed
    detect_compose
    prompt_instance_name

    local pair suggested_service suggested_api
    pair="$(next_free_pair)"
    suggested_service="${pair%% *}"
    suggested_api="${pair##* }"

    printf '\nEach node needs its own host ports. Existing listening ports and ports\n'
    printf 'reserved by other Marzban-node compose files are rejected automatically.\n\n'
    SERVICE_PORT="$(prompt_port 'SERVICE_PORT' "$suggested_service")"
    XRAY_API_PORT="$(prompt_port 'XRAY_API_PORT' "$suggested_api" "$SERVICE_PORT")"

    local app_dir="${INSTALL_ROOT}/${INSTANCE_NAME}"
    local data_dir="${DATA_ROOT}/${INSTANCE_NAME}"
    local cert_file="${data_dir}/cert.pem"
    mkdir -p "$app_dir" "$data_dir"

    save_certificate "$cert_file"
    prompt_protocol
    install_management_command
    write_compose "$app_dir" "$data_dir"

    info "Pulling ${NODE_IMAGE}..."
    "${COMPOSE[@]}" -f "${app_dir}/docker-compose.yml" -p "$INSTANCE_NAME" pull
    info "Starting ${INSTANCE_NAME}..."
    "${COMPOSE[@]}" -f "${app_dir}/docker-compose.yml" -p "$INSTANCE_NAME" up -d --remove-orphans

    printf '\n'
    ok "Marzban node '${INSTANCE_NAME}' installed successfully."
    printf 'Node IP: %s\n' "$(curl -fsS -4 https://ifconfig.io 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
    printf 'SERVICE_PORT: %s\n' "$SERVICE_PORT"
    printf 'XRAY_API_PORT: %s\n' "$XRAY_API_PORT"
    printf 'Management command: %s\n' "$INSTANCE_NAME"
    printf '\nAdd this node to the main panel using the IP and ports above.\n'
    printf 'Logs: %s logs\n' "$INSTANCE_NAME"
    printf 'Status: %s status\n' "$INSTANCE_NAME"
}

main "$@"
