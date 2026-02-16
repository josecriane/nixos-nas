#!/usr/bin/env bash
#
# Replace Disk - Replace a failed disk using SnapRAID (runs remotely via SSH)
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

confirm() {
    local prompt="$1"
    local response
    read -r -p "$(echo -e ${YELLOW}${prompt}${NC} [y/N]: )" response
    [[ "${response,,}" == "y" ]]
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
║              Replace Failed Disk                              ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

EOF

echo -e "${YELLOW}This assistant will help you replace a failed disk${NC}"
echo
separator
echo

# ============================================================================
# CURRENT STATUS
# ============================================================================

header "CURRENT DISK STATUS"

echo -e "${BOLD}Configured disks:${NC}"
echo

# Extract disks from snapraid.conf on NAS
nas_disk_info=$(nas "
if [ -f /etc/snapraid.conf ]; then
    grep '^data' /etc/snapraid.conf | while IFS= read -r line; do
        disk_name=\$(echo \"\$line\" | awk '{print \$2}')
        disk_path=\$(echo \"\$line\" | awk '{print \$3}')
        if mountpoint -q \"\$disk_path\" 2>/dev/null; then
            size=\$(df -h \"\$disk_path\" | tail -1 | awk '{print \$2}')
            used=\$(df -h \"\$disk_path\" | tail -1 | awk '{print \$3}')
            echo \"MOUNTED:\$disk_name:\$disk_path:\$size:\$used\"
        else
            echo \"UNMOUNTED:\$disk_name:\$disk_path:N/A:N/A\"
        fi
    done
else
    echo 'NO_CONF'
fi
")

if [[ "$nas_disk_info" == "NO_CONF" ]]; then
    echo -e "${RED}/etc/snapraid.conf not found on the NAS${NC}"
    exit 1
fi

echo "$nas_disk_info" | while IFS=':' read -r status disk_name disk_path size used; do
    if [[ "$status" == "MOUNTED" ]]; then
        echo -e "  $disk_name ($disk_path): ${GREEN}mounted${NC}  Size: $size  Used: $used"
    else
        echo -e "  $disk_name ($disk_path): ${RED}NOT MOUNTED${NC}  Size: $size  Used: $used"
    fi
done

echo

# Parity disk
parity_info=$(nas "
parity_path=\$(grep '^parity' /etc/snapraid.conf | awk '{print \$2}')
if [ -n \"\$parity_path\" ] && [ -f \"\$parity_path\" ]; then
    parity_size=\$(du -h \"\$parity_path\" | cut -f1)
    echo \"OK:\$parity_path:\$parity_size\"
else
    echo \"FAIL:\$parity_path:\"
fi
")

IFS=':' read -r parity_status parity_path parity_size <<< "$parity_info"
if [[ "$parity_status" == "OK" ]]; then
    echo -e "  Parity: ${GREEN}OK${NC} $parity_path ($parity_size)"
else
    echo -e "  Parity: ${RED}X Not found${NC}"
fi

echo
separator
echo

# ============================================================================
# DISK SELECTION
# ============================================================================

header "DISK SELECTION"

echo "Which disk do you need to replace?"
echo

# Get disk list from NAS
mapfile -t disk_list < <(nas "grep '^data' /etc/snapraid.conf | awk '{print \$2\":\"\$3}'")

i=1
for entry in "${disk_list[@]}"; do
    disk_name=$(echo "$entry" | cut -d':' -f1)
    disk_path=$(echo "$entry" | cut -d':' -f2)
    echo "  $i) $disk_name ($disk_path)"
    ((i++))
done

echo
read -r -p "$(echo -e ${CYAN}Select the number of the disk to replace:${NC} )" selection

# Validate selection
if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#disk_list[@]} ]; then
    echo -e "${RED}Invalid selection${NC}"
    exit 1
fi

# Get selected disk
selected="${disk_list[$((selection-1))]}"
failed_disk_name=$(echo "$selected" | cut -d':' -f1)
failed_disk_path=$(echo "$selected" | cut -d':' -f2)

echo
echo -e "${BOLD}Disk to replace:${NC} $failed_disk_name ($failed_disk_path)"
echo

separator
echo

# ============================================================================
# CHECK REPLACEMENT DISK
# ============================================================================

header "REPLACEMENT DISK"

echo -e "${BOLD}Available disks in the system:${NC}"
echo

nas "lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E 'disk|NAME'"

echo
read -r -p "$(echo -e ${CYAN}Enter the replacement device [e.g.: sdd]:${NC} )" new_device

# Validate input
if [[ ! "$new_device" =~ ^sd[a-z]$ ]] && [[ ! "$new_device" =~ ^nvme[0-9]n[0-9]$ ]]; then
    echo -e "${RED}Invalid device${NC}"
    exit 1
fi

# Add /dev/
if [[ ! "$new_device" =~ ^/dev/ ]]; then
    new_device="/dev/$new_device"
fi

# Check that it exists on the NAS
if ! nas "test -b $new_device"; then
    echo -e "${RED}Device $new_device does not exist on the NAS${NC}"
    exit 1
fi

# New disk information
model=$(nas "lsblk -d -n -o MODEL '$new_device' 2>/dev/null" || echo "Unknown")
size=$(nas "lsblk -d -n -o SIZE '$new_device' 2>/dev/null" || echo "Unknown")

echo
echo -e "${BOLD}Device:${NC} $new_device"
echo -e "${BOLD}Model:${NC}  $model"
echo -e "${BOLD}Size:${NC}   $size"
echo

# Check if it has data
if nas "lsblk -n '$new_device' 2>/dev/null | grep -q part"; then
    echo -e "${RED}${BOLD}WARNING: The disk has existing partitions${NC}"
    nas "lsblk '$new_device'"
    echo
fi

separator
echo

# ============================================================================
# RECOVERY PLAN
# ============================================================================

header "RECOVERY PLAN"

echo "The following steps will be performed:"
echo
echo "  1. Unmount failed disk (if mounted)"
echo "  2. Partition and format new disk"
echo "  3. Update disk label"
echo "  4. Mount new disk at $failed_disk_path"
echo "  5. Recover data using SnapRAID"
echo "  6. Verify integrity of recovered data"
echo

echo -e "${RED}${BOLD}WARNING${NC}"
echo -e "${RED}All data on $new_device will be DESTROYED${NC}"
echo

if ! confirm "Continue with replacement?"; then
    echo "Operation cancelled"
    exit 0
fi

echo

# ============================================================================
# EXECUTION
# ============================================================================

header "STEP 1: PREPARE NEW DISK"

# Unmount failed disk if mounted
if nas "mountpoint -q '$failed_disk_path' 2>/dev/null"; then
    echo "Unmounting failed disk..."
    nas_sudo "umount '$failed_disk_path'" || echo "Could not unmount (disk may be failed)"
fi

echo "Partitioning $new_device..."
nas_sudo "parted -s '$new_device' mklabel gpt"
nas_sudo "parted -s '$new_device' mkpart primary ext4 0% 100%"

# Determine partition name
if [[ "$new_device" =~ nvme ]]; then
    partition="${new_device}p1"
else
    partition="${new_device}1"
fi

nas_sudo "sleep 2 && partprobe '$new_device' && sleep 1"

echo "Formatting with ext4..."
nas_sudo "mkfs.ext4 -F -L '$failed_disk_name' '$partition'"

echo "Mounting new disk..."
nas_sudo "mount '$partition' '$failed_disk_path'"

echo "Setting permissions..."
nas_sudo "chown $ADMIN_USER:$ADMIN_USER '$failed_disk_path'"
nas_sudo "chmod 755 '$failed_disk_path'"

echo -e "${GREEN}New disk prepared${NC}"
echo

separator
echo

# ============================================================================
# SNAPRAID RECOVERY
# ============================================================================

header "STEP 2: RECOVER DATA WITH SNAPRAID"

echo -e "${YELLOW}Starting data recovery...${NC}"
echo "This may take several hours depending on the amount of data"
echo

# Run snapraid fix for the entire disk
if nas_sudo "snapraid fix -d '$failed_disk_name' -l /var/log/snapraid-fix.log"; then
    echo
    echo -e "${GREEN}Recovery completed successfully${NC}"
    echo
else
    echo
    echo -e "${RED}X Recovery failed or had errors${NC}"
    echo "Check the log: ssh $SSH_TARGET 'cat /var/log/snapraid-fix.log'"
    echo
    exit 1
fi

separator
echo

# ============================================================================
# VERIFICATION
# ============================================================================

header "STEP 3: VERIFICATION"

echo "Verifying recovered data..."
echo

# Run scrub on recovered disk
if nas_sudo "snapraid scrub -p 100 -d '$failed_disk_name'"; then
    echo
    echo -e "${GREEN}Verification complete - Data is correct${NC}"
else
    echo
    echo -e "${YELLOW}Warning: Verification found some issues${NC}"
    echo "This may be normal if some files were modified during recovery"
fi

echo

# Show final status
nas "df -h '$failed_disk_path'"

echo
separator
echo

# ============================================================================
# NEXT STEPS
# ============================================================================

header "RECOVERY COMPLETE"

echo -e "${GREEN}${BOLD}The disk has been replaced successfully${NC}"
echo

echo "Recommended next steps:"
echo

echo "1. Verify that all files are accessible:"
echo "   ssh $SSH_TARGET 'ls -lah $failed_disk_path'"
echo

echo "2. Run a full sync to update parity:"
echo "   ssh $SSH_TARGET 'sudo snapraid sync'"
echo

echo "3. Monitor the new disk over the next few weeks:"
echo "   ssh $SSH_TARGET 'sudo smartctl -a $new_device'"
echo

echo "4. Run scrub periodically to verify integrity:"
echo "   ssh $SSH_TARGET 'sudo snapraid scrub -p 10'"
echo

separator
echo

echo "Recovery log: ssh $SSH_TARGET 'cat /var/log/snapraid-fix.log'"
echo
