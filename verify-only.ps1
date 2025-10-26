<#
Verifies Windows features, installed apps, CLI versions, and PowerShell modules.
Color-coded output, with hints for Sandbox/Hyper-V issues and module path sanity.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Write-Result($item, $status, $note = '') {
    switch ($status) {
        'OK'    { $c='Green'; $s='✅ OK' }
        'FAIL'  { $c='Red';   $s='❌ NOT FOUND' }
        'WARN'  { $c='Yellow';$s='⚠️ Check' }
        default { $c='Gray';  $s=$status }
    }
    if ($note) {
        Write-Host ("{0} : {1} — {2}" -f $item, $s, $note) -ForegroundColor $c
    } else {
        Write-Host ("{0} : {1}" -f $item, $s) -ForegroundColor $c
    }
}

Write-Host "`n=== Verification Summary ===" -ForegroundColor Cyan

# ------------------------------
# Windows Features
# ------------------------------
Write-Host "`nChecking Windows Features..." -ForegroundColor Cyan
$features = @('Microsoft-Hyper-V-All','Containers','VirtualMachinePlatform','WindowsSandbox')
$featureStates = @{}
foreach ($f in $features) {
    $obj = Get-WindowsOptionalFeature -Online -FeatureName $f
    $featureStates[$f] = $obj.State
    if ($obj.State -eq 'Enabled') {
        Write-Result $f 'OK'
    } elseif ($obj.State -match 'Pending') {
        Write-Result $f 'WARN' 'Reboot required to complete enabling'
    } else {
        Write-Result $f 'FAIL'
    }
}

# ------------------------------
# Apps (winget fallback)
# ------------------------------
Write-Host "`nChecking Apps..." -ForegroundColor Cyan
$apps = @(
    @{ Id='Python.Python.3'; Name='Python 3'; Cmd='python'; VerArgs='--version' },
    @{ Id='Microsoft.VisualStudioCode'; Name='VS Code'; Cmd='code'; VerArgs='--version' },
    @{ Id='Git.Git'; Name='Git'; Cmd='git'; VerArgs='--version' },
    @{ Id='GitHub.cli'; Name='GitHub CLI'; Cmd='gh'; VerArgs='--version' },
    @{ Id='Docker.DockerDesktop'; Name='Docker Desktop'; Cmd='docker'; VerArgs='--version' },
    @{ Id='Microsoft.PowerShell'; Name='PowerShell 7'; Cmd='pwsh'; VerArgs='$PSVersionTable.PSVersion.ToString()' },
    @{ Id='Microsoft.AzureCLI'; Name='Azure CLI'; Cmd='az'; VerArgs='version' },
    @{ Id='Microsoft.Bicep'; Name='Bicep CLI'; Cmd='bicep'; VerArgs='--version' }
)

foreach ($a in $apps) {
    $installed = winget list --id $a.Id | Select-String $a.Id
    if ($installed) {
        $ver = $null
        if (Get-Command $a.Cmd -ErrorAction SilentlyContinue) {
            if ($a.Cmd -eq 'pwsh') {
                $ver = pwsh -NoLogo -NoProfile -Command $a.VerArgs
            } elseif ($a.Cmd -eq 'az') {
                $json = az version 2>$null
                if ($json) { $ver = "AzureCLI " + ((ConvertFrom-Json $json).\"azure-cli") }
            } else {
                $ver = & $a.Cmd $a.VerArgs 2>$null | Select-Object -First 1
            }
        }
        Write-Result $a.Name 'OK' ($ver ? $ver.Trim() : 'Installed')
    } else {
        Write-Result $a.Name 'FAIL'
    }
}

# ------------------------------
# PowerShell Modules
# ------------------------------
Write-Host "`nChecking PowerShell Modules (machine-wide)..." -ForegroundColor Cyan
$modules = @('Az','Microsoft.Graph','PnP.PowerShell')
foreach ($m in $modules) {
    $found = Get-Module -ListAvailable -Name $m
    if ($found) {
        $paths = $found | Select-Object -ExpandProperty Path
        $inPF = $paths | Where-Object { $_ -match 'Program Files\\PowerShell\\Modules' }
        if ($inPF) {
            Write-Result $m 'OK' ($inPF -join '; ')
        } else {
            Write-Result $m 'WARN' 'Installed but not under Program Files (check OneDrive/Documents avoidance)'
        }
    } else {
        Write-Result $m 'FAIL'
    }
}

Write-Host "`nVerification complete." -ForegroundColor Cyan
