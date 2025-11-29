#!/bin/bash

# Proxmox Scripts Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/mkngrm/proxmoxScripts/main/install.sh | sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
REPO_URL="https://raw.githubusercontent.com/mkngrm/proxmoxScripts/main"
INSTALL_DIR="/opt/proxmoxScripts"
BIN_DIR="/usr/local/bin"

# List of all scripts to install
SCRIPTS=(
    "localUserSetupLXC.sh"
    "disableRootSSHLogin.sh"
    "updateContainers.sh"
    "healthCheck.sh"
    "enableUnattendedUpgrades.sh"
    "bulkContainerControl.sh"
    "snapshotContainers.sh"
    "deploySSHKeys.sh"
    "syncTimezone.sh"
    "deployFile.sh"
    "auditContainers.sh"
    "setupStableDiffusion.sh"
)

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    log_info "Please run: curl -fsSL https://raw.githubusercontent.com/mkngrm/proxmoxScripts/main/install.sh | sudo sh"
    exit 1
fi

# Check if pct command exists (Proxmox indicator)
if ! command -v pct &>/dev/null; then
    log_warn "The 'pct' command was not found. Are you running this on a Proxmox VE host?"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Display banner
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}    Proxmox LXC Management Scripts Installer${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

log_info "Installation directory: $INSTALL_DIR"
log_info "Symlinks will be created in: $BIN_DIR"
echo

# Create installation directory
if [ -d "$INSTALL_DIR" ]; then
    log_warn "Installation directory already exists. Updating scripts..."
else
    log_info "Creating installation directory..."
    mkdir -p "$INSTALL_DIR"
fi

# Download and install each script
success_count=0
failed_count=0

log_info "Downloading scripts from GitHub..."
echo

for script in "${SCRIPTS[@]}"; do
    echo -n "  Installing $script... "

    # Download script
    if curl -fsSL "$REPO_URL/$script" -o "$INSTALL_DIR/$script" 2>/dev/null; then
        # Make executable
        chmod +x "$INSTALL_DIR/$script"

        # Create symlink without .sh extension for convenience
        script_name="${script%.sh}"
        ln -sf "$INSTALL_DIR/$script" "$BIN_DIR/$script_name"

        echo -e "${GREEN}✓${NC}"
        success_count=$((success_count + 1))
    else
        echo -e "${RED}✗${NC}"
        failed_count=$((failed_count + 1))
    fi
done

echo

# Download README
log_info "Downloading documentation..."
if curl -fsSL "$REPO_URL/README.md" -o "$INSTALL_DIR/README.md" 2>/dev/null; then
    log_info "README.md saved to $INSTALL_DIR/README.md"
else
    log_warn "Failed to download README.md"
fi

# Summary
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Installation Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo -e "  ${GREEN}✓${NC} Successfully installed: $success_count scripts"
if [ $failed_count -gt 0 ]; then
    echo -e "  ${RED}✗${NC} Failed: $failed_count scripts"
fi
echo
log_info "Scripts are installed in: $INSTALL_DIR"
log_info "Command symlinks created in: $BIN_DIR"
echo

# Display available commands
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Available Commands:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "User Management:"
echo "  localUserSetupLXC          - Create users with sudo and SSH access"
echo "  disableRootSSHLogin        - Configure root SSH login security"
echo "  deploySSHKeys              - Manage SSH keys across containers"
echo
echo "Package Management:"
echo "  updateContainers           - Update/upgrade packages"
echo "  enableUnattendedUpgrades   - Configure automatic security updates"
echo
echo "Container Operations:"
echo "  bulkContainerControl       - Start/stop/restart containers"
echo "  snapshotContainers         - Create/delete snapshots"
echo "  syncTimezone               - Synchronize timezones"
echo "  deployFile                 - Deploy files across containers"
echo
echo "Monitoring & Security:"
echo "  healthCheck                - Check container health status"
echo "  auditContainers            - Security audit"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Quick Start:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  # Get help for any command"
echo "  localUserSetupLXC -h"
echo
echo "  # Check health of containers"
echo "  healthCheck -c 100 101 102"
echo
echo "  # Update all containers"
echo "  updateContainers -c 100 101 102 -y"
echo
echo "  # View full documentation"
echo "  cat $INSTALL_DIR/README.md"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $failed_count -eq 0 ]; then
    log_info "Installation completed successfully!"
    exit 0
else
    log_warn "Installation completed with some failures"
    exit 1
fi
