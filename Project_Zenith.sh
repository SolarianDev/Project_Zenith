#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Project Zenith
# ==========================================
SCRIPT_VERSION="4.0"
UPDATE_URL="https://raw.githubusercontent.com/SolarianDev/Project_Zenith/main/Project_Zenith.sh"

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
    # Look specifically in bin/ directories to avoid the bash-completion script
    PODMAN_BIN=$(find . -path "*/bin/podman" -type f | head -n 1)

    # Fallback to search any file named podman that is an ELF executable
    if [ -z "$PODMAN_BIN" ] || ! file "$PODMAN_BIN" | grep -qi "ELF"; then
        PODMAN_BIN=$(find . -type f -name podman -exec file {} + 2>/dev/null | grep -i "ELF" | cut -d: -f1 | head -n 1 || true)
    fi

    if [ -z "$PODMAN_BIN" ] || ! file "$PODMAN_BIN" | grep -qi "ELF"; then
        fatal "Could not locate valid Podman ELF binary in the downloaded archive."
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

verify_and_repair_podman() {
    log_info "Verifying Podman health..."
    
    if ! podman info >/dev/null 2>&1; then
        log_warn "Podman is unresponsive. Attempting automatic self-repair..."
        
        podman system migrate >/dev/null 2>&1 || true
        rm -rf "/run/user/$USER_ID/containers" >/dev/null 2>&1 || true
        rm -rf "/run/user/$USER_ID/podman" >/dev/null 2>&1 || true
        
        if ! podman info >/dev/null 2>&1; then
            log_error "Automatic repair failed. Podman is still broken."
        else
            log_success "Podman successfully recovered!"
        fi
    else
        log_success "Podman is functioning correctly."
    fi
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
    
    echo "1. Apply your shell configuration in your current terminal:"
    echo "   source ~/.zshrc  # (or source ~/.bashrc)"
    echo ""
    echo "2. Create your container:"
    echo "   Use Option 2 in the Project Zenith menu to create one interactively,"
    echo "   or run manually:"
    echo ""
    echo "   distrobox create --image ubuntu:latest --name my-box \\"
    echo "     --home $GOINFRE_PATH/homes/my-box \\"
    echo "     --volume $GOINFRE_PATH:$GOINFRE_PATH \\"
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
    
    verify_and_repair_podman
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
    
    rm -f "$INSTALL_DIR/podman" "$INSTALL_DIR/conmon" "$INSTALL_DIR/crun" "$INSTALL_DIR/netavark" "$INSTALL_DIR/aardvark-dns"
    rm -f "$INSTALL_DIR/distrobox"*
    rm -rf "$CONFIG_DIR"/*
    
    log_success "Cleanup complete. Restarting installation workflow."
    run_installation
}


run_create_container() {
    echo -e "\n${BLUE}==============================================================${NC}"
    echo -e "${BLUE}                 CREATE DISTROBOX CONTAINER                   ${NC}"
    echo -e "${BLUE}==============================================================${NC}"

    if ! command -v podman >/dev/null 2>&1 || ! command -v distrobox >/dev/null 2>&1; then
        log_error "Podman or Distrobox binary is not found in PATH."
        log_info "Please run Option 1 (Fresh Install) first."
        echo ""
        read -n 1 -s -r -p "Press any key to return to the menu..."
        return
    fi

    # Container Name
    echo ""
    read -p "Enter container name [default: my-box]: " box_name
    box_name="${box_name:-my-box}"

    # Check if container already exists
    if podman inspect --type container "$box_name" >/dev/null 2>&1; then
        log_warn "A container named '$box_name' already exists."
        read -p "Do you want to enter it now? [y/N]: " enter_existing
        if [[ "$enter_existing" =~ ^[Yy]$ ]]; then
            distrobox enter "$box_name"
        fi
        return
    fi

    # Container Image Selection
    echo -e "\nSelect container base image:"
    echo " 1) Ubuntu latest (ubuntu:latest) [Default]"
    echo " 2) Ubuntu 22.04  (ubuntu:22.04)"
    echo " 3) Debian latest (debian:latest)"
    echo " 4) Arch Linux    (archlinux:latest)"
    echo " 5) Fedora latest (fedora:latest)"
    echo " 6) Custom image"
    read -p "Select an image [1-6, default: 1]: " img_choice

    local box_image
    case "$img_choice" in
        2) box_image="ubuntu:22.04" ;;
        3) box_image="debian:latest" ;;
        4) box_image="archlinux:latest" ;;
        5) box_image="fedora:latest" ;;
        6)
            read -p "Enter custom container image: " box_image
            if [ -z "$box_image" ]; then
                log_error "Image name cannot be empty. Aborting."
                sleep 1
                return
            fi
            ;;
        *) box_image="ubuntu:latest" ;;
    esac

    local box_home="$GOINFRE_PATH/homes/$box_name"
    mkdir -p "$box_home"

    echo ""
    log_info "Creating Distrobox container '$box_name' ($box_image)..."
    log_info "Container Home: $box_home"
    log_info "Goinfre Volume: $GOINFRE_PATH:$GOINFRE_PATH"
    echo ""

    if distrobox create --image "$box_image" --name "$box_name" \
        --home "$box_home" \
        --volume "$GOINFRE_PATH:$GOINFRE_PATH" \
        --yes; then
        
        echo -e "\n${GREEN}==========================================${NC}"
        echo -e "${GREEN}    CONTAINER '$box_name' CREATED!        ${NC}"
        echo -e "${GREEN}==========================================${NC}\n"
        echo -e "You can enter your container at any time with:"
        echo -e "   ${YELLOW}distrobox enter $box_name${NC}\n"

        read -p "Enter '$box_name' now? [Y/n]: " enter_choice
        if [[ "$enter_choice" =~ ^[Yy]$ ]] || [[ -z "$enter_choice" ]]; then
            log_info "Entering $box_name..."
            distrobox enter "$box_name"
        fi
    else
        log_error "Failed to create container '$box_name'."
    fi

    echo ""
    read -n 1 -s -r -p "Press any key to return to the menu..."
}

run_storage_management() {
    while true; do
        clear
        echo -e "${BLUE}==============================================================${NC}"
        echo -e "${BLUE}                 STORAGE MANAGEMENT & CLEANER                 ${NC}"
        echo -e "${BLUE}==============================================================${NC}"

        echo -e "${YELLOW}[DISK USAGE OVERVIEW]${NC}"
        df -h "$GOINFRE_PATH" "$HOME" 2>/dev/null | awk 'NR==1 || /goinfre/ || /sda/ || /mapper/ {print "   " $0}' || df -h "$GOINFRE_PATH" "$HOME"
        echo ""

        echo -e "${YELLOW}[CONTAINER STORAGE USAGE]${NC}"
        if [ -d "$CONTAINER_DIR" ]; then
            local storage_size
            storage_size=$(du -sh "$CONTAINER_DIR" 2>/dev/null | cut -f1 || echo "0")
            echo "   - Podman storage layers: $storage_size ($CONTAINER_DIR)"
        else
            echo "   - Podman storage layers: Not found"
        fi

        if [ -d "$GOINFRE_PATH/homes" ]; then
            local homes_size
            homes_size=$(du -sh "$GOINFRE_PATH/homes" 2>/dev/null | cut -f1 || echo "0")
            echo "   - Container homes total: $homes_size ($GOINFRE_PATH/homes)"
        else
            echo "   - Container homes total: None"
        fi
        echo ""

        echo -e "${BLUE}==============================================================${NC}"
        echo -e " 1) ${GREEN}Safe Prune Cache${NC}     (Removes stopped containers & dangling cache)"
        echo -e " 2) ${YELLOW}Aggressive Prune${NC}     (Removes ALL unused images, volumes & cache)"
        echo -e " 3) ${BLUE}Clean Temp Locks${NC}     (Fixes stale /run/user locks without data loss)"
        echo -e " 4) ${RED}Delete Container Home${NC} (Delete a specific container's home folder)"
        echo -e " 5) Return to Main Menu"
        echo -e "${BLUE}==============================================================${NC}"
        read -p "Select an option [1-5]: " storage_choice

        case "$storage_choice" in
            1)
                log_info "Running safe system prune..."
                podman system prune -f 2>&1 || log_warn "Prune completed with warnings."
                log_success "Safe prune completed."
                sleep 2
                ;;
            2)
                echo -e "\n${RED}WARNING: This removes all container images not currently used by a running container!${NC}"
                read -p "Are you sure you want to proceed? [y/N]: " confirm_agg
                if [[ "$confirm_agg" =~ ^[Yy]$ ]]; then
                    log_info "Running aggressive prune..."
                    podman system prune -a --volumes -f 2>&1 || log_warn "Prune completed with warnings."
                    log_success "Aggressive prune completed."
                else
                    log_info "Aggressive prune canceled."
                fi
                sleep 2
                ;;
            3)
                log_info "Clearing temporary socket and lock files..."
                rm -rf "/run/user/$USER_ID/containers" >/dev/null 2>&1 || true
                rm -rf "/run/user/$USER_ID/podman" >/dev/null 2>&1 || true
                podman system migrate >/dev/null 2>&1 || true
                log_success "Temporary locks cleared."
                sleep 2
                ;;
            4)
                if [ -d "$GOINFRE_PATH/homes" ]; then
                    echo -e "\nExisting container homes:"
                    ls -1 "$GOINFRE_PATH/homes" 2>/dev/null || echo "No container homes found."
                    echo ""
                    read -p "Enter name of container home to delete (or leave empty to cancel): " home_to_del
                    if [ -n "$home_to_del" ] && [ -d "$GOINFRE_PATH/homes/$home_to_del" ]; then
                        read -p "Are you sure you want to PERMANENTLY delete '$GOINFRE_PATH/homes/$home_to_del'? [y/N]: " confirm_del
                        if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                            rm -rf "$GOINFRE_PATH/homes/$home_to_del"
                            log_success "Deleted '$home_to_del' home directory."
                        else
                            log_info "Deletion canceled."
                        fi
                    else
                        log_info "No valid folder specified. Canceled."
                    fi
                else
                    log_info "No container homes directory found."
                fi
                sleep 2
                ;;
            5)
                break
                ;;
            *)
                log_error "Invalid selection. Please enter 1-5."
                sleep 1
                ;;
        esac
    done
}

# ==========================================
# UPDATE SYSTEM
# ==========================================

is_newer_version() {
    local current="$1"
    local remote="$2"
    [ "$current" = "$remote" ] && return 1
    local highest
    highest=$(printf '%s\n%s\n' "$current" "$remote" | sort -V | tail -n 1)
    [ "$highest" = "$remote" ]
}

check_for_updates() {
    local mode="${1:-manual}"
    
    if [ "$mode" == "manual" ]; then
        echo -e "\n${BLUE}==============================================================${NC}"
        echo -e "${BLUE}                   CHECKING FOR UPDATES                       ${NC}"
        echo -e "${BLUE}==============================================================${NC}"
    else
        echo -e "${BLUE}[*] Checking for updates...${NC}"
    fi

    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

    local tmp_file
    tmp_file=$(mktemp)

    # 4-second connect timeout prevents hanging when network is down or restricted
    if ! curl --connect-timeout 4 --max-time 15 -sSfL "$UPDATE_URL" -o "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        if [ "$mode" == "manual" ]; then
            log_error "Failed to fetch updates from GitHub (network or repository unreachable)."
            echo ""
            read -n 1 -s -r -p "Press any key to return to the menu..."
        fi
        return
    fi

    local remote_version
    remote_version=$(grep -m 1 '^SCRIPT_VERSION=' "$tmp_file" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | tr -d ' ' | tr -d '\r' || true)

    # Fallback to parse from header comment if older script version on GitHub
    if [ -z "$remote_version" ]; then
        remote_version=$(grep -m 1 -oE 'Project Zenith \(v[0-9.]+\)' "$tmp_file" | grep -oE '[0-9.]+' || true)
    fi

    if [ -z "$remote_version" ]; then
        rm -f "$tmp_file"
        if [ "$mode" == "manual" ]; then
            log_error "Could not parse version from the remote script."
            echo ""
            read -n 1 -s -r -p "Press any key to return to the menu..."
        fi
        return
    fi

    if is_newer_version "$SCRIPT_VERSION" "$remote_version"; then
        echo -e "\n${YELLOW}==============================================================${NC}"
        log_warn "A new version of Project Zenith (v$remote_version) is available!"
        log_info "You are currently running v$SCRIPT_VERSION"
        echo -e "${YELLOW}==============================================================${NC}\n"

        read -p "Would you like to update and restart now? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]] || [[ -z "$confirm" ]]; then
            # Validate that the downloaded script is a valid bash script
            if ! head -n 1 "$tmp_file" | grep -q "^#!/"; then
                log_error "Downloaded update file appears corrupted or invalid."
                rm -f "$tmp_file"
                sleep 2
                return
            fi

            if ! bash -n "$tmp_file" >/dev/null 2>&1; then
                log_error "Downloaded update contains syntax errors. Update canceled."
                rm -f "$tmp_file"
                sleep 2
                return
            fi

            if [ ! -w "$script_path" ]; then
                log_error "Cannot write to '$script_path'. Check file permissions."
                rm -f "$tmp_file"
                sleep 2
                return
            fi

            chmod +x "$tmp_file"
            if ! cp -f "$tmp_file" "$script_path"; then
                log_error "Failed to replace script file."
                rm -f "$tmp_file"
                sleep 2
                return
            fi
            rm -f "$tmp_file"

            log_success "Successfully updated to v$remote_version!"
            log_info "Restarting Project Zenith..."
            sleep 1
            exec "$script_path" "$@"
        else
            log_info "Update skipped."
            rm -f "$tmp_file"
            sleep 1
        fi
    else
        rm -f "$tmp_file"
        if [ "$mode" == "manual" ]; then
            log_success "Project Zenith is already running the latest version (v$SCRIPT_VERSION)."
            echo ""
            read -n 1 -s -r -p "Press any key to return to the menu..."
        fi
    fi
}

# ==========================================
# INITIALIZATION & MENU
# ==========================================

# Run silent auto-check on startup
check_for_updates "auto"

while true; do
    clear
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${GREEN} PROJECT ZENITH (v${SCRIPT_VERSION}) ${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo -e " 1) ${GREEN}Fresh Install${NC}      (Downloads and sets up everything)"
    echo -e " 2) ${GREEN}Create Container${NC}   (Interactive Distrobox creation)"
    echo -e " 3) ${YELLOW}Storage Manager${NC}    (View disk usage & clean cache)"
    echo -e " 4) ${BLUE}Check for Updates${NC}  (Check and install latest version)"
    echo -e " 5) ${RED}Repair Setup${NC}       (Fully resets and cleans old versions)"
    echo -e " 6) ${RED}Exit${NC}"
    echo -e "${BLUE}==========================================${NC}"
    read -p "Select an option [1-6]: " choice
    
    case "$choice" in
        1 ) run_installation; echo ""; read -n 1 -s -r -p "Press any key to return to the menu..." ;;
        2 ) run_create_container ;;
        3 ) run_storage_management ;;
        4 ) check_for_updates "manual" ;;
        5 ) run_repair; echo ""; read -n 1 -s -r -p "Press any key to return to the menu..." ;;
        6 ) log_info "Exiting..."; exit 0 ;;
        * ) log_error "Invalid selection. Please enter 1, 2, 3, 4, 5, or 6."; sleep 1 ;;
    esac
done
