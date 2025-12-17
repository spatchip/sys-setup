#!/usr/bin/env bash

# .SYNOPSIS
#   Verifies and installs developer tools, containers support, and PowerShell modules on Ubuntu.
#
# .NOTES
#   - Run as root (sudo).
#   - Uses apt for system packages, snap for some GUI apps where appropriate.
#   - Installs native Linux Docker Engine (not Docker Desktop) for containers.
#   - PowerShell modules are installed globally via pwsh.

set -euo pipefail

REBOOT_NEEDED=false

function require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Please run this script with sudo or as root."
        exit 1
    fi
}

require_root

function section() {
    echo -e "\n=== $1 ==="
}

function ok() {
    echo -e "\033[32m$1\033[0m"
}

function warn() {
    echo -e "\033[33m$1\033[0m"
}

function err() {
    echo -e "\033[31m$1\033[0m"
}

function command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Update package lists once at the beginning
apt-get update -y

# ------------------------------
# 1) System updates and basics
# ------------------------------
section "Updating system and installing basics"
apt-get upgrade -y
apt-get install -y curl wget gnupg lsb-release ca-certificates software-properties-common apt-transport-https

# ------------------------------
# 2) Install developer tools via apt where possible
# ------------------------------
section "Installing core developer tools"

# Git
if command_exists git; then
    ok "Git: Installed ($(git --version))"
else
    warn "Installing Git..."
    apt-get install -y git
    ok "Git: Installed"
fi

# Python 3 (default on Ubuntu)
if command_exists python3; then
    ok "Python 3: Installed ($(python3 --version))"
else
    warn "Installing Python 3..."
    apt-get install -y python3 python3-pip python3-venv
    ok "Python 3: Installed"
fi

# GitHub CLI
section "Installing GitHub CLI"
if command_exists gh; then
    ok "GitHub CLI: Installed ($(gh --version | head -1))"
else
    warn "Installing GitHub CLI..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update -y
    apt-get install -y gh
    ok "GitHub CLI: Installed"
fi

# Visual Studio Code (via Microsoft repo)
section "Installing Visual Studio Code"
if command_exists code; then
    ok "VS Code: Installed"
else
    warn "Installing VS Code..."
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
    install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
    rm -f packages.microsoft.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | tee /etc/apt/sources.list.d/vscode.list > /dev/null
    apt-get update -y
    apt-get install -y code
    ok "VS Code: Installed"
fi

# Azure CLI
section "Installing Azure CLI"
if command_exists az; then
    ok "Azure CLI: Installed ($(az version | head -1))"
else
    warn "Installing Azure CLI..."
    mkdir -p /etc/apt/keyrings
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null
    chmod go+r /etc/apt/keyrings/microsoft.gpg
    AZ_DIST=$(lsb_release -cs)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $AZ_DIST main" | tee /etc/apt/sources.list.d/azure-cli.list > /dev/null
    apt-get update -y
    apt-get install -y azure-cli
    ok "Azure CLI: Installed"
fi

# Bicep CLI (via az)
if az bicep version &>/dev/null; then
    ok "Bicep CLI: Installed ($(az bicep version | head -1))"
else
    warn "Installing Bicep CLI via Azure CLI..."
    az bicep install
    ok "Bicep CLI: Installed"
fi

# PowerShell 7 (via snap for easy system-wide access)
section "Installing PowerShell 7"
if command_exists pwsh; then
    ok "PowerShell 7: Installed ($(pwsh --version))"
else
    warn "Installing PowerShell 7..."
    snap install powershell --classic
    ok "PowerShell 7: Installed"
fi

# Docker Engine (native containers support)
section "Installing Docker Engine"
if command_exists docker; then
    ok "Docker: Installed ($(docker --version))"
else
    warn "Installing Docker Engine..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    # Add current user to docker group (assuming script run by sudo from a user)
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        warn "User $SUDO_USER added to docker group. Log out and back in for it to take effect."
    fi
    ok "Docker Engine: Installed"
fi

# ------------------------------
# 3) PowerShell modules (global install via pwsh)
# ------------------------------
section "Installing PowerShell modules (global)"
modules=("Az" "Microsoft.Graph" "PnP.PowerShell")

for module in "${modules[@]}"; do
    if pwsh -Command "Import-Module $module -ErrorAction SilentlyContinue; if (\$?) { exit 0 } else { exit 1 }"; then
        ver=$(pwsh -Command "(Get-Module -ListAvailable $module | Sort-Object Version -Descending | Select-Object -First 1).Version")
        ok "$module: Installed ($ver)"
    else
        warn "$module: NOT Installed (installing globally)..."
        pwsh -Command "Install-Module -Name $module -Scope AllUsers -Force -AllowClobber -Confirm:\$false"
        ok "$module: Installed"
    fi
done

# ------------------------------
# 4) Validate versions
# ------------------------------
section "Validating installed tools"
git --version || warn "Git not on PATH"
python3 --version || warn "Python not on PATH"
gh --version | head -1 || warn "GitHub CLI not on PATH"
code --version | head -1 || warn "VS Code not on PATH"
az version || warn "Azure CLI not on PATH"
az bicep version || warn "Bicep not on PATH"
pwsh --version || warn "PowerShell not on PATH"
docker --version || warn "Docker not on PATH"

# ------------------------------
# 5) Summary
# ------------------------------
section "Summary"
echo "Installed/verified:"
echo "  - Git, Python 3, GitHub CLI, Visual Studio Code"
echo "  - Azure CLI + Bicep CLI"
echo "  - PowerShell 7"
echo "  - Docker Engine (native Linux containers)"
echo "  - PowerShell modules (AllUsers): ${modules[*]}"

if $REBOOT_NEEDED; then
    warn "A reboot may be recommended for some changes (e.g., docker group)."
else
    ok "No reboot required."
fi

echo -e "\nSetup complete! You now have a developer environment similar to the Windows script."
