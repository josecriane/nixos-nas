#!/usr/bin/env bash
#
# SnapRAID Status - Detailed SnapRAID verification
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

# Check that we are root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    echo "Use: sudo $0"
    exit 1
fi

# Banner
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║              SnapRAID - Detailed Status                       ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

EOF

# ============================================================================
# VERIFY INSTALLATION
# ============================================================================

if ! command -v snapraid &> /dev/null; then
    echo -e "${RED}SnapRAID is not installed${NC}"
    exit 1
fi

# ============================================================================
# GENERAL STATUS
# ============================================================================

header "GENERAL STATUS"

snapraid status

separator

# ============================================================================
# DIFFERENCES SINCE LAST SYNC
# ============================================================================

header "DIFFERENCES SINCE LAST SYNC"

echo -e "${YELLOW}Running diff (may take a moment)...${NC}"
echo

snapraid diff

separator

# ============================================================================
# LOG ANALYSIS
# ============================================================================

header "SYNC HISTORY"

if [ -f /var/log/snapraid-sync.log ]; then
    echo -e "${BOLD}Last 5 syncs:${NC}"
    echo

    grep -E "\[.*\] (Starting|completed|failed)" /var/log/snapraid-sync.log 2>/dev/null | tail -10 | while read line; do
        if echo "$line" | grep -q "completed successfully"; then
            echo -e "  ${GREEN}OK${NC} $line"
        elif echo "$line" | grep -q "failed"; then
            echo -e "  ${RED}X${NC} $line"
        else
            echo "  $line"
        fi
    done
else
    echo "  No sync logs available"
fi

echo

header "SCRUB HISTORY"

if [ -f /var/log/snapraid-scrub.log ]; then
    echo -e "${BOLD}Last 5 scrubs:${NC}"
    echo

    grep -E "\[.*\] (Starting|completed|failed)" /var/log/snapraid-scrub.log 2>/dev/null | tail -10 | while read line; do
        if echo "$line" | grep -q "completed successfully"; then
            echo -e "  ${GREEN}OK${NC} $line"
        elif echo "$line" | grep -q "failed"; then
            echo -e "  ${RED}X${NC} $line"
        else
            echo "  $line"
        fi
    done
else
    echo "  No scrub logs available"
fi

echo

separator

# ============================================================================
# DISK SMART
# ============================================================================

header "DISK SMART STATUS"

snapraid smart || echo -e "${YELLOW}Could not run SMART check${NC}"

separator

# ============================================================================
# SYSTEMD TIMERS
# ============================================================================

header "SYSTEMD TIMERS"

echo -e "${BOLD}Timer status:${NC}"
echo

systemctl list-timers --no-pager --all | grep -E "NEXT|snapraid" || echo "No timers configured"

echo
echo -e "${BOLD}Service status:${NC}"
echo

for service in snapraid-sync snapraid-scrub; do
    if systemctl list-unit-files | grep -q "$service.service"; then
        status=$(systemctl is-active "$service.service" 2>/dev/null || echo "inactive")
        if [ "$status" = "active" ]; then
            echo -e "  ${GREEN}OK${NC} $service: ${GREEN}$status${NC}"
        else
            echo -e "  ${BLUE}o${NC} $service: $status"
        fi
    fi
done

echo

separator

# ============================================================================
# CONTENT FILES
# ============================================================================

header "CONTENT FILES"

echo -e "${BOLD}Content file locations:${NC}"
echo

# Find content files
for location in /var/snapraid/snapraid.content /mnt/disk*/snapraid.content; do
    if [ -f "$location" ]; then
        size=$(du -h "$location" | cut -f1)
        mtime=$(stat -c %y "$location" | cut -d'.' -f1)
        echo -e "  ${GREEN}OK${NC} $location"
        echo "    Size: $size"
        echo "    Modified: $mtime"
    else
        echo -e "  ${YELLOW}X${NC} $location (does not exist)"
    fi
done

echo

separator

# ============================================================================
# CONFIGURATION
# ============================================================================

header "CURRENT CONFIGURATION"

if [ -f /etc/snapraid.conf ]; then
    echo -e "${BOLD}Configured disks:${NC}"
    echo
    grep -E "^(parity|data)" /etc/snapraid.conf | sed 's/^/  /'
    echo

    echo -e "${BOLD}Exclusions:${NC}"
    echo
    grep -E "^exclude" /etc/snapraid.conf | sed 's/^/  /' || echo "  No exclusions"
else
    echo -e "${RED}Configuration file not found: /etc/snapraid.conf${NC}"
fi

echo

separator

# ============================================================================
# RECOMMENDATIONS
# ============================================================================

header "RECOMMENDATIONS"

# Calculate days since last sync
if [ -f /var/log/snapraid-sync.log ]; then
    last_sync=$(grep "completed successfully" /var/log/snapraid-sync.log | tail -1 | grep -oP '\[\K[^\]]+' || echo "")

    if [ -n "$last_sync" ]; then
        last_sync_ts=$(date -d "$last_sync" +%s 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        days_since=$((( now_ts - last_sync_ts ) / 86400))

        if [ $days_since -gt 7 ]; then
            echo -e "${RED}Warning${NC} It has been $days_since days since the last successful sync"
            echo "  Recommendation: Run sync soon"
            echo "  Command: sudo snapraid sync"
            echo
        elif [ $days_since -gt 3 ]; then
            echo -e "${YELLOW}Warning${NC} It has been $days_since days since the last sync"
            echo "  Consider running sync"
            echo
        else
            echo -e "${GREEN}OK${NC} Last sync $days_since days ago - OK"
            echo
        fi
    fi
fi

# Check pending differences
diff_output=$(snapraid diff 2>&1 || true)
if echo "$diff_output" | grep -q "equal\|No differences"; then
    echo -e "${GREEN}OK${NC} No pending differences to sync"
else
    # Count changes
    added=$(echo "$diff_output" | grep -c "add" || echo 0)
    removed=$(echo "$diff_output" | grep -c "remove" || echo 0)
    updated=$(echo "$diff_output" | grep -c "update" || echo 0)

    if [ $added -gt 0 ] || [ $removed -gt 0 ] || [ $updated -gt 0 ]; then
        echo -e "${YELLOW}Warning${NC} There are pending changes:"
        [ $added -gt 0 ] && echo "  - Files added: $added"
        [ $removed -gt 0 ] && echo "  - Files removed: $removed"
        [ $updated -gt 0 ] && echo "  - Files modified: $updated"
        echo
        echo "  Recommendation: Run sync to protect the changes"
        echo "  Command: sudo snapraid sync"
    fi
fi

echo

separator
echo

echo -e "${CYAN}Useful commands:${NC}"
echo "  - Sync:              sudo snapraid sync"
echo "  - Verify integrity:  sudo snapraid scrub -p 10"
echo "  - View differences:  sudo snapraid diff"
echo "  - Recover file:      sudo snapraid fix -f /path/to/file"
echo "  - View help:         cat /etc/nixos-nas/snapraid-commands.txt"
echo
