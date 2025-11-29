#!/bin/bash

set -euo pipefail

# Script: Disable Root SSH Login
# Description: Enable or disable root SSH login in one or more LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
ACTION="disable"  # disable or enable
STRICT_MODE=false  # Use 'no' instead of 'prohibit-password'

# Arrays to track results
declare -A CONTAINER_RESULTS
declare -A CONTAINER_PREVIOUS_STATE

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] [OPTIONS]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)

Optional arguments:
  -e                     Enable root SSH login (sets PermitRootLogin yes)
  -s                     Strict mode: completely disable root login (uses 'no' instead of 'prohibit-password')
  -h                     Show this help message

Default behavior:
  Without -e flag: Sets PermitRootLogin to 'prohibit-password' (key-based auth only)
  With -s flag: Sets PermitRootLogin to 'no' (completely blocks root login)
  With -e flag: Sets PermitRootLogin to 'yes' (allows root login)

Examples:
  # Disable password auth for root (allows keys only) - RECOMMENDED
  $0 -c 100 101 102

  # Completely disable root SSH login (strict mode)
  $0 -c 100 101 102 -s

  # Enable root SSH login
  $0 -c 100 101 102 -e

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

configure_root_ssh() {
    local lxc_id=$1
    local action=$2
    local strict_mode=$3
    local ssh_config="/etc/ssh/sshd_config"
    local backup_suffix=".backup-$(date +%Y%m%d-%H%M%S)"

    log_container "$lxc_id" "Starting root SSH configuration..."

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

    # Check if SSH config exists
    if ! pct exec "$lxc_id" -- test -f "$ssh_config"; then
        log_container "$lxc_id" "${RED}SSH config not found at $ssh_config${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: SSH config not found"
        return 1
    fi

    # Get current PermitRootLogin setting
    local current_setting
    current_setting=$(pct exec "$lxc_id" -- grep -i "^PermitRootLogin" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "not-set")

    # Also check for commented lines to see default
    if [ "$current_setting" = "not-set" ]; then
        current_setting=$(pct exec "$lxc_id" -- grep -i "^#PermitRootLogin" "$ssh_config" 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
        current_setting="$current_setting (commented)"
    fi

    CONTAINER_PREVIOUS_STATE[$lxc_id]=$current_setting
    log_container "$lxc_id" "Current setting: PermitRootLogin $current_setting"

    # Determine desired value based on action and strict mode
    local desired_value
    if [ "$action" = "enable" ]; then
        desired_value="yes"
    elif [ "$strict_mode" = true ]; then
        desired_value="no"
    else
        desired_value="prohibit-password"
    fi

    # Check if change is needed
    if [[ "$current_setting" == "$desired_value" ]]; then
        log_container "$lxc_id" "${YELLOW}Already set to '$desired_value', no change needed${NC}"
        CONTAINER_RESULTS[$lxc_id]="SKIPPED: Already $desired_value"
        return 0
    fi

    # Backup the config file
    log_container "$lxc_id" "Backing up SSH config..."
    if ! pct exec "$lxc_id" -- cp "$ssh_config" "${ssh_config}${backup_suffix}"; then
        log_container "$lxc_id" "${RED}Failed to backup SSH config${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Backup failed"
        return 1
    fi

    # Modify the config
    log_container "$lxc_id" "Setting PermitRootLogin to '$desired_value'..."

    # Remove any existing PermitRootLogin lines (commented or not)
    pct exec "$lxc_id" -- sed -i '/^#*PermitRootLogin/d' "$ssh_config"

    # Add the new setting at the end of the file
    pct exec "$lxc_id" -- bash -c "echo 'PermitRootLogin $desired_value' >> $ssh_config"

    # Verify the change
    local new_setting
    new_setting=$(pct exec "$lxc_id" -- grep "^PermitRootLogin" "$ssh_config" | awk '{print $2}')

    if [ "$new_setting" != "$desired_value" ]; then
        log_container "$lxc_id" "${RED}Failed to set PermitRootLogin${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Setting not applied"
        return 1
    fi

    # Reload SSH service
    log_container "$lxc_id" "Reloading SSH service..."
    local ssh_service=""
    if pct exec "$lxc_id" -- systemctl is-active ssh &>/dev/null; then
        ssh_service="ssh"
    elif pct exec "$lxc_id" -- systemctl is-active sshd &>/dev/null; then
        ssh_service="sshd"
    fi

    if [ -n "$ssh_service" ]; then
        if pct exec "$lxc_id" -- systemctl reload "$ssh_service" &>/dev/null || \
           pct exec "$lxc_id" -- systemctl restart "$ssh_service" &>/dev/null; then
            log_container "$lxc_id" "SSH service reloaded"
        else
            log_container "$lxc_id" "${YELLOW}Could not reload SSH service - you may need to restart it manually${NC}"
        fi
    else
        log_container "$lxc_id" "${YELLOW}Could not detect SSH service - restart manually if needed${NC}"
    fi

    log_container "$lxc_id" "${GREEN}Root SSH login ${action}d successfully${NC}"
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
        -e)
            ACTION="enable"
            shift
            ;;
        -s)
            STRICT_MODE=true
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
if [ "$ACTION" = "enable" ]; then
    log_info "Root SSH login will be enabled (PermitRootLogin yes) in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
elif [ "$STRICT_MODE" = true ]; then
    log_info "Root SSH login will be completely disabled (PermitRootLogin no) in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
else
    log_info "Root password login will be disabled (PermitRootLogin prohibit-password) in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
fi
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    configure_root_ssh "$lxc_id" "$ACTION" "$STRICT_MODE"
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
    previous="${CONTAINER_PREVIOUS_STATE[$lxc_id]:-unknown}"

    case $result in
        SUCCESS)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: Success (was: $previous)"
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
echo "  Action: Root SSH login ${ACTION}d"
echo "  Backup: Config files backed up with timestamp suffix"
echo
echo "  Results: $success_count succeeded, $failed_count failed, $skipped_count skipped"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with error if any containers failed
if [ $failed_count -gt 0 ]; then
    exit 1
fi
