<#
.SYNOPSIS
    Safely rotates the Customer-Managed Key (CMK) used by Confidential AVD session hosts.

.DESCRIPTION
    Confidential VMs do NOT support automatic key rotation. A new key version must be
    activated while all VMs sharing the Disk Encryption Set (DES) are stopped/deallocated.
    If any VM is still running when the DES key version is updated, none of the VMs in
    that DES will receive the new key.

    This script performs the full rotation sequence:

      1. Validates pre-requisites (Azure CLI session, HSM/KV access, DES, VMs).
      2. Enables AVD drain mode on the host pool so no new sessions start.
      3. Waits for existing sessions to end (configurable timeout) or forces logoff.
      4. Deallocates all session host VMs associated with the DES.
      5. Creates a new key version in the Key Vault (standard KV) or Managed HSM.
      6. Updates the Disk Encryption Set to reference the new key version.
      7. Starts all session host VMs.
      8. Disables drain mode on the host pool.
      9. Outputs the new key URL for you to store in your hostpool config JSON.

    For Managed HSM keys the script uses the az keyvault key create pattern from
    CreateHSM_CMK.ps1. For standard Key Vault keys it uses az keyvault key rotate.

.PARAMETER SubscriptionName
    Azure subscription name or ID where the session hosts and DES reside.

.PARAMETER HostPoolResourceGroup
    Resource group containing the AVD host pool.

.PARAMETER HostPoolName
    Name of the AVD host pool.

.PARAMETER HostsResourceGroup
    Resource group containing the session host VMs.

.PARAMETER DiskEncryptionSetName
    Name of the Disk Encryption Set backed by the CMK.

.PARAMETER DiskEncryptionSetResourceGroup
    Resource group containing the Disk Encryption Set.

.PARAMETER KeyVaultName
    Name of the Key Vault (standard KV only - for Managed HSM use -HsmName).

.PARAMETER HsmName
    Name of the Managed HSM (use instead of -KeyVaultName for HSM-backed keys).

.PARAMETER KeyName
    Name of the key inside the Key Vault or Managed HSM.

.PARAMETER SessionDrainTimeoutMinutes
    How long to wait for user sessions to end before forcing logoff. Default: 30.

.PARAMETER ForceLogoff
    If set, active sessions are logged off immediately without waiting.

.PARAMETER DryRun
    Validate and display what the script would do without making any changes.

.EXAMPLE
    # Standard Key Vault rotation:
    .\Rotate-CMK.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostPoolResourceGroup "rg-avd-prd-hp" `
        -HostPoolName "hp-avd-prd-weu-001" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -DiskEncryptionSetName "des-avd-prd-cmk-weu-001" `
        -DiskEncryptionSetResourceGroup "rg-avd-prd-cmk" `
        -KeyVaultName "kv-avd-cmk-prd-weu-001" `
        -KeyName "cmk-avd-prd-weu-001"

.EXAMPLE
    # Managed HSM rotation:
    .\Rotate-CMK.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostPoolResourceGroup "rg-avd-prd-hp" `
        -HostPoolName "hp-avd-prd-weu-001" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -DiskEncryptionSetName "des-avd-prd-cmk-weu-001" `
        -DiskEncryptionSetResourceGroup "rg-avd-prd-cmk" `
        -HsmName "kvhsm-avd-prd-weu-001" `
        -KeyName "cmk-avd-prd-weu-001"

.EXAMPLE
    # Dry run - see what would happen:
    .\Rotate-CMK.ps1 ... -DryRun
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionName,

    [Parameter(Mandatory = $true)]
    [string]$HostPoolResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$HostPoolName,

    [Parameter(Mandatory = $true)]
    [string]$HostsResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$DiskEncryptionSetName,

    [Parameter(Mandatory = $true)]
    [string]$DiskEncryptionSetResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$HsmName,

    [Parameter(Mandatory = $true)]
    [string]$KeyName,

    [Parameter(Mandatory = $false)]
    [int]$SessionDrainTimeoutMinutes = 30,

    [Parameter(Mandatory = $false)]
    [switch]$ForceLogoff,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step {
    param([string]$Number, [string]$Message)
    Write-Host ""
    Write-Host "[$Number] $Message" -ForegroundColor Yellow
}

function Write-OK   { param([string]$Message) Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    [..] $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "    [!!] $Message" -ForegroundColor DarkYellow }
function Write-Err  { param([string]$Message) Write-Host "    [ERROR] $Message" -ForegroundColor Red }

function Assert-Success {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) {
        Write-Err $Message
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  CMK Key Rotation for Confidential AVD Session Hosts" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subscription  : $SubscriptionName"
Write-Host "  Host Pool     : $HostPoolName ($HostPoolResourceGroup)"
Write-Host "  Hosts RG      : $HostsResourceGroup"
Write-Host "  DES           : $DiskEncryptionSetName ($DiskEncryptionSetResourceGroup)"
if ($KeyVaultName) {
    Write-Host "  Key Vault     : $KeyVaultName / $KeyName"
} else {
    Write-Host "  Managed HSM   : $HsmName / $KeyName"
}
Write-Host "  Drain Timeout : $SessionDrainTimeoutMinutes minutes"
Write-Host "  Force Logoff  : $ForceLogoff"
Write-Host "  Dry Run       : $DryRun"
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 1 - Validate parameters and Azure CLI session
# ---------------------------------------------------------------------------
Write-Step "1/9" "Validating pre-requisites"

if ([string]::IsNullOrEmpty($KeyVaultName) -and [string]::IsNullOrEmpty($HsmName)) {
    Write-Err "You must provide either -KeyVaultName or -HsmName."
    exit 1
}
if (-not [string]::IsNullOrEmpty($KeyVaultName) -and -not [string]::IsNullOrEmpty($HsmName)) {
    Write-Err "Provide either -KeyVaultName or -HsmName, not both."
    exit 1
}

$accountJson = az account show 2>&1
Assert-Success "Not logged in to Azure CLI. Run 'az login' first."
$account = $accountJson | ConvertFrom-Json
Write-OK "Logged in as: $($account.user.name) - Subscription: $($account.name)"

az account set --subscription $SubscriptionName 2>&1 | Out-Null
Assert-Success "Failed to set subscription '$SubscriptionName'."
Write-OK "Subscription set to: $SubscriptionName"

# ---------------------------------------------------------------------------
# STEP 2 - Get all session hosts associated with the DES
# ---------------------------------------------------------------------------
Write-Step "2/9" "Discovering session host VMs using Disk Encryption Set '$DiskEncryptionSetName'"

$desId = az disk-encryption-set show `
    --name $DiskEncryptionSetName `
    --resource-group $DiskEncryptionSetResourceGroup `
    --query "id" -o tsv 2>&1
Assert-Success "Could not find Disk Encryption Set '$DiskEncryptionSetName' in '$DiskEncryptionSetResourceGroup'."
Write-OK "DES found: $desId"

# Find all VMs in the hosts resource group whose OS disk references this DES
$allVmsJson = az vm list --resource-group $HostsResourceGroup -o json 2>&1
Assert-Success "Failed to list VMs in '$HostsResourceGroup'."
$allVms = $allVmsJson | ConvertFrom-Json

$targetVms = $allVms | Where-Object {
    $_.storageProfile.osDisk.managedDisk.diskEncryptionSet.id -eq $desId
}

if ($targetVms.Count -eq 0) {
    Write-Warn "No VMs found in '$HostsResourceGroup' using DES '$DiskEncryptionSetName'."
    Write-Warn "Continuing - DES key will still be rotated."
} else {
    Write-OK "Found $($targetVms.Count) VM(s) using this DES:"
    $targetVms | ForEach-Object { Write-Info "  $($_.name)" }
}

# ---------------------------------------------------------------------------
# STEP 3 - Enable drain mode on the host pool
# ---------------------------------------------------------------------------
Write-Step "3/9" "Enabling drain mode on host pool '$HostPoolName'"

if ($DryRun) {
    Write-Info "[DRY RUN] Would enable drain mode on host pool."
} else {
    $subscriptionId = az account show --query "id" -o tsv 2>$null
    $apiVersion = "2023-09-05"
    $hpUri = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}?api-version=${apiVersion}"

    $drainBody = @{
        properties = @{ loadBalancerType = "BreadthFirst" }
    } | ConvertTo-Json -Depth 5

    $drainTempFile = [System.IO.Path]::GetTempFileName()
    $drainBody | Out-File $drainTempFile -Encoding UTF8

    # Set each session host into drain mode
    $sessionHostsJson = az rest --method GET --uri "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/sessionHosts?api-version=${apiVersion}" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $sessionHosts = ($sessionHostsJson | ConvertFrom-Json).value
        foreach ($sh in $sessionHosts) {
            $shName = $sh.name.Split('/')[1]
            $shUri = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/sessionHosts/${shName}?api-version=${apiVersion}&force=true"
            $shBody = @{ properties = @{ allowNewSession = $false } } | ConvertTo-Json -Depth 5
            $shTempFile = [System.IO.Path]::GetTempFileName()
            $shBody | Out-File $shTempFile -Encoding UTF8
            az rest --method PATCH --uri $shUri --body "@$shTempFile" | Out-Null
            Remove-Item $shTempFile -Force -ErrorAction SilentlyContinue
            Write-Info "Drain mode enabled on session host: $shName"
        }
    }

    Remove-Item $drainTempFile -Force -ErrorAction SilentlyContinue
    Write-OK "Drain mode enabled. No new sessions will be directed to these hosts."
}

# ---------------------------------------------------------------------------
# STEP 4 - Wait for active sessions to end (or force logoff)
# ---------------------------------------------------------------------------
Write-Step "4/9" "Waiting for active user sessions to end (timeout: $SessionDrainTimeoutMinutes min)"

if ($DryRun) {
    Write-Info "[DRY RUN] Would wait for sessions or force logoff."
} else {
    $subscriptionId = az account show --query "id" -o tsv 2>$null
    $deadline = (Get-Date).AddMinutes($SessionDrainTimeoutMinutes)

    :waitLoop while ((Get-Date) -lt $deadline) {
        $apiVersion = "2023-09-05"
        $sessionsUri = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/userSessions?api-version=${apiVersion}"
        $sessionsJson = az rest --method GET --uri $sessionsUri 2>&1
        if ($LASTEXITCODE -eq 0) {
            $sessions = ($sessionsJson | ConvertFrom-Json).value | Where-Object { $_.properties.sessionState -eq 'Active' }
            $activeCount = ($sessions | Measure-Object).Count
            if ($activeCount -eq 0) {
                Write-OK "No active sessions remaining."
                break waitLoop
            }
            Write-Info "Active sessions: $activeCount - waiting 60 seconds..."
        }
        Start-Sleep -Seconds 60
    }

    # Check again after timeout
    $sessionsJson = az rest --method GET --uri "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/userSessions?api-version=${apiVersion}" 2>&1
    $remainingSessions = ($sessionsJson | ConvertFrom-Json).value | Where-Object { $_.properties.sessionState -eq 'Active' }

    if (($remainingSessions | Measure-Object).Count -gt 0) {
        if ($ForceLogoff) {
            Write-Warn "Timeout reached. Forcing logoff of $($remainingSessions.Count) active session(s)."
            foreach ($session in $remainingSessions) {
                $sessionName = $session.name.Split('/')[2]
                $shName = $session.name.Split('/')[1]
                $logoffUri = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/sessionHosts/${shName}/userSessions/${sessionName}/disconnect?api-version=${apiVersion}"
                az rest --method POST --uri $logoffUri | Out-Null
                Write-Info "Disconnected session: $($session.properties.userPrincipalName)"
            }
            Start-Sleep -Seconds 30
        } else {
            Write-Err "Active sessions still present after $SessionDrainTimeoutMinutes minutes. Use -ForceLogoff to disconnect users automatically or wait longer."
            Write-Warn "Re-enabling new sessions on host pool before exiting."
            # Re-enable sessions before bailing out
            foreach ($sh in $sessionHosts) {
                $shName = $sh.name.Split('/')[1]
                $shUri = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/sessionHosts/${shName}?api-version=${apiVersion}&force=true"
                $shBody = @{ properties = @{ allowNewSession = $true } } | ConvertTo-Json -Depth 5
                $shTempFile = [System.IO.Path]::GetTempFileName()
                $shBody | Out-File $shTempFile -Encoding UTF8
                az rest --method PATCH --uri $shUri --body "@$shTempFile" | Out-Null
                Remove-Item $shTempFile -Force -ErrorAction SilentlyContinue
            }
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 5 - Deallocate all session host VMs
# ---------------------------------------------------------------------------
Write-Step "5/9" "Deallocating $($targetVms.Count) session host VM(s)"

if ($DryRun) {
    Write-Info "[DRY RUN] Would deallocate: $($targetVms.name -join ', ')"
} else {
    foreach ($vm in $targetVms) {
        Write-Info "Deallocating: $($vm.name)"
        az vm deallocate --resource-group $HostsResourceGroup --name $vm.name --no-wait 2>&1 | Out-Null
    }

    Write-Info "Waiting for all VMs to reach Deallocated state..."
    $allDeallocated = $false
    $deadline = (Get-Date).AddMinutes(20)

    while (-not $allDeallocated -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $states = $targetVms | ForEach-Object {
            $state = az vm get-instance-view `
                --resource-group $HostsResourceGroup `
                --name $_.name `
                --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" `
                -o tsv 2>$null
            [PSCustomObject]@{ Name = $_.name; State = $state }
        }
        $notDeallocated = $states | Where-Object { $_.State -ne 'VM deallocated' }
        if ($notDeallocated.Count -eq 0) {
            $allDeallocated = $true
        } else {
            Write-Info "Still waiting: $($notDeallocated.Name -join ', ')"
        }
    }

    if (-not $allDeallocated) {
        Write-Err "Some VMs did not reach Deallocated state within 20 minutes. Aborting rotation."
        exit 1
    }
    Write-OK "All VMs deallocated."
}

# ---------------------------------------------------------------------------
# STEP 6 - Create new key version
# ---------------------------------------------------------------------------
Write-Step "6/9" "Creating new key version"

$newKeyUrl = $null

if ($DryRun) {
    Write-Info "[DRY RUN] Would create new key version in $( if ($KeyVaultName) { "Key Vault $KeyVaultName" } else { "Managed HSM $HsmName" } )"
} else {
    if ($KeyVaultName) {
        # Standard Key Vault: az keyvault key rotate generates a new version
        $rotateJson = az keyvault key rotate `
            --vault-name $KeyVaultName `
            --name $KeyName `
            2>&1
        Assert-Success "Failed to rotate key '$KeyName' in Key Vault '$KeyVaultName'."
        $newKeyUrl = ($rotateJson | ConvertFrom-Json).key.kid
        Write-OK "New key version created: $newKeyUrl"
    } else {
        # Managed HSM: create a new key version manually
        # (az keyvault key rotate is not available for Managed HSM keys)
        $newKeyJson = az keyvault key create `
            --hsm-name $HsmName `
            --name $KeyName `
            --kty RSA-HSM `
            --size 3072 `
            --ops wrapKey unwrapKey `
            --exportable true `
            --default-cvm-policy `
            2>&1
        Assert-Success "Failed to create new key version in Managed HSM '$HsmName'."
        $newKeyUrl = ($newKeyJson | ConvertFrom-Json).key.kid
        Write-OK "New key version created: $newKeyUrl"
    }
}

# ---------------------------------------------------------------------------
# STEP 7 - Update the Disk Encryption Set to reference the new key version
# ---------------------------------------------------------------------------
Write-Step "7/9" "Updating Disk Encryption Set to new key version"

if ($DryRun) {
    Write-Info "[DRY RUN] Would update DES '$DiskEncryptionSetName' to reference new key."
} else {
    $desUpdateJson = az disk-encryption-set update `
        --name $DiskEncryptionSetName `
        --resource-group $DiskEncryptionSetResourceGroup `
        --key-url $newKeyUrl `
        2>&1
    Assert-Success "Failed to update Disk Encryption Set '$DiskEncryptionSetName'."
    Write-OK "DES updated to new key version."

    # Verify the DES now points to the new key
    $desVerifyJson = az disk-encryption-set show `
        --name $DiskEncryptionSetName `
        --resource-group $DiskEncryptionSetResourceGroup `
        --query "properties.activeKey.keyUrl" -o tsv 2>&1
    Write-Info "DES active key URL: $desVerifyJson"
}

# ---------------------------------------------------------------------------
# STEP 8 - Start session host VMs
# ---------------------------------------------------------------------------
Write-Step "8/9" "Starting session host VMs"

if ($DryRun) {
    Write-Info "[DRY RUN] Would start: $($targetVms.name -join ', ')"
} else {
    foreach ($vm in $targetVms) {
        Write-Info "Starting: $($vm.name)"
        az vm start --resource-group $HostsResourceGroup --name $vm.name --no-wait 2>&1 | Out-Null
    }

    Write-Info "Waiting for VMs to reach Running state..."
    $allRunning = $false
    $deadline = (Get-Date).AddMinutes(15)

    while (-not $allRunning -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $states = $targetVms | ForEach-Object {
            $state = az vm get-instance-view `
                --resource-group $HostsResourceGroup `
                --name $_.name `
                --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" `
                -o tsv 2>$null
            [PSCustomObject]@{ Name = $_.name; State = $state }
        }
        $notRunning = $states | Where-Object { $_.State -ne 'VM running' }
        if ($notRunning.Count -eq 0) {
            $allRunning = $true
        } else {
            Write-Info "Still waiting: $($notRunning.Name -join ', ')"
        }
    }

    if (-not $allRunning) {
        Write-Warn "Some VMs did not reach Running state within 15 minutes. Check them manually."
    } else {
        Write-OK "All VMs running."
    }
}

# ---------------------------------------------------------------------------
# STEP 9 - Re-enable new sessions on the host pool
# ---------------------------------------------------------------------------
Write-Step "9/9" "Disabling drain mode - host pool accepting new sessions"

if ($DryRun) {
    Write-Info "[DRY RUN] Would re-enable new sessions on host pool."
} else {
    $subscriptionId = az account show --query "id" -o tsv 2>$null
    $apiVersion = "2023-09-05"
    $sessionHostsJson = az rest --method GET --uri "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/sessionHosts?api-version=${apiVersion}" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $sessionHosts = ($sessionHostsJson | ConvertFrom-Json).value
        foreach ($sh in $sessionHosts) {
            $shName = $sh.name.Split('/')[1]
            $shUri = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${HostPoolResourceGroup}/providers/Microsoft.DesktopVirtualization/hostPools/${HostPoolName}/sessionHosts/${shName}?api-version=${apiVersion}&force=true"
            $shBody = @{ properties = @{ allowNewSession = $true } } | ConvertTo-Json -Depth 5
            $shTempFile = [System.IO.Path]::GetTempFileName()
            $shBody | Out-File $shTempFile -Encoding UTF8
            az rest --method PATCH --uri $shUri --body "@$shTempFile" | Out-Null
            Remove-Item $shTempFile -Force -ErrorAction SilentlyContinue
            Write-Info "New sessions re-enabled on: $shName"
        }
    }
    Write-OK "Drain mode disabled. Host pool accepting new sessions."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "  CMK Rotation Complete" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
if (-not $DryRun -and $newKeyUrl) {
    Write-Host "  New key URL:" -ForegroundColor Cyan
    Write-Host "  $newKeyUrl" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Update your hostpool config JSON with the new key URL." -ForegroundColor White
    Write-Host "     Field: managedHsmKeyUrl (or keyVaultKeyUrl)" -ForegroundColor Gray
    Write-Host "     Value: $newKeyUrl" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Update ComponentLibrary/DiskEncryptionSet/main.parameters.json" -ForegroundColor White
    Write-Host "     Field: keyUrl" -ForegroundColor Gray
    Write-Host "     Value: $newKeyUrl" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. Commit the updated config files to your repo." -ForegroundColor White
}
Write-Host ""
Write-Host "  [DONE]" -ForegroundColor Green
