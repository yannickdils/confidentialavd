<#
.SYNOPSIS
    Creates a new Managed HSM key with a Secure Key Release (SKR) policy for
    Confidential VM disk encryption.

.DESCRIPTION
    Confidential VMs using DiskWithVMGuestState encryption require the Managed HSM
    key to be exportable and to have a key release policy attached. Without this
    policy, the Disk Encryption Set deployment fails with:

        "The target key has no key release policy"

    This script:
      1. Verifies the Azure CLI session
      2. Checks HSM purge protection is enabled (required for key release)
      3. Verifies the Confidential VM Orchestrator service principal exists
      4. Checks that the key does not already exist (exits if it does)
      5. Creates a new RSA-HSM key with --exportable and --default-cvm-policy
         (the Azure-managed default CVM release policy -- no custom attestation
         URL needed)
      6. Verifies the new key has a release policy and is exportable
      7. Assigns 'Managed HSM Crypto Service Release User' role to the CVM
         Orchestrator service principal on the new key (required for VM boot)

    The --default-cvm-policy flag is the Microsoft-recommended approach. It
    automatically generates the correct Secure Key Release policy with the
    proper attestation claims. However, in newer Azure regions (e.g.
    belgiumcentral) this flag may fail because the internal API version it
    uses does not recognise the region. In that case, the script falls back
    to an explicit --policy file containing the official Microsoft CVM
    Secure Key Release policy from:
    https://github.com/Azure/confidential-computing-cvm/blob/main/cvm_deployment/key/skr-policy.json

    See also:
    https://learn.microsoft.com/en-us/azure/confidential-computing/quick-create-confidential-vm-arm

    IMPORTANT:
      - This script must be run by an HSM administrator with the Managed HSM
        Crypto Officer role (or equivalent) on the target HSM.
      - After running this script, update the 'managedHsmKeyUrl' field in the
        hostpool JSON config file with the new key URL printed at the end.
      - The script will NOT replace or delete an existing key. If a key with
        the given name already exists, the script exits without changes.

.PARAMETER HsmName
    The name of the Managed HSM (e.g., kvhsmmgmthubabc001).

.PARAMETER KeyName
    The name of the new key to create (e.g., cmk-avd-prd-extcoreapps-weu-001).

.PARAMETER KeySize
    RSA key size in bits. Default is 3072. Allowed values: 2048, 3072, 4096.

.PARAMETER UamiName
    If set, the specified roles will be assigned to the UAMI on the new key.

.PARAMETER UamiRoles
    The roles which will be assigned to the specified UAMI (if specified) on the new key.

.PARAMETER DryRun
    If set, the script only validates and shows what it would do, without
    making any changes.

.EXAMPLE
    # Create a new CVM key in the Managed HSM:
    .\CreateHSM_CMK.ps1 `
        -HsmName "kvhsmmgmthubabc001" `
        -KeyName "cmk-avd-prd-extcoreapps-weu-001"

.EXAMPLE
    # Dry run first to see what would happen:
    .\CreateHSM_CMK.ps1 `
        -HsmName "kvhsmmgmthubabc001" `
        -KeyName "cmk-avd-prd-extcoreapps-weu-001" `
        -DryRun

.EXAMPLE
    # Create a new CVM key and assign roles on the key to the given UAMI:
    .\CreateHSM_CMK.ps1 `
        -HsmName "kvhsmmgmthubabc001" `
        -KeyName "cmk-avd-prd-extcoreapps-weu-001" `
        -UamiName "uami-cc-hp-avd-prd-extcoreapps-weu-001"

.EXAMPLE
    # Create a new CVM key with a 4096-bit key size:
    .\CreateHSM_CMK.ps1 `
        -HsmName "kvhsmmgmthubabc001" `
        -KeyName "cmk-avd-prd-extcoreapps-weu-001" `
        -KeySize 4096
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$HsmName,

    [Parameter(Mandatory = $true)]
    [string]$KeyName,

    [Parameter(Mandatory = $false)]
    [ValidateSet(2048, 3072, 4096)]
    [int]$KeySize = 3072,

    [Parameter(Mandatory = $false)]
    [string]$UamiName,

    [Parameter(Mandatory = $false)]
    [string[]]$UamiRoles = @("Managed HSM Crypto Service Encryption User", "Managed HSM Crypto User"),

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helper: check $LASTEXITCODE and exit on failure
# ---------------------------------------------------------------------------
function Assert-AzCliSuccess {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] $Message" -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Create Managed HSM Key for Confidential VM Encryption" -ForegroundColor Cyan
Write-Host " Confidential VM - DiskWithVMGuestState Encryption" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "HSM Name:         $HsmName"
Write-Host "Key Name:         $KeyName"
Write-Host "Key Size:         $KeySize"
Write-Host "Policy:           --default-cvm-policy (with fallback to explicit policy)"
Write-Host "Dry Run:          $DryRun"
Write-Host ""

# Verify az CLI is available and logged in
Write-Host "[1/7] Verifying Azure CLI session..." -ForegroundColor Yellow
$azVersion = az version 2>&1
Write-Host "      Azure CLI version info:" -ForegroundColor Gray
$azVersion | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
Write-Host ""
$accountJson = az account show 2>&1
$accountExitCode = $LASTEXITCODE
Write-Host "      Exit code: $accountExitCode" -ForegroundColor Gray
if ($accountExitCode -ne 0) {
    Write-Host "      Error output:" -ForegroundColor Red
    $accountJson | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
}
Assert-AzCliSuccess "Not logged in to Azure CLI. Run 'az login' first."
$account = $accountJson | ConvertFrom-Json
Write-Host "[OK] Logged in to Azure." -ForegroundColor Green
Write-Host "      Subscription: $($account.name) ($($account.id))" -ForegroundColor Gray
Write-Host "      Tenant:       $($account.tenantId)" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# Verify HSM purge protection is enabled (required for key release)
# ---------------------------------------------------------------------------
Write-Host "[2/7] Checking HSM purge protection..." -ForegroundColor Yellow

Write-Host "      Command: az keyvault show --hsm-name $HsmName" -ForegroundColor Gray
$hsmJson = az keyvault show --hsm-name $HsmName 2>&1
Write-Host "      Exit code: $LASTEXITCODE" -ForegroundColor Gray
if ($LASTEXITCODE -ne 0) {
    Write-Host "      Error output:" -ForegroundColor Red
    $hsmJson | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
}
Assert-AzCliSuccess "Failed to retrieve HSM '$HsmName'. Verify the name and your access permissions."

$hsm = $hsmJson | ConvertFrom-Json
$purgeProtection = $hsm.properties.enablePurgeProtection

if ($purgeProtection -eq $true) {
    Write-Host "[OK] Purge protection is enabled on HSM '$HsmName'." -ForegroundColor Green
} else {
    Write-Host "[WARNING] Purge protection is NOT enabled on HSM '$HsmName'." -ForegroundColor Red
    Write-Host "          Key release requires purge protection. Enable it with:" -ForegroundColor Red
    Write-Host "          az keyvault update-hsm --hsm-name $HsmName --enable-purge-protection true" -ForegroundColor Yellow
    Write-Host ""
    if (-not $DryRun) {
        Write-Host "[ERROR] Cannot proceed without purge protection. Exiting." -ForegroundColor Red
        exit 1
    }
}
Write-Host ""

# ---------------------------------------------------------------------------
# Verify the Confidential VM Orchestrator service principal exists
# Note: Role assignment is deferred to AFTER key creation (step 7), because
# the role must be scoped to /keys/<KeyName> which requires the key to exist.
# ---------------------------------------------------------------------------
Write-Host "[3/7] Checking Confidential VM Orchestrator service principal..." -ForegroundColor Yellow

# The CVM Orchestrator is a Microsoft first-party SP that performs secure key
# release during Confidential VM provisioning. It needs the
# 'Managed HSM Crypto Service Release User' role scoped to the key.
# App ID: bf7b6499-ff71-4aa2-97a4-f372087be7f0
$cvmOrchestratorAppId = "bf7b6499-ff71-4aa2-97a4-f372087be7f0"
$cvmRequiredRole = "Managed HSM Crypto Service Release User"
$cvmSpObjectId = $null

# Look up the service principal in the tenant
$cvmSpJson = az ad sp show --id $cvmOrchestratorAppId 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARNING] Confidential VM Orchestrator SP not found in this tenant." -ForegroundColor Red
    Write-Host "          This SP must exist for CVM disk encryption to work." -ForegroundColor Red
    Write-Host "          A Global Admin or User Access Administrator must create it:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "          Connect-Graph -Tenant '<tenantId>' Application.ReadWrite.All" -ForegroundColor Gray
    Write-Host "          New-MgServicePrincipal -AppId bf7b6499-ff71-4aa2-97a4-f372087be7f0 -DisplayName 'Confidential VM Orchestrator'" -ForegroundColor Gray
    Write-Host ""
    if (-not $DryRun) {
        Write-Host "[ERROR] Cannot proceed without the CVM Orchestrator SP. Exiting." -ForegroundColor Red
        exit 1
    }
} else {
    $cvmSp = $cvmSpJson | ConvertFrom-Json
    $cvmSpObjectId = $cvmSp.id
    Write-Host "[OK] CVM Orchestrator SP found (Object ID: $cvmSpObjectId)." -ForegroundColor Green
    Write-Host "     Role assignment will be verified after key creation (step 7)." -ForegroundColor Gray
}
Write-Host ""

# ---------------------------------------------------------------------------
# Check if the key already exists - this script only creates new keys
# ---------------------------------------------------------------------------
Write-Host "[4/7] Checking if key '$KeyName' already exists in HSM '$HsmName'..." -ForegroundColor Yellow

Write-Host "      Command: az keyvault key show --hsm-name $HsmName --name $KeyName" -ForegroundColor Gray
$existingKeyJson = az keyvault key show --hsm-name $HsmName --name $KeyName 2>&1
Write-Host "      Exit code: $LASTEXITCODE" -ForegroundColor Gray
if ($LASTEXITCODE -eq 0) {
    $existingKey = $existingKeyJson | ConvertFrom-Json
    Write-Host ""
    Write-Host "[ERROR] Key '$KeyName' already exists in HSM '$HsmName'." -ForegroundColor Red
    Write-Host "        This script only creates new keys and will not replace existing ones." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Key type:           $($existingKey.key.kty)" -ForegroundColor Gray
    Write-Host "  Key URL:            $($existingKey.key.kid)" -ForegroundColor Gray
    Write-Host "  Exportable:         $($existingKey.attributes.exportable)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Choose a different key name or manually delete the existing key first." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "      Output:" -ForegroundColor Gray
    $existingKeyJson | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
    Write-Host "[OK] Key '$KeyName' does not exist. Proceeding with creation." -ForegroundColor Green
}
Write-Host ""

# ---------------------------------------------------------------------------
# Dry run - stop here
# ---------------------------------------------------------------------------
if ($DryRun) {
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " DRY RUN - No changes will be made" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Would: CREATE new RSA-HSM key '$KeyName' ($KeySize-bit)"
    Write-Host "  --exportable true"
    Write-Host "  --default-cvm-policy (with fallback to explicit policy file if region unsupported)"
    Write-Host ""
    Write-Host "After creation, update 'managedHsmKeyUrl' in the hostpool"
    Write-Host "JSON config with the new key URL."
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Check if the key name is blocked by a soft-deleted key
# ---------------------------------------------------------------------------
$deletedKeyJson = az keyvault key list-deleted --hsm-name $HsmName --query "[?contains(kid, '/$KeyName/') || ends_with(kid, '/$KeyName')].kid" -o tsv 2>&1
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($deletedKeyJson)) {
    Write-Host ""
    Write-Host "[ERROR] Key name '$KeyName' is blocked by a soft-deleted key." -ForegroundColor Red
    Write-Host "        Purge the soft-deleted key first, or choose a different key name." -ForegroundColor Red
    Write-Host ""
    Write-Host "  To purge:  az keyvault key purge --hsm-name $HsmName --name $KeyName" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Host ""

# ---------------------------------------------------------------------------
# Create the new key with exportable flag and CVM release policy
# ---------------------------------------------------------------------------
Write-Host "[5/7] Creating new RSA-HSM key '$KeyName' with CVM release policy..." -ForegroundColor Yellow
Write-Host "      Key type: RSA-HSM, Size: $KeySize, Exportable: true"
Write-Host ""

# Try --default-cvm-policy first (fastest path). If it fails (e.g. the HSM is
# in a newer region like belgiumcentral that the older API version used by
# --default-cvm-policy does not recognise), fall back to an explicit --policy
# file containing the official Microsoft CVM Secure Key Release policy from:
# https://github.com/Azure/confidential-computing-cvm/blob/main/cvm_deployment/key/skr-policy.json

Write-Host "      Attempting --default-cvm-policy..."
Write-Host ""
Write-Host "      Command:" -ForegroundColor Gray
Write-Host "        az keyvault key create --hsm-name $HsmName --name $KeyName --kty RSA-HSM --size $KeySize --ops wrapKey unwrapKey --exportable true --default-cvm-policy" -ForegroundColor Gray
Write-Host ""

$newKeyJson = az keyvault key create `
    --hsm-name $HsmName `
    --name $KeyName `
    --kty RSA-HSM `
    --size $KeySize `
    --ops wrapKey unwrapKey `
    --exportable true `
    --default-cvm-policy `
    2>&1

Write-Host "      Exit code: $LASTEXITCODE" -ForegroundColor Gray
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[WARNING] --default-cvm-policy failed (region may not be supported by the" -ForegroundColor Yellow
    Write-Host "          older API version). Falling back to explicit policy file..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "      --default-cvm-policy error output:" -ForegroundColor Gray
    $newKeyJson | ForEach-Object { Write-Host "        $_" -ForegroundColor Gray }
    Write-Host ""

    # The release policy MUST be set at key creation time -- it cannot be added
    # afterward. A key created without a release policy can never become
    # SKR-capable, even if it is exportable.
    #
    # Belgian-only subset of the official Microsoft CVM Secure Key Release
    # policy. The full global policy (55 regions) exceeds Managed HSM's request
    # size limit.
    # Source: https://github.com/Azure/confidential-computing-cvm/blob/main/cvm_deployment/key/skr-policy.json
    $cvmPolicy = @'
{
  "anyOf": [
    {
      "allOf": [
        {
          "claim": "x-ms-compliance-status",
          "equals": "azure-compliant-cvm"
        },
        {
          "anyOf": [
            {
              "claim": "x-ms-attestation-type",
              "equals": "sevsnpvm"
            },
            {
              "claim": "x-ms-attestation-type",
              "equals": "tdxvm"
            }
          ]
        }
      ],
      "authority": "https://sharedbec.bec.attest.azure.net"
    }
  ],
  "version": "1.0.0"
}
'@

    $policyFile = Join-Path $env:TEMP "cvm-release-policy-$([guid]::NewGuid().ToString('N')).json"
    $cvmPolicy | Out-File -FilePath $policyFile -Encoding utf8 -Force
    Write-Host "      Using explicit CVM release policy file: $policyFile"
    Write-Host ""

    Write-Host "`$newKeyJson = az keyvault key create --hsm-name $HsmName --name $KeyName --kty RSA-HSM --size $KeySize --ops wrapKey unwrapKey --exportable true --policy `"$policyFile`" 2>&1"

    $newKeyJson = az keyvault key create `
        --hsm-name $HsmName `
        --name $KeyName `
        --kty RSA-HSM `
        --size $KeySize `
        --ops wrapKey unwrapKey `
        --exportable true `
        --policy "$policyFile" `
        2>&1

    # Clean up temp policy file
    Remove-Item -Path $policyFile -Force -ErrorAction SilentlyContinue
}

Assert-AzCliSuccess "Failed to create key '$KeyName'. Ensure you have Managed HSM Crypto Officer role."

$newKey = $newKeyJson | ConvertFrom-Json
$newKeyUrl = $newKey.key.kid

Write-Host "[OK] Key created successfully." -ForegroundColor Green
Write-Host "      Key URL: $newKeyUrl" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# Verify the new key has a release policy attached
# ---------------------------------------------------------------------------
Write-Host "[6/7] Verifying release policy on new key..." -ForegroundColor Yellow

$verifyKeyJson = az keyvault key show --hsm-name $HsmName --name $KeyName 2>&1
if ($LASTEXITCODE -eq 0) {
    $verifyKey = $verifyKeyJson | ConvertFrom-Json
    $verifyExportable = $verifyKey.attributes.exportable
    $verifyHasPolicy = ($verifyKey.releasePolicy -and $verifyKey.releasePolicy.encodedPolicy)

    Write-Host "  Exportable:         $verifyExportable"
    Write-Host "  Has release policy: $verifyHasPolicy"

    if (-not $verifyHasPolicy) {
        Write-Host ""
        Write-Host "[ERROR] Key was created but does NOT have a release policy." -ForegroundColor Red
        Write-Host "        Confidential VMs will fail to boot without a release policy." -ForegroundColor Red
        Write-Host "        The release policy must be set at key creation time and cannot" -ForegroundColor Red
        Write-Host "        be added afterward. Delete this key and recreate with the policy." -ForegroundColor Red
        exit 1
    }

    if (-not $verifyExportable) {
        Write-Host ""
        Write-Host "[ERROR] Key was created but is NOT exportable." -ForegroundColor Red
        Write-Host "        Confidential VMs require exportable keys for secure key release." -ForegroundColor Red
        exit 1
    }

    Write-Host "[OK] Release policy verified on new key." -ForegroundColor Green
} else {
    Write-Host "[WARNING] Could not verify new key. Manually confirm release policy exists:" -ForegroundColor Yellow
    Write-Host "          az keyvault key show --hsm-name $HsmName --name $KeyName --query `"{exportable:attributes.exportable, hasReleasePolicy:release_policy.data!=null}`"" -ForegroundColor Gray
}
Write-Host ""

# ---------------------------------------------------------------------------
# Assign CVM Orchestrator role on the (new) key
# Role assignments scoped to /keys/<KeyName> must run AFTER key creation.
# ---------------------------------------------------------------------------
Write-Host "[7/7] Assigning roles on new key..." -ForegroundColor Yellow

if ($null -eq $cvmSpObjectId) {
    Write-Host "[WARNING] CVM Orchestrator SP was not found in step 3. Skipping role assignment." -ForegroundColor Yellow
    Write-Host "          Manually assign '$cvmRequiredRole' after creating the SP." -ForegroundColor Yellow
} else {
    # Check if the role is already assigned at root scope (inherits to all keys)
    $hasRootReleaseRole = $false
    $rootRoleJson = az keyvault role assignment list --hsm-name $HsmName --assignee $cvmSpObjectId --scope "/" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $rootRoles = $rootRoleJson | ConvertFrom-Json
        $hasRootReleaseRole = [bool]($rootRoles | Where-Object { $_.roleName -eq $cvmRequiredRole })
    }

    if ($hasRootReleaseRole) {
        Write-Host "[OK] CVM Orchestrator has '$cvmRequiredRole' at root scope (inherited to all keys)." -ForegroundColor Green
    } else {
        # Check at key scope
        $hasKeyReleaseRole = $false
        $keyRoleJson = az keyvault role assignment list --hsm-name $HsmName --assignee $cvmSpObjectId --scope "/keys/$KeyName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $keyRoles = $keyRoleJson | ConvertFrom-Json
            $hasKeyReleaseRole = [bool]($keyRoles | Where-Object { $_.roleName -eq $cvmRequiredRole })
        }

        if ($hasKeyReleaseRole) {
            Write-Host "[OK] CVM Orchestrator already has '$cvmRequiredRole' on /keys/$KeyName." -ForegroundColor Green
        } else {
            Write-Host "[ACTION] Assigning '$cvmRequiredRole' to CVM Orchestrator on /keys/$KeyName..." -ForegroundColor Yellow
            az keyvault role assignment create --hsm-name $HsmName --assignee $cvmSpObjectId --role $cvmRequiredRole --scope "/keys/$KeyName" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] Failed to assign role. Assign it manually:" -ForegroundColor Red
                Write-Host "        az keyvault role assignment create --hsm-name $HsmName --assignee $cvmSpObjectId --role `"$cvmRequiredRole`" --scope /keys/$KeyName" -ForegroundColor Gray
                Write-Host ""
                Write-Host "[WARNING] Without this role, Confidential VMs will fail to boot." -ForegroundColor Red
            } else {
                Write-Host "[OK] Role assigned successfully." -ForegroundColor Green
            }
        }
    }
}
Write-Host ""

# ---------------------------------------------------------------------------
# Assign role on the (new) key to the UAMI
# Role assignments scoped to /keys/<KeyName> must run AFTER key creation.
# ---------------------------------------------------------------------------
Write-Host "[7/7] Assigning role on new key to UAMI..." -ForegroundColor Yellow

if ([string]::IsNullOrEmpty($UamiName)) {
    Write-Host "[WARNING] No UAMI specified. Skipping role assignment." -ForegroundColor Yellow
    Write-Host "          Manually assign roles `"$($UamiRoles -join '", "')`" to the UAMI after creating the SP." -ForegroundColor Yellow
} else {
    $UamiId = az ad sp list --display-name $UamiName --query "[0].id" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[OK] UAMI `"$UamiName`" not found. Assign roles `"$($UamiRoles -join '", "')`" on /keys/$KeyName to UAMI manually." -ForegroundColor Red
    } else {
        foreach ($Role in $UamiRoles) {
            # Check if the role is already assigned at root scope (inherits to all keys)
            $hasRootReleaseRole = $false
            $rootRoleJson = az keyvault role assignment list --hsm-name $HsmName --assignee $UamiId --scope "/" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $rootRoles = $rootRoleJson | ConvertFrom-Json
                $hasRootReleaseRole = [bool]($rootRoles | Where-Object { $_.roleName -eq $Role })
            }

            if ($hasRootReleaseRole) {
                Write-Host "[OK] UAMI `"$UamiName`" has '$Role' at root scope (inherited to all keys)." -ForegroundColor Green
            } else {
                # Check at key scope
                $hasKeyReleaseRole = $false
                $keyRoleJson = az keyvault role assignment list --hsm-name $HsmName --assignee $UamiId --scope "/keys/$KeyName" 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $keyRoles = $keyRoleJson | ConvertFrom-Json
                    $hasKeyReleaseRole = [bool]($keyRoles | Where-Object { $_.roleName -eq $Role })
                }

                if ($hasKeyReleaseRole) {
                    Write-Host "[OK] UAMI `"$UamiName`" already has '$Role' on /keys/$KeyName." -ForegroundColor Green
                } else {
                    Write-Host "[ACTION] Assigning '$Role' to UAMI `"$UamiName`" on /keys/$KeyName..." -ForegroundColor Yellow
                    az keyvault role assignment create --hsm-name $HsmName --assignee $UamiId --role $Role --scope "/keys/$KeyName" | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "[ERROR] Failed to assign role. Assign it manually:" -ForegroundColor Red
                        Write-Host "        az keyvault role assignment create --hsm-name $HsmName --assignee $UamiId --role `"$Role`" --scope /keys/$KeyName" -ForegroundColor Gray
                        Write-Host ""
                        Write-Host "[WARNING] Without this role, Confidential VMs will fail to boot." -ForegroundColor Red
                    } else {
                        Write-Host "[OK] Role assigned successfully." -ForegroundColor Green
                    }
                }
            }
        }
    }
}
Write-Host ""

# ---------------------------------------------------------------------------
# Output results
# ---------------------------------------------------------------------------
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Key created with default CVM Secure Key Release policy" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "New key URL:" -ForegroundColor Cyan
Write-Host "  $newKeyUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Update the hostpool JSON config file with the new key URL." -ForegroundColor White
Write-Host "     File: Environments/Hostpools/prd_extcoreapps.json (or the relevant file)" -ForegroundColor Gray
Write-Host "     Field: ""managedHsmKeyUrl""" -ForegroundColor Gray
Write-Host "     Value: ""$newKeyUrl""" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Run the AVD-DeployAdditionalHosts pipeline with" -ForegroundColor White
Write-Host "     confidentialCompute = true." -ForegroundColor White
Write-Host "     Alternatively, pass the new key URL via the 'keyUrl' pipeline" -ForegroundColor Gray
Write-Host "     parameter to override without updating the JSON file." -ForegroundColor Gray
Write-Host ""

Write-Host "[DONE] Script completed successfully." -ForegroundColor Green
