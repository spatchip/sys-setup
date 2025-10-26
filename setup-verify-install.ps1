<#
.SYNOPSIS
  Verifies and installs Windows features, developer tools, and PowerShell modules machine-wide.

.NOTES
  - Run as Administrator.
  - Avoids per-user installs and OneDrive/Documents paths.
  - Uses winget for system installs (`--scope machine`).
#>

# ------------------------------
# Guardrails & helpers
# ------------------------------
$ErrorActionPreference = 'Stop'
$script:RebootNeeded = $false

function Require-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Please run this script in an elevated PowerShell (Run as Administrator)." }
}
Require-Admin

function Write-Section($title) {
    Write-Host "`n=== $title ===" -ForegroundColor Cyan
}

function Test-Command($name) {
    return Get-Command $name -ErrorAction SilentlyContinue
}

function Ensure-NuGetProvider {
    if (-not (Get-PackageProvider -ListAvailable | Where-Object Name -eq 'NuGet')) {
        Write-Host "Installing NuGet package provider..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers
    }
}

function Ensure-PSGalleryTrusted {
    $repo = Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue
    if ($null -eq $repo) {
        Register-PSRepository -Name 'PSGallery' -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted
    } elseif ($repo.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    }
}

function Ensure-WindowsFeature($featureName) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $featureName).State
    Write-Host ("{0} : {1}" -f $featureName, $state)
    if ($state -ne 'Enabled') {
        Write-Host "Enabling $featureName..." -ForegroundColor Yellow
        Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart | Out-Null
        $script:RebootNeeded = $true
    }
}

function Test-WingetIdInstalled($id) {
    # Returns $true if winget shows the Id as installed
    $result = winget list --id $id 2>$null
    return ($LASTEXITCODE -eq 0 -and ($result -match [regex]::Escape($id)))
}

function Ensure-AppMachineWide($id, $friendly) {
    if (Test-WingetIdInstalled $id) {
        Write-Host "$friendly : Installed" -ForegroundColor Green
    } else {
        Write-Host "$friendly : NOT Installed (installing...)" -ForegroundColor Yellow
        winget install --id $id --scope machine --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install $friendly ($id) via winget."
        }
    }
}

function Ensure-AzBicepMachineWide() {
    # We install Bicep CLI machine-wide via winget (Microsoft.Bicep)
    if (Test-WingetIdInstalled 'Microsoft.Bicep') {
        Write-Host "Bicep CLI : Installed (machine-wide)" -ForegroundColor Green
    } else {
        Write-Host "Bicep CLI : NOT Installed (installing machine-wide)..." -ForegroundColor Yellow
        winget install --id Microsoft.Bicep --scope machine --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -ne 0) { throw "Failed to install Bicep CLI (Microsoft.Bicep)." }
    }
}

function Ensure-PSModulesMachineWide([string[]]$modules) {
    Ensure-NuGetProvider
    Ensure-PSGalleryTrusted

    # Install to AllUsers to land under Program Files (never Documents)
    foreach ($m in $modules) {
        $found = Get-Module -ListAvailable -Name $m
        if ($found) {
            Write-Host "$m : Installed (machine-wide or available)" -ForegroundColor Green
        } else {
            Write-Host "$m : NOT Installed (installing for AllUsers)..." -ForegroundColor Yellow
            Install-Module -Name $m -Scope AllUsers -Force -AllowClobber -Confirm:$false
        }
    }
}

function Show-PSModulePaths {
    Write-Host "`nCurrent PSModulePath:" -ForegroundColor DarkCyan
    ($env:PSModulePath -split ';') | ForEach-Object { Write-Host "  $_" }
}

# ------------------------------
# 1) Verify Windows Features
# ------------------------------
Write-Section "Checking Windows Features"
$featureList = @(
    'Microsoft-Hyper-V-All',      # Hyper-V and management
    'Containers',                 # Windows containers
    'VirtualMachinePlatform',     # Required for WSL2 backend
    'WindowsSandbox'              # Windows Sandbox
)
$featureList | ForEach-Object { Ensure-WindowsFeature $_ }

# ------------------------------
# 2) Verify WSL availability
# ------------------------------
Write-Section "Checking WSL"
if (Test-Command 'wsl.exe') {
    try {
        wsl --version
    } catch {
        # On some SKUs, wsl --version not supported; at least confirm command exists
        Write-Host "WSL command is present." -ForegroundColor Green
    }
} else {
    Write-Host "WSL not found. On Windows 11, it should be available after enabling VirtualMachinePlatform and reboot if required." -ForegroundColor Yellow
}

# ------------------------------
# 3) Verify / Install apps (machine-wide via winget)
# ------------------------------
Write-Section "Checking Apps (winget machine-wide installs)"

# Ensure winget itself is available
if (-not (Test-Command 'winget.exe')) {
    throw "winget not found. Please update to latest App Installer from Microsoft Store, then re-run."
}

# App catalog (Id => Friendly name)
$apps = [ordered]@{
    'Python.Python.3'            = 'Python 3';
    'Microsoft.VisualStudioCode' = 'Visual Studio Code';
    'Git.Git'                    = 'Git';
    'GitHub.cli'                 = 'GitHub CLI';
    'Docker.DockerDesktop'       = 'Docker Desktop';
    'Microsoft.PowerShell'       = 'PowerShell 7';
    'Microsoft.AzureCLI'         = 'Azure CLI'
}

foreach ($kvp in $apps.GetEnumerator()) {
    Ensure-AppMachineWide -id $kvp.Key -friendly $kvp.Value
}

# Bicep CLI (machine-wide)
Ensure-AzBicepMachineWide

# ------------------------------
# 4) Verify Bicep | Azure CLI | PowerShell 7
# ------------------------------
Write-Section "Validating CLI versions"
if (Test-Command 'az') { az version | Out-Host } else { Write-Host "Azure CLI not on PATH yet." -ForegroundColor Yellow }
if (Test-Command 'bicep') { bicep --version | Out-Host } else { Write-Host "Bicep not on PATH yet." -ForegroundColor Yellow }
if (Test-Command 'pwsh') { pwsh -NoLogo -NoProfile -Command '$PSVersionTable' } else { Write-Host "PowerShell 7 not on PATH yet." -ForegroundColor Yellow }

# ------------------------------
# 5) Machine-wide PowerShell modules
#     Az, Microsoft.Graph, PnP.PowerShell
# ------------------------------
Write-Section "Installing PowerShell modules (AllUsers)"
Show-PSModulePaths
$modulesToInstall = @('Az', 'Microsoft.Graph', 'PnP.PowerShell')
Ensure-PSModulesMachineWide -modules $modulesToInstall

# Double-check where they landed
Write-Host "`nVerifying module installation paths (expect under 'C:\Program Files\PowerShell\Modules'):" -ForegroundColor DarkCyan
foreach ($m in $modulesToInstall) {
    $paths = Get-Module -ListAvailable -Name $m | Select-Object -ExpandProperty Path
    $paths | ForEach-Object { Write-Host "  $m => $_" }
}

# ------------------------------
# 6) Summary & reboot prompt
# ------------------------------
Write-Section "Summary"
Write-Host "Windows features checked: $($featureList -join ', ')"
Write-Host "Apps checked: $((($apps.Keys + 'Microsoft.Bicep') -join ', '))"
Write-Host "PS Modules ensured (AllUsers): $($modulesToInstall -join ', ')"

if ($script:RebootNeeded) {
    Write-Warning "One or more Windows features were enabled. A REBOOT is recommended before using Hyper-V/WSL/Sandbox/Docker."
} else {
    Write-Host "No reboot required." -ForegroundColor Green
}
``
