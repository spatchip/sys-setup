<#
Verifies Windows features, installed apps, CLI versions, and PowerShell modules.
- ASCII-only (no emojis or special punctuation)
- Color-coded output
- Winget checks with timeouts and fallbacks (PATH/registry)
#>

$ErrorActionPreference = 'SilentlyContinue'

function Write-Result {
    param(
        [string]$Item,
        [ValidateSet('OK','FAIL','WARN','INFO')]
        [string]$Status,
        [string]$Note = ''
    )
    switch ($Status) {
        'OK'   { $color='Green';  $label='OK' }
        'FAIL' { $color='Red';    $label='NOT FOUND' }
        'WARN' { $color='Yellow'; $label='CHECK' }
        'INFO' { $color='Cyan';   $label='INFO' }
    }
    if ([string]::IsNullOrWhiteSpace($Note)) {
        Write-Host ("{0} : {1}" -f $Item, $label) -ForegroundColor $color
    } else {
        Write-Host ("{0} : {1} - {2}" -f $Item, $label, $Note) -ForegroundColor $color
    }
}

Write-Host ""
Write-Host "=== Verification Summary ===" -ForegroundColor Cyan

# ------------------------------
# Windows Features
# ------------------------------
Write-Host ""
Write-Host "Checking Windows Features..." -ForegroundColor Cyan
$features = @('Microsoft-Hyper-V-All','Containers','VirtualMachinePlatform','WindowsSandbox')
$featureStates = @{}
foreach ($f in $features) {
    $obj = Get-WindowsOptionalFeature -Online -FeatureName $f
    $featureStates[$f] = $obj.State
    if ($obj.State -eq 'Enabled') {
        Write-Result -Item $f -Status OK
    } elseif ($obj.State -match 'Pending') {
        Write-Result -Item $f -Status WARN -Note 'Reboot required to complete enabling'
    } else {
        Write-Result -Item $f -Status FAIL
    }
}

# ------------------------------
# Helper: non-blocking winget check
# ------------------------------
function Test-WinGetId {
    param(
        [string]$Id,
        [int]$TimeoutSec = 8
    )
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
        return $false
    }
    $out = $p.StandardOutput.ReadToEnd() + "`n" + $p.StandardError.ReadToEnd()
    if ($p.ExitCode -eq 0 -and $out -match [regex]::Escape($Id)) { return $true }
    return $false
}

function Test-ExeVersion {
    param(
        [string]$Cmd,
        [string]$Args="--version"
    )
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) { return $null }
    try {
        $out = & $Cmd $Args 2>$null | Select-Object -First 1
        if (-not $out) { return "Installed (no version output)" }
        return ($out | Out-String).Trim()
    } catch {
        return "Installed (command returned no output)"
    }
}

function Test-RegistryInstalledMachineWide {
    param([string]$DisplayNameLike)
    $keys = @(
      "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($k in $keys) {
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
            if ($null -ne $p.DisplayName -and $p.DisplayName -like "*$DisplayNameLike*") { return $true }
        }
    }
    return $false
}

# ------------------------------
# Apps (winget timeout + fallbacks)
# ------------------------------
Write-Host ""
Write-Host "Checking Apps..." -ForegroundColor Cyan
$apps = @(
    @{ Id='Python.Python.3';            Name='Python 3';            Cmd='python'; VerArgs='--version'; RegLike='Python' },
    @{ Id='Microsoft.VisualStudioCode'; Name='Visual Studio Code';  Cmd='code';   VerArgs='--version'; RegLike='Microsoft Visual Studio Code' },
    @{ Id='Git.Git';                    Name='Git';                 Cmd='git';    VerArgs='--version'; RegLike='Git' },
    @{ Id='GitHub.cli';                 Name='GitHub CLI';          Cmd='gh';     VerArgs='--version'; RegLike='GitHub CLI' },
    @{ Id='Docker.DockerDesktop';       Name='Docker Desktop';      Cmd='docker'; VerArgs='--version'; RegLike='Docker Desktop' },
    @{ Id='Microsoft.PowerShell';       Name='PowerShell 7';        Cmd='pwsh';   VerArgs='$PSVersionTable.PSVersion.ToString()'; RegLike='PowerShell 7' },
    @{ Id='Microsoft.AzureCLI';         Name='Azure CLI';           Cmd='az';     VerArgs='version';   RegLike='Microsoft Azure CLI' },
    @{ Id='Microsoft.Bicep';            Name='Bicep CLI';           Cmd='bicep';  VerArgs='--version'; RegLike='Bicep CLI' }
)

foreach ($a in $apps) {
    $found = $false
    $note  = $null

    $wg = Test-WinGetId -Id $a.Id -TimeoutSec 8
    if ($wg -eq $true) {
        if ($a.Cmd -eq 'pwsh') {
            if (Get-Command
