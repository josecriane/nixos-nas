#!/usr/bin/env bash
#
# NAS Health Check - General system status (runs remotely via SSH)
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.nix"

separator() {
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
}

header() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"
}

# ============================================================================
# CHECK LOCAL CONFIGURATION
# ============================================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: config.nix not found${NC}"
    echo "Run first: ./scripts/setup.sh"
    exit 1
fi

# Read connection details from config.nix
NAS_IP=$(grep 'nasIP' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
ADMIN_USER=$(grep 'adminUser' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
HOSTNAME=$(grep 'hostname' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

SSH_OPTS="-o StrictHostKeyChecking=no"
SSH_TARGET="$ADMIN_USER@$NAS_IP"

# Helper to run commands on the NAS
nas() {
    ssh $SSH_OPTS "$SSH_TARGET" "$@"
}

# ============================================================================
# CONNECTIVITY CHECK
# ============================================================================

echo -e "${YELLOW}Connecting to NAS ($HOSTNAME at $NAS_IP)...${NC}"

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

# Banner
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║              NixOS NAS - Health Check                         ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

EOF

# ============================================================================
# SYSTEM
# ============================================================================

header "SYSTEM INFORMATION"

nas '
echo "Hostname: $(hostname)"
echo "Uptime:   $(uptime | sed "s/.*up /up /;s/,  load.*//")"
echo "Kernel:   $(uname -r)"
echo "NixOS:    $(nixos-version)"
'

echo

separator

# ============================================================================
# CPU AND MEMORY
# ============================================================================

header "CPU AND MEMORY"

nas '
echo "CPU:"
lscpu | grep -E "Model name|CPU\(s\)|CPU MHz" | sed "s/^/  /"
echo
echo "Load (1, 5, 15 min):"
awk "{printf \"  %s, %s, %s\n\", \$1, \$2, \$3}" /proc/loadavg
echo
echo "Memory:"
free -h | grep -E "Mem|Swap" | awk "{printf \"  %-6s Total: %6s  Used: %6s  Free: %6s\n\", \$1, \$2, \$3, \$4}"
'

echo

separator

# ============================================================================
# STORAGE
# ============================================================================

header "STORAGE - INDIVIDUAL DISKS"

nas "df -h /mnt/disk* 2>/dev/null | grep -v 'Filesystem'" || echo "  No disks mounted"

echo

header "STORAGE - MERGERFS POOL"

nas '
if mountpoint -q /mnt/storage; then
    df -h /mnt/storage | grep -v "Filesystem"
    echo
    echo "Breakdown by directory:"
    du -sh /mnt/storage/* 2>/dev/null | sort -h | awk "{printf \"  %-30s %s\n\", \$2, \$1}" || echo "  No data"
else
    echo "  /mnt/storage IS NOT MOUNTED"
fi
'

echo

separator

# ============================================================================
# SMART
# ============================================================================

header "DISK SMART STATUS"

nas '
for disk in /dev/sd[a-z]; do
    if [ -b "$disk" ]; then
        info=$(sudo smartctl -i "$disk" 2>/dev/null)
        model=$(echo "$info" | grep "Device Model" | cut -d: -f2 | xargs)

        # Skip drives without SMART support (USB sticks, etc.)
        if [ -z "$model" ]; then
            continue
        fi

        echo "Disk: $disk"
        serial=$(echo "$info" | grep "Serial Number" | cut -d: -f2 | xargs)
        echo "  Model:  $model"
        echo "  Serial: $serial"

        if sudo smartctl -H "$disk" 2>/dev/null | grep -q "PASSED"; then
            echo "  Status: PASSED"
        else
            echo "  Status: FAILED"
        fi

        attrs=$(sudo smartctl -A "$disk" 2>/dev/null)

        temp=$(echo "$attrs" | grep "Temperature_Celsius" | awk "{print \$10}" | grep -o "^[0-9]*")
        if [ -n "$temp" ]; then
            echo "  Temp:   ${temp}C"
        fi

        hours=$(echo "$attrs" | grep "Power_On_Hours" | awk "{print \$10}" | grep -o "^[0-9]*")
        if [ -n "$hours" ]; then
            days=$((hours / 24))
            echo "  Hours:  $hours ($days days)"
        fi

        echo
    fi
done
'

separator

# ============================================================================
# SERVICES
# ============================================================================

header "SERVICES"

nas '
for pair in "samba-smbd:Samba" "nfs-server:NFS" "sshd:SSH" "smartd:SMART Monitoring" "cockpit.socket:Cockpit" "filebrowser:File Browser"; do
    service=${pair%%:*}
    name=${pair##*:}
    if systemctl is-active --quiet "$service"; then
        echo "  OK $name: active"
    else
        echo "  X  $name: inactive"
    fi
done
'

echo

separator

# ============================================================================
# NETWORK
# ============================================================================

header "NETWORK"

nas '
default_iface=$(ip route | grep default | awk "{print \$5}" | head -1)
if [ -n "$default_iface" ]; then
    echo "Main interface: $default_iface"
    ip_addr=$(ip addr show "$default_iface" 2>/dev/null | grep "inet " | awk "{print \$2}" | cut -d"/" -f1)
    echo "IP:             $ip_addr"
    gateway=$(ip route | grep default | awk "{print \$3}" | head -1)
    echo "Gateway:        $gateway"
    echo "DNS:"
    grep nameserver /etc/resolv.conf | awk "{print \"  \" \$2}"
else
    echo "No network interface detected"
fi
'

echo

echo -e "${BOLD}Listening ports:${NC}"
nas "ss -tuln | grep LISTEN | awk '{printf \"  %-8s %-25s\n\", \$1, \$5}' | sort -u"

echo

separator

# ============================================================================
# SUMMARY
# ============================================================================

header "SUMMARY"

nas '
errors=0
warnings=0

# Check mounted disks
if ! mountpoint -q /mnt/storage; then
    errors=$((errors + 1))
fi

# Check SMART (skip drives without SMART support)
for disk in /dev/sd[a-z]; do
    if [ -b "$disk" ]; then
        model=$(sudo smartctl -i "$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs)
        if [ -n "$model" ]; then
            if ! sudo smartctl -H "$disk" 2>/dev/null | grep -q "PASSED"; then
                errors=$((errors + 1))
            fi
        fi
    fi
done

# Check services
for service in samba-smbd nfs-server sshd; do
    if ! systemctl is-active --quiet "$service"; then
        warnings=$((warnings + 1))
    fi
done

if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
    echo "OK - System OK - No problems detected"
elif [ $errors -eq 0 ]; then
    echo "Warning - System OK - $warnings warnings"
else
    echo "X - Problems detected - $errors errors, $warnings warnings"
fi
'

echo
separator
echo

echo -e "${CYAN}For more details (run via ssh $SSH_TARGET):${NC}"
echo "  - View logs:        journalctl -xe"
echo "  - SMART status:     sudo smartctl -a /dev/sdX"
echo "  - MergerFS disks:   df -h /mnt/disk*"
echo
