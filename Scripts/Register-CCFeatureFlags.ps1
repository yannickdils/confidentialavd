<#
.SYNOPSIS
    Registers required Azure preview feature flags for Confidential Compute VM sizes.

.DESCRIPTION
    The DCasv6/ECasv6 Confidential Compute VM sizes require one of the following
    preview feature flags to be registered on the subscription:

      - Microsoft.Compute/VMSKUPreview      (general preview VM SKU access)
      - Microsoft.Compute/DCav6Series       (DCasv6 series specific access)

    This script attempts to register each flag in order. Some flags may return
    'FeatureRegistrationUnsupported' if they are not exposed via self-service
    registration. Some flags may go to 'Pending' state, requiring an Azure
    support ticket for approval.

    If none of the flags can be registered, the script outputs clear guidance
    on how to request access via Azure Support.

.PARAMETER SubscriptionName
    The name of the Azure subscription to target.

.PARAMETER VmSize
    The VM size to check feature flag requirements for (e.g., Standard_DC8as_v6).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionName,

    [Parameter(Mandatory = $true)]
    [string]$VmSize
)

# Azure CLI writes WARNING messages to stderr. PowerShell 5.1 with
# $ErrorActionPreference = 'Stop' treats ANY stderr output as a terminating
# error. We use 'Continue' globally and check $LASTEXITCODE explicitly instead.
$ErrorActionPreference = 'Continue'

# Set subscription context
az account set --subscription $SubscriptionName
if ($LASTEXITCODE -ne 0) {
    Write-Host "##vso[task.logissue type=error]Failed to set subscription to '$SubscriptionName'"
    exit 1
}

Write-Host "##[section]Checking feature flag requirements for VM size: $VmSize"

# ─────────────────────────────────────────────────────────────────────────────
# Determine which feature flags to attempt based on VM size series.
# The Azure error message for DC/ECasv6 lists three possible flags:
#   - Microsoft.Compute/DCav6Series       (series-specific)
#   - Microsoft.Compute/VMSKUPreview      (general preview SKU access)
#   - Microsoft.Compute/TestSubscription  (internal MS only, skip)
# We try them in order of most likely to succeed for customers.
# ─────────────────────────────────────────────────────────────────────────────
$candidateFeatures = @()

if ($VmSize -match '^Standard_(DC|EC).*_v6$') {
    $candidateFeatures = @('VMSKUPreview', 'DCav6Series')
} elseif ($VmSize -match '^Standard_DC.*_v5$') {
    $candidateFeatures = @('VMSKUPreview', 'DCasv5')
} elseif ($VmSize -match '^Standard_EC.*_v5$') {
    $candidateFeatures = @('VMSKUPreview', 'ECasv5')
}

if ($candidateFeatures.Count -eq 0) {
    Write-Host "[OK] No additional feature flags required for VM size '$VmSize'"
    Write-Host "##vso[task.setvariable variable=featuresRegistered;isOutput=true]skipped"
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Check if ANY of the candidate features is already registered.
#           If so, we are good to go.
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "##[section]Phase 1 - Checking current registration state of candidate feature flags..."

foreach ($feature in $candidateFeatures) {
    $featureFullName = "Microsoft.Compute/" + $feature
    Write-Host "  Checking: $featureFullName"

    $state = az feature show --namespace Microsoft.Compute --name $feature --query "properties.state" -o tsv 2>$null
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0 -and $state -eq "Registered") {
        Write-Host "  [OK] $featureFullName is already Registered"
        Write-Host ""
        Write-Host "##vso[task.setvariable variable=featuresRegistered;isOutput=true]completed"
        Write-Host "##[section][OK] Feature flag already registered - no action needed"
        exit 0
    }

    Write-Host "  State: $(if ($state) { $state } else { 'Unknown/NotFound' })"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Attempt to register each candidate feature flag.
#           Stop at the first one that accepts registration.
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "##[section]Phase 2 - Attempting to register feature flags..."

$registeredFeature = $null
$pendingFeature = $null
$allFailed = $true

foreach ($feature in $candidateFeatures) {
    $featureFullName = "Microsoft.Compute/" + $feature
    Write-Host ""
    Write-Host "  Attempting: $featureFullName"

    # Check current state first
    $state = az feature show --namespace Microsoft.Compute --name $feature --query "properties.state" -o tsv 2>$null

    if ($state -eq "Registered") {
        Write-Host "  [OK] Already registered"
        $registeredFeature = $feature
        $allFailed = $false
        break
    }

    if ($state -eq "Registering" -or $state -eq "Pending") {
        Write-Host "  [INFO] Feature is in state '$state' - will wait for it"
        $pendingFeature = $feature
        $allFailed = $false
        break
    }

    # Attempt registration - capture output to detect FeatureRegistrationUnsupported
    $registerOutput = az feature register --namespace Microsoft.Compute --name $feature 2>&1
    $registerExitCode = $LASTEXITCODE

    if ($registerExitCode -eq 0) {
        # Brief delay - Azure may need a moment to transition state after accepting registration
        Start-Sleep -Seconds 5

        # Check the resulting state
        $newState = az feature show --namespace Microsoft.Compute --name $feature --query "properties.state" -o tsv 2>$null

        if ($newState -eq "Registered") {
            Write-Host "  [OK] $featureFullName registered immediately"
            $registeredFeature = $feature
            $allFailed = $false
            break
        } elseif ($newState -eq "Registering" -or $newState -eq "Pending" -or $newState -eq "NotRegistered") {
            # NotRegistered right after a successful register call is a transient race condition;
            # treat it the same as Registering and let Phase 3 poll until it transitions.
            Write-Host "  [OK] $featureFullName registration accepted (state: $newState) - will wait for completion"
            $pendingFeature = $feature
            $allFailed = $false
            break
        } else {
            Write-Host "  [WARN] $featureFullName registration returned success but state is: $newState"
            Write-Host "  Output: $registerOutput"
        }
    } else {
        $outputString = $registerOutput | Out-String
        if ($outputString -match 'FeatureRegistrationUnsupported') {
            Write-Host "  [SKIP] $featureFullName does not support self-service registration"
        } else {
            Write-Host "  [FAIL] $featureFullName registration failed (exit code: $registerExitCode)"
            Write-Host "  Output: $registerOutput"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: If we found a registered feature, we are done.
#           If we found a pending feature, wait for it.
#           If all failed, provide guidance.
# ─────────────────────────────────────────────────────────────────────────────

if ($registeredFeature) {
    Write-Host ""
    Write-Host "##[section]Propagating feature registration to Microsoft.Compute provider..."
    az provider register --namespace Microsoft.Compute
    if ($LASTEXITCODE -ne 0) {
        Write-Host "##vso[task.logissue type=warning]Provider registration propagation returned non-zero. The feature may take additional time."
    } else {
        Write-Host "[OK] Provider registration propagated successfully"
    }

    Write-Host "Waiting 60 seconds for propagation..."
    Start-Sleep -Seconds 60

    Write-Host "##vso[task.setvariable variable=featuresRegistered;isOutput=true]completed"
    Write-Host "##[section][OK] Feature flag registration completed"
    exit 0
}

if ($pendingFeature) {
    $featureFullName = "Microsoft.Compute/" + $pendingFeature
    Write-Host ""
    Write-Host "##[section]Phase 3 - Waiting for feature $featureFullName to complete registration..."
    $maxWaitMinutes = 30
    $waitIntervalSeconds = 30
    $maxIterations = ($maxWaitMinutes * 60) / $waitIntervalSeconds
    $iteration = 0

    do {
        Start-Sleep -Seconds $waitIntervalSeconds
        $iteration++
        $elapsed = [math]::Round(($iteration * $waitIntervalSeconds) / 60, 1)

        $state = az feature show --namespace Microsoft.Compute --name $pendingFeature --query "properties.state" -o tsv 2>$null

        if ($state -eq "Registered") {
            Write-Host "  [OK] $featureFullName registered after $elapsed minutes"

            Write-Host ""
            Write-Host "##[section]Propagating feature registration to Microsoft.Compute provider..."
            az provider register --namespace Microsoft.Compute
            if ($LASTEXITCODE -ne 0) {
                Write-Host "##vso[task.logissue type=warning]Provider registration propagation returned non-zero."
            } else {
                Write-Host "[OK] Provider registration propagated successfully"
            }

            Write-Host "Waiting 60 seconds for propagation..."
            Start-Sleep -Seconds 60

            Write-Host "##vso[task.setvariable variable=featuresRegistered;isOutput=true]completed"
            Write-Host "##[section][OK] Feature flag registration completed"
            exit 0
        }

        if ($state -eq "Pending") {
            Write-Host "  [WAIT] $featureFullName is Pending (requires Azure approval) - $elapsed min elapsed"
            Write-Host "##vso[task.logissue type=warning]Feature $featureFullName is in Pending state - this requires manual approval via Azure Support."
            Write-Host ""
            Write-Host "##[section]ACTION REQUIRED: Submit an Azure Support request"
            Write-Host "The feature flag $featureFullName requires approval from Microsoft."
            Write-Host ""
            Write-Host "Steps to request access:"
            Write-Host "  1. Go to the Azure Portal > Help + Support > Create a support request"
            Write-Host "  2. Issue type: Technical"
            Write-Host "  3. Service: Virtual Machines running Windows / Linux"
            Write-Host "  4. Summary: Request access to $VmSize (Confidential Compute DCasv6) in belgiumcentral"
            Write-Host "  5. Mention subscription: $SubscriptionName"
            Write-Host "  6. Mention the feature flag: $featureFullName"
            Write-Host ""
            Write-Host "After approval, re-run this pipeline."
            exit 1
        }

        Write-Host "  Waiting: $featureFullName - $state ($elapsed min elapsed)"

        if ($iteration -ge $maxIterations) {
            Write-Host "##vso[task.logissue type=error]Timeout waiting for feature registration after $maxWaitMinutes minutes."
            Write-Host "##vso[task.logissue type=error]Current state: $state"
            Write-Host "##vso[task.logissue type=error]Please check the Azure Portal > Subscriptions > Preview features for status."
            exit 1
        }
    } while ($true)
}

# ─────────────────────────────────────────────────────────────────────────────
# All candidate flags failed self-service registration
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "##[section]FEATURE REGISTRATION FAILED"
Write-Host "##vso[task.logissue type=error]None of the candidate feature flags could be registered via self-service."
Write-Host ""
Write-Host "Attempted flags:"
foreach ($feature in $candidateFeatures) {
    Write-Host "  - Microsoft.Compute/$feature"
}
Write-Host ""
Write-Host "##[section]ACTION REQUIRED: Submit an Azure Support request to enable Confidential Compute"
Write-Host ""
Write-Host "The VM size $VmSize requires a preview feature flag that is not available for"
Write-Host "self-service registration. You need to request access from Microsoft."
Write-Host ""
Write-Host "Option 1 - Azure Portal (recommended):"
Write-Host "  1. Go to: Azure Portal > Subscriptions > '$SubscriptionName' > Preview features"
Write-Host "  2. Search for 'Confidential' or 'DCav6'"
Write-Host "  3. If the feature appears, click Register"
Write-Host "  4. If not, create a support ticket:"
Write-Host "     - Issue type: Technical"
Write-Host "     - Service type: Virtual Machines"
Write-Host "     - Summary: Enable $VmSize (DCasv6 Confidential Compute) in belgiumcentral"
Write-Host "     - Mention subscription ID and the required feature flag"
Write-Host ""
Write-Host "Option 2 - SKU Access Request:"
Write-Host "  1. Go to: Azure Portal > Help + Support > Create a support request"
Write-Host "  2. Issue type: Service and subscription limits (quotas)"
Write-Host "  3. Quota type: Compute-VM (cores-vCPUs) subscription limit increases"
Write-Host "  4. Request access to the DCasv6 VM family in region belgiumcentral"
Write-Host ""
Write-Host "After approval, re-run this pipeline."
exit 1
