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
NODE_IP=$(curl -s -4 ifconfig.io)

# If the IPv4 retrieval is empty, attempt to retrieve the IPv6 address
if [ -z "$NODE_IP" ]; then
    NODE_IP=$(curl -s -6 ifconfig.io)
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
    if ! curl -fsSL "$SCRIPT_URL" -o "$NODE_SCRIPT_TEMP" || [ ! -s "$NODE_SCRIPT_TEMP" ] || ! grep -q '^install_command() {' "$NODE_SCRIPT_TEMP" || ! bash -n "$NODE_SCRIPT_TEMP"; then
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
    exec {NODE_RUNTIME_LOCK_FD}>"$APP_DIR/.node-runtime.lock"
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
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


ORIGINAL_MODULE_SHA256 = "12757c9b4f97095992f0b2dac5615e56317b047b382d34ef5a6e19484c22c83f"
PATCHED_MODULE_SHA256 = "0656179bcb654f98ccd3b8d190f70d3bcb51a05d2dcc4979c8ac1e81e396ed37"
MEMORY_BUDGET_PERCENT = 75

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


def runtime_override(previous, image, module, budget):
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
    # Diagnostics remain opt-in; a fixed metrics port would break multiple instances.
    return result


def configured_image(compose, base, name):
    probe = "node-runtime-probe-" + uuid.uuid4().hex[:12]
    try:
        command(compose + ["-f", str(base), "-p", name, "run", "-d", "--rm", "--no-deps", "-T", "--name", probe,
                           "--entrypoint", "python", "marzban-node", "-c", "import time; time.sleep(60)"])
        return inspect_container(probe)["Image"]
    finally:
        command(["docker", "rm", "-f", probe], check=False, timeout=15)


def image_module(image):
    result = command(["docker", "run", "--rm", "--network", "none", "--entrypoint", "python", image,
                      "-c", "from pathlib import Path; print(Path('/code/xray.py').read_text(), end='')"])
    return patch_module(result.stdout)


def prepare(base, overlay, data, name, compose_string):
    base, overlay, data = Path(base), Path(overlay), Path(data)
    compose = shlex.split(compose_string)
    initial_base_hash = sha256(base.read_bytes())
    command(compose + ["-f", str(base), "-p", name, "config", "-q"])
    old_container = inspect_container(name)
    if old_container and old_container["Config"].get("Labels", {}).get("com.docker.compose.service") != "marzban-node":
        raise RuntimeError("The container name belongs to another service")
    previous = json.loads(overlay.read_text()) if overlay.exists() else {}
    budget = choose_budget(effective_memory())
    image = configured_image(compose, base, name)
    source = image_module(image)
    module = data / "node-runtime-patch" / "xray.py"
    updated = runtime_override(previous, image, module, budget)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    backups = data / "node-runtime-backups"
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix=stamp, dir=backups))
    state = {"base": str(base), "overlay": str(overlay), "module": str(module), "name": name,
             "old_image": old_container["Image"] if old_container else None,
             "old_id": old_container["Id"] if old_container else None,
             "old_restart_count": old_container["RestartCount"] if old_container else 0,
             "was_running": bool(old_container and old_container["State"]["Running"]),
             "budget": budget, "image": image, "backup": str(backup)}
    for label, path in (("overlay", overlay), ("module", module)):
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
        atomic_write(overlay, json.dumps(updated, indent=2) + "\n")
    except BaseException:
        restore_files(state)
        raise
    print("Runtime profile: balanced; Go memory budget: " + budget, file=sys.stderr)
    print(statefile)


def restore_files(state):
    for label in ("module", "overlay"):
        target = Path(state[label])
        if state[label + "_existed"]:
            backup = Path(state["backup"]) / label
            atomic_write(target, backup.read_text(), backup.stat().st_mode & 0o777)
        else:
            try:
                target.unlink()
            except FileNotFoundError:
                pass


def rollback(statefile, compose_string):
    state = json.loads(Path(statefile).read_text())
    restore_files(state)
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
        env = environment(container["Config"].get("Env"))
        if any(env.get(key) != value for key, value in {"GOGC": "50", "GOMEMLIMIT": state["budget"], "XRAY_NODE_MEMORY_PROFILE": "balanced"}.items()):
            raise RuntimeError("Node runtime environment was not applied")


def main(args):
    try:
        if args[0] == "prepare":
            prepare(*args[1:])
        elif args[0] == "rollback":
            rollback(*args[1:])
        elif args[0] == "verify":
            verify(*args[1:])
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
    $COMPOSE -f "$COMPOSE_FILE" -p "$APP_NAME" pull
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
