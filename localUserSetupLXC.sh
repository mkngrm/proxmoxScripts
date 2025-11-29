#!/bin/bash

set -euo pipefail

# Script: Proxmox LXC User Setup
# Description: Create a user in an LXC container with sudo access and SSH key authentication

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
SSH_PUBKEY=""
PASSWORD=""
GENERATE_PASSWORD=false
SUDO_NOPASSWD=false

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID -u USERNAME [OPTIONS]

Required arguments:
  -c LXC_ID          LXC container ID
  -u USERNAME        Username to create

Optional arguments:
  -k SSH_KEY         Path to SSH public key file (default: /root/.ssh/id_rsa.pub)
  -p PASSWORD        Password for the user (not recommended - use -g instead)
  -g                 Generate a random secure password
  -n                 Add user to sudoers with NOPASSWD (allows sudo without password)
  -h                 Show this help message

Examples:
  # Create user with SSH key from default location
  $0 -c 100 -u john -g

  # Create user with custom SSH key and specific password
  $0 -c 100 -u john -k /path/to/key.pub -p MyPassword

  # Create user with passwordless sudo
  $0 -c 100 -u john -g -n

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

generate_password() {
    # Generate a 16-character random password
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-16
}

validate_lxc_exists() {
    if ! pct status "$1" &>/dev/null; then
        log_error "LXC container $1 does not exist or is not accessible"
        exit 1
    fi
}

validate_lxc_running() {
    local status
    status=$(pct status "$1" | awk '{print $2}')
    if [ "$status" != "running" ]; then
        log_error "LXC container $1 is not running (status: $status)"
        exit 1
    fi
}

check_user_exists() {
    if pct exec "$1" -- id "$2" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Parse command line arguments
while getopts "c:u:k:p:gnh" opt; do
    case $opt in
        c) LXC_ID="$OPTARG" ;;
        u) USERNAME="$OPTARG" ;;
        k) SSH_PUBKEY="$OPTARG" ;;
        p) PASSWORD="$OPTARG" ;;
        g) GENERATE_PASSWORD=true ;;
        n) SUDO_NOPASSWD=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required parameters
if [ -z "${LXC_ID:-}" ] || [ -z "${USERNAME:-}" ]; then
    log_error "Missing required arguments"
    usage
fi

# Validate username format
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log_error "Invalid username format. Use lowercase letters, numbers, underscore, and hyphen only."
    exit 1
fi

# Validate LXC container
log_info "Validating LXC container $LXC_ID..."
validate_lxc_exists "$LXC_ID"
validate_lxc_running "$LXC_ID"

# Check if user already exists
if check_user_exists "$LXC_ID" "$USERNAME"; then
    log_error "User '$USERNAME' already exists in LXC $LXC_ID"
    exit 1
fi

# Handle password
if [ "$GENERATE_PASSWORD" = true ]; then
    PASSWORD=$(generate_password)
    log_info "Generated random password for user '$USERNAME'"
elif [ -z "$PASSWORD" ]; then
    log_warn "No password specified. User will only be able to login via SSH key."
    if [ -z "$SSH_PUBKEY" ]; then
        SSH_PUBKEY="/root/.ssh/id_rsa.pub"
        log_warn "No SSH key specified, using default: $SSH_PUBKEY"
    fi
fi

# Validate SSH public key if provided
if [ -n "$SSH_PUBKEY" ] && [ ! -f "$SSH_PUBKEY" ]; then
    log_error "SSH public key not found at: $SSH_PUBKEY"
    exit 1
fi

# Start user creation
log_info "Creating user '$USERNAME' in LXC $LXC_ID..."

# Create the user
if ! pct exec "$LXC_ID" -- adduser --disabled-password --gecos "" "$USERNAME"; then
    log_error "Failed to create user '$USERNAME'"
    exit 1
fi

# Set password if provided
if [ -n "$PASSWORD" ]; then
    log_info "Setting password for user '$USERNAME'..."
    if ! pct exec "$LXC_ID" -- bash -c "echo '$USERNAME:$PASSWORD' | chpasswd"; then
        log_error "Failed to set password"
        exit 1
    fi
fi

# Add user to sudo group
log_info "Adding user '$USERNAME' to sudo group..."
if ! pct exec "$LXC_ID" -- usermod -aG sudo "$USERNAME"; then
    log_error "Failed to add user to sudo group"
    exit 1
fi

# Configure NOPASSWD sudo if requested
if [ "$SUDO_NOPASSWD" = true ]; then
    log_info "Configuring passwordless sudo for user '$USERNAME'..."
    pct exec "$LXC_ID" -- bash -c "echo '$USERNAME ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USERNAME"
    pct exec "$LXC_ID" -- chmod 0440 "/etc/sudoers.d/$USERNAME"
fi

# Configure SSH access
if [ -n "$SSH_PUBKEY" ]; then
    log_info "Configuring SSH key authentication..."

    # Create .ssh directory
    pct exec "$LXC_ID" -- mkdir -p "/home/$USERNAME/.ssh"
    pct exec "$LXC_ID" -- chmod 700 "/home/$USERNAME/.ssh"

    # Add public key
    PUBKEY_CONTENT=$(cat "$SSH_PUBKEY")
    pct exec "$LXC_ID" -- bash -c "echo '$PUBKEY_CONTENT' >> /home/$USERNAME/.ssh/authorized_keys"
    pct exec "$LXC_ID" -- chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
    pct exec "$LXC_ID" -- chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

    log_info "SSH key added successfully"
fi

# Ensure SSH service is enabled and running
log_info "Ensuring SSH service is enabled and started..."
if pct exec "$LXC_ID" -- systemctl is-enabled ssh &>/dev/null || \
   pct exec "$LXC_ID" -- systemctl is-enabled sshd &>/dev/null; then
    # SSH service exists, enable and start it
    if pct exec "$LXC_ID" -- systemctl enable ssh 2>/dev/null || \
       pct exec "$LXC_ID" -- systemctl enable sshd 2>/dev/null; then
        pct exec "$LXC_ID" -- systemctl start ssh 2>/dev/null || \
        pct exec "$LXC_ID" -- systemctl start sshd 2>/dev/null
    fi
else
    log_warn "SSH service not found in container. You may need to install openssh-server"
fi

# Summary
echo
log_info "User setup completed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  LXC Container: $LXC_ID"
echo "  Username: $USERNAME"
if [ -n "$PASSWORD" ]; then
    if [ "$GENERATE_PASSWORD" = true ]; then
        echo "  Password: $PASSWORD"
        log_warn "Save this password securely - it will not be displayed again!"
    else
        echo "  Password: (set)"
    fi
fi
echo "  Sudo access: Enabled"
if [ "$SUDO_NOPASSWD" = true ]; then
    echo "  Sudo password: Not required (NOPASSWD)"
fi
if [ -n "$SSH_PUBKEY" ]; then
    echo "  SSH key: Configured"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Get container IP if possible
if LXC_IP=$(pct exec "$LXC_ID" -- hostname -I 2>/dev/null | awk '{print $1}'); then
    if [ -n "$LXC_IP" ]; then
        log_info "You can now SSH to the container:"
        echo "  ssh $USERNAME@$LXC_IP"
    fi
fi
