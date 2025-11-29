# Proxmox Scripts

A collection of automation scripts for managing Proxmox VE environments. These scripts help expedite and automate common manual processes when working with Proxmox containers and virtual machines.

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
9. Ensures SSH service is enabled and running
10. Continues to next container even if current one fails
11. Displays a detailed summary showing success/failure for each container with SSH connection commands

## Installation

Clone this repository on your Proxmox host:

```bash
cd /root
git clone https://github.com/mkngrm/proxmoxScripts.git
cd proxmoxScripts
chmod +x *.sh
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
