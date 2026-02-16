#!/usr/bin/env bash

# Interactive configuration script for Authentik integration
# Generates the necessary configuration for the NAS

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Utility functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Banner
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║     NixOS NAS - Authentik SSO Configuration               ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo ""

info "This script will help you configure Authentik integration"
info "for Cockpit and File Browser on your NAS."
echo ""

# 1. Gather information
echo "=== Step 1: Network Information ==="
echo ""

read -p "NAS IP [192.168.1.100]: " NAS_IP
NAS_IP=${NAS_IP:-192.168.1.100}

read -p "NAS domain [nas.local]: " NAS_DOMAIN
NAS_DOMAIN=${NAS_DOMAIN:-nas.local}

read -p "Subdomain for Cockpit [cockpit]: " COCKPIT_SUB
COCKPIT_SUB=${COCKPIT_SUB:-cockpit}

read -p "Subdomain for File Browser [files]: " FILES_SUB
FILES_SUB=${FILES_SUB:-files}

echo ""
echo "=== Step 2: Authentik Information ==="
echo ""

read -p "Authentik URL (e.g.: https://authentik.local): " AUTHENTIK_URL
while [ -z "$AUTHENTIK_URL" ]; do
    error "Authentik URL cannot be empty"
    read -p "Authentik URL: " AUTHENTIK_URL
done

read -p "Authentik IP [extract from URL]: " AUTHENTIK_IP
if [ -z "$AUTHENTIK_IP" ]; then
    # Try to extract IP from URL
    AUTHENTIK_IP=$(echo "$AUTHENTIK_URL" | grep -oP '(?<=://)[^:/]+' || echo "")
fi

read -p "Authentik Outpost port [9000]: " OUTPOST_PORT
OUTPOST_PORT=${OUTPOST_PORT:-9000}

OUTPOST_URL="http://${AUTHENTIK_IP}:${OUTPOST_PORT}"

echo ""
echo "=== Step 3: SSL Configuration ==="
echo ""

read -p "Use self-signed certificates? [Y/n]: " USE_SELFSIGNED
USE_SELFSIGNED=${USE_SELFSIGNED:-Y}

if [[ "$USE_SELFSIGNED" =~ ^[Yy]$ ]]; then
    SSL_SELFSIGNED="true"
else
    SSL_SELFSIGNED="false"
    warning "You will need to provide your own SSL certificates"
fi

echo ""
echo "=== Configuration Summary ==="
echo ""
echo "NAS:"
echo "  IP:                $NAS_IP"
echo "  Domain:            $NAS_DOMAIN"
echo "  Cockpit:           https://${COCKPIT_SUB}.${NAS_DOMAIN}"
echo "  File Browser:      https://${FILES_SUB}.${NAS_DOMAIN}"
echo ""
echo "Authentik:"
echo "  URL:               $AUTHENTIK_URL"
echo "  IP:                $AUTHENTIK_IP"
echo "  Outpost URL:       $OUTPOST_URL"
echo ""
echo "SSL:"
echo "  Self-signed:       $SSL_SELFSIGNED"
echo ""

read -p "Is this configuration correct? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    error "Configuration cancelled"
    exit 1
fi

# 2. Verify connectivity
echo ""
echo "=== Step 4: Verify Connectivity ==="
echo ""

info "Checking connectivity with Authentik..."

if curl -s -o /dev/null -w "%{http_code}" "$AUTHENTIK_URL" | grep -q "200\|301\|302"; then
    success "Authentik is accessible at $AUTHENTIK_URL"
else
    warning "Cannot reach Authentik at $AUTHENTIK_URL"
    warning "Verify that Authentik is running and accessible from the NAS"
fi

info "Checking outpost..."
if curl -s -o /dev/null -w "%{http_code}" "$OUTPOST_URL/outpost.goauthentik.io/ping" | grep -q "200\|301\|302\|404"; then
    success "Outpost is accessible at $OUTPOST_URL"
else
    warning "Cannot reach outpost at $OUTPOST_URL"
    warning "Make sure you have a proxy outpost configured in Authentik"
fi

# 3. Generate NixOS configuration
echo ""
echo "=== Step 5: Generate Configuration ==="
echo ""

CONFIG_FILE="/tmp/nas-authentik-config.nix"

info "Generating NixOS configuration..."

cat > "$CONFIG_FILE" <<EOF
# Generated configuration for Authentik integration
# Add or update this in your configuration.nix

{
  # Enable Web UI
  nas.webui = {
    enable = true;

    cockpit = {
      enable = true;
      port = 9090;
      allowUnencrypted = true;
      origins = [
        "https://${NAS_DOMAIN}"
        "https://${COCKPIT_SUB}.${NAS_DOMAIN}"
        "${AUTHENTIK_URL}"
      ];
    };

    filebrowser = {
      enable = true;
      port = 8080;
      rootPath = "/mnt/storage";
      proxyAuth = true;  # Enable proxy authentication
      proxyHeader = "X-authentik-username";
    };
  };

  # Enable Reverse Proxy
  nas.reverseProxy = {
    enable = true;
    domain = "${NAS_DOMAIN}";

    ssl = {
      enable = true;
      useSelfSigned = ${SSL_SELFSIGNED};
    };

    authentik = {
      enable = true;
      url = "${AUTHENTIK_URL}";
      outpostUrl = "${OUTPOST_URL}";
    };

    cockpit = {
      enable = true;
      subdomain = "${COCKPIT_SUB}";
    };

    filebrowser = {
      enable = true;
      subdomain = "${FILES_SUB}";
    };
  };
}
EOF

success "Configuration generated at: $CONFIG_FILE"
echo ""
cat "$CONFIG_FILE"
echo ""

# 4. Generate /etc/hosts configuration
HOSTS_FILE="/tmp/nas-hosts-entry.txt"

info "Generating /etc/hosts entry..."

cat > "$HOSTS_FILE" <<EOF
# Add these lines to /etc/hosts on your clients
# (or configure these entries in your DNS server)

${NAS_IP}  ${NAS_DOMAIN} ${COCKPIT_SUB}.${NAS_DOMAIN} ${FILES_SUB}.${NAS_DOMAIN}
EOF

success "Hosts entry generated at: $HOSTS_FILE"
echo ""
cat "$HOSTS_FILE"
echo ""

# 5. Generate Authentik instructions
AUTHENTIK_GUIDE="/tmp/authentik-config-guide.txt"

info "Generating Authentik configuration guide..."

cat > "$AUTHENTIK_GUIDE" <<EOF
╔═══════════════════════════════════════════════════════════╗
║      Authentik Configuration - Step by Step Guide         ║
╚═══════════════════════════════════════════════════════════╝

=== 1. Create Providers in Authentik ===

1.1 Provider for Cockpit:
    - Go to: Applications > Providers > Create
    - Type: Proxy Provider
    - Name: NAS Cockpit
    - Authorization flow: default-authorization-flow
    - External host: https://${COCKPIT_SUB}.${NAS_DOMAIN}
    - Mode: Forward auth (single application)
    - Cookie domain: ${NAS_DOMAIN}

1.2 Provider for File Browser:
    - Go to: Applications > Providers > Create
    - Type: Proxy Provider
    - Name: NAS File Browser
    - Authorization flow: default-authorization-flow
    - External host: https://${FILES_SUB}.${NAS_DOMAIN}
    - Mode: Forward auth (single application)
    - Cookie domain: ${NAS_DOMAIN}

=== 2. Create Applications in Authentik ===

2.1 Cockpit Application:
    - Go to: Applications > Applications > Create
    - Name: Cockpit
    - Slug: cockpit
    - Provider: NAS Cockpit
    - Launch URL: https://${COCKPIT_SUB}.${NAS_DOMAIN}

2.2 File Browser Application:
    - Go to: Applications > Applications > Create
    - Name: File Browser
    - Slug: filebrowser
    - Provider: NAS File Browser
    - Launch URL: https://${FILES_SUB}.${NAS_DOMAIN}

=== 3. Configure Outpost ===

3.1 If you already have an outpost:
    - Edit the existing outpost
    - Add the "Cockpit" and "File Browser" applications

3.2 If you need to create an outpost:
    - Go to: Applications > Outposts > Create
    - Name: NAS Proxy
    - Type: Proxy
    - Applications: Select Cockpit and File Browser

=== 4. Verify ===

Verify that the outpost is running and accessible at:
${OUTPOST_URL}

=== 5. Final URLs ===

Dashboard:    https://${NAS_DOMAIN}
Cockpit:      https://${COCKPIT_SUB}.${NAS_DOMAIN}
File Browser: https://${FILES_SUB}.${NAS_DOMAIN}

EOF

success "Authentik guide generated at: $AUTHENTIK_GUIDE"
echo ""

# 6. Create apply script
APPLY_SCRIPT="/tmp/apply-nas-config.sh"

info "Generating apply script..."

cat > "$APPLY_SCRIPT" <<'SCRIPT_EOF'
#!/usr/bin/env bash

# Script to apply NAS configuration

set -e

echo "=== Apply NAS Configuration ==="
echo ""

# Check that we are in the correct directory
if [ ! -f "flake.nix" ]; then
    echo "Error: Run this script from the project root directory (where flake.nix is)"
    exit 1
fi

# Check that configuration is updated
echo "1. Verify that configuration.nix has the configuration from:"
echo "   /tmp/nas-authentik-config.nix"
echo ""
read -p "Have you updated configuration.nix? [y/N]: " updated

if [[ ! "$updated" =~ ^[Yy]$ ]]; then
    echo "Please update configuration.nix first"
    exit 1
fi

# Verify syntax
echo ""
echo "2. Verifying flake syntax..."
nix flake check || {
    echo "Error: Flake syntax has errors"
    exit 1
}

# Build
echo ""
echo "3. Building configuration..."
sudo nixos-rebuild build --flake '.#<machine-name>' || {
    echo "Error: Build failed"
    exit 1
}

# Switch
echo ""
echo "4. Applying configuration..."
read -p "Apply changes to system? [y/N]: " apply

if [[ "$apply" =~ ^[Yy]$ ]]; then
    sudo nixos-rebuild switch --flake '.#<machine-name>'
    echo ""
    echo "Configuration applied successfully"
    echo ""
    echo "Verify the services:"
    echo "  systemctl status cockpit.socket"
    echo "  systemctl status filebrowser.service"
    echo "  systemctl status nginx.service"
else
    echo "Changes not applied. To apply manually:"
    echo "  sudo nixos-rebuild switch --flake '.#<machine-name>'"
fi
SCRIPT_EOF

chmod +x "$APPLY_SCRIPT"

success "Apply script generated at: $APPLY_SCRIPT"

# 7. Generate verification script
VERIFY_SCRIPT="/tmp/verify-nas-services.sh"

cat > "$VERIFY_SCRIPT" <<VERIFY_EOF
#!/usr/bin/env bash

# Service verification script

echo "=== NAS Service Verification ==="
echo ""

echo "1. Service status:"
echo ""
echo "Cockpit:"
systemctl is-active cockpit.socket && echo "  OK Active" || echo "  X Inactive"

echo "File Browser:"
systemctl is-active filebrowser.service && echo "  OK Active" || echo "  X Inactive"

echo "Nginx:"
systemctl is-active nginx.service && echo "  OK Active" || echo "  X Inactive"

echo ""
echo "2. Open ports:"
echo ""
ss -tulpn | grep -E ':(80|443|8080|9090)' || echo "  Expected ports not found"

echo ""
echo "3. Connectivity with Authentik:"
echo ""
curl -s -o /dev/null -w "Authentik: HTTP %{http_code}\n" ${AUTHENTIK_URL} || echo "  Connection error"
curl -s -o /dev/null -w "Outpost: HTTP %{http_code}\n" ${OUTPOST_URL}/outpost.goauthentik.io/ping || echo "  Connection error"

echo ""
echo "4. Local access test:"
echo ""
curl -s -o /dev/null -w "Cockpit local: HTTP %{http_code}\n" http://localhost:9090 || echo "  Error"
curl -s -o /dev/null -w "File Browser local: HTTP %{http_code}\n" http://localhost:8080 || echo "  Error"

echo ""
echo "Verification complete."
echo ""
echo "Try accessing:"
echo "  https://${COCKPIT_SUB}.${NAS_DOMAIN}"
echo "  https://${FILES_SUB}.${NAS_DOMAIN}"
VERIFY_EOF

chmod +x "$VERIFY_SCRIPT"

success "Verification script generated at: $VERIFY_SCRIPT"

# 8. Final summary
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                 Configuration Complete                    ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
info "Generated files:"
echo "  1. NixOS configuration:    $CONFIG_FILE"
echo "  2. /etc/hosts entry:       $HOSTS_FILE"
echo "  3. Authentik guide:        $AUTHENTIK_GUIDE"
echo "  4. Apply script:           $APPLY_SCRIPT"
echo "  5. Verification script:    $VERIFY_SCRIPT"
echo ""
info "Next steps:"
echo ""
echo "1. Configure Authentik following the guide at:"
echo "   $AUTHENTIK_GUIDE"
echo ""
echo "2. Update configuration.nix with the contents of:"
echo "   $CONFIG_FILE"
echo ""
echo "3. Add the hosts entry to your clients:"
echo "   cat $HOSTS_FILE"
echo ""
echo "4. Apply the configuration:"
echo "   cd /path/to/nixos-nas"
echo "   sudo nixos-rebuild switch --flake '.#<machine-name>'"
echo ""
echo "5. Verify the services:"
echo "   $VERIFY_SCRIPT"
echo ""
success "Configuration ready to be applied"
echo ""
warning "REMEMBER: Make sure /etc/hosts or DNS is configured"
warning "          on your clients before accessing the URLs"
echo ""

# Ask if they want to see the guide now
read -p "Do you want to see the Authentik guide now? [y/N]: " show_guide
if [[ "$show_guide" =~ ^[Yy]$ ]]; then
    echo ""
    cat "$AUTHENTIK_GUIDE"
fi

echo ""
info "For more information, see: AUTHENTIK-INTEGRATION.md"
echo ""
