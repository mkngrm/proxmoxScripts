#!/bin/bash

set -euo pipefail

# Script: Deploy SSH Keys
# Description: Add or remove SSH keys from users across multiple LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
USERNAME=""
SSH_KEY_FILE=""
ACTION="add"

# Arrays to track results
declare -A CONTAINER_RESULTS

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] -u USERNAME -k KEY_FILE [OPTIONS]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)
  -u USERNAME            Username to manage SSH keys for
  -k KEY_FILE            Path to SSH public key file

Optional arguments:
  -r                     Remove key instead of adding (default: add)
  -h                     Show this help message

Examples:
  # Add SSH key to user across containers
  $0 -c 100 101 102 -u junior -k ~/.ssh/id_rsa.pub

  # Remove SSH key from user
  $0 -c 100 101 102 -u junior -k ~/.ssh/old_key.pub -r

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

manage_ssh_key() {
    local lxc_id=$1
    local username=$2
    local key_file=$3
    local action=$4

    log_container "$lxc_id" "Managing SSH key for user '$username'..."

    # Validate LXC container exists
    if ! validate_lxc_exists "$lxc_id"; then
        log_container "$lxc_id" "${RED}Container does not exist${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Not found"
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

    # Check if user exists
    if ! pct exec "$lxc_id" -- id "$username" &>/dev/null; then
        log_container "$lxc_id" "${RED}User '$username' does not exist${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: User not found"
        return 1
    fi

    # Read the key content
    local key_content
    key_content=$(cat "$key_file")

    # Get user's home directory
    local home_dir
    home_dir=$(pct exec "$lxc_id" -- getent passwd "$username" | cut -d: -f6)

    case $action in
        add)
            # Ensure .ssh directory exists
            pct exec "$lxc_id" -- mkdir -p "$home_dir/.ssh"
            pct exec "$lxc_id" -- chmod 700 "$home_dir/.ssh"

            # Check if key already exists
            if pct exec "$lxc_id" -- grep -Fxq "$key_content" "$home_dir/.ssh/authorized_keys" 2>/dev/null; then
                log_container "$lxc_id" "${YELLOW}Key already exists${NC}"
                CONTAINER_RESULTS[$lxc_id]="SKIPPED: Key exists"
                return 0
            fi

            # Add the key
            pct exec "$lxc_id" -- bash -c "echo '$key_content' >> $home_dir/.ssh/authorized_keys"
            pct exec "$lxc_id" -- chmod 600 "$home_dir/.ssh/authorized_keys"
            pct exec "$lxc_id" -- chown -R "$username:$username" "$home_dir/.ssh"

            log_container "$lxc_id" "${GREEN}SSH key added successfully${NC}"
            CONTAINER_RESULTS[$lxc_id]="SUCCESS"
            ;;

        remove)
            # Check if authorized_keys exists
            if ! pct exec "$lxc_id" -- test -f "$home_dir/.ssh/authorized_keys"; then
                log_container "$lxc_id" "${YELLOW}No authorized_keys file${NC}"
                CONTAINER_RESULTS[$lxc_id]="SKIPPED: No keys file"
                return 0
            fi

            # Check if key exists
            if ! pct exec "$lxc_id" -- grep -Fq "$key_content" "$home_dir/.ssh/authorized_keys" 2>/dev/null; then
                log_container "$lxc_id" "${YELLOW}Key not found${NC}"
                CONTAINER_RESULTS[$lxc_id]="SKIPPED: Key not found"
                return 0
            fi

            # Remove the key
            pct exec "$lxc_id" -- bash -c "grep -Fv '$key_content' $home_dir/.ssh/authorized_keys > $home_dir/.ssh/authorized_keys.tmp && mv $home_dir/.ssh/authorized_keys.tmp $home_dir/.ssh/authorized_keys"
            pct exec "$lxc_id" -- chmod 600 "$home_dir/.ssh/authorized_keys"

            log_container "$lxc_id" "${GREEN}SSH key removed successfully${NC}"
            CONTAINER_RESULTS[$lxc_id]="SUCCESS"
            ;;

        *)
            log_container "$lxc_id" "${RED}Unknown action: $action${NC}"
            CONTAINER_RESULTS[$lxc_id]="FAILED: Invalid action"
            return 1
            ;;
    esac

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
        -u)
            USERNAME="$2"
            shift 2
            ;;
        -k)
            SSH_KEY_FILE="$2"
            shift 2
            ;;
        -r)
            ACTION="remove"
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
if [ ${#LXC_IDS[@]} -eq 0 ] || [ -z "$USERNAME" ] || [ -z "$SSH_KEY_FILE" ]; then
    log_error "Missing required arguments"
    usage
fi

# Validate key file exists
if [ ! -f "$SSH_KEY_FILE" ]; then
    log_error "SSH key file not found: $SSH_KEY_FILE"
    exit 1
fi

# Display summary of what will be done
echo
log_info "SSH key will be ${ACTION}ed for user '$USERNAME' in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
log_info "Key file: $SSH_KEY_FILE"
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    manage_ssh_key "$lxc_id" "$USERNAME" "$SSH_KEY_FILE" "$ACTION"
    echo
done

# Display final summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Summary of operations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Count successes and failures
success_count=0
skipped_count=0
failed_count=0

for lxc_id in "${LXC_IDS[@]}"; do
    result="${CONTAINER_RESULTS[$lxc_id]:-UNKNOWN}"

    case $result in
        SUCCESS)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: Key ${ACTION}ed"
            success_count=$((success_count + 1))
            ;;
        SKIPPED*)
            echo -e "  ${YELLOW}⊘${NC} LXC $lxc_id: $result"
            skipped_count=$((skipped_count + 1))
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
echo "  Results: $success_count succeeded, $skipped_count skipped, $failed_count failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with error if any containers failed
if [ $failed_count -gt 0 ]; then
    exit 1
fi
