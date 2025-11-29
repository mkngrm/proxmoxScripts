#!/bin/bash

set -euo pipefail

# Script: Sync Timezone
# Description: Set timezone across multiple LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
TIMEZONE=""

# Arrays to track results
declare -A CONTAINER_RESULTS
declare -A CONTAINER_PREVIOUS_TZ

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] -t TIMEZONE

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)
  -t TIMEZONE            Timezone to set (e.g., America/New_York, UTC, Europe/London)

Optional arguments:
  -h                     Show this help message

Examples:
  # Set timezone to UTC
  $0 -c 100 101 102 -t UTC

  # Set timezone to Eastern Time
  $0 -c 100 101 102 -t America/New_York

  # Set timezone to Central European Time
  $0 -c 100 101 102 -t Europe/Paris

Common timezones:
  - UTC
  - America/New_York (Eastern)
  - America/Chicago (Central)
  - America/Denver (Mountain)
  - America/Los_Angeles (Pacific)
  - Europe/London
  - Europe/Paris
  - Asia/Tokyo

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

set_timezone() {
    local lxc_id=$1
    local timezone=$2

    log_container "$lxc_id" "Setting timezone to '$timezone'..."

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

    # Get current timezone
    local current_tz
    current_tz=$(pct exec "$lxc_id" -- timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
    CONTAINER_PREVIOUS_TZ[$lxc_id]=$current_tz
    log_container "$lxc_id" "Current timezone: $current_tz"

    # Check if already set
    if [ "$current_tz" = "$timezone" ]; then
        log_container "$lxc_id" "${YELLOW}Already set to '$timezone'${NC}"
        CONTAINER_RESULTS[$lxc_id]="SKIPPED: Already set"
        return 0
    fi

    # Validate timezone exists in container
    if ! pct exec "$lxc_id" -- test -f "/usr/share/zoneinfo/$timezone"; then
        log_container "$lxc_id" "${RED}Invalid timezone: $timezone${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Invalid timezone"
        return 1
    fi

    # Set timezone using timedatectl
    if pct exec "$lxc_id" -- timedatectl set-timezone "$timezone" &>/dev/null; then
        log_container "$lxc_id" "${GREEN}Timezone set successfully${NC}"
        CONTAINER_RESULTS[$lxc_id]="SUCCESS"
    else
        log_container "$lxc_id" "${RED}Failed to set timezone${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Set timezone failed"
        return 1
    fi

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
        -t)
            TIMEZONE="$2"
            shift 2
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
if [ ${#LXC_IDS[@]} -eq 0 ] || [ -z "$TIMEZONE" ]; then
    log_error "Missing required arguments"
    usage
fi

# Display summary of what will be done
echo
log_info "Timezone will be set to '$TIMEZONE' in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    set_timezone "$lxc_id" "$TIMEZONE"
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
    previous="${CONTAINER_PREVIOUS_TZ[$lxc_id]:-unknown}"

    case $result in
        SUCCESS)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: $previous → $TIMEZONE"
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
