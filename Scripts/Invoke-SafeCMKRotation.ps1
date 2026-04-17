<#
.SYNOPSIS
    Safely rotates the Managed HSM Customer-Managed Key for a Confidential AVD
    host pool without conflicting with autoscale.

.DESCRIPTION
    This script wraps Rotate-CMK.ps1 from part 2 of the Confidential AVD series
    with the operational safeguards needed to avoid a race condition between
    AVD autoscale and the CMK rotation procedure.

    The problem it solves
    ---------------------
    AVD autoscale deallocates VMs during ramp-down. The CMK rotation procedure
    requires every VM sharing the Disk Encryption Set to be deallocated at the
    same time before the DES can point to the new key version. If autoscale is
    mid-ramp-down when a rotation starts, you can hit one of two failure modes:

    1. Autoscale brings a VM back online while the rotation is mid-step, so the
       DES update fails because one VM is still running.
    2. Autoscale deallocates a VM that has been excluded from the rotation, so
       the rotation completes but the excluded VM cannot start against the
       new key version.

    The safeguard
    -------------
    Before rotating, this script:
      1. Verifies zero active sessions across the host pool (fails otherwise).
      2. Applies an exclusion tag to every CVM in the host pool, which tells
         autoscale to leave those VMs alone.
      3. Triggers Rotate-CMK.ps1 from part 2 with its full 9-step flow.
      4. Removes the exclusion tag after the rotation completes so autoscale
         resumes normal operation.

    Exclusion tag pattern
    ---------------------
    The AVD autoscale service respects the exclusion tag mechanism documented at
    https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan.
    The tag name is configurable per scaling plan. This script reads the tag
    name from the scaling plan associated with the host pool and applies that
    tag to every CVM for the duration of the rotation.

.PARAMETER SubscriptionName
    The Azure subscription containing the host pool and CVMs.

.PARAMETER HostsResourceGroup
    The resource group containing the CVM session hosts.

.PARAMETER HostPoolName
    The AVD host pool name.

.PARAMETER ScalingPlanName
    The AVD scaling plan applied to the host pool. The script reads the
    exclusion tag name from this plan.

.PARAMETER ScalingPlanResourceGroup
    The resource group containing the scaling plan. Often the same as the
    host pool resource group, but not always.

.PARAMETER KeyVaultName
    The Managed HSM name. Passed through to Rotate-CMK.ps1.

.PARAMETER KeyName
    The CMK name inside the HSM. Passed through to Rotate-CMK.ps1.

.PARAMETER DiskEncryptionSetName
    The Disk Encryption Set name to update. Passed through to Rotate-CMK.ps1.

.PARAMETER MaxActiveSessionsAllowed
    Safety check. Default 0. If the host pool has more active sessions than
    this threshold at the start, the script refuses to proceed. Set to a
    non-zero value only for testing.

.PARAMETER DryRun
    Validates every check without applying any exclusion tag or triggering
    the rotation. Read-only operations still execute.

.EXAMPLE
    .\Scripts\Invoke-SafeCMKRotation.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -HostPoolName "hp-avd-prd-weu-001" `
        -ScalingPlanName "sp-avd-prd-weu-001" `
        -ScalingPlanResourceGroup "rg-avd-prd-mgmt" `
        -KeyVaultName "hsm-avd-prd-weu-001" `
        -KeyName "cmk-avd-prd" `
        -DiskEncryptionSetName "des-avd-prd-weu-001" `
        -DryRun

.EXAMPLE
    # Production rotation inside a maintenance window
    .\Scripts\Invoke-SafeCMKRotation.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -HostPoolName "hp-avd-prd-weu-001" `
        -ScalingPlanName "sp-avd-prd-weu-001" `
        -ScalingPlanResourceGroup "rg-avd-prd-mgmt" `
        -KeyVaultName "hsm-avd-prd-weu-001" `
        -KeyName "cmk-avd-prd" `
        -DiskEncryptionSetName "des-avd-prd-weu-001"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$SubscriptionName,
    [Parameter(Mandatory = $true)] [string]$HostsResourceGroup,
    [Parameter(Mandatory = $true)] [string]$HostPoolName,
    [Parameter(Mandatory = $true)] [string]$ScalingPlanName,
    [Parameter(Mandatory = $true)] [string]$ScalingPlanResourceGroup,
    [Parameter(Mandatory = $true)] [string]$KeyVaultName,
    [Parameter(Mandatory = $true)] [string]$KeyName,
    [Parameter(Mandatory = $true)] [string]$DiskEncryptionSetName,
    [Parameter(Mandatory = $false)] [int]$MaxActiveSessionsAllowed = 0,
    [Parameter(Mandatory = $false)] [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$n, [string]$m) Write-Host "`n[$n] $m" -ForegroundColor Yellow }
function Write-OK   { param([string]$m) Write-Host "    [OK]    $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [WARN]  $m" -ForegroundColor DarkYellow }
function Write-Fail { param([string]$m) Write-Host "    [FAIL]  $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "    [INFO]  $m" -ForegroundColor Gray }

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Safe CMK Rotation for Confidential AVD" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subscription        : $SubscriptionName"
Write-Host "  Host pool           : $HostPoolName ($HostsResourceGroup)"
Write-Host "  Scaling plan        : $ScalingPlanName ($ScalingPlanResourceGroup)"
Write-Host "  HSM                 : $KeyVaultName"
Write-Host "  Key                 : $KeyName"
Write-Host "  Disk Encryption Set : $DiskEncryptionSetName"
Write-Host "  Dry run             : $DryRun"
Write-Host ""

# ---------------------------------------------------------------------------
# Step 1 - Subscription context
# ---------------------------------------------------------------------------
Write-Step "1/6" "Setting subscription context"
az account set --subscription $SubscriptionName | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Fail "az login required"; exit 1 }
Write-OK "Subscription set"

# ---------------------------------------------------------------------------
# Step 2 - Check for active sessions on the host pool
# A CMK rotation requires zero running VMs on the DES; starting a rotation
# while users are logged in will force them out mid-session.
# ---------------------------------------------------------------------------
Write-Step "2/6" "Checking for active user sessions on '$HostPoolName'"

$sessionsJson = az desktopvirtualization session-host list `
    --resource-group $HostsResourceGroup `
    --host-pool-name $HostPoolName `
    -o json

$sessionHosts = $sessionsJson | ConvertFrom-Json
$totalActive = ($sessionHosts | Measure-Object -Property sessions -Sum).Sum
if ($null -eq $totalActive) { $totalActive = 0 }

Write-Info "Session hosts in pool : $($sessionHosts.Count)"
Write-Info "Total active sessions : $totalActive"

if ($totalActive -gt $MaxActiveSessionsAllowed) {
    Write-Fail "Active sessions ($totalActive) exceed threshold ($MaxActiveSessionsAllowed)."
    Write-Fail "Refusing to proceed. Run inside a maintenance window."
    exit 1
}
Write-OK "Active sessions within acceptable threshold"

# ---------------------------------------------------------------------------
# Step 3 - Read the exclusion tag name from the scaling plan
# ---------------------------------------------------------------------------
Write-Step "3/6" "Reading exclusion tag from scaling plan '$ScalingPlanName'"

$planJson = az desktopvirtualization scaling-plan show `
    --resource-group $ScalingPlanResourceGroup `
    --name $ScalingPlanName `
    -o json 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Could not read scaling plan '$ScalingPlanName'."
    exit 1
}

$plan = $planJson | ConvertFrom-Json
$exclusionTag = $plan.exclusionTag
if (-not $exclusionTag) {
    Write-Warn "No exclusion tag set on the scaling plan. Using default 'CMKRotationInProgress'."
    Write-Warn "Add exclusionTag to the scaling plan so future rotations use the canonical tag."
    $exclusionTag = "CMKRotationInProgress"
}
Write-OK "Exclusion tag name: $exclusionTag"

# ---------------------------------------------------------------------------
# Step 4 - Apply the exclusion tag to every CVM in the host pool
# ---------------------------------------------------------------------------
Write-Step "4/6" "Applying exclusion tag to all Confidential VMs"

$cvmsJson = az vm list --resource-group $HostsResourceGroup -o json
$allVms = $cvmsJson | ConvertFrom-Json
$cvms = $allVms | Where-Object { $_.securityProfile.securityType -eq 'ConfidentialVM' }

if ($cvms.Count -eq 0) {
    Write-Fail "No Confidential VMs found in '$HostsResourceGroup'."
    exit 1
}
Write-Info "Found $($cvms.Count) Confidential VM(s) to tag"

if ($DryRun) {
    Write-Info "[DryRun] Would apply tag '$exclusionTag=true' to the following VMs:"
    $cvms | ForEach-Object { Write-Info "  $($_.name)" }
} else {
    foreach ($vm in $cvms) {
        az tag update --resource-id $vm.id `
            --operation merge `
            --tags "$exclusionTag=true" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Tagged: $($vm.name)"
        } else {
            Write-Fail "Failed to tag $($vm.name). Aborting to avoid partial state."
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5 - Trigger Rotate-CMK.ps1 from part 2
# ---------------------------------------------------------------------------
Write-Step "5/6" "Triggering Rotate-CMK.ps1 (part 2, 9-step rotation)"

$rotateScript = Join-Path $PSScriptRoot "Rotate-CMK.ps1"
if (-not (Test-Path $rotateScript)) {
    Write-Fail "Rotate-CMK.ps1 not found at $rotateScript. Check your repo layout."
    Write-Fail "Remove the exclusion tag manually before re-running."
    exit 1
}

if ($DryRun) {
    Write-Info "[DryRun] Would invoke: $rotateScript -DryRun with the provided parameters"
} else {
    & $rotateScript `
        -SubscriptionName $SubscriptionName `
        -HostsResourceGroup $HostsResourceGroup `
        -HostPoolName $HostPoolName `
        -KeyVaultName $KeyVaultName `
        -KeyName $KeyName `
        -DiskEncryptionSetName $DiskEncryptionSetName

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Rotate-CMK.ps1 exited with code $LASTEXITCODE."
        Write-Fail "CVMs still carry the exclusion tag. Remove manually if recovery is safe."
        Write-Fail "Tag to remove: $exclusionTag"
        exit 1
    }
    Write-OK "Rotation completed successfully"
}

# ---------------------------------------------------------------------------
# Step 6 - Remove the exclusion tag so autoscale resumes normal operation
# ---------------------------------------------------------------------------
Write-Step "6/6" "Removing exclusion tag to restore normal autoscale"

if ($DryRun) {
    Write-Info "[DryRun] Would remove tag '$exclusionTag' from all tagged CVMs"
} else {
    foreach ($vm in $cvms) {
        az tag update --resource-id $vm.id `
            --operation delete `
            --tags "$exclusionTag=true" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Untagged: $($vm.name)"
        } else {
            Write-Warn "Failed to untag $($vm.name). Remove manually: $exclusionTag"
        }
    }
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "  Safe CMK rotation complete" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Autoscale is now free to manage the host pool again." -ForegroundColor Gray
Write-Host "  Run Get-AttestationStatus.ps1 to confirm attestation is still healthy." -ForegroundColor Gray
Write-Host ""
