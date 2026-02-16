#!/usr/bin/env bash
#
# SnapRAID Status - Detailed SnapRAID verification (runs remotely via SSH)
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

nas_sudo() {
    ssh $SSH_OPTS "$SSH_TARGET" "sudo $*"
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

# Check snapraid on NAS
if ! nas "command -v snapraid" &>/dev/null; then
    echo -e "${RED}SnapRAID is not installed on the NAS${NC}"
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
# GENERAL STATUS
# ============================================================================

header "GENERAL STATUS"

nas_sudo "snapraid status"

separator

# ============================================================================
# DIFFERENCES SINCE LAST SYNC
# ============================================================================

header "DIFFERENCES SINCE LAST SYNC"

echo -e "${YELLOW}Running diff (may take a moment)...${NC}"
echo

nas_sudo "snapraid diff"

separator

# ============================================================================
# LOG ANALYSIS
# ============================================================================

header "SYNC HISTORY"

nas "
if [ -f /var/log/snapraid-sync.log ]; then
    echo 'Last syncs:'
    echo
    grep -E '\[.*\] (Starting|completed|failed)' /var/log/snapraid-sync.log 2>/dev/null | tail -10
else
    echo '  No sync logs available'
fi
"

echo

header "SCRUB HISTORY"

nas "
if [ -f /var/log/snapraid-scrub.log ]; then
    echo 'Last scrubs:'
    echo
    grep -E '\[.*\] (Starting|completed|failed)' /var/log/snapraid-scrub.log 2>/dev/null | tail -10
else
    echo '  No scrub logs available'
fi
"

echo

separator

# ============================================================================
# DISK SMART
# ============================================================================

header "DISK SMART STATUS"

nas_sudo "snapraid smart" || echo -e "${YELLOW}Could not run SMART check${NC}"

separator

# ============================================================================
# SYSTEMD TIMERS
# ============================================================================

header "SYSTEMD TIMERS"

echo -e "${BOLD}Timer status:${NC}"
echo

nas "systemctl list-timers --no-pager --all | grep -E 'NEXT|snapraid'" || echo "No timers configured"

echo
echo -e "${BOLD}Service status:${NC}"
echo

nas "
for service in snapraid-sync snapraid-scrub; do
    if systemctl list-unit-files | grep -q \"\$service.service\"; then
        status=\$(systemctl is-active \"\$service.service\" 2>/dev/null || echo 'inactive')
        echo \"  \$service: \$status\"
    fi
done
"

echo

separator

# ============================================================================
# CONTENT FILES
# ============================================================================

header "CONTENT FILES"

echo -e "${BOLD}Content file locations:${NC}"
echo

nas "
for location in /var/snapraid/snapraid.content /mnt/disk*/snapraid.content; do
    if [ -f \"\$location\" ]; then
        size=\$(du -h \"\$location\" | cut -f1)
        mtime=\$(stat -c %y \"\$location\" | cut -d'.' -f1)
        echo \"  OK \$location\"
        echo \"    Size: \$size\"
        echo \"    Modified: \$mtime\"
    else
        echo \"  X \$location (does not exist)\"
    fi
done
"

echo

separator

# ============================================================================
# CONFIGURATION
# ============================================================================

header "CURRENT CONFIGURATION"

nas "
if [ -f /etc/snapraid.conf ]; then
    echo 'Configured disks:'
    echo
    grep -E '^(parity|data)' /etc/snapraid.conf | sed 's/^/  /'
    echo
    echo 'Exclusions:'
    echo
    grep -E '^exclude' /etc/snapraid.conf | sed 's/^/  /' || echo '  No exclusions'
else
    echo 'Configuration file not found: /etc/snapraid.conf'
fi
"

echo

separator

# ============================================================================
# RECOMMENDATIONS
# ============================================================================

header "RECOMMENDATIONS"

nas_sudo "
# Check pending differences
diff_output=\$(snapraid diff 2>&1 || true)
if echo \"\$diff_output\" | grep -q 'equal\|No differences'; then
    echo 'OK - No pending differences to sync'
else
    added=\$(echo \"\$diff_output\" | grep -c 'add' || echo 0)
    removed=\$(echo \"\$diff_output\" | grep -c 'remove' || echo 0)
    updated=\$(echo \"\$diff_output\" | grep -c 'update' || echo 0)

    if [ \$added -gt 0 ] || [ \$removed -gt 0 ] || [ \$updated -gt 0 ]; then
        echo 'Warning - There are pending changes:'
        [ \$added -gt 0 ] && echo \"  - Files added: \$added\"
        [ \$removed -gt 0 ] && echo \"  - Files removed: \$removed\"
        [ \$updated -gt 0 ] && echo \"  - Files modified: \$updated\"
        echo
        echo '  Recommendation: Run sync to protect the changes'
        echo '  Command: sudo snapraid sync'
    fi
fi
"

echo

separator
echo

echo -e "${CYAN}Useful commands (run on NAS via ssh $SSH_TARGET):${NC}"
echo "  - Sync:              sudo snapraid sync"
echo "  - Verify integrity:  sudo snapraid scrub -p 10"
echo "  - View differences:  sudo snapraid diff"
echo "  - Recover file:      sudo snapraid fix -f /path/to/file"
echo
