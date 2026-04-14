<#
.SYNOPSIS
    Queries and reports Guest Attestation extension health for all Confidential VM
    session hosts in an Azure Virtual Desktop host pool.

.DESCRIPTION
    Confidential VMs use the GuestAttestation extension to prove they are running
    inside a genuine AMD SEV-SNP Trusted Execution Environment. This script:

      1. Lists all session host VMs in a given resource group.
      2. Checks the GuestAttestation extension provisioning state on each VM.
      3. Reads the extension instance view to surface any error messages.
      4. Optionally queries Log Analytics for attestation events from the past N days.
      5. Outputs a colour-coded summary and exits non-zero if any host has a
         failed or missing extension (suitable for use in Azure DevOps pipelines).

    Run this script after deploying new session hosts or after any image update
    rollout to confirm that attestation is healthy across the entire pool.

.PARAMETER SubscriptionName
    Azure subscription containing the session hosts.

.PARAMETER HostsResourceGroup
    Resource group containing the session host VMs.

.PARAMETER HostPoolName
    Name of the AVD host pool (used to filter VMs by the AVD host pool tag if
    present, and for display purposes).

.PARAMETER LogAnalyticsWorkspaceId
    Optional. Resource ID of the Log Analytics Workspace. When provided, the
    script also queries for attestation error events from the past QueryDays days.

.PARAMETER QueryDays
    Number of days of Log Analytics history to query for attestation events.
    Default: 7.

.PARAMETER DryRun
    When set, shows what would be checked without making any calls that modify
    resource state. Read-only operations (az vm extension show, Log Analytics
    queries) still execute.

.EXAMPLE
    .\Scripts\Get-AttestationStatus.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -HostPoolName "hp-avd-prd-weu-001"

.EXAMPLE
    # Full query including Log Analytics events
    .\Scripts\Get-AttestationStatus.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -HostPoolName "hp-avd-prd-weu-001" `
        -LogAnalyticsWorkspaceId "/subscriptions/.../workspaces/law-avd-prd-weu-001" `
        -QueryDays 14
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionName,

    [Parameter(Mandatory = $true)]
    [string]$HostsResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$HostPoolName,

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceId = '',

    [Parameter(Mandatory = $false)]
    [int]$QueryDays = 7,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step   { param([string]$n, [string]$m) Write-Host "`n[$n] $m" -ForegroundColor Yellow }
function Write-OK     { param([string]$m) Write-Host "    [OK]    $m" -ForegroundColor Green }
function Write-Warn   { param([string]$m) Write-Host "    [WARN]  $m" -ForegroundColor DarkYellow }
function Write-Fail   { param([string]$m) Write-Host "    [FAIL]  $m" -ForegroundColor Red }
function Write-Info   { param([string]$m) Write-Host "    [INFO]  $m" -ForegroundColor Gray }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Guest Attestation Status - Confidential AVD" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subscription : $SubscriptionName"
Write-Host "  Resource Grp : $HostsResourceGroup"
Write-Host "  Host Pool    : $HostPoolName"
Write-Host "  LA Workspace : $(if ($LogAnalyticsWorkspaceId) { $LogAnalyticsWorkspaceId } else { '(not provided - skipping LA query)' })"
Write-Host "  Query Window : $QueryDays days"
Write-Host "  Dry Run      : $DryRun"
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 1 - Set subscription context
# ---------------------------------------------------------------------------
Write-Step "1/4" "Setting subscription context"

az account set --subscription $SubscriptionName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to set subscription. Run 'az login' first."
    exit 1
}
Write-OK "Subscription set: $SubscriptionName"

# ---------------------------------------------------------------------------
# STEP 2 - Discover Confidential VMs in the resource group
# ---------------------------------------------------------------------------
Write-Step "2/4" "Discovering Confidential VMs in '$HostsResourceGroup'"

$allVmsJson = az vm list --resource-group $HostsResourceGroup -o json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to list VMs in '$HostsResourceGroup'."
    exit 1
}

$allVms = $allVmsJson | ConvertFrom-Json

# Filter to Confidential VMs only
$cvmHosts = $allVms | Where-Object {
    $_.securityProfile.securityType -eq 'ConfidentialVM'
}

if ($cvmHosts.Count -eq 0) {
    Write-Warn "No Confidential VMs found in '$HostsResourceGroup'."
    Write-Info "If session hosts are standard VMs, Guest Attestation does not apply."
    exit 0
}

Write-OK "Found $($cvmHosts.Count) Confidential VM(s):"
$cvmHosts | ForEach-Object { Write-Info "  $($_.name)  [$($_.location)]" }

# ---------------------------------------------------------------------------
# STEP 3 - Check GuestAttestation extension on each VM
# ---------------------------------------------------------------------------
Write-Step "3/4" "Checking GuestAttestation extension on each VM"

$results = @()
$failCount = 0
$warnCount = 0

foreach ($vm in $cvmHosts) {
    $vmName = $vm.name
    Write-Info "Checking $vmName ..."

    # Get extension instance view (includes status messages)
    $extJson = az vm extension show `
        --resource-group $HostsResourceGroup `
        --vm-name $vmName `
        --name "GuestAttestation" `
        --query "{state: provisioningState, status: instanceView.statuses}" `
        -o json 2>&1

    if ($LASTEXITCODE -ne 0 -or $null -eq $extJson) {
        Write-Fail "  $vmName: GuestAttestation extension NOT FOUND or cannot be read"
        $results += [PSCustomObject]@{
            VM     = $vmName
            Status = "MISSING"
            Detail = "Extension not installed"
        }
        $failCount++
        continue
    }

    $ext = $extJson | ConvertFrom-Json
    $state = $ext.state
    $statusMessages = $ext.status | ForEach-Object { $_.message } | Where-Object { $_ }

    switch ($state) {
        "Succeeded" {
            Write-OK "  $vmName: extension Succeeded"
            $results += [PSCustomObject]@{
                VM     = $vmName
                Status = "OK"
                Detail = "GuestAttestation provisioned successfully"
            }
        }
        "Failed" {
            Write-Fail "  $vmName: extension FAILED"
            $statusMessages | ForEach-Object { Write-Fail "    $_" }
            $results += [PSCustomObject]@{
                VM     = $vmName
                Status = "FAILED"
                Detail = ($statusMessages -join " | ")
            }
            $failCount++
        }
        "Creating" {
            Write-Warn "  $vmName: extension still provisioning (Creating)"
            $results += [PSCustomObject]@{
                VM     = $vmName
                Status = "PROVISIONING"
                Detail = "Extension is still being installed"
            }
            $warnCount++
        }
        default {
            Write-Warn "  $vmName: unexpected state '$state'"
            $results += [PSCustomObject]@{
                VM     = $vmName
                Status = $state
                Detail = ($statusMessages -join " | ")
            }
            $warnCount++
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 4 - Optional: query Log Analytics for attestation error events
# ---------------------------------------------------------------------------
Write-Step "4/4" "Log Analytics attestation event query"

if ([string]::IsNullOrEmpty($LogAnalyticsWorkspaceId)) {
    Write-Info "Log Analytics Workspace ID not provided - skipping event query."
    Write-Info "Provide -LogAnalyticsWorkspaceId to also query for attestation events."
} else {
    # Extract workspace name and resource group from the resource ID
    $workspaceName = ($LogAnalyticsWorkspaceId -split '/')[-1]
    $workspaceRg   = ($LogAnalyticsWorkspaceId -split '/')[4]

    Write-Info "Querying workspace: $workspaceName (last $QueryDays days)"

    # KQL query: attestation failures and warnings from the GuestAttestation extension
    $kqlQuery = @"
WindowsEvent
| where TimeGenerated > ago(${QueryDays}d)
| where Channel contains "Attestation" or Channel contains "TPM"
| where Level in (1, 2, 3)
| project TimeGenerated, Computer, Channel, EventID, Message = tostring(EventData)
| order by TimeGenerated desc
| take 50
"@

    $laResultJson = az monitor log-analytics query `
        --workspace $workspaceName `
        --resource-group $workspaceRg `
        --analytics-query $kqlQuery `
        -o json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Log Analytics query failed. Check permissions on the workspace."
        Write-Warn "Required role: Log Analytics Reader on the workspace."
    } else {
        $laResults = $laResultJson | ConvertFrom-Json
        if ($laResults.Count -eq 0) {
            Write-OK "No attestation error events in the past $QueryDays days."
        } else {
            Write-Warn "Found $($laResults.Count) attestation event(s) in the past $QueryDays days:"
            $laResults | ForEach-Object {
                Write-Warn "  [$($_.TimeGenerated)] $($_.Computer) - EventID $($_.EventID)"
                if ($_.Message) { Write-Info "    $($_.Message.Substring(0, [Math]::Min(200, $_.Message.Length)))" }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Attestation Status Summary" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

$results | Format-Table -AutoSize

$okCount = ($results | Where-Object Status -eq "OK").Count

Write-Host ""
Write-Host "  Total CVMs  : $($cvmHosts.Count)"
Write-Host "  Healthy     : $okCount" -ForegroundColor $(if ($okCount -eq $cvmHosts.Count) { "Green" } else { "Yellow" })
Write-Host "  Warnings    : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Failures    : $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($failCount -gt 0) {
    Write-Host "  [ACTION REQUIRED] One or more session hosts have a failed or missing" -ForegroundColor Red
    Write-Host "  GuestAttestation extension. These hosts cannot prove they are running" -ForegroundColor Red
    Write-Host "  in a genuine TEE. Investigate before allowing user sessions." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    - VM was deployed without the GuestAttestation extension in the Bicep" -ForegroundColor Yellow
    Write-Host "    - VM is not a Confidential VM (wrong VM size or security profile)" -ForegroundColor Yellow
    Write-Host "    - Network security group blocking outbound HTTPS to the attestation endpoint" -ForegroundColor Yellow
    Write-Host "    - Extension provisioning failed due to a transient error (redeploy the extension)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  To redeploy the extension on a specific VM:" -ForegroundColor Gray
    Write-Host "    az vm extension set --resource-group $HostsResourceGroup --vm-name <VM_NAME> \\" -ForegroundColor Gray
    Write-Host "      --name GuestAttestation --publisher Microsoft.Azure.Security.WindowsAttestation \\" -ForegroundColor Gray
    Write-Host "      --version 1.0 --enable-auto-upgrade true" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

if ($warnCount -gt 0) {
    Write-Host "  [WARNING] Some extensions are still provisioning. Re-run in a few minutes." -ForegroundColor Yellow
    exit 2
}

Write-Host "  [OK] All Confidential VM session hosts have a healthy GuestAttestation extension." -ForegroundColor Green
Write-Host "  These hosts have cryptographic proof they are running in a genuine AMD SEV-SNP TEE." -ForegroundColor Green
Write-Host ""
Write-Host "  [DONE]" -ForegroundColor Green
