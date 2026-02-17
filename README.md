# NixOS NAS

A declarative NAS (Network Attached Storage) configuration using NixOS with MergerFS + SnapRAID. Optimized for media streaming, large files, and low-resource hardware.

## Features

- **MergerFS**: Pool multiple disks of different sizes into a single unified storage
- **SnapRAID**: Snapshot-based parity protection (recover from disk failures)
- **Samba & NFS**: File sharing for Windows, macOS, and Linux clients
- **Web UI**: Cockpit (system admin) + File Browser (file management)
- **Declarative**: Entire system configuration as code with NixOS Flakes
- **Easy Deployment**: Install remotely via nixos-anywhere
- **Secret Management**: Passwords encrypted with agenix
- **SSO Ready**: Optional Authentik integration for single sign-on

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    MERGERFS POOL                            │
│                  /mnt/storage (union)                       │
│                                                             │
│  ┌─────────────┬─────────────┬─────────────┐                │
│  │ /mnt/disk1  │ /mnt/disk2  │ /mnt/diskN  │  (expandable)  │
│  │ (any size)  │ (any size)  │ (any size)  │                │
│  │ ext4        │ ext4        │ ext4        │                │
│  └─────────────┴─────────────┴─────────────┘                │
└─────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │     SNAPRAID      │
                    │   /mnt/parity     │
                    │  (parity disk)    │
                    └───────────────────┘
```

## Requirements

### Hardware

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | x86_64, 2 cores | 4+ cores |
| RAM | 2 GB | 4+ GB |
| System disk | 32 GB | 100+ GB SSD |
| Data disks | 1+ | 2+ (any size mix) |
| Parity disk | 1 (≥ largest data disk) | Same |

### Software

- A machine to deploy from (Linux/macOS with Nix installed)
- Target machine bootable via USB (NixOS ISO or any Linux for nixos-anywhere)

## Quick Start

### 1. Clone and Configure

```bash
git clone https://github.com/josecriane/nixos-nas.git
cd nixos-nas

# Enter dev shell with required tools
nix develop

# Run interactive setup wizard
./scripts/setup.sh
```

The wizard will ask for:
- Network configuration (IP, gateway, DNS)
- Admin username and SSH key
- Samba password
- Which services to enable

### 2. Customize Disk Configuration

Edit `modules/disko.nix` to match your hardware:

```nix
# Change device paths to match your disks
system.device = "/dev/sda";  # System + parity disk
data1.device = "/dev/sdb";   # Data disk 1
data2.device = "/dev/sdc";   # Data disk 2
# Add more data disks as needed
```

### 3. Install

Boot the target machine with NixOS ISO, then from your workstation:

```bash
./scripts/install.sh
```

Or manually with nixos-anywhere:

```bash
nixos-anywhere --flake .#nas root@<NAS_IP>
```

### 4. Post-Installation

The install script handles SSH setup and Samba password configuration automatically.

After installation, initialize SnapRAID parity (this takes several hours on first run):

```bash
ssh admin@<NAS_IP>
sudo snapraid sync
```

## Services

| Service | Port | Description |
|---------|------|-------------|
| Samba (SMB) | 445 | Windows/Mac/Linux file sharing |
| NFS | 2049 | Linux file sharing (better performance) |
| Cockpit | 9090 | Web-based system administration |
| File Browser | 8080 | Web-based file manager |
| SSH | 22 | Remote administration |

## Project Structure

```
nixos-nas/
├── flake.nix              # Flake definition with inputs
├── configuration.nix      # Base system configuration
├── config.example.nix     # Example configuration (copy to config.nix)
├── modules/
│   ├── disko.nix          # Disk partitioning (customize for your hardware)
│   ├── storage-mergerfs.nix  # MergerFS pool configuration
│   ├── snapraid.nix       # SnapRAID parity and schedules
│   ├── services.nix       # Samba and NFS configuration
│   ├── webui.nix          # Cockpit and File Browser
│   ├── networking.nix     # Network optimizations
│   ├── hardware.nix       # Boot and hardware settings
│   ├── users.nix          # User management
│   ├── monitoring.nix     # Health checks and alerts
│   ├── reverse-proxy.nix  # Optional Nginx reverse proxy
│   └── samba-setup.nix    # Samba password from agenix
├── scripts/
│   ├── setup.sh           # Interactive configuration wizard
│   ├── install.sh         # Installation via nixos-anywhere
│   ├── update.sh          # Update NAS configuration
│   ├── nas-health.sh      # System health check
│   ├── snapraid-status.sh # SnapRAID detailed status
│   ├── add-disk.sh        # Add new disk wizard
│   ├── replace-disk.sh    # Replace failed disk wizard
│   ├── benchmark.sh       # Performance tests
│   └── setup-authentik.sh # Authentik SSO setup (optional)
├── examples/
│   ├── disko-2-data-disks.nix  # Minimal: 2 data disks
│   ├── disko-4-data-disks.nix  # Medium: 4 data disks
│   ├── disko-nvme-system.nix   # NVMe system + HDD data
│   ├── config-minimal.nix      # Minimal configuration
│   └── config-full.nix         # Full configuration
└── secrets/
    └── secrets.example.nix  # Example secrets configuration
```

## Configuration

### What You Must Customize

| File | What to Change |
|------|----------------|
| `config.nix` | Network, username, SSH keys, domain |
| `modules/disko.nix` | Disk devices (`/dev/sdX`) for your hardware |
| `secrets/secrets.nix` | Age public keys for secret encryption |

### Optional Customization

| File | Purpose |
|------|---------|
| `configuration.nix` | Enable/disable services, firewall rules |
| `modules/services.nix` | Samba shares, NFS exports |
| `modules/snapraid.nix` | Sync schedule, scrub frequency |

## Secret Management

This project uses [agenix](https://github.com/ryantm/agenix) for secret management.

### Setup Secrets

1. Copy the example:
   ```bash
   cp secrets/secrets.example.nix secrets/secrets.nix
   ```

2. Get your NAS's age key (after first boot):
   ```bash
   ssh admin@nas "cat /etc/ssh/ssh_host_ed25519_key.pub" | ssh-to-age
   ```

3. Add your admin key:
   ```bash
   ssh-to-age < ~/.ssh/id_ed25519.pub
   ```

4. Update `secrets/secrets.nix` with both keys

5. Create encrypted secrets:
   ```bash
   echo "your-password" | age -r "age1..." -o secrets/samba-password.age
   ```

## Operations

### Automated Tasks

These run automatically via systemd timers:

| Task | Schedule | Description |
|------|----------|-------------|
| SnapRAID sync | Daily 2 AM | Update parity data |
| SnapRAID scrub | Weekly (Sun 3 AM) | Verify 8% of data |
| SMART monitoring | Continuous | Disk health checks |

### Manual Commands

Run these when you need to check status or force immediate sync:

```bash
nas-status                # System overview
sudo snapraid status      # SnapRAID status
sudo snapraid diff        # Changes since last sync
sudo snapraid sync        # Force immediate sync
sudo snapraid scrub -p 10 # Verify 10% of data
```

### Adding a New Disk

```bash
# Use the wizard
sudo ./scripts/add-disk.sh

# Or manually:
# 1. Add disk to modules/disko.nix
# 2. Add to modules/storage-mergerfs.nix
# 3. Add to modules/snapraid.nix
# 4. nixos-rebuild switch
# 5. snapraid sync
```

### Recovering from Disk Failure

```bash
# Use the wizard
sudo ./scripts/replace-disk.sh

# Or manually:
# 1. Replace failed disk
# 2. Format with same label: mkfs.ext4 -L diskN /dev/sdX1
# 3. Mount: mount /dev/sdX1 /mnt/diskN
# 4. Recover: snapraid fix -d diskN
```

## Why MergerFS + SnapRAID?

| Feature | MergerFS + SnapRAID | ZFS | Traditional RAID |
|---------|---------------------|-----|------------------|
| RAM usage | < 1 GB | 4-8+ GB | Low |
| Mixed disk sizes | ✅ Yes | ❌ No | ❌ No |
| Easy expansion | ✅ Add anytime | Complex | Rebuild required |
| Individual disk access | ✅ Yes | ❌ No | ❌ No |
| File-level recovery | ✅ Yes | Pool-level | No |
| Real-time protection | ❌ Snapshot | ✅ Yes | ✅ Yes |
| Best for | Media, static files | Databases, VMs | Enterprise |

**For a home NAS with limited RAM serving media files, MergerFS + SnapRAID is ideal.**

## Limitations

1. **SnapRAID is not real-time**: Changes are only protected after a sync
2. **Parity disk size**: Must be ≥ your largest data disk
3. **Not a backup**: Protects against disk failure, not accidental deletion or ransomware
4. **Single parity**: Default config tolerates 1 disk failure (can add 2-parity)

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `nix flake check` to verify
5. Submit a pull request

## Resources

- [SnapRAID Official Site](http://www.snapraid.it/)
- [MergerFS GitHub](https://github.com/trapexit/mergerfs)
- [Perfect Media Server](https://perfectmediaserver.com/)
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [agenix](https://github.com/ryantm/agenix)

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
