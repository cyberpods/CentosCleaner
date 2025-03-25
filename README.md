# System Cleanup Script

![Bash](https://img.shields.io/badge/shell_script-%23121011.svg?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)

A robust Bash script for cleaning and maintaining Linux systems, particularly RHEL/CentOS-based distributions.

## Features

- 🧹 Comprehensive system cleanup (logs, temp files, caches, and more)
- 📊 Disk space reporting before and after cleanup
- 🔒 Safety checks and dry-run mode
- 📝 Detailed logging with rotation
- 🐳 Docker cleanup support
- 🧠 Old kernel removal
- 🛡️ Root permission verification

## Requirements

- Linux system (tested on RHEL/CentOS 7+)
- Bash 4.0+
- Root privileges
- Basic utilities: `yum`, `journalctl`, `find`, `df`

## Installation

```bash
curl -O https://raw.githubusercontent.com/cyberpods/CentosCleaner/refs/heads/main/cleanup.sh
chmod +x cleanup.sh
