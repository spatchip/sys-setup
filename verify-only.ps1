<#
Verifies Windows features, installed apps, CLI versions, and PowerShell modules.
- Uses timeouts for winget to avoid hangs
- Falls back to PATH/registry/version checks
- Color-coded results
#>

$ErrorActionPreference = 'SilentlyContinue'

function Write-Result($item, $status, $note = '') {
    switch ($status) {
        'OK'    { $c='Green'; $s='✅ OK' }
        'FAIL'  { $c='Red';   $s='❌ NOT FOUND' }
        'WARN'  { $c='Yellow';$s='⚠️ Check' }
        default { $c='Gray';  $s=$status }
    }
    if ($note) { Write-Host ("{0} : {1} — {2}" -f $item, $s, $note) -ForegroundColor $c }
    else       { Write-Host ("{0} : {1}"       -f $item, $s)        -ForegroundColor $c }
}

function Test-WinGetId([string]$Id, [int]$TimeoutSec = 8) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "winget"
    $psi.Arguments = "list --id $Id --disable-interactivity --accept-source-agreements"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        return $false  # timed out -> treat as not confirmed
    }
    $out = $p.StandardOutput.ReadToEnd() + "`n" + $p.StandardError.ReadToEnd()
    if ($p.ExitCode -eq 0 -and $out -match [regex]::Escape($Id)) { return $true }
    return $false
}

function Test-ExeVersion($cmd, $args="--version") {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { return $null }
    try {
        $out = & $cmd $args 2>$null | Select-Object -First 1
        if (-not $out) { return "Installed (version not detected)" }
        return ($out | Out-String).Trim()
    } catch { return "Installed (no version output)" }
}

function Test-RegistryInstalledMachineWide([string]$displayNameLike) {
    $keys = @(
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($k in $keys) {
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = (Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue).DisplayName
            if ($dn -and ($dn -like "*$displayNameLike*")) { return $true }
        }
    }
    return $false
}

Write-Host "`n=== Verification Summary (Non-blocking) ===" -ForegroundColor Cyan

# ------------------------------
# Windows Features
# ------------------------------
Write-Host "`nChecking Windows Features..." -ForegroundColor Cyan
$features = @(
  'Microsoft-Hyper-V-All',
  'Containers',
  'VirtualMachinePlatform',
  'WindowsSandbox'
)

$featureStates = @{}
foreach ($f in $features) {
    $obj = Get-WindowsOptionalFeature -Online -FeatureName $f
    $featureStates[$f] = $obj.State
    if ($obj.State -eq 'Enabled') { Write-Result $f 'OK' }
    elseif ($obj.State -match 'Pending') { Write-Result $f 'WARN' 'Reboot required to complete enabling' }
    else { Write-Result $f 'FAIL' }
}

# ------------------------------
# Apps (winget with timeout + fallbacks)
# ------------------------------
Write-Host "`nChecking Apps..." -ForegroundColor Cyan
$apps = @(
    @{ Id='Python.Python.3';            Name='Python 3';          Cmd='python';   VerArgs='--version';   RegLike='Python' },
    @{ Id='Microsoft.VisualStudioCode'; Name='Visual Studio Code';Cmd='code';     VerArgs='--version';   RegLike='Microsoft Visual Studio Code' },
    @{ Id='Git.Git';                    Name='Git';               Cmd='git';      VerArgs='--version';   RegLike='Git' },
    @{ Id='GitHub.cli';                 Name='GitHub CLI';        Cmd='gh';       VerArgs='--version';   RegLike='GitHub CLI' },
    @{ Id='Docker.DockerDesktop';       Name='Docker Desktop';    Cmd='docker';   VerArgs='--version';   RegLike='Docker Desktop' },
    @{ Id='Microsoft.PowerShell';       Name='PowerShell 7';      Cmd='pwsh';     VerArgs='$PSVersionTable.PSVersion.ToString()'; RegLike='PowerShell 7' },
    @{ Id='Microsoft.AzureCLI';         Name='Azure CLI';         Cmd='az';       VerArgs='version';     RegLike='Microsoft Azure CLI' },
    @{ Id='Microsoft.Bicep';            Name='Bicep CLI';         Cmd='bicep';    VerArgs='--version';   RegLike='Bicep CLI' }
)

foreach ($a in $apps) {
    $found = $null
    $note  = $null

    # 1) Try winget (quick timeout)
    $wg = Test-WinGetId -Id $a.Id -TimeoutSec 8

    if ($wg -eq $true) {
        # Confirm with version command if possible
        if ($a.Cmd -eq 'pwsh') {
            if (Get-Command pwsh -ErrorAction SilentlyContinue) {
                $note = pwsh -NoLogo -NoProfile -Command $a.VerArgs
            }
        } elseif ($a.Cmd -eq 'az') {
            if (Get-Command az -ErrorAction SilentlyContinue) {
                try {
                    $j = az version 2>$null
                    if ($LASTEXITCODE -eq 0) { $note = "AzureCLI " + ((ConvertFrom-Json $j).\"azure-cli") }
                } catch {}
            }
        } else {
            $note = Test-ExeVersion $a.Cmd $a.VerArgs
        }
        $found = $true
    }
    elseif ($wg -eq $false) {
        # winget says not installed or timed out; try fallbacks
        $ver = $null
        if ($a.Cmd -eq 'pwsh') {
            if (Get-Command pwsh -ErrorAction SilentlyContinue) {
                $ver = pwsh -NoLogo -NoProfile -Command $a.VerArgs
            }
        } elseif ($a.Cmd -eq 'az') {
            if (Get-Command az -ErrorAction SilentlyContinue) {
                try {
                    $j = az version 2>$null
                    if ($LASTEXITCODE -eq 0) { $ver = "AzureCLI " + ((ConvertFrom-Json $j).\"azure-cli") }
                } catch {}
            }
        } else {
            $ver = Test-ExeVersion $a.Cmd $a.VerArgs
        }

        if ($ver) { $found = $true; $note = $ver }
        elseif (Test-RegistryInstalledMachineWide $a.RegLike) { $found = $true; $note = "Detected via HKLM uninstall keys" }
        else { $found = $false }
    }
    else {
        # winget not present -> rely on fallbacks only
        $ver = Test-ExeVersion $a.Cmd $a.VerArgs
        if ($ver) { $found = $true; $note = $ver }
        elseif (Test-RegistryInstalledMachineWide $a.RegLike) { $found = $true; $note = "Detected via HKLM uninstall keys" }
        else { $found = $false }
    }

    if ($found) { Write-Result $a.Name 'OK' ($note ? $note.ToString().Trim() : 'Installed') }
    else        { Write-Result $a.Name 'FAIL' }
}

# Docker daemon ping
if (Get-Command docker -ErrorAction SilentlyContinue) {
    try {
        $pong = docker version --format '{{.Server.Version}}' 2>$null
        if ($pong) { Write-Result 'Docker Engine' 'OK' ("Server " + $pong) }
        else       { Write-Result 'Docker Engine' 'WARN' 'Desktop installed but engine not reachable; open Docker Desktop once' }
    } catch {
        Write-Result 'Docker Engine' 'WARN' 'Desktop installed but engine not reachable; open Docker Desktop once'
    }
}

# ------------------------------
# PowerShell Modules (Program Files only)
# ------------------------------
Write-Host "`nChecking PowerShell Modules (machine-wide)..." -ForegroundColor Cyan
$modules = @('Az','Microsoft.Graph','PnP.PowerShell')
foreach ($m in $modules) {
    $found = Get-Module -ListAvailable -Name $m
    if ($found) {
        $paths = $found | Select-Object -ExpandProperty Path
        $inPF  = $paths | Where-Object { $_ -match 'Program Files\\PowerShell\\Modules' -or $_ -match 'Program Files\\WindowsPowerShell\\Modules' }
        if ($inPF) { Write-Result $m 'OK' ($inPF -join '; ') }
        else       { Write-Result $m 'WARN' 'Installed but not under Program Files (check OneDrive/Documents avoidance)' }
    } else {
        Write-Result $m 'FAIL'
    }
}

# ------------------------------
# Sandbox guidance
# ------------------------------
if ($featureStates['WindowsSandbox'] -ne 'Enabled') {
    Write-Host "`nSandbox not enabled. Hints:" -ForegroundColor Yellow
    Write-Host " - Reboot if any feature shows 'Pending'." -ForegroundColor Yellow
    Write-Host " - Ensure virtualization is enabled in BIOS/UEFI (Task Manager > CPU > Virtualization: Enabled)." -ForegroundColor Yellow
    Write-Host " - Windows edition must be Pro/Enterprise/Education." -ForegroundColor Yellow
    Write-Host " - Optionally re-run:" -ForegroundColor Yellow
    Write-Host "   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All,VirtualMachinePlatform,Containers,WindowsSandbox -All -NoRestart" -ForegroundColor Yellow
}

Write-Host "`nVerification complete." -ForegroundColor Cyan
