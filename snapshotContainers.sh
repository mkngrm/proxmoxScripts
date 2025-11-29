#!/bin/bash

set -euo pipefail

# Script: Snapshot Containers
# Description: Create or delete snapshots across multiple LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
ACTION=""
SNAPSHOT_NAME=""
DESCRIPTION=""

# Arrays to track results
declare -A CONTAINER_RESULTS

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] -a ACTION -s SNAPSHOT_NAME [OPTIONS]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)
  -a ACTION              Action: create or delete
  -s SNAPSHOT_NAME       Name for the snapshot

Optional arguments:
  -d DESCRIPTION         Description for the snapshot (create only)
  -h                     Show this help message

Examples:
  # Create snapshots before updates
  $0 -c 100 101 102 -a create -s pre-update -d "Before system update"

  # Create snapshots with timestamp
  $0 -c 100 101 102 -a create -s backup-\$(date +%Y%m%d)

  # Delete old snapshots
  $0 -c 100 101 102 -a delete -s pre-update

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

snapshot_exists() {
    pct listsnapshot "$1" 2>/dev/null | grep -q "^$2\s" && return 0 || return 1
}

manage_snapshot() {
    local lxc_id=$1
    local action=$2
    local snapshot_name=$3
    local description=$4

    log_container "$lxc_id" "Managing snapshot: $snapshot_name"

    # Validate LXC container exists
    if ! validate_lxc_exists "$lxc_id"; then
        log_container "$lxc_id" "${RED}Container does not exist${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Not found"
        return 1
    fi

    case $action in
        create)
            # Check if snapshot already exists
            if snapshot_exists "$lxc_id" "$snapshot_name"; then
                log_container "$lxc_id" "${YELLOW}Snapshot '$snapshot_name' already exists${NC}"
                CONTAINER_RESULTS[$lxc_id]="SKIPPED: Already exists"
                return 0
            fi

            # Create snapshot
            log_container "$lxc_id" "Creating snapshot..."
            local cmd="pct snapshot $lxc_id $snapshot_name"
            if [ -n "$description" ]; then
                cmd+=" --description \"$description\""
            fi

            if eval "$cmd" &>/dev/null; then
                log_container "$lxc_id" "${GREEN}Snapshot created successfully${NC}"
                CONTAINER_RESULTS[$lxc_id]="SUCCESS"
            else
                log_container "$lxc_id" "${RED}Failed to create snapshot${NC}"
                CONTAINER_RESULTS[$lxc_id]="FAILED: Creation failed"
                return 1
            fi
            ;;

        delete)
            # Check if snapshot exists
            if ! snapshot_exists "$lxc_id" "$snapshot_name"; then
                log_container "$lxc_id" "${YELLOW}Snapshot '$snapshot_name' does not exist${NC}"
                CONTAINER_RESULTS[$lxc_id]="SKIPPED: Not found"
                return 0
            fi

            # Delete snapshot
            log_container "$lxc_id" "Deleting snapshot..."
            if pct delsnapshot "$lxc_id" "$snapshot_name" &>/dev/null; then
                log_container "$lxc_id" "${GREEN}Snapshot deleted successfully${NC}"
                CONTAINER_RESULTS[$lxc_id]="SUCCESS"
            else
                log_container "$lxc_id" "${RED}Failed to delete snapshot${NC}"
                CONTAINER_RESULTS[$lxc_id]="FAILED: Deletion failed"
                return 1
            fi
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
        -a)
            ACTION="$2"
            shift 2
            ;;
        -s)
            SNAPSHOT_NAME="$2"
            shift 2
            ;;
        -d)
            DESCRIPTION="$2"
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
if [ ${#LXC_IDS[@]} -eq 0 ] || [ -z "$ACTION" ] || [ -z "$SNAPSHOT_NAME" ]; then
    log_error "Missing required arguments"
    usage
fi

# Validate action
if [[ ! "$ACTION" =~ ^(create|delete)$ ]]; then
    log_error "Invalid action: $ACTION (must be 'create' or 'delete')"
    usage
fi

# Display summary of what will be done
echo
log_info "Snapshot '$SNAPSHOT_NAME' will be ${ACTION}d in ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
if [ -n "$DESCRIPTION" ] && [ "$ACTION" = "create" ]; then
    log_info "Description: $DESCRIPTION"
fi
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    manage_snapshot "$lxc_id" "$ACTION" "$SNAPSHOT_NAME" "$DESCRIPTION"
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
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: Snapshot ${ACTION}d"
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
