#!/bin/bash

set -euo pipefail

# Script: Bulk Container Control
# Description: Start, stop, or restart multiple LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
ACTION=""

# Arrays to track results
declare -A CONTAINER_RESULTS

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] -a ACTION

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)
  -a ACTION              Action to perform: start, stop, restart, shutdown

Optional arguments:
  -h                     Show this help message

Actions:
  start     - Start stopped containers
  stop      - Force stop running containers
  shutdown  - Gracefully shutdown running containers
  restart   - Restart running containers

Examples:
  # Start multiple containers
  $0 -c 100 101 102 -a start

  # Restart containers
  $0 -c 100 101 102 -a restart

  # Gracefully shutdown containers
  $0 -c 100 101 102 -a shutdown

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

get_lxc_status() {
    pct status "$1" 2>/dev/null | awk '{print $2}'
}

control_container() {
    local lxc_id=$1
    local action=$2

    log_container "$lxc_id" "Performing action: $action"

    # Validate LXC container exists
    if ! validate_lxc_exists "$lxc_id"; then
        log_container "$lxc_id" "${RED}Container does not exist${NC}"
        CONTAINER_RESULTS[$lxc_id]="FAILED: Not found"
        return 1
    fi

    local current_status
    current_status=$(get_lxc_status "$lxc_id")
    log_container "$lxc_id" "Current status: $current_status"

    case $action in
        start)
            if [ "$current_status" = "running" ]; then
                log_container "$lxc_id" "${YELLOW}Already running${NC}"
                CONTAINER_RESULTS[$lxc_id]="SKIPPED: Already running"
                return 0
            fi

            if pct start "$lxc_id"; then
                # Wait for container to start
                sleep 2
                local wait_count=0
                while [ $wait_count -lt 30 ]; do
                    if [ "$(get_lxc_status "$lxc_id")" = "running" ]; then
                        log_container "$lxc_id" "${GREEN}Started successfully${NC}"
                        CONTAINER_RESULTS[$lxc_id]="SUCCESS"
                        return 0
                    fi
                    sleep 1
                    wait_count=$((wait_count + 1))
                done
                log_container "$lxc_id" "${YELLOW}Started but taking longer than expected${NC}"
                CONTAINER_RESULTS[$lxc_id]="SUCCESS (slow start)"
            else
                log_container "$lxc_id" "${RED}Failed to start${NC}"
                CONTAINER_RESULTS[$lxc_id]="FAILED: Start failed"
                return 1
            fi
            ;;

        stop)
            if [ "$current_status" = "stopped" ]; then
                log_container "$lxc_id" "${YELLOW}Already stopped${NC}"
                CONTAINER_RESULTS[$lxc_id]="SKIPPED: Already stopped"
                return 0
            fi

            if pct stop "$lxc_id"; then
                log_container "$lxc_id" "${GREEN}Stopped successfully${NC}"
                CONTAINER_RESULTS[$lxc_id]="SUCCESS"
            else
                log_container "$lxc_id" "${RED}Failed to stop${NC}"
                CONTAINER_RESULTS[$lxc_id]="FAILED: Stop failed"
                return 1
            fi
            ;;

        shutdown)
            if [ "$current_status" = "stopped" ]; then
                log_container "$lxc_id" "${YELLOW}Already stopped${NC}"
                CONTAINER_RESULTS[$lxc_id]="SKIPPED: Already stopped"
                return 0
            fi

            if pct shutdown "$lxc_id"; then
                # Wait for graceful shutdown
                sleep 2
                local wait_count=0
                while [ $wait_count -lt 60 ]; do
                    if [ "$(get_lxc_status "$lxc_id")" = "stopped" ]; then
                        log_container "$lxc_id" "${GREEN}Shutdown successfully${NC}"
                        CONTAINER_RESULTS[$lxc_id]="SUCCESS"
                        return 0
                    fi
                    sleep 2
                    wait_count=$((wait_count + 1))
                done
                log_container "$lxc_id" "${YELLOW}Shutdown timeout, may still be shutting down${NC}"
                CONTAINER_RESULTS[$lxc_id]="TIMEOUT"
            else
                log_container "$lxc_id" "${RED}Failed to shutdown${NC}"
                CONTAINER_RESULTS[$lxc_id]="FAILED: Shutdown failed"
                return 1
            fi
            ;;

        restart)
            if [ "$current_status" != "running" ]; then
                log_container "$lxc_id" "${YELLOW}Container not running, starting instead${NC}"
                pct start "$lxc_id"
                CONTAINER_RESULTS[$lxc_id]="SUCCESS (started)"
            elif pct reboot "$lxc_id"; then
                # Wait for reboot
                sleep 3
                local wait_count=0
                while [ $wait_count -lt 60 ]; do
                    if [ "$(get_lxc_status "$lxc_id")" = "running" ]; then
                        log_container "$lxc_id" "${GREEN}Restarted successfully${NC}"
                        CONTAINER_RESULTS[$lxc_id]="SUCCESS"
                        return 0
                    fi
                    sleep 2
                    wait_count=$((wait_count + 1))
                done
                log_container "$lxc_id" "${YELLOW}Restart taking longer than expected${NC}"
                CONTAINER_RESULTS[$lxc_id]="SUCCESS (slow restart)"
            else
                log_container "$lxc_id" "${RED}Failed to restart${NC}"
                CONTAINER_RESULTS[$lxc_id]="FAILED: Restart failed"
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
if [ ${#LXC_IDS[@]} -eq 0 ] || [ -z "$ACTION" ]; then
    log_error "Missing required arguments"
    usage
fi

# Validate action
if [[ ! "$ACTION" =~ ^(start|stop|shutdown|restart)$ ]]; then
    log_error "Invalid action: $ACTION"
    usage
fi

# Display summary of what will be done
echo
log_info "Action '$ACTION' will be performed on ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    control_container "$lxc_id" "$ACTION"
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
        SUCCESS*)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: $result"
            success_count=$((success_count + 1))
            ;;
        SKIPPED*)
            echo -e "  ${YELLOW}⊘${NC} LXC $lxc_id: $result"
            skipped_count=$((skipped_count + 1))
            ;;
        TIMEOUT)
            echo -e "  ${YELLOW}⌛${NC} LXC $lxc_id: Operation timeout"
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
