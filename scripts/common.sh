#!/usr/bin/env bash
# Common helpers for NixOS NAS scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MACHINES_DIR="$PROJECT_DIR/machines"
SECRETS_DIR="$PROJECT_DIR/secrets"

separator() {
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
}

header() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"
}

confirm() {
    local prompt="$1"
    local response
    read -rp "$(echo -e "${YELLOW}${prompt}${NC} [y/N]: ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

# List available machines (directories under machines/ excluding example)
list_machines() {
    local machines=()
    for dir in "$MACHINES_DIR"/*/; do
        local name
        name=$(basename "$dir")
        [[ "$name" == "example" ]] && continue
        [[ -f "$dir/config.nix" ]] && machines+=("$name")
    done
    echo "${machines[@]}"
}

# Resolve and validate machine name from $1
# Sets: MACHINE, MACHINE_DIR, CONFIG_FILE, KEY_DIR
resolve_machine() {
    local requested="${1:-}"
    local available
    available=$(list_machines)

    if [[ -z "$requested" ]]; then
        echo -e "${RED}Error: No machine name specified${NC}"
        echo ""
        echo "Usage: $(basename "${BASH_SOURCE[1]}") <machine>"
        echo ""
        if [[ -n "$available" ]]; then
            echo "Available machines:"
            for m in $available; do
                echo "  - $m"
            done
        else
            echo "No machines configured. Run: ./scripts/setup.sh <machine-name>"
        fi
        exit 1
    fi

    MACHINE="$requested"
    MACHINE_DIR="$MACHINES_DIR/$MACHINE"
    CONFIG_FILE="$MACHINE_DIR/config.nix"
    KEY_DIR="$SECRETS_DIR/${MACHINE}-keys"

    if [[ ! -d "$MACHINE_DIR" ]]; then
        echo -e "${RED}Error: Machine '$MACHINE' not found${NC}"
        echo ""
        if [[ -n "$available" ]]; then
            echo "Available machines:"
            for m in $available; do
                echo "  - $m"
            done
        else
            echo "No machines configured. Run: ./scripts/setup.sh <machine-name>"
        fi
        exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: config.nix not found for machine '$MACHINE'${NC}"
        echo "Run first: ./scripts/setup.sh $MACHINE"
        exit 1
    fi
}

# Read NAS_IP, ADMIN_USER, HOSTNAME from CONFIG_FILE
read_config() {
    NAS_IP=$(grep 'nasIP' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
    ADMIN_USER=$(grep 'adminUser' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
    HOSTNAME=$(grep 'hostname' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

    SSH_OPTS="-o StrictHostKeyChecking=no"
    SSH_TARGET="$ADMIN_USER@$NAS_IP"
}

# Run a command on the NAS via SSH
nas() {
    ssh $SSH_OPTS "$SSH_TARGET" "$@"
}

# Run a command on the NAS via SSH with sudo
nas_sudo() {
    ssh $SSH_OPTS "$SSH_TARGET" "sudo $*"
}

# Check that the NAS is reachable and SSH works
check_connectivity() {
    echo -e "${YELLOW}Connecting to $MACHINE ($HOSTNAME at $NAS_IP)...${NC}"

    if ! ping -c 1 -W 3 "$NAS_IP" &>/dev/null; then
        echo -e "${RED}Cannot reach $NAS_IP${NC}"
        exit 1
    fi

    if ! ssh $SSH_OPTS -o ConnectTimeout=5 -o BatchMode=yes "$SSH_TARGET" "echo ok" &>/dev/null; then
        echo -e "${RED}Cannot connect via SSH to $SSH_TARGET${NC}"
        exit 1
    fi

    echo -e "${GREEN}Connected${NC}"
    echo
}
