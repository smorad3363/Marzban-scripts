#!/usr/bin/env bash
set -e


while [[ $# -gt 0 ]]; do
    key="$1"
    
    case $key in
        install|update|uninstall|up|down|restart|status|logs|core-update|install-script|uninstall-script|edit)
            COMMAND="$1"
            shift # past argument
        ;;
        --name)
            if [[ "$COMMAND" == "install" || "$COMMAND" == "install-script" ]]; then
                APP_NAME="$2"
                shift # past argument
            else
                echo "Error: --name parameter is only allowed with 'install' or 'install-script' commands."
                exit 1
            fi
            shift # past value
        ;;
        *)
            shift # past unknown argument
        ;;
    esac
done

# Fetch IP address from ipinfo.io API
NODE_IP=$(curl -fsS --connect-timeout 5 --max-time 8 -4 ifconfig.io 2>/dev/null || true)

# If the IPv4 retrieval is empty, attempt to retrieve the IPv6 address
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(curl -fsS --connect-timeout 5 --max-time 8 -6 ifconfig.io 2>/dev/null || true)
fi

if [[ "$COMMAND" == "install" || "$COMMAND" == "install-script" ]] && [ -z "$APP_NAME" ]; then
    APP_NAME="marzban-node"
fi
# Set script name if APP_NAME is not set
if [ -z "$APP_NAME" ]; then
    SCRIPT_NAME=$(basename "$0")
    APP_NAME="${SCRIPT_NAME%.*}"
fi

INSTALL_DIR="/opt"

if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
    APP_DIR="$INSTALL_DIR/$APP_NAME"
elif [ -d "$INSTALL_DIR/Marzban-node" ]; then
    APP_DIR="$INSTALL_DIR/Marzban-node"
else
    APP_DIR="$INSTALL_DIR/$APP_NAME"
fi

DATA_DIR="/var/lib/$APP_NAME"
DATA_MAIN_DIR="/var/lib/$APP_NAME"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
RUNTIME_COMPOSE_FILE="$APP_DIR/docker-compose.runtime.json"
NODE_RUNTIME_STATE=""
NODE_RUNTIME_PREPARED=false
NODE_RUNTIME_COMMITTED=false
NODE_RUNTIME_LOCK_FD=""
NODE_SCRIPT_TEMP=""
LAST_XRAY_CORES=5
CERT_FILE="$DATA_DIR/cert.pem"
FETCH_REPO="smorad3363/Marzban-scripts"
SCRIPT_URL="https://github.com/$FETCH_REPO/raw/master/marzban-node.sh"

colorized_echo() {
    local color=$1
    local text=$2
    local style=${3:-0}  # Default style is normal

    case $color in
        "red")
            printf "\e[${style};91m${text}\e[0m\n"
        ;;
        "green")
            printf "\e[${style};92m${text}\e[0m\n"
        ;;
        "yellow")
            printf "\e[${style};93m${text}\e[0m\n"
        ;;
        "blue")
            printf "\e[${style};94m${text}\e[0m\n"
        ;;
        "magenta")
            printf "\e[${style};95m${text}\e[0m\n"
        ;;
        "cyan")
            printf "\e[${style};96m${text}\e[0m\n"
        ;;
        *)
            echo "${text}"
        ;;
    esac
}

check_running_as_root() {
    if [ "$(id -u)" != "0" ]; then
        colorized_echo red "This command must be run as root."
        exit 1
    fi
}

detect_os() {
    # Detect the operating system
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
        elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME/{print $2}' /etc/os-release | tr -d '"')
        elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
        elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

detect_and_update_package_manager() {
    colorized_echo blue "Updating package manager"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
        $PKG_MANAGER update -qq >/dev/null 2>&1
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        PKG_MANAGER="yum"
        $PKG_MANAGER update -y -q >/dev/null 2>&1
        $PKG_MANAGER install -y -q epel-release >/dev/null 2>&1
    elif [[ "$OS" == "Fedora"* ]]; then
        PKG_MANAGER="dnf"
        $PKG_MANAGER update -q -y >/dev/null 2>&1
    elif [[ "$OS" == "Arch"* ]]; then
        PKG_MANAGER="pacman"
        $PKG_MANAGER -Sy --noconfirm --quiet >/dev/null 2>&1
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER refresh --quiet >/dev/null 2>&1
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}


detect_compose() {
    # Check if docker compose command exists
    if docker compose >/dev/null 2>&1; then
        COMPOSE='docker compose'
        elif docker-compose >/dev/null 2>&1; then
        COMPOSE='docker-compose'
    else
        colorized_echo red "docker compose not found"
        exit 1
    fi
}

install_package () {
    if [ -z "$PKG_MANAGER" ]; then
        detect_and_update_package_manager
    fi

    PACKAGE=$1
    colorized_echo blue "Installing $PACKAGE"
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        $PKG_MANAGER -y -qq install "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]]; then
        $PKG_MANAGER install -y -q "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "Fedora"* ]]; then
        $PKG_MANAGER install -y -q "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "Arch"* ]]; then
        $PKG_MANAGER -S --noconfirm --quiet "$PACKAGE" >/dev/null 2>&1
    elif [[ "$OS" == "openSUSE"* ]]; then
        PKG_MANAGER="zypper"
        $PKG_MANAGER --quiet install -y "$PACKAGE" >/dev/null 2>&1
    else
        colorized_echo red "Unsupported operating system"
        exit 1
    fi
}

install_docker() {
    # Install Docker and Docker Compose using the official installation script
    colorized_echo blue "Installing Docker"
    curl -fsSL https://get.docker.com | sh
    colorized_echo green "Docker installed successfully"
}

install_marzban_node_script() {
    colorized_echo blue "Installing marzban script"
    TARGET_PATH="/usr/local/bin/$APP_NAME"
    stage_marzban_node_script
    publish_marzban_node_script "$TARGET_PATH"
    
    sed -i "s/^APP_NAME=.*/APP_NAME=\"$APP_NAME\"/" $TARGET_PATH
    
    chmod 755 $TARGET_PATH
    colorized_echo green "Marzban-node script installed successfully at $TARGET_PATH"
}

stage_marzban_node_script() {
    if [ -n "$NODE_SCRIPT_TEMP" ]; then
        return
    fi
    NODE_SCRIPT_TEMP=$(mktemp)
    trap cleanup_node_runtime EXIT
    if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 "$SCRIPT_URL" -o "$NODE_SCRIPT_TEMP" || [ ! -s "$NODE_SCRIPT_TEMP" ] || ! grep -q '^install_command() {' "$NODE_SCRIPT_TEMP" || ! bash -n "$NODE_SCRIPT_TEMP"; then
        colorized_echo red "Failed to download a valid node management script."
        return 1
    fi
}

publish_marzban_node_script() {
    local target="$1" candidate
    candidate=$(mktemp "${target}.tmp.XXXXXX")
    if ! install -m 755 "$NODE_SCRIPT_TEMP" "$candidate" || ! mv -f -- "$candidate" "$target"; then
        rm -f -- "$candidate"
        return 1
    fi
    rm -f -- "$NODE_SCRIPT_TEMP"
    NODE_SCRIPT_TEMP=""
}

# Get a list of occupied ports
get_occupied_ports() {
    if command -v ss &>/dev/null; then
        OCCUPIED_PORTS=$(ss -tuln | awk '{print $5}' | grep -Eo '[0-9]+$' | sort | uniq)
    elif command -v netstat &>/dev/null; then
        OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort | uniq)
    else
        colorized_echo yellow "Neither ss nor netstat found. Attempting to install net-tools."
        detect_os
        install_package net-tools
        if command -v netstat &>/dev/null; then
            OCCUPIED_PORTS=$(netstat -tuln | awk '{print $4}' | grep -Eo '[0-9]+$' | sort | uniq)
        else
            colorized_echo red "Failed to install net-tools. Please install it manually."
            exit 1
        fi
    fi
}

# Function to check if a port is occupied
is_port_occupied() {
    if echo "$OCCUPIED_PORTS" | grep -q -w "$1"; then
        return 0
    else
        return 1
    fi
}

install_marzban_node() {
    # Fetch releases
    mkdir -p "$DATA_DIR"
    mkdir -p "$APP_DIR"
    mkdir -p "$DATA_MAIN_DIR"
    
    # Проверка на существование файла перед его очисткой
    if [ -f "$CERT_FILE" ]; then
        >"$CERT_FILE"
    fi
    
    # Function to print information to the user
    print_info() {
        echo -e "\033[1;34m$1\033[0m"
    }
    
    # Prompt the user to input the certificate
    echo -e "Please paste the content of the Client Certificate, press ENTER on a new line when finished: "
    
    while IFS= read -r line; do
        if [[ -z $line ]]; then
            break
        fi
        echo "$line" >>"$CERT_FILE"
    done
    
    print_info "Certificate saved to $CERT_FILE"
    
    # Prompt the user to choose REST or another protocol
    read -p "Do you want to use REST protocol? (Y/n): " -r use_rest
    
    # Default to "Y" if the user just presses ENTER
    if [[ -z "$use_rest" || "$use_rest" =~ ^[Yy]$ ]]; then
        USE_REST=true
    else
        USE_REST=false
    fi
    
    get_occupied_ports
    
    # Prompt the user to enter ports with occupation check
    while true; do
        read -p "Enter the SERVICE_PORT (default 62050): " -r SERVICE_PORT
        if [[ -z "$SERVICE_PORT" ]]; then
            SERVICE_PORT=62050
        fi
        if [[ "$SERVICE_PORT" -ge 1 && "$SERVICE_PORT" -le 65535 ]]; then
            if is_port_occupied "$SERVICE_PORT"; then
                colorized_echo red "Port $SERVICE_PORT is already in use. Please enter another port."
            else
                break
            fi
        else
            colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
        fi
    done
    
    while true; do
        read -p "Enter the XRAY_API_PORT (default 62051): " -r XRAY_API_PORT
        if [[ -z "$XRAY_API_PORT" ]]; then
            XRAY_API_PORT=62051
        fi
        if [[ "$XRAY_API_PORT" -ge 1 && "$XRAY_API_PORT" -le 65535 ]]; then
            if is_port_occupied "$XRAY_API_PORT"; then
                colorized_echo red "Port $XRAY_API_PORT is already in use. Please enter another port."
            elif [[ "$XRAY_API_PORT" -eq "$SERVICE_PORT" ]]; then
                colorized_echo red "Port $XRAY_API_PORT cannot be the same as SERVICE_PORT. Please enter another port."
            else
                break
            fi
        else
            colorized_echo red "Invalid port. Please enter a port between 1 and 65535."
        fi
    done
    
    colorized_echo blue "Generating compose file"
    
    # Write content to the file
    cat > "$COMPOSE_FILE" <<EOL
services:
  marzban-node:
    container_name: $APP_NAME
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host
    environment:
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/cert.pem"
      SERVICE_PORT: "$SERVICE_PORT"
      XRAY_API_PORT: "$XRAY_API_PORT"
EOL
    
    # Add SERVICE_PROTOCOL line only if REST is selected
    if [[ "$USE_REST" = true ]]; then
        cat >> "$COMPOSE_FILE" <<EOL
      SERVICE_PROTOCOL: "rest"
EOL
    fi
    
    cat >> "$COMPOSE_FILE" <<EOL

    volumes:
      - $DATA_MAIN_DIR:/var/lib/marzban
      - $DATA_DIR:/var/lib/marzban-node
EOL
    colorized_echo green "File saved in $APP_DIR/docker-compose.yml"
}


uninstall_marzban_node_script() {
    if [ -f "/usr/local/bin/$APP_NAME" ]; then
        colorized_echo yellow "Removing marzban-node script"
        rm "/usr/local/bin/$APP_NAME"
    fi
}

uninstall_marzban_node() {
    runtime_manager remove-idle "$APP_NAME"
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Removing directory: $APP_DIR"
        rm -r "$APP_DIR"
    fi
}

uninstall_marzban_node_docker_images() {
    images=$(docker images | grep marzban-node | awk '{print $3}')
    
    if [ -n "$images" ]; then
        colorized_echo yellow "Removing Docker images of Marzban-node"
        for image in $images; do
            if docker rmi "$image" >/dev/null 2>&1; then
                colorized_echo yellow "Image $image removed"
            fi
        done
    fi
}

uninstall_marzban_node_data_files() {
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Removing directory: $DATA_DIR"
        rm -r "$DATA_DIR"
    fi
}

node_compose() {
    local files=(-f "$COMPOSE_FILE")
    if [ -f "$RUNTIME_COMPOSE_FILE" ]; then
        files+=(-f "$RUNTIME_COMPOSE_FILE")
    fi
    $COMPOSE "${files[@]}" "$@"
}

release_runtime_lock() {
    if [ -n "$NODE_RUNTIME_LOCK_FD" ]; then
        flock -u "$NODE_RUNTIME_LOCK_FD"
        exec {NODE_RUNTIME_LOCK_FD}>&-
        NODE_RUNTIME_LOCK_FD=""
    fi
}

cleanup_node_runtime() {
    if [ -n "$NODE_RUNTIME_STATE" ] && [ "$NODE_RUNTIME_COMMITTED" != true ]; then
        if ! runtime_manager rollback "$NODE_RUNTIME_STATE" "$COMPOSE"; then
            colorized_echo red "Automatic runtime recovery failed. Backup: $NODE_RUNTIME_STATE"
        fi
    fi
    release_runtime_lock
    if [ -n "$NODE_SCRIPT_TEMP" ]; then
        rm -f -- "$NODE_SCRIPT_TEMP"
    fi
}

prepare_node_runtime() {
    if [ "$NODE_RUNTIME_PREPARED" = true ]; then
        return
    fi
    detect_os
    if ! command -v python3 >/dev/null 2>&1; then
        install_package python3
    fi
    if ! command -v flock >/dev/null 2>&1; then
        install_package util-linux
    fi
    exec {NODE_RUNTIME_LOCK_FD}>"/run/lock/marzban-node-runtime.lock"
    flock -x "$NODE_RUNTIME_LOCK_FD"
    trap cleanup_node_runtime EXIT
    NODE_RUNTIME_STATE=$(runtime_manager prepare "$COMPOSE_FILE" "$RUNTIME_COMPOSE_FILE" "$DATA_DIR" "$APP_NAME" "$COMPOSE")
    NODE_RUNTIME_PREPARED=true
}

runtime_manager() {
    python3 - "$@" <<'NODE_RUNTIME_PYTHON'
# BEGIN EMBEDDED NODE RUNTIME MANAGER
#!/usr/bin/env python3
"""Embedded installer support; never reads or rewrites node certificates or users."""

import ast
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import urllib.request
import zipfile
import io


ORIGINAL_MODULE_SHA256 = "12757c9b4f97095992f0b2dac5615e56317b047b382d34ef5a6e19484c22c83f"
ORIGINAL_REST_SHA256 = "0bd9a6bab39d52f46e2070f4b1488a0428c43a2ffce5fdc7c7c1e8e031b26a55"
PATCHED_MODULE_SHA256 = "6217af10d9b6b4353bcf53ede335d9cd4b8ebbe48475cabef194b862e2eb75b2"
MEMORY_BUDGET_PERCENT = 75
SS2022_POLICY_CORE_VERSION = (26, 10, 31)
PINNED_CORE_VERSION = "26.3.27"
PINNED_CORE_ASSETS = {
    "x86_64": ("64", "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae", "8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed"),
    "aarch64": ("arm64-v8a", "4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c", "c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04"),
}

# BEGIN EMBEDDED IDLE GUARD
IDLE_GUARD_SOURCE = '#!/usr/bin/env python3\n"""Reap confirmed idle TCP sockets owned by one selected node container.\n\nKernel data-idle timers, two byte-counter snapshots, inode ownership and a final\nrescan are required. No conntrack table is flushed and no process is killed.\n"""\nimport argparse\nimport json\nimport os\nfrom pathlib import Path\nimport re\nimport subprocess\nimport time\n\nSOCKET_STATES = ("fin-wait-2", "close-wait", "established")\n# Inodes and TCP counters come from ss; owners() verifies process ownership.\nSOCKET_DETAILS = ["ss", "-HtnieO"]\n\n\ndef command(args):\n    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=20).stdout\n\n\ndef endpoint(value):\n    host, port = value.rsplit(":", 1)\n    return host.strip("[]"), int(port)\n\n\ndef parse_sockets(output):\n    result = {}\n    for line in output.splitlines():\n        parts = line.split()\n        if len(parts) < 4:\n            continue\n        try:\n            queues = [int(parts[0]), int(parts[1])]\n            local, peer = endpoint(parts[2]), endpoint(parts[3])\n        except ValueError:\n            continue\n        values = {k: int(v) for k, v in re.findall(r"\\b(ino|bytes_sent|bytes_received|lastsnd|lastrcv):(\\d+)", line)}\n        if not values.get("ino") or "lastsnd" not in values or "lastrcv" not in values:\n            continue\n        inode = str(values["ino"])\n        result[inode] = {"local": local, "peer": peer, "bytes": [values.get("bytes_sent", 0), values.get("bytes_received", 0)],\n                         "idle_ms": min(values["lastsnd"], values["lastrcv"]), "queues": queues}\n    return result\n\n\ndef snapshot():\n    result = {}\n    # An application-owned half-close is not covered by the kernel\'s orphaned\n    # FIN-WAIT timeout. Reap confirmed idle half-closes before open sessions.\n    for state in SOCKET_STATES:\n        sockets = parse_sockets(command([*SOCKET_DETAILS, "state", state]))\n        for item in sockets.values():\n            item["state"] = state\n        result.update(sockets)\n    return result\n\n\ndef socket_filter(item):\n    host, port = item["local"]\n    peer, peer_port = item["peer"]\n    # iproute2 treats an unbracketed IPv6 suffix as a port, including\n    # IPv4-mapped addresses returned for dual-stack Xray listeners.\n    host = "[" + host + "]" if ":" in host else host\n    peer = "[" + peer + "]" if ":" in peer else peer\n    return ["src", host, "sport", "=", ":" + str(port), "dst", peer, "dport", "=", ":" + str(peer_port)]\n\n\ndef batch_filter(items):\n    result = []\n    for item in items:\n        if result:\n            result.append("or")\n        result.extend(["("] + socket_filter(item) + [")"])\n    return result\n\n\ndef owners(container):\n    inspected = json.loads(command(["docker", "inspect", container]))[0]\n    if inspected["Config"].get("Labels", {}).get("com.docker.compose.service") != "marzban-node":\n        raise RuntimeError("Selected container is not a Marzban node")\n    env = dict(x.split("=", 1) for x in inspected["Config"].get("Env", []) if "=" in x)\n    protected = {22, 6111, int(env.get("SERVICE_PORT", 62050)), int(env.get("XRAY_API_PORT", 62051))}\n    inodes = set()\n    for line in command(["docker", "top", container, "-eo", "pid,comm"]).splitlines()[1:]:\n        parts = line.split()\n        if len(parts) != 2 or parts[1] != "xray":\n            continue\n        try:\n            for descriptor in Path("/proc", parts[0], "fd").iterdir():\n                try:\n                    link = os.readlink(descriptor)\n                    match = re.fullmatch(r"socket:\\[(\\d+)\\]", link)\n                    if match:\n                        inodes.add(match[1])\n                except OSError:\n                    pass\n        except OSError:\n            pass\n    return inodes, protected\n\n\ndef eligible(current, previous, owned, protected, idle_seconds):\n    selected = {}\n    for inode, item in current.items():\n        before = previous.get(inode)\n        receive, send = item["queues"]\n        # CLOSE-WAIT\'s final FIN can occupy one sequence byte without payload.\n        empty = send == 0 and (receive == 0 or item.get("state") == "close-wait" and receive == 1)\n        if inode not in owned or before is None or not empty:\n            continue\n        if item["local"][1] in protected or item["peer"][1] in protected:\n            continue\n        if item["idle_ms"] < idle_seconds * 1000:\n            continue\n        if any(item[k] != before[k] for k in ("local", "peer", "bytes")):\n            continue\n        selected[inode] = item\n    return selected\n\n\ndef save_state(path, data):\n    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)\n    temporary = path.with_name(path.name + ".tmp")\n    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)\n    with os.fdopen(descriptor, "w") as stream:\n        json.dump(data, stream)\n    os.replace(temporary, path)\n\n\ndef port_summary(current, previous, owned, ports, seconds):\n    result = {port: {"states": {}, "recvq_bytes": 0, "sendq_bytes": 0, "matched": 0,\n                     "matched_tx_bytes": 0, "matched_rx_bytes": 0} for port in ports}\n    for inode in owned & current.keys():\n        item = current[inode]\n        port = item["local"][1]\n        if port not in result:\n            continue\n        row = result[port]\n        state = item["state"]\n        row["states"][state] = row["states"].get(state, 0) + 1\n        row["recvq_bytes"] += item["queues"][0]\n        row["sendq_bytes"] += item["queues"][1]\n        old = previous.get(inode)\n        if old and old["local"] == item["local"] and old["peer"] == item["peer"]:\n            tx, rx = (new - before for new, before in zip(item["bytes"], old["bytes"]))\n            if tx >= 0 and rx >= 0:\n                row["matched"] += 1\n                row["matched_tx_bytes"] += tx\n                row["matched_rx_bytes"] += rx\n    return {"sample_unix": time.time(), "seconds": seconds, "ports": result}\n\n\ndef run(container, state_path, idle_seconds=300, apply=False, limit=2000, summary_path=None):\n    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()\n    previous = {}\n    seconds = None\n    now = time.monotonic()\n    if state_path.exists():\n        state = json.loads(state_path.read_text())\n        # JSON round trips lists; normalise addresses before comparisons.\n        if state.get("boot") == boot and state.get("container") == container and 30 <= now - state.get("time", now) <= 180:\n            previous = state.get("sockets", {})\n            seconds = round(now - state["time"], 2)\n            for value in previous.values():\n                value["local"] = tuple(value["local"])\n                value["peer"] = tuple(value["peer"])\n    current = snapshot()\n    owned, protected = owners(container)\n    selected = eligible(current, previous, owned, protected, idle_seconds)\n    attempted = 0\n    if apply and selected:\n        # Recheck data progress and ownership immediately before socket destroy.\n        fresh = snapshot()\n        fresh_owned, protected = owners(container)\n        selected = eligible(fresh, selected, fresh_owned, protected, idle_seconds)\n        targets = list(selected.items())[:limit]\n        for state in SOCKET_STATES:\n            state_targets = [(inode, item) for inode, item in targets if item["state"] == state]\n            for offset in range(0, len(state_targets), 64):\n                batch = dict(state_targets[offset:offset + 64])\n                filters = batch_filter(batch.values())\n                # Fail closed if iproute2 matches an unexpected socket inode.\n                matches = parse_sockets(command([*SOCKET_DETAILS, "state", state, *filters]))\n                for item in matches.values(): item["state"] = state\n                if set(matches) - set(batch):\n                    raise RuntimeError("Socket batch filter matched an unexpected inode")\n                confirmed = eligible(matches, batch, fresh_owned, protected, idle_seconds)\n                if confirmed:\n                    command(["ss", "-Knt", "state", state] + batch_filter(confirmed.values()))\n                    attempted += len(confirmed)\n        remaining = snapshot()\n        closed = sum(inode not in remaining for inode in list(selected)[:limit])\n        current = remaining\n    else:\n        closed = 0\n    # Store node sockets only. Never retain other services\' endpoint inventory.\n    save_state(state_path, {"boot": boot, "container": container, "time": now, "sockets": {k: v for k, v in current.items() if k in owned}})\n    if summary_path is not None:\n        try:\n            admission = json.loads(Path("/run/marzban-node-admission.json").read_text())\n            ports = set(admission["data_ports"]) - protected\n            save_state(summary_path, port_summary(current, previous, owned, ports, seconds))\n        except (OSError, ValueError, KeyError):\n            pass  # An unavailable metrics sink must not interrupt socket cleanup.\n    return {"container": container, "apply": apply, "idle_seconds": idle_seconds, "owned_tcp": len(set(current) & owned),\n            "confirmed_idle": len(selected), "attempted": attempted, "closed": closed}\n\n\nif __name__ == "__main__":\n    parser = argparse.ArgumentParser(description=__doc__)\n    parser.add_argument("--container", required=True)\n    parser.add_argument("--state", required=True, type=Path)\n    parser.add_argument("--idle-seconds", type=int, default=300)\n    parser.add_argument("--apply", action="store_true")\n    parser.add_argument("--port-summary", type=Path)\n    args = parser.parse_args()\n    if args.idle_seconds < 300:\n        parser.error("Production idle timeout must be at least 300 seconds")\n    print(json.dumps(run(args.container, args.state, args.idle_seconds, args.apply, summary_path=args.port_summary)))\n'
# END EMBEDDED IDLE GUARD

# BEGIN EMBEDDED CONNECTION GUARD
CONNECTION_GUARD_SOURCE = '#!/usr/bin/env python3\n"""Pause new node TCP sessions under local conntrack or memory pressure.\n\nOnly public TCP listeners owned by Xray in Marzban-node containers are gated.\nThis is local admission control, not a limit on a provider\'s upstream table.\n"""\nimport argparse\nimport fcntl\nimport ipaddress\nimport json\nimport os\nfrom pathlib import Path\nimport re\nimport shutil\nimport signal\nimport subprocess\nimport time\n\nPOLICY = Path(\'/etc/marzban-node/connection-budget.json\')\nSTATUS = Path(\'/run/marzban-node-admission.json\')\nCHAIN = \'MZN_ADMIT\'\nMARKER = \'marzban-node-budget-v1\'\nHOOK = [\'-m\', \'comment\', \'--comment\', MARKER, \'-j\', CHAIN]\nMEMORY_HOLD_SECONDS = 8\n\n\ndef run(args, check=True, **kwargs):\n    return subprocess.run(args, text=True, capture_output=True, check=check, timeout=15, **kwargs)\n\n\ndef default_budget():\n    memory = next(int(line.split()[1]) * 1024 for line in Path(\'/proc/meminfo\').read_text().splitlines() if line.startswith(\'MemTotal:\'))\n    return 32768 if memory < 3 * 1024**3 else 65536 if memory < 7 * 1024**3 else 131072\n\n\ndef default_memory_reserve():\n    """Reserve host memory for the kernel, sockets and non-Xray services.\n\n    Defaults scale with MemTotal, capped to avoid withholding disproportionate\n    amounts on large hosts. An explicit null in the policy disables the gate.\n    """\n    total = next(int(line.split()[1]) // 1024 for line in Path(\'/proc/meminfo\').read_text().splitlines() if line.startswith(\'MemTotal:\'))\n    pause = max(128, min(1024, total * 15 // 100))\n    resume = max(pause + 128, min(1536, total * 25 // 100))\n    return pause, resume\n\n\ndef read_policy(path=POLICY):\n    value = json.loads(path.read_text()) if path.exists() else {}\n    if not isinstance(value, dict) or set(value) - {\'tracked_budget\', \'pause_percent\', \'resume_percent\', \'memory\'}:\n        raise ValueError(\'Unknown connection-budget setting\')\n    budget = value[\'tracked_budget\'] if \'tracked_budget\' in value else default_budget()\n    pause, resume = value.get(\'pause_percent\', 75), value.get(\'resume_percent\', 60)\n    if type(budget) is not int or not 1024 <= budget <= 1048576:\n        raise ValueError(\'tracked_budget must be an integer from 1024 to 1048576\')\n    if any(type(x) is not int for x in (pause, resume)) or not 10 <= resume < pause <= 90:\n        raise ValueError(\'Require 10 <= resume_percent < pause_percent <= 90\')\n    memory = value.get(\'memory\')\n    if memory is not None:\n        keys = (\'pause_available_mib\', \'resume_available_mib\')\n        if not isinstance(memory, dict) or set(memory) != set(keys):\n            raise ValueError(\'Memory admission needs pause_available_mib and resume_available_mib\')\n        memory = tuple(memory[key] for key in keys)\n        if any(type(x) is not int for x in memory) or not 128 <= memory[0] < memory[1]:\n            raise ValueError(\'Memory admission requires integer MiB limits with 128 <= pause < resume\')\n    elif \'memory\' not in value:\n        memory = default_memory_reserve()\n    return (budget, pause, resume), memory\n\n\ndef policy(path=POLICY):\n    return read_policy(path)[0]\n\n\ndef memory_available():\n    for line in Path(\'/proc/meminfo\').read_text().splitlines():\n        if line.startswith(\'MemAvailable:\'):\n            return int(line.split()[1]) // 1024\n    return None\n\n\ndef memory_gate(available, limits, paused, pending_since, now):\n    if limits is None or available is None:\n        return False, None\n    pause, resume = limits\n    should_pause = available < resume if paused else available <= pause\n    if should_pause == paused:\n        return paused, None\n    if pending_since is None:\n        return paused, now\n    if now - pending_since >= MEMORY_HOLD_SECONDS:\n        return should_pause, None\n    return paused, pending_since\n\n\ndef pressure(count, maximum, settings, paused=False):\n    budget, high, low = settings\n    budget = min(maximum, budget)\n    if count < 0 or budget < 1:\n        raise ValueError(\'Invalid conntrack counters\')\n    paused = count > budget * low // 100 if paused else count >= budget * high // 100\n    return paused, budget\n\n\ndef listener_ports(output, pids, protected):\n    ports = set()\n    for line in output.splitlines():\n        if not (pids & {int(v) for v in re.findall(r\'pid=(\\d+)\', line)}):\n            continue\n        parts = line.split()\n        if len(parts) < 5:\n            continue\n        try:\n            host, port = parts[3].rsplit(\':\', 1)\n            port = int(port)\n            host = host.strip(\'[]\').split(\'%\', 1)[0]\n            if host != \'*\':\n                address = ipaddress.ip_address(host)\n                if address.is_loopback or getattr(address, \'ipv4_mapped\', None) and address.ipv4_mapped.is_loopback:\n                    continue\n            if 1 <= port <= 65535 and port not in protected:\n                ports.add(port)\n        except ValueError:\n            continue\n    return ports\n\n\ndef discover_ports():\n    names = run([\'docker\', \'ps\', \'--filter\', \'label=com.docker.compose.service=marzban-node\', \'--format\', \'{{.Names}}\']).stdout.splitlines()\n    pids, protected = set(), {22, 6111}\n    for name in names:\n        info = json.loads(run([\'docker\', \'inspect\', name]).stdout)[0]\n        # Bridge-mode container ports do not traverse the host INPUT chain.\n        if info.get(\'HostConfig\', {}).get(\'NetworkMode\') != \'host\':\n            continue\n        env = dict(x.split(\'=\', 1) for x in info[\'Config\'].get(\'Env\', []) if \'=\' in x)\n        protected.update(int(env.get(key, default)) for key, default in [(\'SERVICE_PORT\', \'62050\'), (\'XRAY_API_PORT\', \'62051\')])\n        top = run([\'docker\', \'top\', name, \'-eo\', \'pid,comm\']).stdout\n        for line in top.splitlines()[1:]:\n            parts = line.split()\n            if len(parts) == 2 and parts[1] == \'xray\':\n                pids.add(int(parts[0]))\n    # Protect SSH even when its configured port differs from 22 or 6111.\n    output = run([\'ss\', \'-Hlntp\']).stdout\n    for line in output.splitlines():\n        if \'"sshd"\' in line or \'"sshd-session"\' in line:\n            try: protected.add(int(line.split()[3].rsplit(\':\', 1)[1]))\n            except (IndexError, ValueError): pass\n    return listener_ports(output, pids, protected)\n\n\ndef rules(ports, paused):\n    lines = [\'*filter\', \':\' + CHAIN + \' - [0:0]\', \'-F \' + CHAIN]\n    ports = sorted(set(ports) - {22, 6111})\n    if any(type(p) is not int or not 1 <= p <= 65535 for p in ports):\n        raise ValueError(\'Invalid data port\')\n    if paused:\n        for offset in range(0, len(ports), 15):\n            selected = \',\'.join(map(str, ports[offset:offset + 15]))\n            lines.append(\'-A \' + CHAIN + \' ! -i lo -p tcp --syn -m conntrack --ctstate NEW -m multiport --dports \' + selected + \' -j REJECT --reject-with tcp-reset\')\n    lines += [\'-A \' + CHAIN + \' -m comment --comment \' + MARKER + \' -j RETURN\', \'COMMIT\', \'\']\n    return \'\\n\'.join(lines)\n\n\nclass Firewall:\n    def __init__(self, families=None):\n        if families is None:\n            families = [\'iptables\']\n            if Path(\'/proc/net/if_inet6\').exists() and Path(\'/proc/net/if_inet6\').read_text().strip():\n                families.append(\'ip6tables\')\n        self.families = families\n        self.last = None\n\n    def check_owner(self, binary):\n        result = run([binary, \'-w\', \'5\', \'-S\', CHAIN], check=False)\n        if result.returncode == 0 and MARKER not in result.stdout:\n            raise RuntimeError(\'Refusing to change an unowned firewall chain\')\n        return result.returncode == 0\n\n    def apply(self, ports, paused):\n        key = (tuple(sorted(ports)), paused)\n        if self.last == key:\n            return\n        for binary in self.families:\n            if not shutil.which(binary) or not shutil.which(binary + \'-restore\'):\n                raise RuntimeError(\'Node admission needs \' + binary)\n            self.check_owner(binary)\n            # --noflush leaves every other chain, table and rule unchanged.\n            run([binary + \'-restore\', \'-w\', \'5\', \'--noflush\'], input=rules(ports, paused))\n            if run([binary, \'-w\', \'5\', \'-C\', \'INPUT\'] + HOOK, check=False).returncode:\n                run([binary, \'-w\', \'5\', \'-I\', \'INPUT\', \'1\'] + HOOK)\n        self.last = key\n\n    def clear(self):\n        errors = []\n        for binary in dict.fromkeys(self.families + [\'iptables\', \'ip6tables\']):\n            try:\n                if not shutil.which(binary) or not self.check_owner(binary):\n                    continue\n                while run([binary, \'-w\', \'5\', \'-C\', \'INPUT\'] + HOOK, check=False).returncode == 0:\n                    run([binary, \'-w\', \'5\', \'-D\', \'INPUT\'] + HOOK)\n                run([binary, \'-w\', \'5\', \'-F\', CHAIN])\n                run([binary, \'-w\', \'5\', \'-X\', CHAIN])\n            except Exception as exc:\n                errors.append(str(exc))\n        self.last = None\n        if errors:\n            raise RuntimeError(\'; \'.join(errors))\n\n\ndef counters():\n    root = Path(\'/proc/sys/net/netfilter\')\n    return int((root / \'nf_conntrack_count\').read_text()), int((root / \'nf_conntrack_max\').read_text())\n\n\ndef serve():\n    firewall = Firewall()\n    conn_paused, mem_paused, pending = False, False, None\n    previous_memory, reasons, ports, refresh = None, [], set(), 0\n    def stop(*_): raise KeyboardInterrupt\n    signal.signal(signal.SIGTERM, stop)\n    signal.signal(signal.SIGINT, stop)\n    try:\n        while True:\n            now = time.monotonic()\n            settings, memory = read_policy()\n            count, maximum = counters()\n            conn_paused, budget = pressure(count, maximum, settings, conn_paused)\n            available = memory_available() if memory is not None else None\n            if memory != previous_memory:\n                pending = None\n                previous_memory = memory\n            mem_paused, pending = memory_gate(available, memory, mem_paused, pending, now)\n            next_reasons = [name for name, paused in ((\'conntrack\', conn_paused), (\'memory\', mem_paused)) if paused]\n            if now >= refresh or bool(next_reasons) != bool(reasons):\n                ports = discover_ports()\n                refresh = now + 15\n            firewall.apply(ports, bool(next_reasons))\n            state = {\'pid\': os.getpid(), \'count\': count, \'kernel_max\': maximum, \'budget\': budget, \'paused\': bool(ports and next_reasons),\n                     \'reasons\': next_reasons, \'memory_available_mib\': available,\n                     \'data_ports\': sorted(ports), \'pause_at\': budget * settings[1] // 100,\n                     \'resume_at\': budget * settings[2] // 100, \'sample_unix\': time.time()}\n            if next_reasons != reasons:\n                print(json.dumps(state), flush=True)\n            STATUS.write_text(json.dumps(state) + \'\\n\')\n            STATUS.chmod(0o600)\n            reasons = next_reasons\n            time.sleep(2)\n    except KeyboardInterrupt:\n        pass\n    finally:\n        firewall.clear()\n        STATUS.unlink(missing_ok=True)\n\n\ndef main():\n    parser = argparse.ArgumentParser(description=__doc__)\n    parser.add_argument(\'--clear\', action=\'store_true\')\n    args = parser.parse_args()\n    # A second service/installer must not replace a gate while the daemon runs.\n    with open(\'/run/marzban-node-admission.lock\', \'a\') as lock:\n        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)\n        if args.clear:\n            Firewall().clear()\n            STATUS.unlink(missing_ok=True)\n        else:\n            serve()\n\n\nif __name__ == \'__main__\':\n    main()\n'
# END EMBEDDED CONNECTION GUARD

# BEGIN EMBEDDED HEALTH
HEALTH_SOURCE = '#!/usr/bin/env python3\n"""Record bounded, host-local Marzban node performance history."""\nimport argparse\nimport datetime\nimport errno\nimport fcntl\nimport ipaddress\nimport json\nimport os\nfrom pathlib import Path\nimport re\nimport shutil\nimport socket\nimport subprocess\nimport time\n\n\nLOG_DIR = Path("/var/log/marzban-node-health")\nLOG_NAME = "samples.jsonl"\nFILE_BYTES = 8 * 1024**2\nFILE_COUNT = 8  # Includes the current file.\nFREE_RESERVE = 512 * 1024**2\nPAIRS = Path("/etc/gremgr/pairs")\nGRE_TOOL = "/usr/local/sbin/gremgr-pair"\nNET = Path("/sys/class/net")\nTICKS = os.sysconf("SC_CLK_TCK")\nPROTOCOL_FIELDS = {\n    "Ip": "InDiscards OutDiscards OutNoRoutes ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates",\n    "Icmp": "InDestUnreachs OutDestUnreachs InErrors OutErrors",\n    "Tcp": "ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts",\n    "TcpExt": "ListenOverflows ListenDrops TCPTimeouts TCPBacklogDrop TCPRcvQDrop TCPSynRetrans TCPMTUPFail TCPMTUPSuccess TCPMemoryPressures",\n    "Udp": "InDatagrams OutDatagrams NoPorts InErrors RcvbufErrors SndbufErrors",\n}\nLINK_FIELDS = {0: "rx_bytes", 1: "rx_packets", 2: "rx_errors", 3: "rx_dropped",\n               8: "tx_bytes", 9: "tx_packets", 10: "tx_errors", 11: "tx_dropped"}\n\n\ndef read(path):\n    try:\n        return Path(path).read_text().strip()\n    except OSError:\n        return ""\n\n\ndef number(path):\n    value = read(path)\n    return int(value) if value.isdigit() else None\n\n\ndef output(args):\n    try:\n        result = subprocess.run(args, text=True, capture_output=True, timeout=2)\n        return result.stdout if result.returncode == 0 else ""\n    except (OSError, subprocess.TimeoutExpired):\n        return ""\n\n\ndef json_input(raw, default):\n    try:\n        return json.loads(raw)\n    except ValueError:\n        return default\n\n\ndef paired_counters(raw):\n    result = {}\n    lines = raw.splitlines()\n    for header, values in zip(lines[::2], lines[1::2]):\n        names, counts = header.split(), values.split()\n        group = names[0].rstrip(":")\n        if group in PROTOCOL_FIELDS and counts and names[0] == counts[0]:\n            selected = PROTOCOL_FIELDS[group].split()\n            result[group] = {k: int(v) for k, v in zip(names[1:], counts[1:]) if k in selected}\n    return result\n\n\ndef interfaces():\n    result = {}\n    for line in read("/proc/net/dev").splitlines()[2:]:\n        device, fields = line.split(":", 1)\n        device = device.strip()\n        values = fields.split()\n        stats = {key: int(values[i]) for i, key in LINK_FIELDS.items()}\n        stats["mtu"] = number(NET / device / "mtu")\n        stats["rps_masks"] = [read(p) for p in sorted((NET / device / "queues").glob("rx-*/rps_cpus"))]\n        result[device] = stats\n    for q in json_input(output(["tc", "-j", "-s", "qdisc", "show"]), []):\n        if q.get("dev") in result:\n            fields = ("kind", "handle", "drops", "overlimits", "requeues", "backlog", "qlen")\n            result[q["dev"]].setdefault("qdiscs", []).append({k: q[k] for k in fields if k in q})\n    return result\n\n\ndef managed_path(identity):\n    if not re.fullmatch(r"[0-9a-f]{10}", identity):\n        raise ValueError("Invalid GRE pair ID")\n    cfg = json_input(read(PAIRS / (identity + ".json")), {})\n    device = "gmp-" + identity\n    if cfg.get("id") != identity or cfg.get("tunnel") != device or cfg.get("role") not in ("foreign", "iran"):\n        raise ValueError("Unknown managed GRE pair")\n    peer = str(ipaddress.IPv4Address(cfg["peer_tun"]))\n    routes = json_input(output(["ip", "-j", "-4", "route", "get", peer]), [])\n    route = routes[0] if routes and routes[0].get("dev") == device else {}\n    metrics = route.get("metrics", [])\n    if isinstance(metrics, dict):\n        metrics = [metrics]\n    pmtu = next((int(m["mtu"]) for m in metrics if str(m.get("mtu", "")).isdigit()), None)\n    mtu = number(NET / device / "mtu")\n    return {"role": cfg["role"], "configured_mtu": cfg["mtu"], "link_mtu": mtu,\n            "route_matches": bool(route), "route_mtu": pmtu,\n            "mtu_mismatch": bool(mtu and pmtu and pmtu < mtu)}\n\n\ndef repair_path(identity):\n    path = managed_path(identity)\n    mtu, learned = path["link_mtu"], path["route_mtu"]\n    if path["role"] != "foreign" or not path["route_matches"] or not mtu or path["configured_mtu"] != mtu:\n        raise ValueError("Expected an active, consistent node-side GRE pair")\n    if not learned or learned >= mtu:\n        print("No smaller route MTU observed for " + identity)\n        return\n    if learned < 1280:\n        raise ValueError("Observed MTU below 1280 requires manual investigation")\n    subprocess.run([GRE_TOOL, "set-mtu", identity, str(learned)], check=True, timeout=90)\n    updated = managed_path(identity)\n    if updated["link_mtu"] != learned or updated["configured_mtu"] != learned:\n        raise RuntimeError("GRE MTU change did not take effect")\n    print(f"Set the matching ingress pair {identity} to {learned} using gremgr-pair set-mtu.")\n\n\ndef xray_processes():\n    result = {}\n    for comm in Path("/proc").glob("[0-9]*/comm"):\n        if read(comm).lower() != "xray":\n            continue\n        proc = comm.parent\n        fields = read(proc / "stat").rpartition(") ")[2].split()\n        if len(fields) < 22:\n            continue\n        status = dict(line.split(":", 1) for line in read(proc / "status").splitlines() if ":" in line)\n        entry = {"start_ticks": int(fields[19]), "cpu_ticks": int(fields[11]) + int(fields[12]),\n                 "threads": int(fields[17]), "rss_kib": int(status.get("VmRSS", "0").split()[0])}\n        group = next((s[3:] for s in read(proc / "cgroup").splitlines() if s.startswith("0::/")), "")\n        if group:\n            cgroup = Path("/sys/fs/cgroup") / group.lstrip("/")\n            entry["cgroup_memory_bytes"] = number(cgroup / "memory.current")\n            entry["cgroup_memory_max"] = read(cgroup / "memory.max")\n            for file in ("cpu.stat", "memory.events"):\n                entry[file] = {k: int(v) for k, v in (l.split() for l in read(cgroup / file).splitlines())}\n        result[proc.name] = entry\n    return result\n\n\ndef disk_space(directory):\n    stat = os.statvfs(directory)\n    return {"free_bytes": stat.f_bavail * stat.f_frsize, "total_bytes": stat.f_blocks * stat.f_frsize,\n            "free_inodes": stat.f_favail}\n\n\ndef snapshot(directory):\n    cpu = {p[0]: list(map(int, p[1:9])) for p in (line.split() for line in read("/proc/stat").splitlines())\n           if p and p[0].startswith("cpu")}\n    memory = {k.rstrip(":"): int(v) for k, v, *_ in (l.split() for l in read("/proc/meminfo").splitlines())\n              if k.rstrip(":") in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree", "Slab", "SReclaimable", "Dirty")}\n    disk = {}\n    for path in Path("/sys/block").glob("*/stat"):\n        if path.parent.name.startswith(("loop", "ram")):\n            continue\n        values = read(path).split()\n        if len(values) >= 11:\n            disk[path.parent.name] = {k: int(values[i]) for i, k in ((0, "reads"), (2, "sectors_read"), (4, "writes"),\n                                                                     (6, "sectors_written"), (8, "in_flight"), (9, "io_ms"))}\n    tcp = paired_counters(read("/proc/net/snmp"))\n    tcp.update(paired_counters(read("/proc/net/netstat")))\n    paths = {}\n    for path in PAIRS.glob("*.json"):\n        try:\n            paths[path.stem] = managed_path(path.stem)\n        except (KeyError, ValueError, TypeError):\n            paths[path.stem] = {"error": "invalid GRE profile"}\n    table = Path("/proc/sys/net/netfilter")\n    conntrack = {k: number(table / ("nf_conntrack_" + k)) for k in ("count", "max", "tcp_timeout_established")}\n    if shutil.which("conntrack"):\n        for key, count in re.findall(r"\\b(insert_failed|drop|early_drop|search_restart)=(\\d+)", output(["conntrack", "-S"])):\n            conntrack[key] = conntrack.get(key, 0) + int(count)\n    admission = json_input(read("/run/marzban-node-admission.json"), {})\n    instances = {}\n    for file in Path("/run/marzban-node-health-ports").glob("*.json"):\n        summary = json_input(read(file), {})\n        if 0 <= time.time() - summary.get("sample_unix", 0) <= 180:\n            instances[file.stem] = summary\n    pressure = {k: read("/proc/pressure/" + k).splitlines() for k in ("cpu", "io", "memory")}\n    return {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),\n            "boot_id": read("/proc/sys/kernel/random/boot_id"), "monotonic_s": time.monotonic(),\n            "load": read("/proc/loadavg").split()[:3], "cpu_ticks": cpu, "memory_kib": memory, "pressure": pressure,\n            "disk_space": disk_space(directory), "disk_io": disk, "links": interfaces(), "protocols": tcp,\n            "softnet": [[int(x, 16) for x in l.split()[:3]] for l in read("/proc/net/softnet_stat").splitlines()],\n            "sockets": (read("/proc/net/sockstat") + "\\n" + read("/proc/net/sockstat6")).strip().splitlines(),\n            "conntrack": conntrack, "admission": {k: admission[k] for k in ("paused", "reasons", "memory_available_mib", "budget", "pause_at", "resume_at", "sample_unix") if k in admission},\n            "gre": paths, "xray": xray_processes(), "port_samples": instances}\n\n\ndef interval(previous, current):\n    seconds = current["monotonic_s"] - previous["monotonic_s"]\n    if current["boot_id"] != previous["boot_id"] or seconds <= 0:\n        return {}\n    result = {"seconds": round(seconds, 2), "cpu_pct": {}, "link_mbps": {}, "xray_cpu_pct": {}}\n    for name, values in current["cpu_ticks"].items():\n        if name in previous["cpu_ticks"]:\n            diff = [a - b for a, b in zip(values, previous["cpu_ticks"][name])]\n            total = sum(diff)\n            if total > 0 and min(diff) >= 0:\n                result["cpu_pct"][name] = {"busy": round(100 * (total - diff[3] - diff[4]) / total, 1),\n                                           "softirq": round(100 * diff[6] / total, 1), "steal": round(100 * diff[7] / total, 1)}\n    for name, values in current["links"].items():\n        old = previous["links"].get(name, {})\n        if all(key in old and values[key] >= old[key] for key in ("rx_bytes", "tx_bytes")):\n            result["link_mbps"][name] = {k: round((values[k + "_bytes"] - old[k + "_bytes"]) * 8 / (1e6 * seconds), 3) for k in ("rx", "tx")}\n    for pid, entry in current["xray"].items():\n        old = previous["xray"].get(pid, {})\n        if old.get("start_ticks") == entry["start_ticks"]:\n            result["xray_cpu_pct"][pid] = round(100 * (entry["cpu_ticks"] - old["cpu_ticks"]) / (TICKS * seconds), 1)\n    result["protocol_delta"] = {}\n    for group, keys in {"Ip": ("FragFails", "ReasmFails"), "Tcp": ("OutSegs", "RetransSegs"),\n                        "TcpExt": ("ListenDrops", "TCPTimeouts"), "Udp": ("RcvbufErrors", "SndbufErrors")}.items():\n        old, now = previous["protocols"].get(group, {}), current["protocols"].get(group, {})\n        for key in keys:\n            if key in old and key in now and now[key] >= old[key]:\n                result["protocol_delta"][key] = now[key] - old[key]\n    return result\n\n\ndef append_record(directory, record, limit=FILE_BYTES, files=FILE_COUNT, reserve=FREE_RESERVE):\n    data = (json.dumps(record, separators=(",", ":"), allow_nan=False) + "\\n").encode()\n    if len(data) > limit:\n        raise ValueError("Sample exceeds a complete log segment")\n    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)\n    try:\n        fcntl.flock(fd, fcntl.LOCK_EX)\n        space = disk_space(directory)\n        if space["free_bytes"] < reserve + len(data) or space["free_inodes"] < 2:\n            return False\n        active = directory / LOG_NAME\n        if active.exists() and active.stat().st_size + len(data) > limit:\n            for suffix in range(files - 1, 0, -1):\n                src = active if suffix == 1 else directory / f"{LOG_NAME}.{suffix - 1}"\n                if src.exists():\n                    src.replace(directory / f"{LOG_NAME}.{suffix}")\n        with active.open("ab", buffering=0) as stream:\n            offset = stream.tell()\n            try:\n                if stream.write(data) != len(data):\n                    raise OSError("Incomplete health sample")\n            except OSError:\n                stream.truncate(offset)\n                raise\n        return True\n    finally:\n        os.close(fd)\n\n\ndef notify(message):\n    address = os.environ.get("NOTIFY_SOCKET")\n    if address:\n        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:\n            sock.sendto(message.encode(), "\\0" + address[1:] if address.startswith("@") else address)\n\n\ndef serve():\n    os.umask(0o077)\n    LOG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)\n    previous = None\n    while True:\n        started = time.monotonic()\n        current = snapshot(LOG_DIR)\n        if previous:\n            current["interval"] = interval(previous, current)\n        try:\n            written = append_record(LOG_DIR, current)\n        except OSError as error:\n            if error.errno not in (errno.ENOSPC, errno.EDQUOT):\n                raise\n            written = False\n        status = "Recorded sample" if written else "History paused: insufficient free space"\n        notify(("READY=1\\n" if previous is None else "") + f"STATUS={status} at {current[\'utc\']}")\n        previous = current\n        time.sleep(max(1, 60 - (time.monotonic() - started)))\n\n\ndef main():\n    parser = argparse.ArgumentParser(description=__doc__)\n    mode = parser.add_mutually_exclusive_group(required=True)\n    mode.add_argument("--serve", action="store_true")\n    mode.add_argument("--once", action="store_true")\n    mode.add_argument("--apply-gre-pmtu", metavar="PAIR_ID")\n    args = parser.parse_args()\n    if args.serve:\n        serve()\n    elif args.once:\n        directory = next(p for p in (LOG_DIR, *LOG_DIR.parents) if p.is_dir())\n        print(json.dumps(snapshot(directory)))\n    else:\n        repair_path(args.apply_gre_pmtu)\n\n\nif __name__ == "__main__":\n    main()\n'
# END EMBEDDED HEALTH


def health_paths():
    return {"health_script": Path("/usr/local/lib/marzban-node/health.py"),
            "health_service": Path("/etc/systemd/system/marzban-node-health.service")}


def install_health(state):
    script = Path(state["health_script"])
    unit = Path(state["health_service"])
    service = ("[Unit]\nDescription=Marzban node performance history\nAfter=local-fs.target\n"
               "[Service]\nType=notify\nExecStart=/usr/bin/python3 " + str(script) + " --serve\n"
               "TimeoutStartSec=90\nRestart=on-failure\nRestartSec=30\nNice=10\nUMask=0077\n"
               "LogsDirectory=marzban-node-health\nLogsDirectoryMode=0700\n"
               "NoNewPrivileges=true\nProtectSystem=strict\nProtectHome=true\nPrivateTmp=true\n"
               "[Install]\nWantedBy=multi-user.target\n")
    changed = False
    for path, contents, mode in [(script, HEALTH_SOURCE, 0o755), (unit, service, 0o644)]:
        if not path.exists() or path.read_text() != contents:
            atomic_write(path, contents, mode)
            changed = True
    if changed:
        command(["systemctl", "daemon-reload"])
    command(["systemctl", "enable", unit.name])
    command(["systemctl", "restart" if changed else "start", unit.name])
    command(["systemctl", "is-active", "--quiet", unit.name])


def connection_paths():
    return {'admission_script': Path('/usr/local/lib/marzban-node/connection_guard.py'),
            'admission_service': Path('/etc/systemd/system/marzban-node-admission.service')}


def connection_settings():
    namespace = {'__name__': 'node_admission'}
    exec(compile(CONNECTION_GUARD_SOURCE, 'connection_guard.py', 'exec'), namespace)
    return namespace['policy']()


def install_connection_guard(state):
    unit = Path(state['admission_service']).name
    command(['systemctl', 'stop', unit], check=False)
    script = Path(state['admission_script'])
    script.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(script, CONNECTION_GUARD_SOURCE, 0o700)
    atomic_write(Path(state['admission_service']), '[Unit]\nDescription=Marzban node connection admission\nAfter=docker.service\n[Service]\nType=simple\nExecStart=/usr/bin/python3 ' + str(script) + '\nExecStopPost=/usr/bin/python3 ' + str(script) + ' --clear\nRestart=on-failure\nRestartSec=5\nTimeoutStopSec=15\nUMask=0077\n[Install]\nWantedBy=multi-user.target\n', 0o644)
    command(['systemctl', 'daemon-reload'])
    command(['systemctl', 'enable', '--now', unit])
    for _ in range(10):
        if command(['systemctl', 'is-active', unit], check=False).returncode == 0 and Path('/run/marzban-node-admission.json').exists():
            try:
                status = json.loads(Path('/run/marzban-node-admission.json').read_text())
                pid = int(command(['systemctl', 'show', unit, '--property=MainPID', '--value']).stdout.strip())
                if status['pid'] == pid and time.time() - status['sample_unix'] < 15:
                    return
            except (KeyError, ValueError, OSError):
                pass
        time.sleep(1)
    raise RuntimeError('Node admission guard did not become ready')


def guard_paths(data, name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", name):
        raise RuntimeError("Invalid node name for a system service")
    unit = "marzban-idle-" + name
    return {"guard": Path(data) / "node-runtime-patch/idle_guard.py",
            "guard_service": Path("/etc/systemd/system") / (unit + ".service"),
            "guard_timer": Path("/etc/systemd/system") / (unit + ".timer")}


def install_idle_guard(state):
    if not Path("/run/systemd/system").is_dir() or not shutil.which("ss"):
        raise RuntimeError("Idle guard needs systemd and iproute2; previous node will be restored")
    paths = guard_paths(state["data"], state["name"])
    unit = paths["guard_service"].stem
    atomic_write(paths["guard"], IDLE_GUARD_SOURCE, 0o700)
    summary = Path("/run/marzban-node-health-ports") / (state["name"] + ".json")
    arguments = " ".join('"' + str(v).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"' for v in [paths["guard"], "--container", state["name"], "--state", Path(state["data"]) / "node-runtime-idle-state.json", "--port-summary", summary, "--apply"])
    atomic_write(paths["guard_service"], "[Unit]\nDescription=Reap confirmed idle TCP sockets for Marzban node\nAfter=docker.service\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 " + arguments + "\nTimeoutStartSec=45\nUMask=0077\n", 0o644)
    atomic_write(paths["guard_timer"], "[Unit]\nDescription=Marzban idle TCP cleanup\n[Timer]\nOnBootSec=60\nOnUnitActiveSec=60\nAccuracySec=5\n[Install]\nWantedBy=timers.target\n", 0o644)
    command(["systemctl", "daemon-reload"])
    command(["systemctl", "enable", "--now", unit + ".timer"])


def remove_idle_guard(name):
    paths = guard_paths("/var/lib/" + name, name)
    command(["systemctl", "disable", "--now", paths["guard_timer"].name], check=False)
    for label in ("guard_timer", "guard_service"):
        paths[label].unlink(missing_ok=True)
    remaining = command(['docker', 'ps', '-a', '--filter', 'label=com.docker.compose.service=marzban-node', '--format', '{{.Names}}'], check=False)
    if remaining.returncode == 0 and not (set(remaining.stdout.splitlines()) - {name}):
        paths = dict(connection_paths(), **health_paths())
        unit = paths['admission_service'].name
        command(['systemctl', 'disable', '--now', unit], check=False)
        command(["systemctl", "disable", "--now", paths["health_service"].name], check=False)
        for path in paths.values():
            path.unlink(missing_ok=True)
    command(["systemctl", "daemon-reload"], check=False)


def network_plan():
    """Conservative host defaults; leave UDP, routes, MTU and firewall intact."""
    limits = {"net.ipv4.tcp_keepalive_time": 120, "net.ipv4.tcp_keepalive_intvl": 30,
              "net.ipv4.tcp_keepalive_probes": 4, "net.netfilter.nf_conntrack_tcp_timeout_established": 7200}
    requested = dict(limits, **{"net.ipv4.tcp_mtu_probing": 1,
                               "net.ipv4.conf.all.send_redirects": 0,
                               "net.ipv4.conf.default.send_redirects": 0})
    requested["net.netfilter.nf_conntrack_max"] = connection_settings()[0]
    old, new = {}, {}
    for key, value in requested.items():
        probe = command(["sysctl", "-n", key], check=False)
        if probe.returncode or not probe.stdout.strip().isdigit():
            continue
        current = int(probe.stdout.strip())
        old[key] = str(current)
        if key == 'net.netfilter.nf_conntrack_max':
            # Keep an existing sensible smaller table. When shrinking, retain
            # 25% free capacity for the live count; never flush existing flows.
            target = min(current, value) if current >= 32768 else value
            sample = command(['sysctl', '-n', 'net.netfilter.nf_conntrack_count'], check=False)
            if sample.returncode or not sample.stdout.strip().isdigit():
                target = max(current, target)
            else:
                count = int(sample.stdout.strip())
                if target < current:
                    target = max(target, min(current, (count * 4 + 2) // 3))
            new[key] = str(target)
        else:
            new[key] = str(min(current, value) if key in limits else max(current, value) if key == 'net.ipv4.tcp_mtu_probing' else value)
    return old, new

RUNTIME_METHOD = '''    def _apply_runtime_limits(self):
        if os.getenv("XRAY_NODE_MEMORY_PROFILE", "") == "balanced":
            levels = self.setdefault("policy", {}).setdefault("levels", {})
            levels.setdefault("0", {})
            for values in levels.values():
                for key, limit in (("handshake", 15), ("connIdle", 120), ("bufferSize", 64)):
                    current = values.get(key)
                    values[key] = min(current, limit) if isinstance(current, (int, float)) and current >= 0 else limit

        listen = os.getenv("XRAY_NODE_METRICS_LISTEN", "")
        if listen:
            host, port = listen.rsplit(":", 1)
            if host != "127.0.0.1" or not port.isdigit() or not 1 <= int(port) <= 65535:
                raise ValueError("Node diagnostics must listen on an IPv4 loopback port")
            metrics = self.setdefault("metrics", {})
            metrics.setdefault("tag", "NodeDiagnostics")
            metrics["listen"] = listen

'''


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def patch_module(source):
    digest = sha256(source.encode())
    if digest == PATCHED_MODULE_SHA256:
        return source
    if digest != ORIGINAL_MODULE_SHA256:
        raise RuntimeError("Unsupported node runtime module; existing services were not stopped")
    edits = [
        ("import atexit\n", "import atexit\nimport os\n"),
        ("        self._apply_api()\n", "        self._apply_api()\n        self._apply_runtime_limits()\n"),
        ("    def to_json(self, **json_kwargs):\n", RUNTIME_METHOD + "    def to_json(self, **json_kwargs):\n"),
        (
            "        atexit.register(lambda: self.stop() if self.started else None)\n",
            "        for name in (\"GOGC\", \"GOMEMLIMIT\"):\n"
            "            value = os.getenv(name)\n"
            "            if value:\n"
            "                self._env[name] = value\n\n"
            "        atexit.register(lambda: self.stop() if self.started else None)\n",
        ),
    ]
    for before, after in edits:
        if source.count(before) != 1:
            raise RuntimeError("Unexpected node module layout")
        source = source.replace(before, after, 1)
    # Capture a particular child, rather than following self.process across a
    # restart. Merge stderr so an unread pipe cannot block the core.
    start = source.index("    def __capture_process_logs(self):\n")
    end = source.index("    @contextmanager\n", start)
    source = source[:start] + '''    def __capture_process_logs(self):
        process = self.process
        def capture():
            try:
                for output in process.stdout:
                    output = output.strip()
                    if output:
                        self._logs_buffer.append(output)
                        for buf in list(self._temp_log_buffers.values()):
                            buf.append(output)
                        if DEBUG:
                            logger.debug(output)
            finally:
                process.stdout.close()
        threading.Thread(target=capture, daemon=True).start()

''' + source[end:]
    source = source.replace("        self.restarting = False\n", "        self.restarting = False\n        self._process_lock = threading.RLock()\n", 1)
    source = source.replace("            stderr=subprocess.PIPE,\n", "            stderr=subprocess.STDOUT,\n", 1)
    start = source.index("    def stop(self):\n")
    end = source.index("    def on_start(self,", start)
    source = source[:start] + '''    def stop(self):
        with self._process_lock:
            process = self.process
            if process is None:
                return
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            else:
                process.wait()
            self.process = None
            logger.warning("Xray core stopped")
            for func in self._on_stop_funcs:
                threading.Thread(target=func, daemon=True).start()

    def restart(self, config: XRayConfig):
        with self._process_lock:
            if self.restarting:
                return
            self.restarting = True
            try:
                logger.warning("Restarting Xray core...")
                self.stop()
                self.start(config)
            finally:
                self.restarting = False

''' + source[end:]
    # Serialise direct start calls with stop/restart, including RPyC callers.
    start = source.index("    def start(self, config: XRayConfig):\n")
    end = source.index("    def stop(self):\n", start)
    lines = source[start:end].splitlines(True)
    source = source[:start] + lines[0] + "        with self._process_lock:\n" + "".join("    " + line if line.strip() else line for line in lines[1:]) + source[end:]
    ast.parse(source)
    if sha256(source.encode()) != PATCHED_MODULE_SHA256:
        raise RuntimeError("Node runtime patch checksum mismatch")
    return source


def memory_bytes(value):
    match = re.fullmatch(r"([0-9]+)(B|KiB|MiB|GiB|TiB)", str(value))
    if not match:
        return 0
    return int(match[1]) * {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4}[match[2]]


def effective_memory():
    total = int(next(line.split()[1] for line in Path("/proc/meminfo").read_text().splitlines() if line.startswith("MemTotal:"))) * 1024
    for filename in ("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"):
        try:
            value = Path(filename).read_text().strip()
            if value.isdigit() and int(value) > 0:
                total = min(total, int(value))
        except OSError:
            pass
    return total


def choose_budget(total):
    # Recompute on upgrades too, so an old 50% budget cannot retain the old policy.
    return str(max(1, total * MEMORY_BUDGET_PERCENT // (100 * 1024**2))) + "MiB"


def stage_pinned_core(data):
    """Verify the official binary before touching a running service."""
    architecture = platform.machine().lower()
    architecture = {"amd64": "x86_64", "arm64": "aarch64"}.get(architecture, architecture)
    if architecture not in PINNED_CORE_ASSETS:
        raise RuntimeError("Pinned Xray core is not verified for architecture: " + architecture)
    asset, archive_digest, binary_digest = PINNED_CORE_ASSETS[architecture]
    target = Path(data) / "node-runtime-core" / PINNED_CORE_VERSION / "xray"
    if target.is_file() and sha256(target.read_bytes()) == binary_digest:
        return target
    url = "https://github.com/XTLS/Xray-core/releases/download/v" + PINNED_CORE_VERSION + "/Xray-linux-" + asset + ".zip"
    with urllib.request.urlopen(url, timeout=45) as response:
        archive = response.read(80 * 1024**2 + 1)
    if sha256(archive) != archive_digest:
        raise RuntimeError("Official Xray archive checksum mismatch; node was not stopped")
    binary = zipfile.ZipFile(io.BytesIO(archive)).read("xray")
    if sha256(binary) != binary_digest:
        raise RuntimeError("Official Xray binary checksum mismatch; node was not stopped")
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".xray-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(binary)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o755)
        result = command([temporary, "version"], timeout=10)
        if not result.stdout.startswith("Xray " + PINNED_CORE_VERSION + " "):
            raise RuntimeError("Unexpected pinned Xray version")
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return target


def command(args, check=True, timeout=300):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError("Command failed: " + " ".join(args[:4]) + "\n" + result.stderr[-1500:])
    return result


def inspect_container(name):
    result = command(["docker", "inspect", name], check=False, timeout=15)
    return json.loads(result.stdout)[0] if result.returncode == 0 else None


def atomic_write(path, content, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".node-runtime-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def environment(values):
    if isinstance(values, dict):
        return dict(values)
    return dict(value.split("=", 1) for value in (values or []) if "=" in value)


def runtime_override(previous, image, module, budget, core=None):
    result = copy.deepcopy(previous)
    service = result.setdefault("services", {}).setdefault("marzban-node", {})
    service["image"] = image
    env = environment(service.get("environment"))
    env.update(GOGC="50", GOMEMLIMIT=budget, XRAY_NODE_MEMORY_PROFILE="balanced", XRAY_NODE_RUNTIME_SHA256=PATCHED_MODULE_SHA256)
    service["environment"] = env
    def target(value):
        if isinstance(value, dict):
            return value.get("target")
        parts = value.split(":")
        return parts[1] if len(parts) > 1 else parts[0]
    service["volumes"] = [value for value in service.get("volumes", []) if target(value) != "/code/xray.py"]
    service["volumes"].append({"type": "bind", "source": str(module), "target": "/code/xray.py", "read_only": True})
    if core is not None:
        env["XRAY_EXECUTABLE_PATH"] = "/opt/marzban-runtime/xray"
        service["volumes"] = [value for value in service["volumes"] if target(value) != "/opt/marzban-runtime/xray"]
        service["volumes"].append({"type": "bind", "source": str(core), "target": "/opt/marzban-runtime/xray", "read_only": True})
    # Diagnostics remain opt-in; a fixed metrics port would break multiple instances.
    return result


def bound_container_log(service, base_logging):
    override = service.get("logging", {})
    driver = override.get("driver", base_logging.get("Type"))
    options = dict(base_logging.get("Config") or {}) if base_logging.get("Type") == driver else {}
    options.update(override.get("options") or {})
    if driver != "json-file" or str(options.get("max-size", "-1")) != "-1":
        return
    cap = min(3, max(1, int(options.get("max-file", 3))))
    service["logging"] = dict(override, driver=driver, options=dict(override.get("options") or {},
                              **{"max-size": "8m", "max-file": str(cap)}))


def configured_image(compose, base, name):
    probe = "node-runtime-probe-" + uuid.uuid4().hex[:12]
    try:
        image = configured_node_image(compose, base, name)
        if command(["docker", "image", "inspect", image], check=False).returncode:
            pull_node_image(base, name, shlex.join(compose))
        command(compose + ["-f", str(base), "-p", name, "run", "-d", "--rm", "--no-deps", "-T", "--name", probe,
                           "--entrypoint", "python", "marzban-node", "-c", "import time; time.sleep(60)"])
        # Inspect the configured executable with its existing mounts. Updating
        # the node image does not update a separately installed Xray binary.
        result = command(["docker", "exec", probe, "python", "-c",
                          "import os,subprocess,json; "
                          "p=os.getenv('XRAY_EXECUTABLE_PATH','/usr/local/bin/xray'); "
                          "r=subprocess.run([p,'version'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True,timeout=10); "
                          "print(json.dumps({'version':r.stdout.splitlines()[0] if r.returncode==0 and r.stdout else '', 'executable':p}))"],
                         timeout=15)
        inspected = inspect_container(probe)
        return {"image": inspected["Image"], "core": json.loads(result.stdout),
                "logging": inspected.get("HostConfig", {}).get("LogConfig", {}),
                "memory_limit": max(0, int(inspected.get("HostConfig", {}).get("Memory", 0)))}
    finally:
        command(["docker", "rm", "-f", probe], check=False, timeout=15)


def configured_node_image(compose, base, name):
    arguments = compose + ["-f", str(base), "-p", name, "config"]
    result = command(arguments + ["--format", "json"], check=False)
    if result.returncode == 0 and result.stdout.strip():
        return json.loads(result.stdout)["services"]["marzban-node"]["image"]
    # Compose v1 has no JSON config mode. Read its normalized service block.
    text = command(arguments).stdout
    match = re.search(r"(?ms)^  marzban-node:\n(?P<block>(?:^    .*\n|^\n)+)", text)
    if match:
        image = re.search(r"(?m)^    image: (.+)$", match.group("block"))
        if image:
            return image.group(1).strip().strip("\"'")
    raise RuntimeError("Cannot determine the configured node image")


def pull_node_image(base, name, compose_string):
    compose = shlex.split(compose_string)
    result = command(compose + ["-f", str(base), "-p", name, "pull", "marzban-node"], check=False)
    if result.returncode == 0:
        return
    image = configured_node_image(compose, base, name)
    if image not in ("gozargah/marzban-node:latest", "docker.io/gozargah/marzban-node:latest"):
        raise RuntimeError("Configured node image pull failed: " + result.stderr[-1000:])
    mirror = "ghcr.io/gozargah/marzban-node:latest"
    print("Docker Hub pull failed; using the official GHCR mirror. Runtime source checks still apply.", file=sys.stderr)
    command(["docker", "pull", mirror])
    command(["docker", "tag", mirror, image])


def report_core_compatibility(core, name):
    version = core.get("version", "")
    print("Runtime core: " + (version or "version unavailable") + " (previous executable preserved for rollback)", file=sys.stderr)
    match = re.match(r"^Xray ([0-9]+)\.([0-9]+)\.([0-9]+)\b", version)
    if not match or tuple(map(int, match.groups())) < SS2022_POLICY_CORE_VERSION:
        print("Warning: this legacy or unrecognized core may ignore the SS2022 idle and buffer policy. "
              "GOMEMLIMIT alone cannot prevent connection accumulation or GC CPU pressure. "
              "Official v26.3.27 is pinned by this installer. An external per-process idle guard or a separately reviewed core fix is needed for affected transports; "
              "'" + name + " core-update' does not remove this install/update pin.", file=sys.stderr)


def image_module(image):
    result = command(["docker", "run", "--rm", "--network", "none", "--entrypoint", "python", image,
                      "-c", "from pathlib import Path; print(Path('/code/xray.py').read_text(), end='')"])
    return patch_module(result.stdout)


def patch_rest_module(source):
    if sha256(source.encode()) != ORIGINAL_REST_SHA256:
        raise RuntimeError("Unsupported REST module; existing services were not stopped")
    before = "if f'Xray {self.core_version} started' in log:\n                            break"
    if source.count(before) != 2:
        raise RuntimeError("Unexpected REST startup wait loop")
    result = source.replace(before, "if f'Xray {self.core_version} started' in log:\n                            return self.response()")
    ast.parse(result)
    return result


def image_rest_module(image):
    result = command(["docker", "run", "--rm", "--network", "none", "--entrypoint", "python", image,
                      "-c", "from pathlib import Path; print(Path('/code/rest_service.py').read_text(), end='')"])
    return patch_rest_module(result.stdout)


def prepare(base, overlay, data, name, compose_string):
    base, overlay, data = Path(base), Path(overlay), Path(data)
    compose = shlex.split(compose_string)
    initial_base_hash = sha256(base.read_bytes())
    command(compose + ["-f", str(base), "-p", name, "config", "-q"])
    old_container = inspect_container(name)
    if old_container and old_container["Config"].get("Labels", {}).get("com.docker.compose.service") != "marzban-node":
        raise RuntimeError("The container name belongs to another service")
    previous = json.loads(overlay.read_text()) if overlay.exists() else {}
    configured = configured_image(compose, base, name)
    memory = effective_memory()
    if configured.get("memory_limit", 0) > 0:
        memory = min(memory, configured["memory_limit"])
    budget = choose_budget(memory)
    image = configured["image"]
    report_core_compatibility(configured["core"], name)
    source = image_module(image)
    rest_source = image_rest_module(image)
    core = stage_pinned_core(data)
    module = data / "node-runtime-patch" / "xray.py"
    updated = runtime_override(previous, image, module, budget, core)
    rest_module = data / "node-runtime-patch/rest_service.py"
    service = updated["services"]["marzban-node"]
    bound_container_log(service, configured.get("logging", {}))
    service["volumes"] = [v for v in service["volumes"] if not (isinstance(v, dict) and v.get("target") == "/code/rest_service.py") and not (isinstance(v, str) and v.split(":")[1:2] == ["/code/rest_service.py"])]
    service["volumes"].append({"type": "bind", "source": str(rest_module), "target": "/code/rest_service.py", "read_only": True})
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    backups = data / "node-runtime-backups"
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix=stamp, dir=backups))
    state = {"base": str(base), "overlay": str(overlay), "module": str(module), "name": name, "data": str(data),
             "old_image": old_container["Image"] if old_container else None,
             "old_id": old_container["Id"] if old_container else None,
             "old_restart_count": old_container["RestartCount"] if old_container else 0,
             "was_running": bool(old_container and old_container["State"]["Running"]),
             "budget": budget, "image": image, "backup": str(backup), "memory_limit": configured.get("memory_limit", 0)}
    paths = dict(guard_paths(data, name), **connection_paths(), **health_paths(), rest_module=rest_module, network_profile=Path("/etc/sysctl.d/93-marzban-node-network.conf"))
    state.update({key: str(value) for key, value in paths.items()})
    state["network_old"], state["network_new"] = network_plan()
    state["guard_enabled"] = command(["systemctl", "is-enabled", paths["guard_timer"].name], check=False).returncode == 0
    state["guard_active"] = command(["systemctl", "is-active", paths["guard_timer"].name], check=False).returncode == 0
    state['admission_enabled'] = command(['systemctl', 'is-enabled', paths['admission_service'].name], check=False).returncode == 0
    state['admission_active'] = command(['systemctl', 'is-active', paths['admission_service'].name], check=False).returncode == 0
    state["health_enabled"] = command(["systemctl", "is-enabled", paths["health_service"].name], check=False).returncode == 0
    state["health_active"] = command(["systemctl", "is-active", paths["health_service"].name], check=False).returncode == 0
    for label, path in [("overlay", overlay), ("module", module)] + list(paths.items()):
        state[label + "_existed"] = path.exists()
        if path.exists():
            shutil.copy2(path, backup / label)
    if sha256(base.read_bytes()) != initial_base_hash:
        raise RuntimeError("Compose changed during preparation; retry with the new configuration")
    statefile = backup / "state.json"
    atomic_write(statefile, json.dumps(state, indent=2) + "\n")
    try:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", dir=base.parent) as candidate:
            json.dump(updated, candidate)
            candidate.flush()
            command(compose + ["-f", str(base), "-f", candidate.name, "-p", name, "config", "-q"])
        atomic_write(module, source, 0o644)
        atomic_write(rest_module, rest_source, 0o644)
        atomic_write(overlay, json.dumps(updated, indent=2) + "\n")
    except BaseException:
        restore_files(state)
        raise
    print("Runtime profile: balanced; Go memory budget: " + budget, file=sys.stderr)
    print(statefile)


def restore_files(state):
    for label in ("module", "overlay", "guard", "guard_service", "guard_timer", "rest_module", "network_profile", 'admission_script', 'admission_service', 'health_script', 'health_service'):
        if label not in state:
            continue
        target = Path(state[label])
        if state[label + "_existed"]:
            backup = Path(state["backup"]) / label
            atomic_write(target, backup.read_text(), backup.stat().st_mode & 0o777)
        elif target.exists():
            try:
                target.unlink()
            except FileNotFoundError:
                pass


def rollback(statefile, compose_string):
    state = json.loads(Path(statefile).read_text())
    timer = Path(state["guard_timer"]).name
    command(["systemctl", "stop", timer], check=False)
    if "health_service" in state:
        health = Path(state["health_service"]).name
        command(["systemctl", "stop", health], check=False)
        if not state.get("health_enabled"):
            command(["systemctl", "disable", health], check=False)
    if 'admission_service' in state:
        admission = Path(state['admission_service']).name
        command(['systemctl', 'stop', admission], check=False)
        if not state.get('admission_enabled'):
            command(['systemctl', 'disable', admission], check=False)
    if not state["guard_enabled"]:
        command(["systemctl", "disable", timer], check=False)
    restore_files(state)
    for key, value in state["network_old"].items():
        command(["sysctl", "-w", key + "=" + value], check=False)
    command(["systemctl", "daemon-reload"], check=False)
    if state.get("health_active"):
        command(["systemctl", "start", health], check=False)
    if state.get('admission_active'):
        command(['systemctl', 'start', admission], check=False)
    if state["guard_active"]:
        command(["systemctl", "start", timer], check=False)
    compose = shlex.split(compose_string)
    if state["was_running"]:
        recovery = Path(state["backup"]) / "recovery.json"
        atomic_write(recovery, json.dumps({"services": {"marzban-node": {"image": state["old_image"]}}}))
        files = ["-f", state["base"]]
        if state["overlay_existed"]:
            files += ["-f", state["overlay"]]
        command(compose + files + ["-f", str(recovery), "-p", state["name"], "up", "-d", "--no-deps", "marzban-node"])
    else:
        current = inspect_container(state["name"])
        if current and current["Config"].get("Labels", {}).get("com.docker.compose.service") == "marzban-node":
            command(["docker", "rm", "-f", state["name"]])
    print("Previous node runtime restored", file=sys.stderr)


def verify(statefile):
    state = json.loads(Path(statefile).read_text())
    for _ in range(3):
        time.sleep(1)
        container = inspect_container(state["name"])
        previous_restarts = state["old_restart_count"] if container and container["Id"] == state["old_id"] else 0
        if not container or not container["State"]["Running"] or container["State"]["Restarting"] or container["RestartCount"] > previous_restarts:
            raise RuntimeError("Node container did not remain running")
        if container["Image"] != state["image"]:
            raise RuntimeError("Running node image differs from the prepared runtime")
        if container.get("HostConfig", {}).get("Memory", 0) != state["memory_limit"]:
            raise RuntimeError("Running node memory limit differs from the prepared runtime")
        env = environment(container["Config"].get("Env"))
        if any(env.get(key) != value for key, value in {"GOGC": "50", "GOMEMLIMIT": state["budget"], "XRAY_NODE_MEMORY_PROFILE": "balanced"}.items()):
            raise RuntimeError("Node runtime environment was not applied")
    version = command(["docker", "exec", state["name"], "/opt/marzban-runtime/xray", "version"], timeout=15).stdout
    if not version.startswith("Xray " + PINNED_CORE_VERSION + " "):
        raise RuntimeError("Running node core does not match the verified version pin")
    install_idle_guard(state)
    install_connection_guard(state)
    install_health(state)
    # Preparation may have taken minutes. Re-sample before shrinking a live
    # table, while retaining the original values in the rollback manifest.
    _, state['network_new'] = network_plan()
    atomic_write(Path(statefile), json.dumps(state, indent=2) + '\n')
    if state["network_new"]:
        atomic_write(state["network_profile"], "# Marzban defaults; installation rollback retains prior values.\n" + "".join(key + " = " + value + "\n" for key, value in state["network_new"].items()), 0o644)
        command(["sysctl", "-p", state["network_profile"]])


def main(args):
    try:
        if args[0] == "prepare":
            prepare(*args[1:])
        elif args[0] == "rollback":
            rollback(*args[1:])
        elif args[0] == "verify":
            verify(*args[1:])
        elif args[0] == "remove-idle":
            remove_idle_guard(*args[1:])
        elif args[0] == "pull":
            pull_node_image(*args[1:])
        else:
            raise RuntimeError("Unknown runtime operation")
    except Exception as error:
        print("Node runtime error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
# END EMBEDDED NODE RUNTIME MANAGER
NODE_RUNTIME_PYTHON
}

up_marzban_node() {
    prepare_node_runtime
    if node_compose -p "$APP_NAME" up -d --remove-orphans && runtime_manager verify "$NODE_RUNTIME_STATE"; then
        # Updates commit after publishing the staged CLI; a failed copy must roll back.
        if [ -z "$NODE_SCRIPT_TEMP" ]; then
            NODE_RUNTIME_COMMITTED=true
            release_runtime_lock
        fi
        return
    fi
    runtime_manager rollback "$NODE_RUNTIME_STATE" "$COMPOSE"
    NODE_RUNTIME_STATE=""
    release_runtime_lock
    return 1
}

down_marzban_node() {
    node_compose -p "$APP_NAME" down
}

show_marzban_node_logs() {
    node_compose -p "$APP_NAME" logs
}

follow_marzban_node_logs() {
    node_compose -p "$APP_NAME" logs -f
}

update_marzban_node_script() {
    colorized_echo blue "Updating marzban-node script"
    stage_marzban_node_script
    publish_marzban_node_script "/usr/local/bin/$APP_NAME"
    colorized_echo green "marzban-node script updated successfully"
}

update_marzban_node() {
    # Pull the configured tag, rather than the locally pinned runtime image.
    runtime_manager pull "$COMPOSE_FILE" "$APP_NAME" "$COMPOSE"
}

is_marzban_node_installed() {
    if [ -d $APP_DIR ]; then
        return 0
    else
        return 1
    fi
}

is_marzban_node_up() {
    if [ -z "$(node_compose ps -q -a)" ]; then
        return 1
    else
        return 0
    fi
}

install_command() {
    check_running_as_root
    # The original one-liner upgrades an existing instance without replacing its inputs.
    if [ -f "$COMPOSE_FILE" ]; then
        update_command
        return
    fi
    # Check if marzban is already installed
    if is_marzban_node_installed; then
        colorized_echo red "Marzban-node is already installed at $APP_DIR"
        read -p "Do you want to override the previous installation? (y/n) "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            colorized_echo red "Aborted installation"
            exit 1
        fi
    fi
    detect_os
    if ! command -v jq >/dev/null 2>&1; then
        install_package jq
    fi
    if ! command -v curl >/dev/null 2>&1; then
        install_package curl
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
    fi
    detect_compose
    install_marzban_node_script
    install_marzban_node
    up_marzban_node
    follow_marzban_node_logs
    echo "Use your IP: $NODE_IP and defaults ports: $SERVICE_PORT and $XRAY_API_PORT to setup your Marzban Main Panel"
}

uninstall_command() {
    check_running_as_root
    # Check if marzban is installed
    if ! is_marzban_node_installed; then
        colorized_echo red "Marzban-node not installed!"
        exit 1
    fi
    
    read -p "Do you really want to uninstall Marzban-node? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo red "Aborted"
        exit 1
    fi
    
    detect_compose
    if is_marzban_node_up; then
        down_marzban_node
    fi
    uninstall_marzban_node_script
    uninstall_marzban_node
    uninstall_marzban_node_docker_images
    
    read -p "Do you want to remove Marzban-node data files too ($DATA_DIR)? (y/n) "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        colorized_echo green "Marzban-node uninstalled successfully"
    else
        uninstall_marzban_node_data_files
        colorized_echo green "Marzban-node uninstalled successfully"
    fi
}

up_command() {
    help() {
        colorized_echo red "Usage: marzban-node up [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if marzban-node is installed
    if ! is_marzban_node_installed; then
        colorized_echo red "Marzban-node's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if is_marzban_node_up; then
        colorized_echo red "Marzban-node's already up"
        exit 1
    fi
    
    up_marzban_node
    if [ "$no_logs" = false ]; then
        follow_marzban_node_logs
    fi
}

down_command() {
    # Check if marzban-node is installed
    if ! is_marzban_node_installed; then
        colorized_echo red "Marzban-node not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_marzban_node_up; then
        colorized_echo red "Marzban-node already down"
        exit 1
    fi
    
    down_marzban_node
}

restart_command() {
    help() {
        colorized_echo red "Usage: marzban-node restart [options]"
        echo
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-logs     do not follow logs after starting"
    }
    
    local no_logs=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-logs)
                no_logs=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if marzban-node is installed
    if ! is_marzban_node_installed; then
        colorized_echo red "Marzban-node not installed!"
        exit 1
    fi
    
    detect_compose
    prepare_node_runtime
    down_marzban_node
    up_marzban_node
    
}

status_command() {
    # Check if marzban-node is installed
    if ! is_marzban_node_installed; then
        echo -n "Status: "
        colorized_echo red "Not Installed"
        exit 1
    fi
    
    detect_compose
    
    if ! is_marzban_node_up; then
        echo -n "Status: "
        colorized_echo blue "Down"
        exit 1
    fi
    
    echo -n "Status: "
    colorized_echo green "Up"
    
    json=$(node_compose ps -a --format=json)
    services=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .Service')
    states=$(echo "$json" | jq -r 'if type == "array" then .[] else . end | .State')
    # Print out the service names and statuses
    for i in $(seq 0 $(expr $(echo $services | wc -w) - 1)); do
        service=$(echo $services | cut -d' ' -f $(expr $i + 1))
        state=$(echo $states | cut -d' ' -f $(expr $i + 1))
        echo -n "- $service: "
        if [ "$state" == "running" ]; then
            colorized_echo green $state
        else
            colorized_echo red $state
        fi
    done
}

logs_command() {
    help() {
        colorized_echo red "Usage: marzban-node logs [options]"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help        display this help message"
        echo "  -n, --no-follow   do not show follow logs"
    }
    
    local no_follow=false
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -n|--no-follow)
                no_follow=true
            ;;
            -h|--help)
                help
                exit 0
            ;;
            *)
                echo "Error: Invalid option: $1" >&2
                help
                exit 0
            ;;
        esac
        shift
    done
    
    # Check if marzban is installed
    if ! is_marzban_node_installed; then
        colorized_echo red "Marzban-node's not installed!"
        exit 1
    fi
    
    detect_compose
    
    if ! is_marzban_node_up; then
        colorized_echo red "Marzban-node is not up."
        exit 1
    fi
    
    if [ "$no_follow" = true ]; then
        show_marzban_node_logs
    else
        follow_marzban_node_logs
    fi
}

update_command() {
    check_running_as_root
    # Check if marzban is installed
    if ! is_marzban_node_installed; then
        colorized_echo red "Marzban-node not installed!"
        exit 1
    fi
    
    detect_compose
    
    stage_marzban_node_script
    colorized_echo blue "Pulling latest version"
    update_marzban_node
    
    colorized_echo blue "Restarting Marzban-node services"
    up_marzban_node
    update_marzban_node_script
    NODE_RUNTIME_COMMITTED=true
    release_runtime_lock
    
    colorized_echo blue "Marzban-node updated successfully"
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                ARCH='32'
            ;;
            'amd64' | 'x86_64')
                ARCH='64'
            ;;
            'armv5tel')
                ARCH='arm32-v5'
            ;;
            'armv6l')
                ARCH='arm32-v6'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv7' | 'armv7l')
                ARCH='arm32-v7a'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv8' | 'aarch64')
                ARCH='arm64-v8a'
            ;;
            'mips')
                ARCH='mips32'
            ;;
            'mipsle')
                ARCH='mips32le'
            ;;
            'mips64')
                ARCH='mips64'
                lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
            'mips64le')
                ARCH='mips64le'
            ;;
            'ppc64')
                ARCH='ppc64'
            ;;
            'ppc64le')
                ARCH='ppc64le'
            ;;
            'riscv64')
                ARCH='riscv64'
            ;;
            's390x')
                ARCH='s390x'
            ;;
            *)
                echo "error: The architecture is not supported."
                exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

# Function to update the Xray core
get_xray_core() {
    identify_the_operating_system_and_architecture
    clear
    
    
    validate_version() {
        local version="$1"
        
        local response=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$version")
        if echo "$response" | grep -q '"message": "Not Found"'; then
            echo "invalid"
        else
            echo "valid"
        fi
    }
    
    
    print_menu() {
        clear
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;32m      Xray-core Installer     \033[0m"
        echo -e "\033[1;32m==============================\033[0m"
       current_version=$(get_current_xray_core_version)
        echo -e "\033[1;33m>>>> Current Xray-core version: \033[1;1m$current_version\033[0m"
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;33mAvailable Xray-core versions:\033[0m"
        for ((i=0; i<${#versions[@]}; i++)); do
            echo -e "\033[1;34m$((i + 1)):\033[0m ${versions[i]}"
        done
        echo -e "\033[1;32m==============================\033[0m"
        echo -e "\033[1;35mM:\033[0m Enter a version manually"
        echo -e "\033[1;31mQ:\033[0m Quit"
        echo -e "\033[1;32m==============================\033[0m"
    }
    
    
    latest_releases=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=$LAST_XRAY_CORES")
    
    
    versions=($(echo "$latest_releases" | grep -oP '"tag_name": "\K(.*?)(?=")'))
    
    while true; do
        print_menu
        read -p "Choose a version to install (1-${#versions[@]}), or press M to enter manually, Q to quit: " choice
        
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#versions[@]}" ]; then
            
            choice=$((choice - 1))
            
            selected_version=${versions[choice]}
            break
            elif [ "$choice" == "M" ] || [ "$choice" == "m" ]; then
            while true; do
                read -p "Enter the version manually (e.g., v1.2.3): " custom_version
                if [ "$(validate_version "$custom_version")" == "valid" ]; then
                    selected_version="$custom_version"
                    break 2
                else
                    echo -e "\033[1;31mInvalid version or version does not exist. Please try again.\033[0m"
                fi
            done
            elif [ "$choice" == "Q" ] || [ "$choice" == "q" ]; then
            echo -e "\033[1;31mExiting.\033[0m"
            exit 0
        else
            echo -e "\033[1;31mInvalid choice. Please try again.\033[0m"
            sleep 2
        fi
    done
    
    echo -e "\033[1;32mSelected version $selected_version for installation.\033[0m"
    
    
if ! dpkg -s unzip >/dev/null 2>&1; then
    echo -e "\033[1;33mInstalling required packages...\033[0m"
    detect_os
    install_package unzip
fi

    
    
    mkdir -p $DATA_MAIN_DIR/xray-core
    cd $DATA_MAIN_DIR/xray-core
    
    
    
    xray_filename="Xray-linux-$ARCH.zip"
    xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${selected_version}/${xray_filename}"
    
    echo -e "\033[1;33mDownloading Xray-core version ${selected_version} in the background...\033[0m"
    wget "${xray_download_url}" -q &
    wait
    
    
    echo -e "\033[1;33mExtracting Xray-core in the background...\033[0m"
    unzip -o "${xray_filename}" >/dev/null 2>&1 &
    wait
    rm "${xray_filename}"
}
get_current_xray_core_version() {
    # The runtime overlay can intentionally select a different executable from
    # the preserved legacy core and the binary bundled in the container image.
    if [ -f "$RUNTIME_COMPOSE_FILE" ]; then
        local runtime_version
        runtime_version=$(docker exec "$APP_NAME" /opt/marzban-runtime/xray version 2>/dev/null | awk 'NR == 1 && $1 == "Xray" {print $2}')
        if [ -n "$runtime_version" ]; then
            echo "$runtime_version (in container)"
            return
        fi
    fi
    XRAY_BINARY="$DATA_MAIN_DIR/xray-core/xray"
    if [ -f "$XRAY_BINARY" ]; then
        version_output=$("$XRAY_BINARY" -version 2>/dev/null)
        if [ $? -eq 0 ]; then
            version=$(echo "$version_output" | head -n1 | awk '{print $2}')
            echo "$version"
            return
        fi
    fi

    # If local binary is not found or failed, check in the Docker container
    CONTAINER_NAME="$APP_NAME"
    if docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
        version_output=$(docker exec "$CONTAINER_NAME" xray -version 2>/dev/null)
        if [ $? -eq 0 ]; then
            # Extract the version number from the first line
            version=$(echo "$version_output" | head -n1 | awk '{print $2}')
            echo "$version (in container)"
            return
        fi
    fi

    echo "Not installed"
}

install_yq() {
    if command -v yq &>/dev/null; then
        colorized_echo green "yq is already installed."
        return
    fi

    identify_the_operating_system_and_architecture

    local base_url="https://github.com/mikefarah/yq/releases/latest/download"
    local yq_binary=""

    case "$ARCH" in
        '64' | 'x86_64')
            yq_binary="yq_linux_amd64"
            ;;
        'arm32-v7a' | 'arm32-v6' | 'arm32-v5' | 'armv7l')
            yq_binary="yq_linux_arm"
            ;;
        'arm64-v8a' | 'aarch64')
            yq_binary="yq_linux_arm64"
            ;;
        '32' | 'i386' | 'i686')
            yq_binary="yq_linux_386"
            ;;
        *)
            colorized_echo red "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    local yq_url="${base_url}/${yq_binary}"
    colorized_echo blue "Downloading yq from ${yq_url}..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        colorized_echo yellow "Neither curl nor wget is installed. Attempting to install curl."
        install_package curl || {
            colorized_echo red "Failed to install curl. Please install curl or wget manually."
            exit 1
        }
    fi


    if command -v curl &>/dev/null; then
        if curl -L "$yq_url" -o /usr/local/bin/yq; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using curl. Please check your internet connection."
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if wget -O /usr/local/bin/yq "$yq_url"; then
            chmod +x /usr/local/bin/yq
            colorized_echo green "yq installed successfully!"
        else
            colorized_echo red "Failed to download yq using wget. Please check your internet connection."
            exit 1
        fi
    fi


    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi


    hash -r

    if command -v yq &>/dev/null; then
        colorized_echo green "yq is ready to use."
    elif [ -x "/usr/local/bin/yq" ]; then

        colorized_echo yellow "yq is installed at /usr/local/bin/yq but not found in PATH."
        colorized_echo yellow "You can add /usr/local/bin to your PATH environment variable."
    else
        colorized_echo red "yq installation failed. Please try again or install manually."
        exit 1
    fi
}



update_core_command() {
    check_running_as_root
    get_xray_core

    if ! command -v yq &>/dev/null; then
        echo "yq is not installed. Installing yq..."
        install_yq
    fi

    if ! grep -q 'XRAY_EXECUTABLE_PATH: "/var/lib/marzban-node/xray-core/xray"' "$COMPOSE_FILE"; then
        yq eval '.services."marzban-node".environment.XRAY_EXECUTABLE_PATH = "/var/lib/marzban-node/xray-core/xray"' -i "$COMPOSE_FILE"
    fi

    if ! yq eval ".services.\"marzban-node\".volumes[] | select(. == \"${DATA_MAIN_DIR}:/var/lib/marzban-node\")" "$COMPOSE_FILE" &>/dev/null; then
        yq eval ".services.\"marzban-node\".volumes += \"${DATA_MAIN_DIR}:/var/lib/marzban-node\"" -i "$COMPOSE_FILE"
    fi
    
    # Restart Marzban-node
    colorized_echo red "Restarting Marzban-node..."
    $APP_NAME restart -n
    colorized_echo blue "Installation of XRAY-CORE version $selected_version completed."
}


check_editor() {
    if [ -z "$EDITOR" ]; then
        if command -v nano >/dev/null 2>&1; then
            EDITOR="nano"
            elif command -v vi >/dev/null 2>&1; then
            EDITOR="vi"
        else
            detect_os
            install_package nano
            EDITOR="nano"
        fi
    fi
}


edit_command() {
    detect_os
    check_editor
    if [ -f "$COMPOSE_FILE" ]; then
        $EDITOR "$COMPOSE_FILE"
    else
        colorized_echo red "Compose file not found at $COMPOSE_FILE"
        exit 1
    fi
}


usage() {
    colorized_echo blue "================================"
    colorized_echo magenta "       $APP_NAME Node CLI Help"
    colorized_echo blue "================================"
    colorized_echo cyan "Usage:"
    echo "  $APP_NAME [command]"
    echo

    colorized_echo cyan "Commands:"
    colorized_echo yellow "  up              $(tput sgr0)– Start services"
    colorized_echo yellow "  down            $(tput sgr0)– Stop services"
    colorized_echo yellow "  restart         $(tput sgr0)– Restart services"
    colorized_echo yellow "  status          $(tput sgr0)– Show status"
    colorized_echo yellow "  logs            $(tput sgr0)– Show logs"
    colorized_echo yellow "  install         $(tput sgr0)– Install/reinstall Marzban-node"
    colorized_echo yellow "  update          $(tput sgr0)– Update to latest version"
    colorized_echo yellow "  uninstall       $(tput sgr0)– Uninstall Marzban-node"
    colorized_echo yellow "  install-script  $(tput sgr0)– Install Marzban-node script"
    colorized_echo yellow "  uninstall-script  $(tput sgr0)– Uninstall Marzban-node script"
    colorized_echo yellow "  edit            $(tput sgr0)– Edit docker-compose.yml (via nano or vi)"
    colorized_echo yellow "  core-update     $(tput sgr0)– Update/Change Xray core"
    
    echo
    colorized_echo cyan "Node Information:"
    colorized_echo magenta "  Cert file path: $CERT_FILE"
    colorized_echo magenta "  Node IP: $NODE_IP"
    echo
    current_version=$(get_current_xray_core_version)
    colorized_echo cyan "Current Xray-core version: " 1  # 1 for bold
    colorized_echo magenta "$current_version" 1
    echo
    DEFAULT_SERVICE_PORT="62050"
    DEFAULT_XRAY_API_PORT="62051"
    
    if [ -f "$COMPOSE_FILE" ]; then
        SERVICE_PORT=$(awk -F': ' '/SERVICE_PORT:/ {gsub(/"/, "", $2); print $2}' "$COMPOSE_FILE")
        XRAY_API_PORT=$(awk -F': ' '/XRAY_API_PORT:/ {gsub(/"/, "", $2); print $2}' "$COMPOSE_FILE")
    fi
    
    SERVICE_PORT=${SERVICE_PORT:-$DEFAULT_SERVICE_PORT}
    XRAY_API_PORT=${XRAY_API_PORT:-$DEFAULT_XRAY_API_PORT}

    colorized_echo cyan "Ports:"
    colorized_echo magenta "  Service port: $SERVICE_PORT"
    colorized_echo magenta "  API port: $XRAY_API_PORT"
    colorized_echo blue "================================="
    echo
}

case "$COMMAND" in
    install)
        install_command
    ;;
    update)
        update_command
    ;;
    uninstall)
        uninstall_command
    ;;
    up)
        up_command
    ;;
    down)
        down_command
    ;;
    restart)
        restart_command
    ;;
    status)
        status_command
    ;;
    logs)
        logs_command
    ;;
    core-update)
        update_core_command
    ;;
    install-script)
        install_marzban_node_script
    ;;
    uninstall-script)
        uninstall_marzban_node_script
    ;;
    edit)
        edit_command
    ;;
    *)
        usage
    ;;
esac
