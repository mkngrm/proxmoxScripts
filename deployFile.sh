#!/bin/bash

set -euo pipefail

# Script: Deploy File
# Description: Copy files to multiple LXC containers with backup

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
SOURCE_FILE=""
DEST_PATH=""
OWNER=""
PERMISSIONS=""
BACKUP=true

# Arrays to track results
declare -A CONTAINER_RESULTS

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] -f SOURCE_FILE -d DEST_PATH [OPTIONS]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)
  -f SOURCE_FILE         Source file on Proxmox host to deploy
  -d DEST_PATH           Destination path in containers

Optional arguments:
  -o OWNER               Set owner (user:group format, e.g., root:root)
  -p PERMISSIONS         Set permissions (octal, e.g., 644, 755)
  -n                     No backup (skip backing up existing file)
  -h                     Show this help message

Examples:
  # Deploy custom motd to containers
  $0 -c 100 101 102 -f /root/custom_motd -d /etc/motd

  # Deploy script with specific permissions
  $0 -c 100 101 102 -f /root/script.sh -d /usr/local/bin/script.sh -p 755 -o root:root

  # Deploy config without backup
  $0 -c 100 101 102 -f /root/app.conf -d /etc/app/app.conf -n

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

deploy_file() {
    local lxc_id=$1
    local source_file=$2
    local dest_path=$3
    local owner=$4
    local permissions=$5
    local backup=$6

    log_container "$lxc_id" "Deploying file to '$dest_path'..."

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

    # Backup existing file if it exists and backup is enabled
    if [ "$backup" = true ] && pct exec "$lxc_id" -- test -f "$dest_path"; then
        local backup_path="${dest_path}.backup-$(date +%Y%m%d-%H%M%S)"
        log_container "$lxc_id" "Backing up existing file to $backup_path"
        pct exec "$lxc_id" -- cp "$dest_path" "$backup_path"
    fi

    # Ensure destination directory exists
    local dest_dir
    dest_dir=$(dirname "$dest_path")
    pct exec "$lxc_id" -- mkdir -p "$dest_dir"

    # Copy file to container
    log_container "$lxc_id" "Copying file..."
    if ! pct push "$lxc_id" "$source_file" "$dest_path"; then
        log_container "$lxc_id" "${RED}Failed to copy file${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Copy failed"
        return 1
    fi

    # Set ownership if specified
    if [ -n "$owner" ]; then
        log_container "$lxc_id" "Setting owner to $owner"
        if ! pct exec "$lxc_id" -- chown "$owner" "$dest_path"; then
            log_container "$lxc_id" "${YELLOW}Failed to set owner${NC}"
        fi
    fi

    # Set permissions if specified
    if [ -n "$permissions" ]; then
        log_container "$lxc_id" "Setting permissions to $permissions"
        if ! pct exec "$lxc_id" -- chmod "$permissions" "$dest_path"; then
            log_container "$lxc_id" "${YELLOW}Failed to set permissions${NC}"
        fi
    fi

    log_container "$lxc_id" "${GREEN}File deployed successfully${NC}"
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
        -f)
            SOURCE_FILE="$2"
            shift 2
            ;;
        -d)
            DEST_PATH="$2"
            shift 2
            ;;
        -o)
            OWNER="$2"
            shift 2
            ;;
        -p)
            PERMISSIONS="$2"
            shift 2
            ;;
        -n)
            BACKUP=false
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
if [ ${#LXC_IDS[@]} -eq 0 ] || [ -z "$SOURCE_FILE" ] || [ -z "$DEST_PATH" ]; then
    log_error "Missing required arguments"
    usage
fi

# Validate source file exists
if [ ! -f "$SOURCE_FILE" ]; then
    log_error "Source file not found: $SOURCE_FILE"
    exit 1
fi

# Display summary of what will be done
echo
log_info "File '$SOURCE_FILE' will be deployed to ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
log_info "Destination: $DEST_PATH"
if [ -n "$OWNER" ]; then
    log_info "Owner: $OWNER"
fi
if [ -n "$PERMISSIONS" ]; then
    log_info "Permissions: $PERMISSIONS"
fi
if [ "$BACKUP" = true ]; then
    log_info "Backup: Enabled"
else
    log_info "Backup: Disabled"
fi
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    deploy_file "$lxc_id" "$SOURCE_FILE" "$DEST_PATH" "$OWNER" "$PERMISSIONS" "$BACKUP"
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
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: File deployed"
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
