<#
.SYNOPSIS
  Verifies and installs Windows features, developer tools, and PowerShell modules machine-wide.

.NOTES
  - Run as Administrator.
  - Avoids per-user installs and OneDrive/Documents paths.
  - Uses winget for system installs (--scope machine) where supported.
#>

# ------------------------------
# Guardrails & globals
# ------------------------------
$ErrorActionPreference = 'Stop'
$script:RebootNeeded = $false

# Allow Microsoft Store as a last-resort source (set to $true only if needed)
$script:AllowMSStoreFallback = $false

function Require-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Please run this script in an elevated PowerShell (Run as Administrator)." }
}
Require-Admin

# Ensure TLS 1.2 for PSGallery/NuGet on older hosts
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol } catch {}

function Write-Section($title) { Write-Host "`n=== $title ===" -ForegroundColor Cyan }
function Write-Ok($msg){ Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg){ Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg){ Write-Host $msg -ForegroundColor Red }
function Test-Command($name) { Get-Command $name -ErrorAction SilentlyContinue }

# ------------------------------
# Windows Features
# ------------------------------
function Ensure-WindowsFeature([Parameter(Mandatory)]$featureName) {
    try {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
        Write-Host ("{0} : {1}" -f $featureName, $feat.State)
        if ($feat.State -ne 'Enabled') {
            Write-Warn "Enabling $featureName..."
            Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart | Out-Null
            $script:RebootNeeded = $true
        }
    } catch {
        Write-Err "Feature $featureName not found on this SKU: $($_.Exception.Message)"
    }
}

# ------------------------------
# Winget helpers (non-interactive)
# ------------------------------
function WarmUp-Winget {
    if (-not (Test-Command 'winget.exe')) { throw "winget not found. Install/Update **App Installer** from Microsoft Store, then re-run." }
    try { winget source list --disable-interactivity   *> $null } catch {}
    try { winget source update --disable-interactivity *> $null } catch {}
}

function Test-WingetIdAvailable([string]$Id, [string]$Source = 'winget') {
    $show = & winget show --id $Id --exact --source $Source --disable-interactivity 2>$null | Out-String
    return ($LASTEXITCODE -eq 0 -and $show -and -not ($show -match 'No package found'))
}

function Test-WingetIdInstalled([Parameter(Mandatory)] [string]$Id, [string]$Source='winget') {
    $out = & winget list --id $Id --exact --source $Source --disable-interactivity 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($out -match 'No installed package found') { return $false }
    return ($out -match [regex]::Escape($Id))
}

function Resolve-PackageId {
    param(
        [Parameter(Mandatory)] [string[]]$Candidates, # ordered by preference
        [string]$PrimarySource = 'winget'
    )
    foreach ($id in $Candidates) {
        if (Test-WingetIdAvailable $id $PrimarySource) {
            return [pscustomobject]@{ Id=$id; Source=$PrimarySource }
        }
    }
    if ($script:AllowMSStoreFallback) {
        try { winget source update --name msstore --accept-source-agreements --disable-interactivity *> $null } catch {}
        foreach ($id in $Candidates) {
            if (Test-WingetIdAvailable $id 'msstore') {
                return [pscustomobject]@{ Id=$id; Source='msstore' }
            }
        }
    }
    return $null
}

function Ensure-AppMachineWide {
    param(
        [Parameter(Mandatory)] [string[]]$Ids,       # one or more candidate IDs (preferred first)
        [Parameter(Mandatory)] [string]$Friendly
    )

    # Already installed?
    foreach ($src in @('winget','msstore')) {
        foreach ($id in $Ids) {
            if (Test-WingetIdInstalled $id $src) {
                Write-Ok "$Friendly : Installed ($id via $src)"
                return
            }
        }
    }

    # Resolve available ID+source
    $resolved = Resolve-PackageId -Candidates $Ids -PrimarySource 'winget'
    if ($null -eq $resolved) {
        throw "$Friendly : No candidate IDs available in winget (and msstore fallback is $($script:AllowMSStoreFallback)). Candidates: $($Ids -join ', ')"
    }

    $id = $resolved.Id
    $src = $resolved.Source
    Write-Warn "$Friendly : NOT Installed (installing $id from $src machine-wide)..."

    $baseArgs = @(
        'install'
        '--id', $id
        '--exact'
        '--source', $src
        '--scope', 'machine'
        '--accept-source-agreements'
        '--accept-package-agreements'
        '--disable-interactivity'
    )

    & winget @baseArgs --silent
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Retrying $Friendly without --silent for diagnostics..."
        & winget @baseArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install $Friendly ($id) via $src."
        }
    }

    Start-Sleep -Seconds 3
    if (Test-WingetIdInstalled $id $src) {
        Write-Ok "$Friendly : Installed ($id via $src)"
    } else {
        Write-Err "$Friendly : Install appears incomplete; verify manually."
    }
}

function Ensure-BicepCli() {
    # Prefer machine-wide winget package; fallback to 'az bicep install'
    $candidates = @('Microsoft.Bicep')
    $resolved = Resolve-PackageId -Candidates $candidates -PrimarySource 'winget'

    if ($resolved -ne $null) {
        if (Test-WingetIdInstalled $resolved.Id $resolved.Source) {
            Write-Ok "Bicep CLI : Installed ($($resolved.Id) via $($resolved.Source))"
            return
        }
        Write-Warn "Bicep CLI : NOT Installed (installing $($resolved.Id) from $($resolved.Source) machine-wide)..."
        & winget install --id $resolved.Id --exact --source $resolved.Source --scope machine --accept-source-agreements --accept-package-agreements --disable-interactivity --silent
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Winget install failed; trying 'az bicep install'…"
            if (Test-Command 'az') { try { az bicep install | Out-Null; Write-Ok "Bicep CLI : Installed via az" } catch { throw "Bicep install failed via winget and az: $($_.Exception.Message)" } }
            else { throw "Bicep install failed via winget, and Azure CLI not present to bootstrap." }
        } else { Write-Ok "Bicep CLI : Installed ($($resolved.Id) via $($resolved.Source))" }
    } else {
        if (Test-Command 'az') { try { az bicep install | Out-Null; Write-Ok "Bicep CLI : Installed via az" } catch { throw "Bicep install failed via az: $($_.Exception.Message)" } }
        else { throw "Bicep CLI not available via winget and Azure CLI is not installed." }
    }
}

# ------------------------------
# Environment refresh for PATH
# ------------------------------
function Refresh-EnvPath {
    $machine = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue).Path
    $user    = (Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue).Path
    $combined = @($user, $machine) -ne $null -join ';'
    if ($combined) { $env:Path = $combined }
}

# ------------------------------
# PowerShell Gallery / modules
# ------------------------------
# Put AllUsers paths first (so resolution prefers Program Files locations, not OneDrive)
$paths   = $env:PSModulePath -split ';'
$sysPF   = $paths | Where-Object { $_ -match '\\Program Files\\WindowsPowerShell\\Modules' -or $_ -match '\\Program Files\\PowerShell\\Modules' }
$userRst = $paths | Where-Object { $_ -notin $sysPF }
$env:PSModulePath = ($sysPF + $userRst) -join ';'

function Ensure-PowerShellGetUpToDate {
    if (-not (Get-PackageProvider -ListAvailable | Where-Object Name -eq 'NuGet')) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers
    }
    $pg = Get-Module -ListAvailable PowerShellGet | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pg -or $pg.Version -lt [version]'2.2.5') {
        Install-Module PowerShellGet -Repository PSGallery -Scope AllUsers -Force -AllowClobber -Confirm:$false
        Import-Module PowerShellGet -Force
    }
}

function Install-ModuleSafe {
    param(
        [Parameter(Mandatory)] [string]$Name
    )
    try {
        Install-Module -Name $Name -Repository PSGallery -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Warn "$Name : Direct install failed — attempting Save-Module fallback..."
        $staging = 'C:\ProgramData\PSModuleStaging'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Save-Module -Name $Name -Repository PSGallery -Path $staging -Force -Confirm:$false -ErrorAction Stop
        $dest1 = 'C:\Program Files\WindowsPowerShell\Modules'
        $dest2 = 'C:\Program Files\PowerShell\Modules'
        foreach ($modDir in Get-ChildItem -Directory -Path (Join-Path $staging $Name)) {
            foreach ($dest in @($dest1,$dest2)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                Copy-Item -Recurse -Force -Path $modDir.FullName -Destination (Join-Path $dest $Name) -ErrorAction SilentlyContinue
            }
        }
    }
    $found = Get-Module -ListAvailable -Name $Name
    if (-not $found) { throw "Module $Name failed to install for AllUsers." }
    $ver = ($found | Sort-Object Version -Descending | Select-Object -First 1).Version
    Write-Ok "$Name : Installed ($ver)"
}

function Ensure-PSModulesMachineWide([string[]]$modules) {
    $repo = Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue
    if ($null -eq $repo) {
        Register-PSRepository -Name 'PSGallery' -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted
    } elseif ($repo.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    }

    Ensure-PowerShellGetUpToDate

    foreach ($m in $modules) {
        $found = Get-Module -ListAvailable -Name $m
        if ($found) {
            $ver = ($found | Sort-Object Version -Descending | Select-Object -First 1).Version
            Write-Ok "$m : Installed ($ver)"
        } else {
            Write-Warn "$m : NOT Installed (installing for AllUsers from PSGallery)..."
            Install-ModuleSafe -Name $m
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
    'Microsoft-Hyper-V-All',             # Hyper-V and management
    'Containers',                        # Windows containers
    'VirtualMachinePlatform',            # Required for WSL2 backend
    'Microsoft-Windows-Subsystem-Linux', # WSL platform
    'Containers-DisposableClientVM'      # Windows Sandbox (correct name)
)
$featureList | ForEach-Object { Ensure-WindowsFeature $_ }

# ------------------------------
# 2) Verify / bootstrap WSL
# ------------------------------
Write-Section "Checking WSL"
if (Test-Command 'wsl.exe') {
    try {
        $v = & wsl --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { Write-Host $v }
        else { & wsl -l -v 2>$null | Out-Host }
    } catch {
        Write-Warn "WSL present but version query failed: $($_.Exception.Message)"
    }
} else {
    Write-Warn "wsl.exe not currently available. After reboot (features enabled above), WSL will be present."
    $script:RebootNeeded = $true
}

# ------------------------------
# 3) Verify / Install apps (machine-wide via winget)
# ------------------------------
Write-Section "Checking Apps (winget machine-wide installs)"
WarmUp-Winget

# Preferred IDs per app (first available is used)
$apps = @(
    @{ Friendly='Python 3';            Ids=@('Python.Python.3.13','Python.Python.3.12','Python.Python.3.11','Python.Python.3') },
    @{ Friendly='Visual Studio Code';  Ids=@('Microsoft.VisualStudioCode') },
    @{ Friendly='Git';                 Ids=@('Git.Git') },
    @{ Friendly='GitHub CLI';          Ids=@('GitHub.cli') },
    @{ Friendly='Docker Desktop';      Ids=@('Docker.DockerDesktop') },
    @{ Friendly='PowerShell 7';        Ids=@('Microsoft.PowerShell') },
    @{ Friendly='Azure CLI';           Ids=@('Microsoft.AzureCLI') }
)
foreach ($app in $apps) { Ensure-AppMachineWide -Ids $app.Ids -Friendly $app.Friendly }

# Bicep CLI (machine-wide)
Ensure-BicepCli

# ------------------------------
# 4) Validate CLI versions (with PATH refresh)
# ------------------------------
Write-Section "Validating CLI versions"
Refresh-EnvPath
if (Test-Command 'az')    { az version | Out-Host } else { Write-Warn "Azure CLI not on PATH yet." }
if (Test-Command 'bicep') { bicep --version | Out-Host } else { Write-Warn "Bicep not on PATH yet." }
if (Test-Command 'pwsh')  { pwsh -NoLogo -NoProfile -Command '$PSVersionTable' } else { Write-Warn "PowerShell 7 not on PATH yet." }

# ------------------------------
# 5) Machine-wide PowerShell modules
# ------------------------------
Write-Section "Installing PowerShell modules (AllUsers)"
Show-PSModulePaths
$modulesToInstall = @('Az', 'Microsoft.Graph', 'PnP.PowerShell')
Ensure-PSModulesMachineWide -modules $modulesToInstall

Write-Host "`nVerifying module installation paths (prefer 'C:\Program Files\PowerShell\Modules' or '...\WindowsPowerShell\Modules'):" -ForegroundColor DarkCyan
foreach ($m in $modulesToInstall) {
    $paths = Get-Module -ListAvailable -Name $m | Select-Object -ExpandProperty Path
    if ($paths) { $paths | ForEach-Object { Write-Host "  $m => $_" } }
}

# ------------------------------
# 6) Summary & reboot prompt
# ------------------------------
Write-Section "Summary"
Write-Host "Windows features checked: $($featureList -join ', ')"
Write-Host "Apps ensured: $($apps.Friendly -join ', '), plus Bicep CLI"
Write-Host "PS Modules ensured (AllUsers): $($modulesToInstall -join ', ')"

if ($script:RebootNeeded) {
    Write-Warning "One or more Windows features were enabled. A REBOOT is recommended before using Hyper-V/WSL/Sandbox/Docker."
} else {
    Write-Ok "No reboot required."
}
