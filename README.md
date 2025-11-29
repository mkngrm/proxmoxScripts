# Proxmox Scripts

A collection of automation scripts for managing Proxmox VE environments. These scripts help expedite and automate common manual processes when working with Proxmox containers and virtual machines.

## Overview

This repository contains scripts designed to streamline Proxmox administration tasks, including user management, container configuration, and system automation.

## Scripts

### localUserSetupLXC.sh

Automates the creation of a user in an LXC container with sudo access and SSH key authentication.

#### Features

- **Parameterized & Flexible**: Command-line arguments for all configuration options
- **Security Focused**: Generates secure random passwords, validates inputs, and follows best practices
- **Error Handling**: Comprehensive validation and error checking at each step
- **User-Friendly**: Colored output, detailed logging, and helpful error messages
- **Production Ready**: Validates LXC state, checks for existing users, and handles edge cases

#### Usage

```bash
./localUserSetupLXC.sh -c LXC_ID -u USERNAME [OPTIONS]
```

**Required Arguments:**
- `-c LXC_ID` - LXC container ID
- `-u USERNAME` - Username to create

**Optional Arguments:**
- `-k SSH_KEY` - Path to SSH public key file (default: `/root/.ssh/id_rsa.pub`)
- `-p PASSWORD` - Password for the user (not recommended - use `-g` instead)
- `-g` - Generate a random secure password
- `-n` - Add user to sudoers with NOPASSWD (allows sudo without password)
- `-h` - Show help message

#### Examples

Create user with auto-generated password:
```bash
./localUserSetupLXC.sh -c 100 -u john -g
```

Create user with custom SSH key and passwordless sudo:
```bash
./localUserSetupLXC.sh -c 100 -u jane -k ~/.ssh/my_key.pub -g -n
```

Create user with SSH key only (no password):
```bash
./localUserSetupLXC.sh -c 100 -u admin -k ~/.ssh/admin_key.pub
```

Create user with specific password:
```bash
./localUserSetupLXC.sh -c 100 -u developer -k ~/.ssh/dev_key.pub -p MySecurePass123
```

#### Requirements

- Proxmox VE host
- Root access or appropriate permissions to execute `pct` commands
- Target LXC container must be running
- OpenSSH server installed in the target container (for SSH access)

#### What It Does

1. Validates the LXC container exists and is running
2. Checks that the username doesn't already exist
3. Creates the user in the container
4. Sets the password (if provided or generated)
5. Adds the user to the sudo group
6. Optionally configures passwordless sudo
7. Configures SSH key authentication (if key provided)
8. Ensures SSH service is enabled and running
9. Displays a summary with connection information

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
- SSH key authentication is more secure than password authentication
- Always validate the LXC ID to ensure you're modifying the correct container

## License

MIT License - Feel free to use and modify these scripts for your needs.

## Support

For issues or questions, please open an issue on GitHub.

---

**Note:** These scripts are provided as-is. Always test in a non-production environment first and ensure you have backups before making system changes.
