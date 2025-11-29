#!/bin/bash

set -euo pipefail

# Script: Setup Stable Diffusion LXC
# Description: Create and configure an LXC container for Stable Diffusion (CPU mode)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
LXC_ID=""
LXC_HOSTNAME="stable-diffusion"
MEMORY_MB=8192
DISK_SIZE_GB=50
CORES=4
WEBUI_PORT=7860

# Functions
usage() {
    cat << EOF
Usage: $0 -c LXC_ID [OPTIONS]

Required arguments:
  -c LXC_ID              LXC container ID to create

Optional arguments:
  -n HOSTNAME            Hostname for container (default: stable-diffusion)
  -m MEMORY_MB           Memory in MB (default: 8192, recommend 8GB+)
  -d DISK_SIZE_GB        Disk size in GB (default: 50)
  -r CORES               CPU cores (default: 4)
  -p PORT                WebUI port (default: 7860)
  -h                     Show this help message

What this does:
  - Creates a Debian LXC container with Docker support
  - Installs AUTOMATIC1111's Stable Diffusion WebUI
  - Configures for CPU-only mode
  - Downloads SD 1.5 model (smaller, faster than SDXL)
  - Sets up web interface accessible from your network

Examples:
  # Create with defaults
  $0 -c 200

  # Create with more resources
  $0 -c 200 -m 16384 -r 8 -d 100

Requirements:
  - At least 8GB RAM recommended
  - 50GB+ disk space for models
  - This will take 10-30 minutes for initial setup

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

log_step() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}[STEP]${NC} $1"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c)
            LXC_ID="$2"
            shift 2
            ;;
        -n)
            LXC_HOSTNAME="$2"
            shift 2
            ;;
        -m)
            MEMORY_MB="$2"
            shift 2
            ;;
        -d)
            DISK_SIZE_GB="$2"
            shift 2
            ;;
        -r)
            CORES="$2"
            shift 2
            ;;
        -p)
            WEBUI_PORT="$2"
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
if [ -z "$LXC_ID" ]; then
    log_error "Missing required argument: -c LXC_ID"
    usage
fi

# Check if LXC already exists
if pct status "$LXC_ID" &>/dev/null; then
    log_error "LXC container $LXC_ID already exists"
    exit 1
fi

# Display configuration
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Stable Diffusion LXC Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Container ID: $LXC_ID"
echo "  Hostname: $LXC_HOSTNAME"
echo "  Memory: ${MEMORY_MB}MB"
echo "  Disk: ${DISK_SIZE_GB}GB"
echo "  CPU Cores: $CORES"
echo "  WebUI Port: $WEBUI_PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
log_warn "This will take 10-30 minutes for initial setup"
log_warn "Large models will be downloaded (~4-7GB)"
echo
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Step 1: Create LXC container
log_step "Creating LXC container"

log_info "Downloading Debian 12 template if needed..."
if ! pveam list local | grep -q "debian-12"; then
    pveam download local debian-12-standard_12.7-1_amd64.tar.zst
fi

log_info "Creating container..."
pct create "$LXC_ID" local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
    --hostname "$LXC_HOSTNAME" \
    --memory "$MEMORY_MB" \
    --cores "$CORES" \
    --rootfs local-lvm:${DISK_SIZE_GB} \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --features nesting=1 \
    --unprivileged 0 \
    --start 1

log_info "Waiting for container to start..."
sleep 5

# Wait for container to be fully running
for i in {1..30}; do
    if pct exec "$LXC_ID" -- systemctl is-system-running --wait &>/dev/null; then
        break
    fi
    sleep 2
done

log_info "Container created and started"

# Step 2: Update system and install dependencies
log_step "Installing system dependencies"

pct exec "$LXC_ID" -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
pct exec "$LXC_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wget \
    git \
    python3 \
    python3-pip \
    python3-venv \
    libgl1 \
    libglib2.0-0 \
    curl \
    ca-certificates \
    gnupg \
    lsb-release"

log_info "Base dependencies installed"

# Step 3: Install Docker
log_step "Installing Docker"

pct exec "$LXC_ID" -- bash -c "curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh"
pct exec "$LXC_ID" -- systemctl enable docker
pct exec "$LXC_ID" -- systemctl start docker

log_info "Docker installed and started"

# Step 4: Set up Stable Diffusion WebUI
log_step "Setting up Stable Diffusion WebUI"

pct exec "$LXC_ID" -- bash -c "cd /opt && git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git"

# Create environment configuration for CPU
pct exec "$LXC_ID" -- bash -c "cat > /opt/stable-diffusion-webui/webui-user.sh << 'EOFCONFIG'
#!/bin/bash

# CPU optimization flags
export COMMANDLINE_ARGS=\"--skip-torch-cuda-test --precision full --no-half --use-cpu all --listen --port ${WEBUI_PORT}\"

# Disable CUDA
export TORCH_CUDA_ARCH_LIST=\"\"

# Performance tuning
export PYTORCH_CUDA_ALLOC_CONF=\"\"
export NUMEXPR_MAX_THREADS=${CORES}
EOFCONFIG"

pct exec "$LXC_ID" -- chmod +x /opt/stable-diffusion-webui/webui-user.sh

log_info "WebUI repository cloned and configured for CPU"

# Step 5: Create systemd service
log_step "Creating systemd service"

pct exec "$LXC_ID" -- bash -c "cat > /etc/systemd/system/stable-diffusion.service << 'EOFSERVICE'
[Unit]
Description=Stable Diffusion WebUI
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/stable-diffusion-webui
ExecStart=/bin/bash /opt/stable-diffusion-webui/webui.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSERVICE"

pct exec "$LXC_ID" -- systemctl daemon-reload
pct exec "$LXC_ID" -- systemctl enable stable-diffusion

log_info "Systemd service created"

# Step 6: Initial setup (this downloads models)
log_step "Running initial setup (this will take several minutes)"

log_warn "Downloading Python dependencies and Stable Diffusion model..."
log_warn "This is the longest part - please be patient!"

# Run webui.sh once to set everything up, then stop it
pct exec "$LXC_ID" -- bash -c "cd /opt/stable-diffusion-webui && timeout 600 ./webui.sh --exit || true"

log_info "Initial setup complete"

# Step 7: Download a small, fast model
log_step "Downloading optimized model for CPU"

pct exec "$LXC_ID" -- bash -c "cd /opt/stable-diffusion-webui/models/Stable-diffusion && \
    wget -q --show-progress https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors"

log_info "Model downloaded"

# Step 8: Start the service
log_step "Starting Stable Diffusion WebUI"

pct exec "$LXC_ID" -- systemctl start stable-diffusion

log_info "Service started"

# Get container IP
sleep 3
CONTAINER_IP=$(pct exec "$LXC_ID" -- hostname -I | awk '{print $1}')

# Final summary
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo -e "${GREEN}✓${NC} Stable Diffusion WebUI is now running"
echo
echo "Access the WebUI at:"
echo -e "  ${BLUE}http://${CONTAINER_IP}:${WEBUI_PORT}${NC}"
echo
echo "Container Details:"
echo "  Container ID: $LXC_ID"
echo "  Hostname: $LXC_HOSTNAME"
echo "  IP Address: $CONTAINER_IP"
echo
echo "Useful Commands:"
echo "  # Check service status"
echo "  pct exec $LXC_ID -- systemctl status stable-diffusion"
echo
echo "  # View logs"
echo "  pct exec $LXC_ID -- journalctl -u stable-diffusion -f"
echo
echo "  # Restart service"
echo "  pct exec $LXC_ID -- systemctl restart stable-diffusion"
echo
echo "  # Enter container"
echo "  pct enter $LXC_ID"
echo
echo "Performance Notes:"
echo "  ⚠ CPU-only mode is SLOW (2-10 minutes per image)"
echo "  • Start with 512x512 images for faster generation"
echo "  • Use 20-30 steps maximum"
echo "  • Consider SD 1.5 models instead of SDXL"
echo "  • Batch generation overnight works well"
echo
echo "Next Steps:"
echo "  1. Open http://${CONTAINER_IP}:${WEBUI_PORT} in your browser"
echo "  2. Wait 1-2 minutes for first startup"
echo "  3. Try a simple prompt: 'a cat on a beach'"
echo "  4. Use Settings > Speed to reduce steps for faster preview"
echo
echo "If you decide you need a GPU:"
echo "  • Stop this container: pct stop $LXC_ID"
echo "  • Convert to VM for easier GPU passthrough"
echo "  • Or set up a separate GPU-enabled VM/container"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
