#!/bin/bash

set -euo pipefail

# Script: Enable Unattended Upgrades
# Description: Configure automatic security updates on multiple LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
EMAIL_ADDRESS=""
ENABLE_AUTO_REBOOT=false

# Arrays to track results
declare -A CONTAINER_RESULTS

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] [OPTIONS]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)

Optional arguments:
  -e EMAIL               Email address for update notifications
  -r                     Enable automatic reboot when required
  -h                     Show this help message

What this does:
  - Installs unattended-upgrades package
  - Configures automatic security updates
  - Optionally sets email notifications
  - Optionally enables auto-reboot when needed

Examples:
  # Enable unattended upgrades on multiple containers
  $0 -c 100 101 102

  # Enable with email notifications
  $0 -c 100 101 102 -e admin@example.com

  # Enable with auto-reboot
  $0 -c 100 101 102 -r

EOF
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_container() {
    echo -e "${BLUE}[LXC $1]${NC} $2"
}

validate_lxc_exists() {
    if ! pct status "$1" &>/dev/null; then
        return 1
    fi
    return 0
}

validate_lxc_running() {
    local status
    status=$(pct status "$1" 2>/dev/null | awk '{print $2}')
    if [ "$status" != "running" ]; then
        return 1
    fi
    return 0
}

configure_unattended_upgrades() {
    local lxc_id=$1
    local email_address=$2
    local enable_auto_reboot=$3

    log_container "$lxc_id" "Configuring unattended upgrades..."

    # Validate LXC container exists
    if ! validate_lxc_exists "$lxc_id"; then
        log_container "$lxc_id" "${RED}Container does not exist${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Container not found"
        return 1
    fi

    # Validate LXC container is running
    if ! validate_lxc_running "$lxc_id"; then
        local status
        status=$(pct status "$lxc_id" 2>/dev/null | awk '{print $2}')
        log_container "$lxc_id" "${RED}Container not running (status: $status)${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Not running"
        return 1
    fi

    # Update package lists
    log_container "$lxc_id" "Updating package lists..."
    pct exec "$lxc_id" -- apt-get update -qq &>/dev/null

    # Check if already installed
    if pct exec "$lxc_id" -- dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        log_container "$lxc_id" "unattended-upgrades already installed"
    else
        # Install unattended-upgrades
        log_container "$lxc_id" "Installing unattended-upgrades..."
        if ! pct exec "$lxc_id" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades" &>/dev/null; then
            log_container "$lxc_id" "${RED}Failed to install unattended-upgrades${NC}"
            CONTAINER_RESULTS[$lxc_id]="FAILED: Installation failed"
            return 1
        fi
    fi

    # Configure unattended-upgrades
    log_container "$lxc_id" "Configuring automatic updates..."

    # Enable automatic updates for security
    pct exec "$lxc_id" -- bash -c 'cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF'

    # Configure 50unattended-upgrades
    local config_additions=""

    if [ -n "$email_address" ]; then
        config_additions+="Unattended-Upgrade::Mail \"$email_address\";\n"
        config_additions+="Unattended-Upgrade::MailReport \"on-change\";\n"
        log_container "$lxc_id" "Email notifications configured: $email_address"
    fi

    if [ "$enable_auto_reboot" = true ]; then
        config_additions+="Unattended-Upgrade::Automatic-Reboot \"true\";\n"
        config_additions+="Unattended-Upgrade::Automatic-Reboot-Time \"03:00\";\n"
        log_container "$lxc_id" "Auto-reboot enabled (03:00 if needed)"
    fi

    if [ -n "$config_additions" ]; then
        pct exec "$lxc_id" -- bash -c "echo -e '$config_additions' >> /etc/apt/apt.conf.d/50unattended-upgrades"
    fi

    # Enable and start the service
    pct exec "$lxc_id" -- systemctl enable unattended-upgrades &>/dev/null || true
    pct exec "$lxc_id" -- systemctl start unattended-upgrades &>/dev/null || true

    log_container "$lxc_id" "${GREEN}Unattended upgrades configured successfully${NC}"
    CONTAINER_RESULTS[$lxc_id]="SUCCESS"
    return 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c)
            shift
            while [[ $# -gt 0 ]] && [[ ! $1 =~ ^- ]]; do
                LXC_IDS+=("$1")
                shift
            done
            ;;
        -e)
            EMAIL_ADDRESS="$2"
            shift 2
            ;;
        -r)
            ENABLE_AUTO_REBOOT=true
            shift
            ;;
        -h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ ${#LXC_IDS[@]} -eq 0 ]; then
    log_error "Missing required argument: -c LXC_ID"
    usage
fi

# Display summary of what will be done
echo
log_info "Configuring unattended upgrades in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
if [ -n "$EMAIL_ADDRESS" ]; then
    log_info "Email notifications: $EMAIL_ADDRESS"
fi
if [ "$ENABLE_AUTO_REBOOT" = true ]; then
    log_info "Auto-reboot: Enabled (03:00)"
fi
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    configure_unattended_upgrades "$lxc_id" "$EMAIL_ADDRESS" "$ENABLE_AUTO_REBOOT"
    echo
done

# Display final summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Summary of operations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Count successes and failures
success_count=0
failed_count=0

for lxc_id in "${LXC_IDS[@]}"; do
    result="${CONTAINER_RESULTS[$lxc_id]:-UNKNOWN}"

    case $result in
        SUCCESS)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: Configured successfully"
            success_count=$((success_count + 1))
            ;;
        FAILED*)
            echo -e "  ${RED}✗${NC} LXC $lxc_id: $result"
            failed_count=$((failed_count + 1))
            ;;
        *)
            echo -e "  ${YELLOW}?${NC} LXC $lxc_id: $result"
            failed_count=$((failed_count + 1))
            ;;
    esac
done

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $success_count succeeded, $failed_count failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with error if any containers failed
if [ $failed_count -gt 0 ]; then
    exit 1
fi
