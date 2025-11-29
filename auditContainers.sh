#!/bin/bash

set -euo pipefail

# Script: Audit Containers
# Description: Security audit across multiple LXC containers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
LXC_IDS=()

# Arrays to track results
declare -A CONTAINER_ISSUES

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [LXC_ID...]

Required arguments:
  -c LXC_ID [LXC_ID...]  One or more LXC container IDs (space-separated)

Optional arguments:
  -h                     Show this help message

Security checks performed:
  - Users with sudo/root access
  - SSH root login configuration
  - Users with empty passwords
  - World-writable files in sensitive directories
  - SUID/SGID binaries
  - Listening network services

Examples:
  # Audit multiple containers
  $0 -c 100 101 102

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

audit_container() {
    local lxc_id=$1
    local issues_found=0
    local issues_list=()

    log_container "$lxc_id" "Running security audit..."

    # Validate LXC container exists
    if ! validate_lxc_exists "$lxc_id"; then
        log_container "$lxc_id" "${RED}Container does not exist${NC}"
        CONTAINER_ISSUES[$lxc_id]="NOT_FOUND"
        return 1
    fi

    # Validate LXC container is running
    if ! validate_lxc_running "$lxc_id"; then
        local status
        status=$(pct status "$lxc_id" 2>/dev/null | awk '{print $2}')
        log_container "$lxc_id" "${RED}Container not running (status: $status)${NC}"
        CONTAINER_ISSUES[$lxc_id]="NOT_RUNNING"
        return 1
    fi

    # Check users with sudo access
    log_container "$lxc_id" "Checking sudo users..."
    local sudo_users
    sudo_users=$(pct exec "$lxc_id" -- getent group sudo 2>/dev/null | cut -d: -f4 || echo "")
    if [ -n "$sudo_users" ]; then
        log_container "$lxc_id" "Sudo users: $sudo_users"
    fi

    # Check root SSH login setting
    log_container "$lxc_id" "Checking SSH root login..."
    local root_login
    root_login=$(pct exec "$lxc_id" -- grep -i "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not-set")

    if [ "$root_login" = "yes" ]; then
        log_container "$lxc_id" "${YELLOW}⚠ Root SSH login enabled${NC}"
        issues_found=$((issues_found + 1))
        issues_list+=("Root SSH enabled")
    elif [ "$root_login" = "not-set" ]; then
        log_container "$lxc_id" "Root SSH login: default (check distribution default)"
    else
        log_container "$lxc_id" "Root SSH login: $root_login"
    fi

    # Check for users with empty passwords
    log_container "$lxc_id" "Checking for empty passwords..."
    local empty_pass_users
    empty_pass_users=$(pct exec "$lxc_id" -- awk -F: '($2 == "" || $2 == "!") && $1 != "root" {print $1}' /etc/shadow 2>/dev/null | tr '\n' ' ' || echo "")

    if [ -n "$empty_pass_users" ]; then
        log_container "$lxc_id" "${YELLOW}⚠ Users with empty/locked passwords: $empty_pass_users${NC}"
        issues_found=$((issues_found + 1))
        issues_list+=("Empty passwords: $empty_pass_users")
    fi

    # Check listening services
    log_container "$lxc_id" "Checking listening services..."
    local listening_ports
    listening_ports=$(pct exec "$lxc_id" -- ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | awk -F: '{print $NF}' | sort -u | tr '\n' ' ' || echo "")

    if [ -n "$listening_ports" ]; then
        log_container "$lxc_id" "Listening ports: $listening_ports"
    fi

    # Check for world-writable files in /etc
    log_container "$lxc_id" "Checking world-writable files in /etc..."
    local world_writable
    world_writable=$(pct exec "$lxc_id" -- find /etc -type f -perm -002 2>/dev/null | head -5 | tr '\n' ' ' || echo "")

    if [ -n "$world_writable" ]; then
        log_container "$lxc_id" "${YELLOW}⚠ World-writable files found in /etc${NC}"
        issues_found=$((issues_found + 1))
        issues_list+=("World-writable /etc files")
    fi

    # Check SUID binaries
    log_container "$lxc_id" "Checking SUID binaries..."
    local suid_count
    suid_count=$(pct exec "$lxc_id" -- find /usr /bin /sbin -type f -perm -4000 2>/dev/null | wc -l || echo "0")
    log_container "$lxc_id" "SUID binaries found: $suid_count"

    # Check if firewall is active
    log_container "$lxc_id" "Checking firewall status..."
    local ufw_status
    ufw_status=$(pct exec "$lxc_id" -- ufw status 2>/dev/null | grep -i "status:" | awk '{print $2}' || echo "not-installed")

    if [ "$ufw_status" = "inactive" ] || [ "$ufw_status" = "not-installed" ]; then
        log_container "$lxc_id" "${YELLOW}⚠ Firewall not active${NC}"
        issues_found=$((issues_found + 1))
        issues_list+=("No firewall")
    else
        log_container "$lxc_id" "Firewall: $ufw_status"
    fi

    # Check for unattended upgrades
    log_container "$lxc_id" "Checking unattended upgrades..."
    if pct exec "$lxc_id" -- dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        log_container "$lxc_id" "Unattended upgrades: installed"
    else
        log_container "$lxc_id" "${YELLOW}⚠ Unattended upgrades not installed${NC}"
        issues_found=$((issues_found + 1))
        issues_list+=("No auto-updates")
    fi

    # Store results
    if [ $issues_found -eq 0 ]; then
        log_container "$lxc_id" "${GREEN}Audit completed - no major issues${NC}"
        CONTAINER_ISSUES[$lxc_id]="CLEAN"
    else
        log_container "$lxc_id" "${YELLOW}Audit completed - $issues_found issue(s) found${NC}"
        CONTAINER_ISSUES[$lxc_id]=$(IFS=", "; echo "${issues_list[*]}")
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
log_info "Running security audit on ${#LXC_IDS[@]} container(s): ${LXC_IDS[*]}"
echo

# Process each container
for lxc_id in "${LXC_IDS[@]}"; do
    audit_container "$lxc_id"
    echo
done

# Display final summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Security Audit Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Count statuses
clean_count=0
issues_count=0
offline_count=0

for lxc_id in "${LXC_IDS[@]}"; do
    issues="${CONTAINER_ISSUES[$lxc_id]:-UNKNOWN}"

    case $issues in
        CLEAN)
            echo -e "  ${GREEN}✓${NC} LXC $lxc_id: No major issues"
            clean_count=$((clean_count + 1))
            ;;
        NOT_RUNNING)
            echo -e "  ${RED}⊗${NC} LXC $lxc_id: Not running"
            offline_count=$((offline_count + 1))
            ;;
        NOT_FOUND)
            echo -e "  ${RED}✗${NC} LXC $lxc_id: Not found"
            offline_count=$((offline_count + 1))
            ;;
        *)
            echo -e "  ${YELLOW}⚠${NC} LXC $lxc_id: $issues"
            issues_count=$((issues_count + 1))
            ;;
    esac
done

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $clean_count clean, $issues_count with issues, $offline_count offline"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with warning if any containers have issues
if [ $issues_count -gt 0 ] || [ $offline_count -gt 0 ]; then
    exit 1
fi
