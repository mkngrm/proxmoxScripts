#!/bin/bash

set -euo pipefail

# Script: Update Containers
# Description: Update and upgrade packages across multiple LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
AUTO_YES=false
REBOOT_IF_NEEDED=false
UPDATE_ONLY=false

# Arrays to track results
declare -A CONTAINER_RESULTS
declare -A CONTAINER_UPDATES

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] [OPTIONS]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)

Optional arguments:
  -y                     Auto-yes (non-interactive, assumes yes to prompts)
  -r                     Reboot containers if required after updates
  -u                     Update only (skip upgrade, only refresh package lists)
  -h                     Show this help message

Examples:
  # Update and upgrade packages in multiple containers
  $0 -c 100 101 102 -y

  # Update only (refresh package lists without upgrading)
  $0 -c 100 101 102 -u

  # Update, upgrade, and reboot if needed
  $0 -c 100 101 102 -y -r

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

update_container() {
    local lxc_id=$1
    local auto_yes=$2
    local reboot_if_needed=$3
    local update_only=$4

    log_container "$lxc_id" "Starting package update process..."

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

    # Run apt update
    log_container "$lxc_id" "Updating package lists..."
    if ! pct exec "$lxc_id" -- apt-get update -qq 2>&1 | grep -v "^$"; then
        log_container "$lxc_id" "${YELLOW}Package list update completed with warnings${NC}"
    fi

    # If update-only mode, skip upgrade
    if [ "$update_only" = true ]; then
        log_container "$lxc_id" "Package lists updated (skipping upgrade)"
        CONTAINER_RESULTS[$lxc_id]="SUCCESS"
        CONTAINER_UPDATES[$lxc_id]="Updated lists only"
        return 0
    fi

    # Check for upgradable packages
    local upgradable_count
    upgradable_count=$(pct exec "$lxc_id" -- apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")

    if [ "$upgradable_count" -eq 0 ]; then
        log_container "$lxc_id" "${GREEN}No updates available${NC}"
        CONTAINER_RESULTS[$lxc_id]="SUCCESS"
        CONTAINER_UPDATES[$lxc_id]="Already up to date"
        return 0
    fi

    log_container "$lxc_id" "Found $upgradable_count package(s) to upgrade"

    # Run apt upgrade
    local apt_flags="-qq"
    if [ "$auto_yes" = true ]; then
        apt_flags="-y -qq"
    fi

    log_container "$lxc_id" "Upgrading packages..."
    if pct exec "$lxc_id" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get upgrade $apt_flags" &>/dev/null; then
        log_container "$lxc_id" "${GREEN}Packages upgraded successfully${NC}"
        CONTAINER_UPDATES[$lxc_id]="$upgradable_count package(s) upgraded"
    else
        log_container "$lxc_id" "${RED}Package upgrade failed${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Upgrade failed"
        return 1
    fi

    # Check if reboot is required
    if pct exec "$lxc_id" -- test -f /var/run/reboot-required; then
        log_container "$lxc_id" "${YELLOW}Reboot required${NC}"

        if [ "$reboot_if_needed" = true ]; then
            log_container "$lxc_id" "Rebooting container..."
            pct reboot "$lxc_id"

            # Wait for container to come back up
            sleep 5
            local wait_count=0
            while [ $wait_count -lt 30 ]; do
                if validate_lxc_running "$lxc_id"; then
                    log_container "$lxc_id" "Container rebooted successfully"
                    CONTAINER_UPDATES[$lxc_id]="${CONTAINER_UPDATES[$lxc_id]}, rebooted"
                    break
                fi
                sleep 2
                wait_count=$((wait_count + 1))
            done

            if [ $wait_count -eq 30 ]; then
                log_container "$lxc_id" "${YELLOW}Container taking longer than expected to start${NC}"
            fi
        else
            CONTAINER_UPDATES[$lxc_id]="${CONTAINER_UPDATES[$lxc_id]}, reboot needed"
        fi
    fi

    log_container "$lxc_id" "${GREEN}Update completed${NC}"
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
        -y)
            AUTO_YES=true
            shift
            ;;
        -r)
            REBOOT_IF_NEEDED=true
            shift
            ;;
        -u)
            UPDATE_ONLY=true
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
if [ "$UPDATE_ONLY" = true ]; then
    log_info "Updating package lists in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
else
    log_info "Updating and upgrading packages in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
fi
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    update_container "$lxc_id" "$AUTO_YES" "$REBOOT_IF_NEEDED" "$UPDATE_ONLY"
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
    updates="${CONTAINER_UPDATES[$lxc_id]:-No info}"

    case $result in
        SUCCESS)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: $updates"
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
