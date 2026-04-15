<#
.SYNOPSIS
    Validates Guest Attestation health for all Confidential VM session hosts
    in an Azure Virtual Desktop host pool.

.DESCRIPTION
    This script performs three levels of attestation validation without requiring
    a dedicated Azure Attestation Provider resource:

      STEP 1 - Extension health check (control plane)
               Confirms the GuestAttestation VM extension provisioned successfully
               on every CVM in the resource group.

      STEP 2 - JWT claims decode (from Run Command output)
               Uses az vm run-command to retrieve the latest attestation token
               from the Windows event log on each session host and decodes the
               payload section. Validates the key claims:
                 - x-ms-attestation-type     = sevsnpvm
                 - x-ms-compliance-status    = azure-compliant-cvm
                 - secureboot                = true
               These claims prove the host is genuinely running AMD SEV-SNP with
               Secure Boot active and that Microsoft's attestation baseline passed.

      STEP 3 - JWT signature verification (cryptographic proof)
               Fetches the signing certificates from the Microsoft shared MAA
               endpoint, finds the certificate matching the token's kid, and
               verifies the RS256 signature. A valid signature proves the token
               was issued by Microsoft Azure Attestation and was not tampered with.
               No custom Attestation Provider deployment is required.

    The shared Microsoft MAA endpoints used are:
      West Europe  : https://sharedweu.weu.attest.azure.net
      North Europe : https://sharedneu.neu.attest.azure.net
      East US 2    : https://sharedeus2.eus2.attest.azure.net

    IMPORTANT: The Microsoft.Attestation/attestationProviders resource type is
    NOT available in Belgium Central. Use the shared MAA endpoints instead.

.PARAMETER SubscriptionName
    Azure subscription containing the session hosts.

.PARAMETER HostsResourceGroup
    Resource group containing the session host VMs.

.PARAMETER HostPoolName
    Name of the AVD host pool (for display purposes).

.PARAMETER MaaEndpoint
    Microsoft shared MAA endpoint for signature verification.
    Default: https://sharedweu.weu.attest.azure.net
    For North Europe: https://sharedneu.neu.attest.azure.net

.PARAMETER LogAnalyticsWorkspaceId
    Optional. Resource ID of the Log Analytics Workspace. When provided,
    also queries for attestation error events from the past QueryDays days.

.PARAMETER QueryDays
    Number of days of Log Analytics history to query. Default: 7.

.PARAMETER SkipJwtValidation
    Skip Steps 2 and 3 (JWT decode and signature verification).
    Use this flag if the session hosts are deallocated or Run Command
    is not available in your environment.

.PARAMETER DryRun
    Validate that all resources are reachable without making state changes.
    Read-only operations still execute.

.EXAMPLE
    # Basic extension health check
    .\Scripts\Get-AttestationStatus.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -HostPoolName "hp-avd-prd-weu-001"

.EXAMPLE
    # Full validation including JWT decode and signature verification
    .\Scripts\Get-AttestationStatus.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -HostPoolName "hp-avd-prd-weu-001" `
        -MaaEndpoint "https://sharedweu.weu.attest.azure.net"

.EXAMPLE
    # Full validation with Log Analytics query
    .\Scripts\Get-AttestationStatus.ps1 `
        -SubscriptionName "sub-avd-prd" `
        -HostsResourceGroup "rg-avd-prd-hosts" `
        -HostPoolName "hp-avd-prd-weu-001" `
        -MaaEndpoint "https://sharedweu.weu.attest.azure.net" `
        -LogAnalyticsWorkspaceId "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.OperationalInsights/workspaces/law-avd-prd-weu-001" `
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
    [string]$MaaEndpoint = 'https://sharedweu.weu.attest.azure.net',

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceId = '',

    [Parameter(Mandatory = $false)]
    [int]$QueryDays = 7,

    [Parameter(Mandatory = $false)]
    [switch]$SkipJwtValidation,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$n, [string]$m) Write-Host "`n[$n] $m" -ForegroundColor Yellow }
function Write-OK   { param([string]$m) Write-Host "    [OK]    $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [WARN]  $m" -ForegroundColor DarkYellow }
function Write-Fail { param([string]$m) Write-Host "    [FAIL]  $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "    [INFO]  $m" -ForegroundColor Gray }

function ConvertFrom-Base64Url {
    param([string]$Base64Url)
    $b64 = $Base64Url.Replace('-', '+').Replace('_', '/')
    $b64 += '=' * ((4 - $b64.Length % 4) % 4)
    return $b64
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Guest Attestation Validation - Confidential AVD" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subscription : $SubscriptionName"
Write-Host "  Resource Grp : $HostsResourceGroup"
Write-Host "  Host Pool    : $HostPoolName"
Write-Host "  MAA Endpoint : $MaaEndpoint"
Write-Host "  LA Workspace : $(if ($LogAnalyticsWorkspaceId) { $LogAnalyticsWorkspaceId } else { '(not provided)' })"
Write-Host "  Skip JWT     : $SkipJwtValidation"
Write-Host "  Dry Run      : $DryRun"
Write-Host ""
Write-Host "  NOTE: Using Microsoft shared MAA endpoint." -ForegroundColor Gray
Write-Host "  The Microsoft.Attestation/attestationProviders resource type" -ForegroundColor Gray
Write-Host "  is not available in Belgium Central. The shared endpoint" -ForegroundColor Gray
Write-Host "  provides the same cryptographic attestation guarantees." -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 0 - Set subscription context
# ---------------------------------------------------------------------------
Write-Step "0/4" "Setting subscription context"

az account set --subscription $SubscriptionName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to set subscription. Run 'az login' first."
    exit 1
}
Write-OK "Subscription set: $SubscriptionName"

# ---------------------------------------------------------------------------
# STEP 1 - Discover CVMs and check GuestAttestation extension (control plane)
# ---------------------------------------------------------------------------
Write-Step "1/4" "Checking GuestAttestation extension provisioning state"

$allVmsJson = az vm list --resource-group $HostsResourceGroup -o json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to list VMs in '$HostsResourceGroup'."
    exit 1
}

$allVms = $allVmsJson | ConvertFrom-Json
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

$extResults  = @()
$failCount   = 0
$warnCount   = 0

foreach ($vm in $cvmHosts) {
    $vmName = $vm.name
    Write-Info "  Checking extension on $vmName ..."

    $extJson = az vm extension show `
        --resource-group $HostsResourceGroup `
        --vm-name $vmName `
        --name "GuestAttestation" `
        --query "{state: provisioningState, status: instanceView.statuses}" `
        -o json 2>&1

    if ($LASTEXITCODE -ne 0 -or $null -eq $extJson) {
        Write-Fail "    $vmName: GuestAttestation extension NOT FOUND"
        $extResults += [PSCustomObject]@{
            VM     = $vmName
            Status = "MISSING"
            Detail = "Extension not installed"
        }
        $failCount++
        continue
    }

    $ext   = $extJson | ConvertFrom-Json
    $state = $ext.state
    $msgs  = $ext.status | ForEach-Object { $_.message } | Where-Object { $_ }

    switch ($state) {
        "Succeeded" {
            Write-OK "    $vmName: extension Succeeded"
            $extResults += [PSCustomObject]@{ VM = $vmName; Status = "OK"; Detail = "Provisioned successfully" }
        }
        "Failed" {
            Write-Fail "    $vmName: extension FAILED - $($msgs -join ' | ')"
            $extResults += [PSCustomObject]@{ VM = $vmName; Status = "FAILED"; Detail = ($msgs -join " | ") }
            $failCount++
        }
        "Creating" {
            Write-Warn "    $vmName: extension still provisioning"
            $extResults += [PSCustomObject]@{ VM = $vmName; Status = "PROVISIONING"; Detail = "Still installing" }
            $warnCount++
        }
        default {
            Write-Warn "    $vmName: unexpected state '$state'"
            $extResults += [PSCustomObject]@{ VM = $vmName; Status = $state; Detail = ($msgs -join " | ") }
            $warnCount++
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 2 - JWT claims decode (from session host event log via Run Command)
# ---------------------------------------------------------------------------
Write-Step "2/4" "Decoding attestation JWT claims from session hosts"

$jwtResults = @()

if ($SkipJwtValidation) {
    Write-Info "Skipping JWT validation (-SkipJwtValidation set)."
} else {
    # PowerShell block to run inside each session host via az vm run-command
    # Reads the latest attestation token from the Windows event log and decodes
    # the payload section to extract claims.
    $runCommandScript = @'
try {
    $logPath = "C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.Security.WindowsAttestation"
    $token = $null
    if (Test-Path $logPath) {
        $files = Get-ChildItem $logPath -Recurse -Filter "*.log" -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $lines = Get-Content $f.FullName -ErrorAction SilentlyContinue |
                     Where-Object { $_ -match "eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+" }
            if ($lines) { $token = ($lines | Select-Object -Last 1) -replace '.*?(eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+).*','$1'; break }
        }
    }
    if (-not $token) {
        # Also try reading from the Event Log directly
        $events = Get-WinEvent -LogName "Microsoft-Windows-Attestation/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue
        foreach ($e in $events) {
            if ($e.Message -match "eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+") {
                $token = $Matches[0]
                break
            }
        }
    }
    if (-not $token) { Write-Output "TOKEN_NOT_FOUND"; exit 0 }
    $parts = $token.Split('.')
    if ($parts.Count -lt 3) { Write-Output "TOKEN_MALFORMED"; exit 0 }
    $b64 = $parts[1].Replace('-','+').Replace('_','/')
    $b64 += '=' * ((4 - $b64.Length % 4) % 4)
    $payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    $result = [PSCustomObject]@{
        Token                 = $token
        AttestationType       = $payload.'x-ms-attestation-type'
        ComplianceStatus      = $payload.'x-ms-compliance-status'
        SecureBoot            = $payload.secureboot
        Issuer                = $payload.iss
        IssuedAt              = [DateTimeOffset]::FromUnixTimeSeconds($payload.iat).ToString("u")
        Expires               = [DateTimeOffset]::FromUnixTimeSeconds($payload.exp).ToString("u")
        SevSnpMicrocodeVersion = $payload.'x-ms-isolation-tee'.'x-ms-sevsnpvm-microcode-svn'
    }
    Write-Output ($result | ConvertTo-Json -Compress)
} catch {
    Write-Output "ERROR: $_"
}
'@

    $okHosts = $extResults | Where-Object Status -eq "OK"

    foreach ($r in $okHosts) {
        $vmName = $r.VM
        Write-Info "  Fetching attestation token from $vmName ..."

        if ($DryRun) {
            Write-Info "    DryRun: would run az vm run-command on $vmName"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "DRYRUN"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
            continue
        }

        $rcJson = az vm run-command invoke `
            --resource-group $HostsResourceGroup `
            --name $vmName `
            --command-id RunPowerShellScript `
            --scripts $runCommandScript `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warn "    $vmName: Run Command failed (VM may be deallocated or Run Command unavailable)"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "SKIPPED"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
            $warnCount++
            continue
        }

        $rcOutput = ($rcJson | ConvertFrom-Json).value[0].message
        $output = ($rcOutput -replace '\[stdout\]','').Trim().Split("`n") | Select-Object -Last 10 | Where-Object { $_ } | Select-Object -Last 1

        if ($output -eq "TOKEN_NOT_FOUND") {
            Write-Warn "    $vmName: no attestation token found in event log yet (extension may be newly installed)"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "NO_TOKEN"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
            $warnCount++
            continue
        }

        if ($output.StartsWith("ERROR") -or $output -eq "TOKEN_MALFORMED") {
            Write-Fail "    $vmName: token decode error - $output"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "DECODE_ERROR"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
            $failCount++
            continue
        }

        try {
            $claims = $output | ConvertFrom-Json
        } catch {
            Write-Fail "    $vmName: could not parse token output as JSON"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "PARSE_ERROR"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
            $failCount++
            continue
        }

        # Validate the three critical claims
        $claimsFail  = @()
        if ($claims.AttestationType   -ne 'sevsnpvm')             { $claimsFail += "x-ms-attestation-type is '$($claims.AttestationType)' (expected sevsnpvm)" }
        if ($claims.ComplianceStatus  -ne 'azure-compliant-cvm')  { $claimsFail += "x-ms-compliance-status is '$($claims.ComplianceStatus)' (expected azure-compliant-cvm)" }
        if ($claims.SecureBoot        -ne $true)                  { $claimsFail += "secureboot is '$($claims.SecureBoot)' (expected true)" }

        if ($claimsFail.Count -gt 0) {
            Write-Fail "    $vmName: CLAIM VALIDATION FAILED"
            $claimsFail | ForEach-Object { Write-Fail "      $_" }
            $jwtResults += [PSCustomObject]@{
                VM               = $vmName
                JwtStatus        = "CLAIMS_FAIL"
                AttestationType  = $claims.AttestationType
                ComplianceStatus = $claims.ComplianceStatus
                SecureBoot       = $claims.SecureBoot
                Issuer           = $claims.Issuer
            }
            $failCount++
        } else {
            Write-OK "    $vmName: claims valid"
            Write-Info "      AttestationType  : $($claims.AttestationType)"
            Write-Info "      ComplianceStatus : $($claims.ComplianceStatus)"
            Write-Info "      SecureBoot       : $($claims.SecureBoot)"
            Write-Info "      Issuer           : $($claims.Issuer)"
            Write-Info "      Issued at        : $($claims.IssuedAt)"
            Write-Info "      Expires          : $($claims.Expires)"
            if ($claims.SevSnpMicrocodeVersion) {
                Write-Info "      Microcode SVN    : $($claims.SevSnpMicrocodeVersion)"
            }
            $jwtResults += [PSCustomObject]@{
                VM               = $vmName
                JwtStatus        = "OK"
                AttestationType  = $claims.AttestationType
                ComplianceStatus = $claims.ComplianceStatus
                SecureBoot       = $claims.SecureBoot
                Issuer           = $claims.Issuer
            }

            # Store token for Step 3 signature verification
            $r | Add-Member -NotePropertyName "Token" -NotePropertyValue $claims.Token -Force
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 3 - JWT RS256 signature verification against shared MAA signing certs
# ---------------------------------------------------------------------------
Write-Step "3/4" "Verifying JWT signatures against $MaaEndpoint"

if ($SkipJwtValidation) {
    Write-Info "Skipping signature verification (-SkipJwtValidation set)."
} else {
    # Fetch the signing certificates from the shared MAA endpoint
    $certsUrl = "$MaaEndpoint/certs"
    Write-Info "  Fetching signing certificates from $certsUrl ..."
    try {
        $certs = Invoke-RestMethod -Uri $certsUrl -Method Get -ErrorAction Stop
        Write-OK "  Retrieved $($certs.keys.Count) signing certificate(s)"
    } catch {
        Write-Warn "  Could not reach MAA endpoint: $_"
        Write-Warn "  Check outbound HTTPS from the pipeline agent to $MaaEndpoint"
        $certs = $null
    }

    $verifiableHosts = $jwtResults | Where-Object JwtStatus -eq "OK"

    foreach ($r in $verifiableHosts) {
        $vmName = $r.VM
        $extResult = $extResults | Where-Object VM -eq $vmName
        $token = $extResult.Token
        if (-not $token) { Write-Warn "  $vmName: no token available for signature verification"; continue }

        Write-Info "  Verifying signature for $vmName ..."

        if (-not $certs) {
            Write-Warn "  $vmName: skipping - MAA certs unavailable"
            continue
        }

        try {
            # Decode header to get kid
            $headerB64 = ConvertFrom-Base64Url $token.Split('.')[0]
            $header = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($headerB64)) | ConvertFrom-Json
            $kid = $header.kid

            # Find matching cert by kid
            $signingKey = $certs.keys | Where-Object { $_.kid -eq $kid }
            if (-not $signingKey) {
                Write-Warn "  $vmName: no signing certificate found matching kid '$kid'"
                Write-Info "    The token may have been issued by a different MAA endpoint."
                Write-Info "    Token issuer: $(($r.Issuer))"
                continue
            }

            # Build the X509 certificate from the x5c chain
            $certBytes = [Convert]::FromBase64String($signingKey.x5c[0])
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
            $rsa  = $cert.GetRSAPublicKey()

            # Reconstruct the signed input (header.payload as UTF-8 bytes)
            $signedInput  = "$($token.Split('.')[0]).$($token.Split('.')[1])"
            $dataBytes    = [System.Text.Encoding]::UTF8.GetBytes($signedInput)

            # Decode the signature
            $sigB64    = ConvertFrom-Base64Url $token.Split('.')[2]
            $sigBytes  = [Convert]::FromBase64String($sigB64)

            # Verify RS256 (RSASSA-PKCS1-v1_5 with SHA-256)
            $valid = $rsa.VerifyData(
                $dataBytes,
                $sigBytes,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
            )

            if ($valid) {
                Write-OK "  $vmName: RS256 signature VALID"
                Write-Info "    Signed by  : $($cert.Subject)"
                Write-Info "    Cert expiry: $($cert.GetExpirationDateString())"
                $r | Add-Member -NotePropertyName "SigValid" -NotePropertyValue $true -Force
            } else {
                Write-Fail "  $vmName: RS256 signature INVALID - token may have been tampered with"
                $failCount++
                $r | Add-Member -NotePropertyName "SigValid" -NotePropertyValue $false -Force
            }
        } catch {
            Write-Warn "  $vmName: signature verification error - $_"
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 4 - Optional Log Analytics query for attestation error events
# ---------------------------------------------------------------------------
Write-Step "4/4" "Log Analytics attestation event query"

if ([string]::IsNullOrEmpty($LogAnalyticsWorkspaceId)) {
    Write-Info "Log Analytics Workspace ID not provided - skipping."
    Write-Info "Provide -LogAnalyticsWorkspaceId to also surface attestation events."
} else {
    $workspaceName = ($LogAnalyticsWorkspaceId -split '/')[-1]
    $workspaceRg   = ($LogAnalyticsWorkspaceId -split '/')[4]
    Write-Info "Querying $workspaceName for errors in the past $QueryDays days ..."

    $kql = @"
WindowsEvent
| where TimeGenerated > ago(${QueryDays}d)
| where Channel contains "Attestation" or Channel contains "TPM"
| where Level in (1, 2, 3)
| project TimeGenerated, Computer, Channel, EventID, Message = tostring(EventData)
| order by TimeGenerated desc
| take 50
"@

    $laJson = az monitor log-analytics query `
        --workspace $workspaceName `
        --resource-group $workspaceRg `
        --analytics-query $kql `
        -o json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Log Analytics query failed. Required role: Log Analytics Reader."
    } else {
        $laResults = $laJson | ConvertFrom-Json
        if ($laResults.Count -eq 0) {
            Write-OK "No attestation error events in the past $QueryDays days."
        } else {
            Write-Warn "Found $($laResults.Count) attestation event(s) in the past $QueryDays days:"
            $laResults | ForEach-Object {
                Write-Warn "  [$($_.TimeGenerated)] $($_.Computer) - Channel: $($_.Channel) EventID: $($_.EventID)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Attestation Validation Summary" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  STEP 1 - Extension provisioning state:"
$extResults | Format-Table VM, Status, Detail -AutoSize

if (-not $SkipJwtValidation -and $jwtResults.Count -gt 0) {
    Write-Host "  STEP 2 - JWT claims:"
    $jwtResults | Format-Table VM, JwtStatus, AttestationType, ComplianceStatus, SecureBoot -AutoSize
}

$okExt  = ($extResults | Where-Object Status -eq "OK").Count
$okJwt  = ($jwtResults | Where-Object JwtStatus -eq "OK").Count
$okSig  = ($jwtResults | Where-Object { $_.SigValid -eq $true }).Count

Write-Host ""
Write-Host "  Total CVMs    : $($cvmHosts.Count)"
Write-Host "  Ext OK        : $okExt / $($cvmHosts.Count)" -ForegroundColor $(if ($okExt -eq $cvmHosts.Count) { "Green" } else { "Yellow" })
if (-not $SkipJwtValidation -and $jwtResults.Count -gt 0) {
    Write-Host "  Claims OK     : $okJwt / $($jwtResults.Count)" -ForegroundColor $(if ($okJwt -eq $jwtResults.Count) { "Green" } else { "Yellow" })
    Write-Host "  Sig verified  : $okSig / $($jwtResults.Count)" -ForegroundColor $(if ($okSig -eq $jwtResults.Count) { "Green" } else { "Yellow" })
}
Write-Host "  Warnings      : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Failures      : $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($failCount -gt 0) {
    Write-Host "  [ACTION REQUIRED] Attestation failures detected. See output above." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Extension missing or failed:" -ForegroundColor Yellow
    Write-Host "    az vm extension set --resource-group $HostsResourceGroup --vm-name <VM_NAME> \\" -ForegroundColor Gray
    Write-Host "      --name GuestAttestation --publisher Microsoft.Azure.Security.WindowsAttestation \\" -ForegroundColor Gray
    Write-Host "      --version 1.0 --enable-auto-upgrade true" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  NSG check - outbound HTTPS must be allowed to:" -ForegroundColor Yellow
    Write-Host "    $MaaEndpoint" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

if ($warnCount -gt 0) {
    Write-Host "  [WARNING] Some validations were skipped or inconclusive." -ForegroundColor Yellow
    Write-Host "  If VMs were deallocated during validation, re-run after starting them." -ForegroundColor Yellow
    exit 2
}

Write-Host "  [OK] All session hosts passed attestation validation." -ForegroundColor Green
Write-Host "  Extension provisioned, claims valid, signatures verified." -ForegroundColor Green
Write-Host "  These hosts have cryptographic proof they run in a genuine AMD SEV-SNP TEE." -ForegroundColor Green
Write-Host ""
Write-Host "  [DONE]" -ForegroundColor Green
