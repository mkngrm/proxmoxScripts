#!/bin/bash

set -euo pipefail

# Script: Proxmox LXC User Setup
# Description: Create a user in one or more LXC containers with sudo access and SSH key authentication

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
SSH_PUBKEY=""
PASSWORD=""
GENERATE_PASSWORD=false
SUDO_NOPASSWD=false
LXC_IDS=()

# Arrays to track results
declare -A CONTAINER_RESULTS
declare -A CONTAINER_IPS

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] -u USERNAME [OPTIONS]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)
  -u USERNAME            Username to create

Optional arguments:
  -k SSH_KEY             Path to SSH public key file (default: /root/.ssh/id_rsa.pub)
  -p PASSWORD            Password for the user (not recommended - use -g instead)
  -g                     Generate a random secure password
  -n                     Add user to sudoers with NOPASSWD (allows sudo without password)
  -h                     Show this help message

Examples:
  # Create user in a single container
  $0 -c 100 -u john -g

  # Create user in multiple containers
  $0 -c 100 101 102 -u john -g

  # Create user with custom SSH key and passwordless sudo in multiple containers
  $0 -c 100 101 -u jane -k ~/.ssh/my_key.pub -g -n

  # Create user with specific password across multiple containers
  $0 -c 100 101 102 -u developer -k ~/.ssh/dev_key.pub -p MySecurePass123

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

generate_password() {
    # Generate a 16-character random password
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-16
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

check_user_exists() {
    if pct exec "$1" -- id "$2" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

setup_user_in_container() {
    local lxc_id=$1
    local username=$2
    local password=$3
    local ssh_key=$4
    local sudo_nopasswd=$5

    log_container "$lxc_id" "Starting user setup..."

    # Validate LXC container exists
    if ! validate_lxc_exists "$lxc_id"; then
        log_container "$lxc_id" "${RED}Container does not exist or is not accessible${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Container not found"
        return 1
    fi

    # Validate LXC container is running
    if ! validate_lxc_running "$lxc_id"; then
        local status
        status=$(pct status "$lxc_id" 2>/dev/null | awk '{print $2}')
        log_container "$lxc_id" "${RED}Container is not running (status: $status)${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Not running"
        return 1
    fi

    # Check if user already exists
    if check_user_exists "$lxc_id" "$username"; then
        log_container "$lxc_id" "${YELLOW}User '$username' already exists, skipping${NC}"
        CONTAINER_RESULTS[$lxc_id]="SKIPPED: User exists"
        return 0
    fi

    # Create the user
    log_container "$lxc_id" "Creating user '$username'..."
    if ! pct exec "$lxc_id" -- adduser --disabled-password --gecos "" "$username" &>/dev/null; then
        log_container "$lxc_id" "${RED}Failed to create user${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: User creation failed"
        return 1
    fi

    # Set password if provided
    if [ -n "$password" ]; then
        log_container "$lxc_id" "Setting password..."
        if ! pct exec "$lxc_id" -- bash -c "echo '$username:$password' | chpasswd" &>/dev/null; then
            log_container "$lxc_id" "${RED}Failed to set password${NC}"
            CONTAINER_RESULTS[$lxc_id]="FAILED: Password setup failed"
            return 1
        fi
    fi

    # Check if sudo is installed, install if needed
    if ! pct exec "$lxc_id" -- command -v sudo &>/dev/null; then
        log_container "$lxc_id" "sudo not found, installing..."
        if pct exec "$lxc_id" -- bash -c "apt-get update -qq && apt-get install -y sudo" &>/dev/null; then
            log_container "$lxc_id" "sudo installed successfully"
        else
            log_container "$lxc_id" "${RED}Failed to install sudo${NC}"
            CONTAINER_RESULTS[$lxc_id]="FAILED: Could not install sudo"
            return 1
        fi
    fi

    # Add user to sudo group
    log_container "$lxc_id" "Adding user to sudo group..."
    if ! pct exec "$lxc_id" -- usermod -aG sudo "$username" &>/dev/null; then
        log_container "$lxc_id" "${RED}Failed to add user to sudo group${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Sudo setup failed"
        return 1
    fi

    # Configure NOPASSWD sudo if requested
    if [ "$sudo_nopasswd" = true ]; then
        log_container "$lxc_id" "Configuring passwordless sudo..."
        pct exec "$lxc_id" -- bash -c "echo '$username ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$username" &>/dev/null
        pct exec "$lxc_id" -- chmod 0440 "/etc/sudoers.d/$username" &>/dev/null
    fi

    # Configure SSH access
    if [ -n "$ssh_key" ]; then
        log_container "$lxc_id" "Configuring SSH key authentication..."

        # Create .ssh directory
        pct exec "$lxc_id" -- mkdir -p "/home/$username/.ssh" &>/dev/null
        pct exec "$lxc_id" -- chmod 700 "/home/$username/.ssh" &>/dev/null

        # Add public key
        local pubkey_content
        pubkey_content=$(cat "$ssh_key")
        pct exec "$lxc_id" -- bash -c "echo '$pubkey_content' >> /home/$username/.ssh/authorized_keys" &>/dev/null
        pct exec "$lxc_id" -- chmod 600 "/home/$username/.ssh/authorized_keys" &>/dev/null
        pct exec "$lxc_id" -- chown -R "$username:$username" "/home/$username/.ssh" &>/dev/null
    fi

    # Ensure SSH service is enabled and running
    log_container "$lxc_id" "Checking SSH service..."

    # Method 1: Check if SSH port is listening (most reliable)
    local ssh_detected=false
    if pct exec "$lxc_id" -- ss -tlnp 2>/dev/null | grep -q ':22 ' || \
       pct exec "$lxc_id" -- netstat -tlnp 2>/dev/null | grep -q ':22 ' || \
       pct exec "$lxc_id" -- lsof -i:22 &>/dev/null; then
        ssh_detected=true
        log_container "$lxc_id" "SSH is listening on port 22"
    fi

    # Method 2: Check for sshd process
    if [ "$ssh_detected" = false ] && pct exec "$lxc_id" -- pgrep -f 'sshd|ssh' &>/dev/null; then
        ssh_detected=true
        log_container "$lxc_id" "SSH daemon process is running"
    fi

    # Try to detect and manage the service via systemctl (best effort)
    local ssh_service=""
    if pct exec "$lxc_id" -- systemctl is-active ssh &>/dev/null; then
        ssh_service="ssh"
    elif pct exec "$lxc_id" -- systemctl is-active sshd &>/dev/null; then
        ssh_service="sshd"
    elif pct exec "$lxc_id" -- systemctl status ssh &>/dev/null; then
        ssh_service="ssh"
    elif pct exec "$lxc_id" -- systemctl status sshd &>/dev/null; then
        ssh_service="sshd"
    fi

    if [ -n "$ssh_service" ]; then
        # Try to enable service for boot if not already
        if ! pct exec "$lxc_id" -- systemctl is-enabled "$ssh_service" &>/dev/null; then
            if pct exec "$lxc_id" -- systemctl enable "$ssh_service" &>/dev/null; then
                log_container "$lxc_id" "SSH service enabled for auto-start on boot"
            fi
        fi

        # Try to start if not running
        if ! pct exec "$lxc_id" -- systemctl is-active "$ssh_service" &>/dev/null; then
            if pct exec "$lxc_id" -- systemctl start "$ssh_service" &>/dev/null; then
                log_container "$lxc_id" "SSH service started"
            fi
        fi
    fi

    # Final message
    if [ "$ssh_detected" = false ]; then
        log_container "$lxc_id" "${YELLOW}SSH may not be running. Install openssh-server if needed${NC}"
    fi

    # Get container IP
    local lxc_ip
    if lxc_ip=$(pct exec "$lxc_id" -- hostname -I 2>/dev/null | awk '{print $1}'); then
        if [ -n "$lxc_ip" ]; then
            CONTAINER_IPS[$lxc_id]=$lxc_ip
        fi
    fi

    log_container "$lxc_id" "${GREEN}User setup completed successfully${NC}"
    CONTAINER_RESULTS[$lxc_id]="SUCCESS"
    return 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c)
            shift
            # Collect all container IDs until next flag or end of args
            while [[ $# -gt 0 ]] && [[ ! $1 =~ ^- ]]; do
                LXC_IDS+=("$1")
                shift
            done
            ;;
        -u)
            USERNAME="$2"
            shift 2
            ;;
        -k)
            SSH_PUBKEY="$2"
            shift 2
            ;;
        -p)
            PASSWORD="$2"
            shift 2
            ;;
        -g)
            GENERATE_PASSWORD=true
            shift
            ;;
        -n)
            SUDO_NOPASSWD=true
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
if [ ${#LXC_IDS[@]} -eq 0 ] || [ -z "${USERNAME:-}" ]; then
    log_error "Missing required arguments"
    usage
fi

# Validate username format
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log_error "Invalid username format. Use lowercase letters, numbers, underscore, and hyphen only."
    exit 1
fi

# Handle password generation (once for all containers)
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

# Display summary of what will be done
echo
log_info "Setting up user '$USERNAME' in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    setup_user_in_container "$lxc_id" "$USERNAME" "$PASSWORD" "$SSH_PUBKEY" "$SUDO_NOPASSWD"
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
skipped_count=0

for lxc_id in "${LXC_IDS[@]}"; do
    result="${CONTAINER_RESULTS[$lxc_id]:-UNKNOWN}"
    case $result in
        SUCCESS)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: Success"
            if [ -n "${CONTAINER_IPS[$lxc_id]:-}" ]; then
                echo "    ssh $USERNAME@${CONTAINER_IPS[$lxc_id]}"
            fi
            ((success_count++))
            ;;
        SKIPPED*)
            echo -e "  ${YELLOW}⊘${NC} LXC $lxc_id: $result"
            ((skipped_count++))
            ;;
        FAILED*)
            echo -e "  ${RED}✗${NC} LXC $lxc_id: $result"
            ((failed_count++))
            ;;
        *)
            echo -e "  ${YELLOW}?${NC} LXC $lxc_id: $result"
            ((failed_count++))
            ;;
    esac
done

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
echo
echo "  Results: $success_count succeeded, $failed_count failed, $skipped_count skipped"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with error if any containers failed
if [ $failed_count -gt 0 ]; then
    exit 1
fi
