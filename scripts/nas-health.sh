#!/usr/bin/env bash
#
# NAS Health Check - General system status
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

separator() {
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
}

header() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"
}

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

echo -e "${BOLD}Hostname:${NC} $(hostname)"
echo -e "${BOLD}Uptime:${NC}   $(uptime -p)"
echo -e "${BOLD}Kernel:${NC}   $(uname -r)"
echo -e "${BOLD}NixOS:${NC}    $(nixos-version)"
echo

separator

# ============================================================================
# CPU AND MEMORY
# ============================================================================

header "CPU AND MEMORY"

# CPU
echo -e "${BOLD}CPU:${NC}"
lscpu | grep -E "Model name|CPU\(s\)|CPU MHz" | sed 's/^/  /'
echo

# Load
echo -e "${BOLD}Load (1, 5, 15 min):${NC}"
cat /proc/loadavg | awk '{printf "  %s, %s, %s\n", $1, $2, $3}'
echo

# Memory
echo -e "${BOLD}Memory:${NC}"
free -h | grep -E "Mem|Swap" | awk '{printf "  %-6s Total: %6s  Used: %6s  Free: %6s\n", $1, $2, $3, $4}'
echo

separator

# ============================================================================
# STORAGE
# ============================================================================

header "STORAGE - INDIVIDUAL DISKS"

df -h /mnt/disk* 2>/dev/null | grep -v "Filesystem" || echo "  No disks mounted"
echo

header "STORAGE - MERGERFS POOL"

if mountpoint -q /mnt/storage; then
    df -h /mnt/storage | grep -v "Filesystem"
    echo

    # Detailed breakdown
    echo -e "${BOLD}Breakdown by directory:${NC}"
    du -sh /mnt/storage/* 2>/dev/null | sort -h | awk '{printf "  %-30s %s\n", $2, $1}' || echo "  No data"
else
    echo -e "${RED}  /mnt/storage IS NOT MOUNTED${NC}"
fi

echo

header "STORAGE - SNAPRAID PARITY"

if mountpoint -q /mnt/parity; then
    df -h /mnt/parity | grep -v "Filesystem"
else
    echo -e "${RED}  /mnt/parity IS NOT MOUNTED${NC}"
fi

echo

separator

# ============================================================================
# SMART
# ============================================================================

header "DISK SMART STATUS"

for disk in /dev/sd[abc]; do
    if [ -b "$disk" ]; then
        echo -e "${BOLD}Disk: $disk${NC}"

        # Model
        model=$(sudo smartctl -i "$disk" 2>/dev/null | grep "Device Model" | cut -d: -f2 | xargs)
        serial=$(sudo smartctl -i "$disk" 2>/dev/null | grep "Serial Number" | cut -d: -f2 | xargs)

        echo "  Model:  $model"
        echo "  Serial: $serial"

        # SMART status
        if sudo smartctl -H "$disk" 2>/dev/null | grep -q "PASSED"; then
            echo -e "  Status: ${GREEN}PASSED${NC}"
        else
            echo -e "  Status: ${RED}FAILED${NC}"
        fi

        # Temperature
        temp=$(sudo smartctl -A "$disk" 2>/dev/null | grep "Temperature_Celsius" | awk '{print $10}')
        if [ -n "$temp" ]; then
            if [ "$temp" -lt 45 ]; then
                echo -e "  Temp:   ${GREEN}${temp}C${NC}"
            elif [ "$temp" -lt 55 ]; then
                echo -e "  Temp:   ${YELLOW}${temp}C${NC}"
            else
                echo -e "  Temp:   ${RED}${temp}C${NC}"
            fi
        fi

        # Power on hours
        hours=$(sudo smartctl -A "$disk" 2>/dev/null | grep "Power_On_Hours" | awk '{print $10}')
        if [ -n "$hours" ]; then
            days=$((hours / 24))
            echo "  Hours:  $hours ($days days)"
        fi

        echo
    fi
done

separator

# ============================================================================
# SNAPRAID
# ============================================================================

header "SNAPRAID"

if command -v snapraid &> /dev/null; then
    echo -e "${BOLD}SnapRAID Status:${NC}"
    echo

    # Run snapraid status and capture output
    if sudo snapraid status 2>&1 | grep -q "No status file found"; then
        echo -e "  ${YELLOW}SnapRAID has not been synced yet${NC}"
        echo "  Run: sudo snapraid sync"
    else
        sudo snapraid status 2>&1 | head -20 | sed 's/^/  /'
    fi
else
    echo -e "${RED}  SnapRAID is not installed${NC}"
fi

echo

# Last sync
if [ -f /var/log/snapraid-sync.log ]; then
    echo -e "${BOLD}Last sync:${NC}"
    tail -5 /var/log/snapraid-sync.log | sed 's/^/  /'
else
    echo "  No sync logs"
fi

echo

separator

# ============================================================================
# SERVICES
# ============================================================================

header "SERVICES"

check_service() {
    local service=$1
    local name=$2

    if systemctl is-active --quiet "$service"; then
        echo -e "  ${GREEN}OK${NC} $name: ${GREEN}active${NC}"
    else
        echo -e "  ${RED}X${NC} $name: ${RED}inactive${NC}"
    fi
}

check_service "smbd" "Samba"
check_service "nfs-server" "NFS"
check_service "sshd" "SSH"
check_service "smartd" "SMART Monitoring"

echo

# SnapRAID timers
echo -e "${BOLD}SnapRAID Timers:${NC}"
systemctl list-timers --no-pager | grep snapraid | awk '{printf "  %-30s %s %s\n", $NF, $1, $2}' || echo "  Not configured"

echo

separator

# ============================================================================
# NETWORK
# ============================================================================

header "NETWORK"

# Main interface
default_iface=$(ip route | grep default | awk '{print $5}' | head -1)

if [ -n "$default_iface" ]; then
    echo -e "${BOLD}Main interface:${NC} $default_iface"

    # IP
    ip_addr=$(ip addr show "$default_iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
    echo -e "${BOLD}IP:${NC}             $ip_addr"

    # Gateway
    gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    echo -e "${BOLD}Gateway:${NC}        $gateway"

    # DNS
    echo -e "${BOLD}DNS:${NC}"
    grep nameserver /etc/resolv.conf | awk '{print "  " $2}'
else
    echo -e "${RED}No network interface detected${NC}"
fi

echo

# Open ports
echo -e "${BOLD}Listening ports:${NC}"
sudo ss -tuln | grep LISTEN | awk '{printf "  %-8s %-25s\n", $1, $5}' | sort -u

echo

separator

# ============================================================================
# SUMMARY
# ============================================================================

header "SUMMARY"

# Calculate overall status
errors=0
warnings=0

# Check mounted disks
if ! mountpoint -q /mnt/storage; then
    ((errors++))
fi

# Check SMART
for disk in /dev/sd[abc]; do
    if [ -b "$disk" ]; then
        if ! sudo smartctl -H "$disk" 2>/dev/null | grep -q "PASSED"; then
            ((errors++))
        fi
    fi
done

# Check services
for service in smbd nfs-server sshd; do
    if ! systemctl is-active --quiet "$service"; then
        ((warnings++))
    fi
done

# Show summary
if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
    echo -e "${GREEN}${BOLD}OK - System OK - No problems detected${NC}"
elif [ $errors -eq 0 ]; then
    echo -e "${YELLOW}${BOLD}Warning - System OK - $warnings warnings${NC}"
else
    echo -e "${RED}${BOLD}X - Problems detected - $errors errors, $warnings warnings${NC}"
fi

echo
separator
echo

echo -e "${CYAN}For more details:${NC}"
echo "  - View logs:        journalctl -xe"
echo "  - SMART status:     sudo smartctl -a /dev/sdX"
echo "  - SnapRAID status:  sudo snapraid status"
echo "  - MergerFS disks:   df -h /mnt/disk*"
echo

exit $errors
