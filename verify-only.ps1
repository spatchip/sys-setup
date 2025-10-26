<#
.SYNOPSIS
  Verifies Windows features, apps, and PowerShell modules with color-coded output.
#>

function Write-Result($item, $status) {
    switch ($status) {
        'OK'    { Write-Host "$item : ✅ OK" -ForegroundColor Green }
        'FAIL'  { Write-Host "$item : ❌ NOT FOUND" -ForegroundColor Red }
        'WARN'  { Write-Host "$item : ⚠️ Check" -ForegroundColor Yellow }
    }
}

Write-Host "`n=== Verification Summary ===" -ForegroundColor Cyan

# ------------------------------
# Windows Features
# ------------------------------
Write-Host "`nChecking Windows Features..." -ForegroundColor Cyan
$features = @('Microsoft-Hyper-V-All','Containers','VirtualMachinePlatform','WindowsSandbox')
foreach ($f in $features) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
    if ($state -eq 'Enabled') { Write-Result $f 'OK' } else { Write-Result $f 'FAIL' }
}

# ------------------------------
# Apps via winget
# ------------------------------
Write-Host "`nChecking Apps..." -ForegroundColor Cyan
$apps = @(
    @{Id='Python.Python.3'; Name='Python 3'},
    @{Id='Microsoft.VisualStudioCode'; Name='VS Code'},
    @{Id='Git.Git'; Name='Git'},
    @{Id='GitHub.cli'; Name='GitHub CLI'},
    @{Id='Docker.DockerDesktop'; Name='Docker Desktop'},
    @{Id='Microsoft.PowerShell'; Name='PowerShell 7'},
    @{Id='Microsoft.AzureCLI'; Name='Azure CLI'},
    @{Id='Microsoft.Bicep'; Name='Bicep CLI'}
)
foreach ($app in $apps) {
    $installed = winget list --id $app.Id | Select-String $app.Id
    if ($installed) { Write-Result $app.Name 'OK' } else { Write-Result $app.Name 'FAIL' }
}

# ------------------------------
# CLI Versions
# ------------------------------
Write-Host "`nChecking CLI Tools..." -ForegroundColor Cyan
if (Get-Command az -ErrorAction SilentlyContinue) { Write-Result 'Azure CLI' 'OK' } else { Write-Result 'Azure CLI' 'FAIL' }
if (Get-Command bicep -ErrorAction SilentlyContinue) { Write-Result 'Bicep CLI' 'OK' } else { Write-Result 'Bicep CLI' 'FAIL' }
if (Get-Command pwsh -ErrorAction SilentlyContinue) { Write-Result 'PowerShell 7' 'OK' } else { Write-Result 'PowerShell 7' 'FAIL' }

# ------------------------------
# PowerShell Modules
# ------------------------------
Write-Host "`nChecking PowerShell Modules (machine-wide)..." -ForegroundColor Cyan
$modules = @('Az','Microsoft.Graph','PnP.PowerShell')
foreach ($m in $modules) {
    $found = Get-Module -ListAvailable -Name $m
    if ($found) {
        # Check path to ensure it's under Program Files
        $paths = $found | Select-Object -ExpandProperty Path
        if ($paths -match 'Program Files') { Write-Result $m 'OK' } else { Write-Result $m 'WARN' }
    } else {
        Write-Result $m 'FAIL'
    }
}

Write-Host "`nVerification complete." -ForegroundColor Cyan
