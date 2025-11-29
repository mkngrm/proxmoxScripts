#!/bin/bash

set -euo pipefail

# Script: Health Check Containers
# Description: Check health status of multiple LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()
DISK_THRESHOLD=80
MEMORY_THRESHOLD=90

# Arrays to track results
declare -A CONTAINER_STATUS
declare -A CONTAINER_ISSUES

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...] [OPTIONS]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)

Optional arguments:
  -d PERCENT             Disk usage warning threshold (default: 80%)
  -m PERCENT             Memory usage warning threshold (default: 90%)
  -h                     Show this help message

Health checks performed:
  - Container running status
  - Disk space usage
  - Memory usage
  - SSH service status
  - System load average

Examples:
  # Check health of multiple containers
  $0 -c 100 101 102

  # Check with custom thresholds
  $0 -c 100 101 102 -d 90 -m 85

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

check_container_health() {
    local lxc_id=$1
    local disk_threshold=$2
    local memory_threshold=$3
    local issues=()

    log_container "$lxc_id" "Running health checks..."

    # Validate LXC container exists
    if ! validate_lxc_exists "$lxc_id"; then
        log_container "$lxc_id" "${RED}Container does not exist${NC}"
        CONTAINER_STATUS[$lxc_id]="NOT_FOUND"
        CONTAINER_ISSUES[$lxc_id]="Container not found"
        return 1
    fi

    # Check if running
    if ! validate_lxc_running "$lxc_id"; then
        local status
        status=$(pct status "$lxc_id" 2>/dev/null | awk '{print $2}')
        log_container "$lxc_id" "${RED}Container not running (status: $status)${NC}"
        CONTAINER_STATUS[$lxc_id]="NOT_RUNNING"
        CONTAINER_ISSUES[$lxc_id]="Status: $status"
        return 1
    fi

    # Check disk usage
    log_container "$lxc_id" "Checking disk usage..."
    local disk_usage
    disk_usage=$(pct exec "$lxc_id" -- df -h / | tail -1 | awk '{print $5}' | sed 's/%//')

    if [ "$disk_usage" -ge "$disk_threshold" ]; then
        log_container "$lxc_id" "${YELLOW}Disk usage: ${disk_usage}% (threshold: ${disk_threshold}%)${NC}"
        issues+=("Disk ${disk_usage}%")
    else
        log_container "$lxc_id" "Disk usage: ${disk_usage}%"
    fi

    # Check memory usage
    log_container "$lxc_id" "Checking memory usage..."
    local memory_usage
    memory_usage=$(pct exec "$lxc_id" -- free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')

    if [ "$memory_usage" -ge "$memory_threshold" ]; then
        log_container "$lxc_id" "${YELLOW}Memory usage: ${memory_usage}% (threshold: ${memory_threshold}%)${NC}"
        issues+=("Memory ${memory_usage}%")
    else
        log_container "$lxc_id" "Memory usage: ${memory_usage}%"
    fi

    # Check SSH service
    log_container "$lxc_id" "Checking SSH service..."
    local ssh_status="unknown"
    if pct exec "$lxc_id" -- systemctl is-active ssh &>/dev/null; then
        ssh_status="running"
        log_container "$lxc_id" "SSH service: running"
    elif pct exec "$lxc_id" -- systemctl is-active sshd &>/dev/null; then
        ssh_status="running"
        log_container "$lxc_id" "SSH service: running"
    elif pct exec "$lxc_id" -- pgrep -f 'sshd' &>/dev/null; then
        ssh_status="running"
        log_container "$lxc_id" "SSH service: running"
    else
        ssh_status="not running"
        log_container "$lxc_id" "${YELLOW}SSH service: not running${NC}"
        issues+=("SSH not running")
    fi

    # Check system load
    log_container "$lxc_id" "Checking system load..."
    local load_avg
    load_avg=$(pct exec "$lxc_id" -- uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    log_container "$lxc_id" "Load average (1m): $load_avg"

    # Get uptime
    local uptime_str
    uptime_str=$(pct exec "$lxc_id" -- uptime -p)
    log_container "$lxc_id" "Uptime: $uptime_str"

    # Determine overall status
    if [ ${#issues[@]} -eq 0 ]; then
        log_container "$lxc_id" "${GREEN}Health check passed${NC}"
        CONTAINER_STATUS[$lxc_id]="HEALTHY"
        CONTAINER_ISSUES[$lxc_id]="All checks passed"
    else
        log_container "$lxc_id" "${YELLOW}Health check completed with warnings${NC}"
        CONTAINER_STATUS[$lxc_id]="WARNING"
        CONTAINER_ISSUES[$lxc_id]=$(IFS=", "; echo "${issues[*]}")
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
        -d)
            DISK_THRESHOLD="$2"
            shift 2
            ;;
        -m)
            MEMORY_THRESHOLD="$2"
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
if [ ${#LXC_IDS[@]} -eq 0 ]; then
    log_error "Missing required argument: -c LXC_ID"
    usage
fi

# Display summary of what will be done
echo
log_info "Running health checks on ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
log_info "Thresholds: Disk ${DISK_THRESHOLD}%, Memory ${MEMORY_THRESHOLD}%"
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    check_container_health "$lxc_id" "$DISK_THRESHOLD" "$MEMORY_THRESHOLD"
    echo
done

# Display final summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Health Check Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Count statuses
healthy_count=0
warning_count=0
failed_count=0

for lxc_id in "${LXC_IDS[@]}"; do
    status="${CONTAINER_STATUS[$lxc_id]:-UNKNOWN}"
    issues="${CONTAINER_ISSUES[$lxc_id]:-No info}"

    case $status in
        HEALTHY)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: Healthy"
            healthy_count=$((healthy_count + 1))
            ;;
        WARNING)
            echo -e "  ${YELLOW}⚠${NC} LXC $lxc_id: $issues"
            warning_count=$((warning_count + 1))
            ;;
        NOT_RUNNING)
            echo -e "  ${RED}⊗${NC} LXC $lxc_id: Not running ($issues)"
            failed_count=$((failed_count + 1))
            ;;
        NOT_FOUND)
            echo -e "  ${RED}✗${NC} LXC $lxc_id: Not found"
            failed_count=$((failed_count + 1))
            ;;
        *)
            echo -e "  ${YELLOW}?${NC} LXC $lxc_id: $status"
            failed_count=$((failed_count + 1))
            ;;
    esac
done

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $healthy_count healthy, $warning_count warnings, $failed_count offline/failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with warning if any containers have warnings or failures
if [ $warning_count -gt 0 ] || [ $failed_count -gt 0 ]; then
    exit 1
fi
