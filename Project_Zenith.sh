#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Project Zenith (v3.0)
# ==========================================

# Colors & Formatting
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Dependency Versions (Update these variables to bump versions)
PODMAN_VERSION="v5.8.2"
CONMON_VERSION="v2.2.1"
CRUN_VERSION="1.28"
NETAVARK_VERSION="v1.16.0"
AARDVARK_VERSION="v1.17.1"

# Logging Functions
log_info() { echo -e "${BLUE}[*] $1${NC}"; }
log_success() { echo -e "${GREEN}[+] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[!] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; >&2; }
fatal() { log_error "$1"; exit 1; }

# 0. PREREQUISITE CHECK
for cmd in curl wget tar gunzip find readlink id file; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fatal "Required command '$cmd' is missing. Please install it first."
    fi
done

# 1. DYNAMIC PATH DETECTION
USER_ID=$(id -u)
GOINFRE_BASE="$HOME/goinfre"

if [ ! -d "$GOINFRE_BASE" ]; then
    fatal "~/goinfre not found. Setup failed."
fi

# Get the absolute path resolving all symlinks
GOINFRE_PATH=$(readlink -f "$GOINFRE_BASE")
INSTALL_DIR="$GOINFRE_PATH/bin"
CONTAINER_DIR="$GOINFRE_PATH/containers"
CONFIG_DIR="$HOME/.config/containers"

export PATH="$INSTALL_DIR:$PATH"

# ==========================================
# CORE FUNCTIONS
# ==========================================

prepare_directories() {
    log_info "Preparing directories..."
    mkdir -p "$INSTALL_DIR" \
             "$CONTAINER_DIR/storage" \
             "$CONTAINER_DIR/run" \
             "$CONFIG_DIR"
}

download_tool() {
    local url="$1"
    local output="$2"
    local expected_type="$3"

    echo "   - Fetching $output..."
    if ! wget -q "$url" -O "$output"; then
        rm -f "$output"
        fatal "Failed to download $output from network."
    fi

    if ! file "$output" | grep -qi "$expected_type"; then
        rm -f "$output"
        fatal "Downloaded file '$output' is invalid or corrupted (Expected: $expected_type). The source URL might be dead."
    fi
}

install_podman() {
    log_info "Downloading Podman Engine (${PODMAN_VERSION})..."
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"

    wget -q --show-progress "https://github.com/mgoltzsche/podman-static/releases/download/${PODMAN_VERSION}/podman-linux-amd64.tar.gz" -O podman.tar.gz
    
    if ! file podman.tar.gz | grep -qi "gzip"; then
        fatal "Podman archive is invalid or corrupted."
    fi

    tar -xf podman.tar.gz

    local PODMAN_BIN
    PODMAN_BIN=$(find . -name podman -type f | head -n 1)
    if [ -z "$PODMAN_BIN" ]; then
        fatal "Could not locate podman binary in the downloaded archive."
    fi

    rm -f "$INSTALL_DIR/podman"
    cp "$PODMAN_BIN" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/podman"

    cd "$GOINFRE_PATH"
    rm -rf "$TMP_DIR"
    log_success "Podman installed successfully."
}

install_dependencies() {
    log_info "Downloading Dependencies..."
    cd "$INSTALL_DIR"

    download_tool "https://github.com/containers/conmon/releases/download/${CONMON_VERSION}/conmon.amd64" "conmon" "ELF"
    chmod +x conmon

    download_tool "https://github.com/containers/crun/releases/download/${CRUN_VERSION}/crun-${CRUN_VERSION}-linux-amd64" "crun" "ELF"
    chmod +x crun

    download_tool "https://github.com/containers/netavark/releases/download/${NETAVARK_VERSION}/netavark.gz" "netavark.gz" "gzip"
    gunzip -f netavark.gz
    chmod +x netavark

    download_tool "https://github.com/containers/aardvark-dns/releases/download/${AARDVARK_VERSION}/aardvark-dns.gz" "aardvark-dns.gz" "gzip"
    gunzip -f aardvark-dns.gz
    chmod +x aardvark-dns
    
    log_success "Dependencies installed successfully."
}

generate_configs() {
    log_info "Generating Configuration Files..."

    cat > "$CONFIG_DIR/storage.conf" <<EOL
[storage]
driver = "vfs"
graphroot = "$CONTAINER_DIR/storage"
runroot = "/run/user/$USER_ID"

[storage.options]
ignore_chown_errors = "true"
EOL

    cat > "$CONFIG_DIR/containers.conf" <<EOL
[engine]
conmon_path = [
    "$INSTALL_DIR/conmon",
    "/usr/libexec/podman/conmon",
    "/usr/bin/conmon"
]
helper_binaries_dir = [
    "$INSTALL_DIR",
    "/usr/libexec/podman",
    "/usr/bin"
]
network_cmd_path = "$INSTALL_DIR/netavark"
runtime = "crun"
EOL

    cat > "$CONFIG_DIR/policy.json" <<EOL
{
    "default": [ { "type": "insecureAcceptAnything" } ],
    "transports": {
        "docker-daemon": { "": [{"type": "insecureAcceptAnything"}] }
    }
}
EOL

    cat > "$CONFIG_DIR/registries.conf" <<EOL
[registries.search]
registries = ['docker.io']
EOL
    log_success "Configurations generated."
}

install_distrobox() {
    log_info "Installing Distrobox..."
    if ! curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix "$GOINFRE_PATH" > /dev/null; then
        fatal "Distrobox installation failed."
    fi
    log_success "Distrobox installed."
}

update_shell_rc() {
    local target_rc="$1"
    if [ -f "$target_rc" ]; then
        if ! grep -q "CONTAINERS_STORAGE_CONF" "$target_rc"; then
            {
                echo ""
                echo "# Custom Podman/Distrobox Config"
                echo "export PATH=\"$INSTALL_DIR:\$PATH\""
                echo "export CONTAINERS_STORAGE_CONF=\"$CONFIG_DIR/storage.conf\""
            } >> "$target_rc"
            log_success "Updated $target_rc"
        else
            log_info "Config already exists in $target_rc"
        fi
    fi
}

finish_installation() {
    echo -e "\n${GREEN}==========================================${NC}"
    echo -e "${GREEN}       INSTALLATION COMPLETE!             ${NC}"
    echo -e "${GREEN}==========================================${NC}\n"

    echo "1. Apply your shell configuration:"
    echo "   source ~/.zshrc  # (or source ~/.bashrc)"
    echo ""
    echo "2. Create your container with CONTROLLER SUPPORT (Copy-Paste this):"
    echo ""
    echo "   distrobox create --image ubuntu:latest --name my-box \\"
    echo "     --home $GOINFRE_PATH/homes/my-box \\"
    echo "     --volume $GOINFRE_PATH:$GOINFRE_PATH \\"
    echo "     --device /dev/input:/dev/input \\"
    echo "     --device /dev/uinput:/dev/uinput \\"
    echo "     --yes"
    echo ""
}

# ==========================================
# EXECUTION WORKFLOWS
# ==========================================

run_installation() {
    log_success "Detected Real Goinfre Path: ${GOINFRE_PATH}"
    prepare_directories
    install_podman
    install_dependencies
    generate_configs
    install_distrobox
    log_info "Updating Shell Configurations..."
    update_shell_rc "$HOME/.zshrc"
    update_shell_rc "$HOME/.bashrc"
    finish_installation
}

run_repair() {
    echo -e "\n${RED}==============================================================${NC}"
    echo -e "${RED}                      !!! WARNING !!!                         ${NC}"
    echo -e "${RED}==============================================================${NC}"
    echo -e "${YELLOW}You are about to initiate a FULL RESET of the environment.${NC}"
    echo -e "${YELLOW}This will completely delete ALL Distrobox binaries, Podman${NC}"
    echo -e "${YELLOW}tools, and reset your container configuration files in goinfre.${NC}"
    echo -e "${RED}==============================================================${NC}\n"
    
    read -p "Are you absolutely sure you want to proceed? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Repair canceled by user. Returning to menu..."
        return
    fi

    log_warn "Initiating Setup Repair..."
    log_info "Cleaning up old binaries and configurations..."
    
    # Remove Podman and Dependencies
    rm -f "$INSTALL_DIR/podman" "$INSTALL_DIR/conmon" "$INSTALL_DIR/crun" "$INSTALL_DIR/netavark" "$INSTALL_DIR/aardvark-dns"
    
    # Fully wipe Distrobox files
    rm -f "$INSTALL_DIR/distrobox"*
    
    # Wipe Configurations
    rm -rf "$CONFIG_DIR"/*
    
    log_success "Cleanup complete. Restarting installation workflow."
    run_installation
}

# ==========================================
# INTERACTIVE MENU
# ==========================================

while true; do
    clear
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${GREEN} PROJECT ZENITH       ${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo -e " 1) ${GREEN}Fresh Install${NC} (Downloads and sets up everything)"
    echo -e " 2) ${YELLOW}Repair Setup${NC}  (Fully resets and cleans old versions)"
    echo -e " 3) ${RED}Exit${NC}"
    echo -e "${BLUE}==========================================${NC}"

    read -p "Select an option [1-3]: " choice
    case "$choice" in
        1 ) run_installation; break ;;
        2 ) run_repair; break ;;
        3 ) log_info "Exiting..."; exit 0 ;;
        * ) log_error "Invalid selection. Please enter 1, 2, or 3."; sleep 1 ;;
    esac
done
