#!/usr/bin/env bash
#
# Replace Disk - Replace a failed disk using SnapRAID
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

confirm() {
    local prompt="$1"
    local response
    read -r -p "$(echo -e ${YELLOW}${prompt}${NC} [y/N]: )" response
    [[ "${response,,}" == "y" ]]
}

# Check that we are root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root${NC}"
    echo "Use: sudo $0"
    exit 1
fi

# Check snapraid
if ! command -v snapraid &> /dev/null; then
    echo -e "${RED}SnapRAID is not installed${NC}"
    exit 1
fi

# Banner
clear
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

# Extract disks from snapraid.conf
if [ -f /etc/snapraid.conf ]; then
    grep "^data" /etc/snapraid.conf | while IFS= read -r line; do
        disk_name=$(echo "$line" | awk '{print $2}')
        disk_path=$(echo "$line" | awk '{print $3}')

        # Check if mounted
        if mountpoint -q "$disk_path" 2>/dev/null; then
            status="${GREEN}mounted${NC}"
            size=$(df -h "$disk_path" | tail -1 | awk '{print $2}')
            used=$(df -h "$disk_path" | tail -1 | awk '{print $3}')
        else
            status="${RED}NOT MOUNTED${NC}"
            size="N/A"
            used="N/A"
        fi

        echo -e "  $disk_name ($disk_path): $status  Size: $size  Used: $used"
    done
else
    echo -e "${RED}/etc/snapraid.conf not found${NC}"
    exit 1
fi

echo

# Parity disk
parity_path=$(grep "^parity" /etc/snapraid.conf | awk '{print $2}')
if [ -n "$parity_path" ] && [ -f "$parity_path" ]; then
    parity_size=$(du -h "$parity_path" | cut -f1)
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

# List available disks
disk_list=()
i=1
grep "^data" /etc/snapraid.conf | while IFS= read -r line; do
    disk_name=$(echo "$line" | awk '{print $2}')
    disk_path=$(echo "$line" | awk '{print $3}')
    disk_list+=("$disk_name:$disk_path")
    echo "  $i) $disk_name ($disk_path)"
    ((i++))
done > /tmp/disk_list.txt

# Read list into array
mapfile -t disk_list < <(grep "^data" /etc/snapraid.conf | awk '{print $2":"$3}')

cat /tmp/disk_list.txt
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

lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E "disk|NAME"

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

# Check that it exists
if [ ! -b "$new_device" ]; then
    echo -e "${RED}Device $new_device does not exist${NC}"
    exit 1
fi

# New disk information
model=$(lsblk -d -n -o MODEL "$new_device" 2>/dev/null || echo "Unknown")
size=$(lsblk -d -n -o SIZE "$new_device" 2>/dev/null || echo "Unknown")

echo
echo -e "${BOLD}Device:${NC} $new_device"
echo -e "${BOLD}Model:${NC}  $model"
echo -e "${BOLD}Size:${NC}   $size"
echo

# Check if it has data
if lsblk -n "$new_device" 2>/dev/null | grep -q "part"; then
    echo -e "${RED}${BOLD}WARNING: The disk has existing partitions${NC}"
    lsblk "$new_device"
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

echo -e "${YELLOW}Estimated time: 2-6 hours (depends on data size)${NC}"
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
if mountpoint -q "$failed_disk_path" 2>/dev/null; then
    echo "Unmounting failed disk..."
    umount "$failed_disk_path" || echo "Could not unmount (disk may be failed)"
fi

echo "Partitioning $new_device..."
parted -s "$new_device" mklabel gpt
parted -s "$new_device" mkpart primary ext4 0% 100%

# Determine partition name
if [[ "$new_device" =~ nvme ]]; then
    partition="${new_device}p1"
else
    partition="${new_device}1"
fi

sleep 2
partprobe "$new_device"
sleep 1

echo "Formatting with ext4..."
mkfs.ext4 -F -L "$failed_disk_name" "$partition"

echo "Mounting new disk..."
mount "$partition" "$failed_disk_path"

echo "Setting permissions..."
chown nas:nas "$failed_disk_path"
chmod 755 "$failed_disk_path"

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
if snapraid fix -d "$failed_disk_name" -l /var/log/snapraid-fix.log; then
    echo
    echo -e "${GREEN}Recovery completed successfully${NC}"
    echo
else
    echo
    echo -e "${RED}X Recovery failed or had errors${NC}"
    echo "Check the log: /var/log/snapraid-fix.log"
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
if snapraid scrub -p 100 -d "$failed_disk_name"; then
    echo
    echo -e "${GREEN}Verification complete - Data is correct${NC}"
else
    echo
    echo -e "${YELLOW}Warning: Verification found some issues${NC}"
    echo "This may be normal if some files were modified during recovery"
fi

echo

# Show final status
df -h "$failed_disk_path"

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
echo "   ls -lah $failed_disk_path"
echo

echo "2. Run a full sync to update parity:"
echo "   sudo snapraid sync"
echo

echo "3. Monitor the new disk over the next few weeks:"
echo "   sudo smartctl -a $new_device"
echo

echo "4. Run scrub periodically to verify integrity:"
echo "   sudo snapraid scrub -p 10"
echo

separator
echo

echo "Recovery log saved at: /var/log/snapraid-fix.log"
echo

echo -e "${CYAN}For more information about SnapRAID:${NC}"
echo "  cat /etc/nixos-nas/snapraid-commands.txt"
echo
