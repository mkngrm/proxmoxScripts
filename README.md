# Proxmox Scripts

A collection of automation scripts for managing Proxmox VE environments. These scripts help expedite and automate common manual processes when working with Proxmox containers and virtual machines.

## Quick Start

Install with one command on your Proxmox host:

```bash
curl -fsSL https://raw.githubusercontent.com/mkngrm/proxmoxScripts/main/install.sh | sh
```

## Overview

This repository contains scripts designed to streamline Proxmox administration tasks, including user management, container configuration, and system automation.

## Scripts

### localUserSetupLXC.sh

Automates the creation of a user in one or more LXC containers with sudo access and SSH key authentication.

#### Features

- **Multi-Container Support**: Create the same user in multiple containers with a single command
- **Parameterized & Flexible**: Command-line arguments for all configuration options
- **Security Focused**: Generates secure random passwords, validates inputs, and follows best practices
- **Error Handling**: Comprehensive validation and error checking at each step
- **Graceful Failures**: Continues processing remaining containers even if one fails
- **User-Friendly**: Colored output, detailed logging, and helpful error messages with summary report
- **Production Ready**: Validates LXC state, checks for existing users, and handles edge cases

#### Usage

```bash
./localUserSetupLXC.sh -c LXC_ID [LXC_ID...] -u USERNAME [OPTIONS]
```

**Required Arguments:**
- `-c LXC_ID [LXC_ID...]` - One or more LXC container IDs (space-separated)
- `-u USERNAME` - Username to create

**Optional Arguments:**
- `-k SSH_KEY` - Path to SSH public key file (default: `/root/.ssh/id_rsa.pub`)
- `-p PASSWORD` - Password for the user (not recommended - use `-g` instead)
- `-g` - Generate a random secure password (same password used for all containers)
- `-n` - Add user to sudoers with NOPASSWD (allows sudo without password)
- `-h` - Show help message

#### Examples

Create user in a single container:
```bash
./localUserSetupLXC.sh -c 100 -u john -g
```

Create user in multiple containers:
```bash
./localUserSetupLXC.sh -c 100 101 102 -u john -g
```

Create user with custom SSH key and passwordless sudo in multiple containers:
```bash
./localUserSetupLXC.sh -c 100 101 102 -u jane -k ~/.ssh/my_key.pub -g -n
```

Create user across all development containers:
```bash
./localUserSetupLXC.sh -c 100 101 102 103 104 -u developer -k ~/.ssh/dev_key.pub -g
```

Create user with specific password in multiple containers:
```bash
./localUserSetupLXC.sh -c 100 101 -u admin -k ~/.ssh/admin_key.pub -p MySecurePass123
```

#### Requirements

- Proxmox VE host
- Root access or appropriate permissions to execute `pct` commands
- Target LXC container must be running
- Container must have `apt` package manager (Debian/Ubuntu based)
- OpenSSH server installed in the target container (for SSH access)

**Note:** The script will automatically install `sudo` if it's not present in the container.

#### What It Does

For each specified container, the script:

1. Validates the LXC container exists and is running
2. Checks that the username doesn't already exist (skips if exists)
3. Creates the user in the container
4. Sets the password (if provided or generated - same password for all containers)
5. Checks if `sudo` is installed, and installs it automatically if missing
6. Adds the user to the sudo group
7. Optionally configures passwordless sudo
8. Configures SSH key authentication (if key provided)
9. Ensures SSH service is enabled (auto-start on boot) and running
10. Continues to next container even if current one fails
11. Displays a detailed summary showing success/failure for each container with SSH connection commands

---

### disableRootSSHLogin.sh

Configure root SSH login security across one or more LXC containers by modifying the SSH daemon configuration.

#### Features

- **Multi-Container Support**: Configure root SSH access in multiple containers with a single command
- **Security Best Practice**: Defaults to `prohibit-password` (key-based auth only) instead of complete disable
- **Safe Configuration**: Backs up SSH config before making changes
- **Flexible**: Three modes - secure (prohibit-password), strict (no), or enable (yes)
- **Status Reporting**: Shows current setting before making changes
- **Automatic Service Reload**: Reloads SSH service to apply changes immediately
- **Production Safe**: Validates containers and verifies changes are applied

#### Usage

```bash
./disableRootSSHLogin.sh -c LXC_ID [LXC_ID...] [OPTIONS]
```

**Required Arguments:**
- `-c LXC_ID [LXC_ID...]` - One or more LXC container IDs (space-separated)

**Optional Arguments:**
- `-e` - Enable root SSH login (sets `PermitRootLogin yes`)
- `-s` - Strict mode: completely disable root login (sets `PermitRootLogin no`)
- `-h` - Show help message

**Default Behavior:**
- Without flags: Sets `PermitRootLogin prohibit-password` (allows key-based auth only) - **RECOMMENDED**
- With `-s` flag: Sets `PermitRootLogin no` (completely blocks root login)
- With `-e` flag: Sets `PermitRootLogin yes` (allows root login with password)

#### Examples

Disable root password login but allow SSH keys (recommended):
```bash
./disableRootSSHLogin.sh -c 100 101 102 103
```

Completely disable all root SSH login (strict mode):
```bash
./disableRootSSHLogin.sh -c 100 101 102 -s
```

Enable root SSH login with password:
```bash
./disableRootSSHLogin.sh -c 100 101 -e
```

#### Requirements

- Proxmox VE host
- Root access or appropriate permissions to execute `pct` commands
- Target LXC containers must be running
- OpenSSH server installed in the target containers

#### What It Does

For each specified container, the script:

1. Validates the LXC container exists and is running
2. Checks if `/etc/ssh/sshd_config` exists
3. Reads the current `PermitRootLogin` setting
4. Backs up the SSH config with a timestamp
5. Removes any existing `PermitRootLogin` lines (commented or uncommented)
6. Adds the new `PermitRootLogin` setting:
   - Default: `prohibit-password` (blocks password auth, allows keys)
   - With `-s`: `no` (blocks all root login)
   - With `-e`: `yes` (allows all root login)
7. Reloads the SSH service to apply changes immediately
8. Continues to next container even if current one fails
9. Displays a detailed summary showing the previous setting and result for each container

**Security Notes:**
- **`prohibit-password` (default)**: Best practice - blocks brute-force password attacks while maintaining key-based emergency access
- **`no` (strict mode)**: Most restrictive - completely blocks root SSH, requires logging in as regular user
- Recommended workflow: SSH as regular user with key, then use `sudo` for administrative tasks

---

### updateContainers.sh

Batch update and upgrade packages across multiple LXC containers.

**Usage:** `./updateContainers.sh -c LXC_ID [LXC_ID...] [OPTIONS]`

**Options:**
- `-y` - Auto-yes (non-interactive)
- `-r` - Reboot containers if required after updates
- `-u` - Update only (skip upgrade, only refresh package lists)

**Examples:**
```bash
# Update and upgrade all containers
./updateContainers.sh -c 100 101 102 -y

# Update package lists only
./updateContainers.sh -c 100 101 102 -u

# Update, upgrade, and auto-reboot if needed
./updateContainers.sh -c 100 101 102 -y -r
```

---

### healthCheck.sh

Check health status of multiple containers including disk space, memory, SSH, and system load.

**Usage:** `./healthCheck.sh -c LXC_ID [LXC_ID...] [OPTIONS]`

**Options:**
- `-d PERCENT` - Disk usage warning threshold (default: 80%)
- `-m PERCENT` - Memory usage warning threshold (default: 90%)

**Checks performed:**
- Container running status
- Disk space usage
- Memory usage
- SSH service status
- System load average
- Uptime

**Example:**
```bash
./healthCheck.sh -c 100 101 102 -d 90 -m 85
```

---

### enableUnattendedUpgrades.sh

Configure automatic security updates using unattended-upgrades package.

**Usage:** `./enableUnattendedUpgrades.sh -c LXC_ID [LXC_ID...] [OPTIONS]`

**Options:**
- `-e EMAIL` - Email address for update notifications
- `-r` - Enable automatic reboot when required (at 03:00)

**What it does:**
- Installs unattended-upgrades package
- Configures automatic security updates
- Optionally sets email notifications
- Optionally enables auto-reboot when needed

**Examples:**
```bash
# Enable with email notifications
./enableUnattendedUpgrades.sh -c 100 101 102 -e admin@example.com

# Enable with auto-reboot
./enableUnattendedUpgrades.sh -c 100 101 102 -r
```

---

### bulkContainerControl.sh

Start, stop, shutdown, or restart multiple LXC containers.

**Usage:** `./bulkContainerControl.sh -c LXC_ID [LXC_ID...] -a ACTION`

**Actions:**
- `start` - Start stopped containers
- `stop` - Force stop running containers
- `shutdown` - Gracefully shutdown running containers
- `restart` - Restart running containers

**Examples:**
```bash
# Start containers
./bulkContainerControl.sh -c 100 101 102 -a start

# Gracefully shutdown
./bulkContainerControl.sh -c 100 101 102 -a shutdown

# Restart containers
./bulkContainerControl.sh -c 100 101 102 -a restart
```

---

### snapshotContainers.sh

Create or delete snapshots across multiple LXC containers.

**Usage:** `./snapshotContainers.sh -c LXC_ID [LXC_ID...] -a ACTION -s SNAPSHOT_NAME [OPTIONS]`

**Options:**
- `-a ACTION` - Action: `create` or `delete`
- `-s NAME` - Snapshot name
- `-d DESCRIPTION` - Description for snapshot (create only)

**Examples:**
```bash
# Create snapshots before updates
./snapshotContainers.sh -c 100 101 102 -a create -s pre-update -d "Before system update"

# Create snapshots with timestamp
./snapshotContainers.sh -c 100 101 102 -a create -s backup-$(date +%Y%m%d)

# Delete old snapshots
./snapshotContainers.sh -c 100 101 102 -a delete -s pre-update
```

---

### deploySSHKeys.sh

Add or remove SSH keys from users across multiple containers.

**Usage:** `./deploySSHKeys.sh -c LXC_ID [LXC_ID...] -u USERNAME -k KEY_FILE [OPTIONS]`

**Options:**
- `-u USERNAME` - Username to manage SSH keys for
- `-k KEY_FILE` - Path to SSH public key file
- `-r` - Remove key instead of adding

**Examples:**
```bash
# Add SSH key to user
./deploySSHKeys.sh -c 100 101 102 -u junior -k ~/.ssh/id_rsa.pub

# Remove old SSH key
./deploySSHKeys.sh -c 100 101 102 -u junior -k ~/.ssh/old_key.pub -r
```

---

### syncTimezone.sh

Set timezone across multiple containers.

**Usage:** `./syncTimezone.sh -c LXC_ID [LXC_ID...] -t TIMEZONE`

**Common timezones:**
- `UTC`
- `America/New_York`, `America/Chicago`, `America/Denver`, `America/Los_Angeles`
- `Europe/London`, `Europe/Paris`
- `Asia/Tokyo`

**Example:**
```bash
./syncTimezone.sh -c 100 101 102 -t America/New_York
```

---

### deployFile.sh

Copy files to multiple containers with automatic backup.

**Usage:** `./deployFile.sh -c LXC_ID [LXC_ID...] -f SOURCE_FILE -d DEST_PATH [OPTIONS]`

**Options:**
- `-f SOURCE_FILE` - Source file on Proxmox host
- `-d DEST_PATH` - Destination path in containers
- `-o OWNER` - Set owner (user:group format)
- `-p PERMISSIONS` - Set permissions (octal, e.g., 644, 755)
- `-n` - No backup (skip backing up existing file)

**Examples:**
```bash
# Deploy custom motd
./deployFile.sh -c 100 101 102 -f /root/custom_motd -d /etc/motd

# Deploy script with specific permissions
./deployFile.sh -c 100 101 102 -f /root/script.sh -d /usr/local/bin/script.sh -p 755 -o root:root
```

---

### auditContainers.sh

Security audit across multiple containers.

**Usage:** `./auditContainers.sh -c LXC_ID [LXC_ID...]`

**Security checks performed:**
- Users with sudo/root access
- SSH root login configuration
- Users with empty passwords
- World-writable files in sensitive directories
- SUID/SGID binaries count
- Listening network services
- Firewall status (UFW)
- Unattended upgrades configuration

**Example:**
```bash
./auditContainers.sh -c 100 101 102
```

---

## Installation

### Quick Install (Recommended)

Install all scripts with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/mkngrm/proxmoxScripts/main/install.sh | sh
```

Or using wget:

```bash
wget -qO- https://raw.githubusercontent.com/mkngrm/proxmoxScripts/main/install.sh | sh
```

This will:
- Download all scripts to `/opt/proxmoxScripts`
- Make them executable
- Create command symlinks in `/usr/local/bin` (e.g., `localUserSetupLXC`)
- Download documentation

**Note:** The installer requires root privileges and will prompt if not run with sudo.

### Manual Installation

Alternatively, clone the repository:

```bash
cd /root
git clone https://github.com/mkngrm/proxmoxScripts.git
cd proxmoxScripts
chmod +x *.sh
```

### Updating

To update to the latest version, simply run the installer again:

```bash
curl -fsSL https://raw.githubusercontent.com/mkngrm/proxmoxScripts/main/install.sh | sh
```

## Contributing

Feel free to submit issues, fork the repository, and create pull requests for any improvements.

## Best Practices

- **Always use `-g` flag** to generate secure passwords instead of hardcoding them
- **Test scripts in a development environment** before running in production
- **Review script output** for any warnings or errors
- **Keep SSH keys secure** and use different keys for different purposes
- **Use passwordless sudo (`-n`) sparingly** and only for trusted automation accounts

## Security Notes

- Passwords are passed to the container via command-line arguments, which may be visible in process lists briefly
- Generated passwords are displayed only once - save them securely
- When using `-g` flag with multiple containers, the same password is used across all containers
- SSH key authentication is more secure than password authentication
- Always validate the LXC IDs to ensure you're modifying the correct containers
- The script continues processing even if one container fails - review the summary for any errors

## License

MIT License - Feel free to use and modify these scripts for your needs.

## Support

For issues or questions, please open an issue on GitHub.

---

**Note:** These scripts are provided as-is. Always test in a non-production environment first and ensure you have backups before making system changes.
