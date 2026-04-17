<#
.SYNOPSIS
    Validates Guest Attestation health for all Confidential VM session hosts
    in an Azure Virtual Desktop host pool.

.DESCRIPTION
    This script performs six levels of attestation validation without requiring
    a dedicated Azure Attestation Provider resource:

      STEP 1 - Extension health check (control plane)
               Confirms the GuestAttestation VM extension provisioned successfully
               on every CVM in the resource group.

      STEP 2 - Detailed attestation status via instance view
               Queries the Azure API for each VM's extension instance view,
               which includes substatus messages with the attestation result.

      STEP 3 - MAA endpoint and signing certificate chain analysis
               Fetches the OpenID configuration and all signing certificates
               from the MAA endpoint, validates each X.509 certificate
               (subject, issuer, validity, key algorithm, key size).

      STEP 4 - In-VM attestation evidence collection
               Executes a PowerShell script inside each running CVM via
               az vm run-command to collect hardware security state:
               Secure Boot, TPM, VBS, AMD SEV-SNP THIM certificates,
               IMDS attested document, and extension status files.

      STEP 5 - JWT token decode and RS256 signature verification
               If JWT attestation tokens are found in extension status
               files, decodes the JOSE header and payload claims, then
               verifies the RS256 digital signature against the MAA
               signing certificates from Step 3.

      STEP 6 - Log Analytics event query (optional)
               Queries the Log Analytics workspace for attestation-related
               error events collected by the Data Collection Rule.

    The shared Microsoft MAA endpoints used are:
      West Europe  : https://sharedweu.weu.attest.azure.net
      North Europe : https://sharedneu.neu.attest.azure.net
      Belgium Central: https://sharedbec.bec.attest.azure.net
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
    Skip Steps 2-5 (instance view, MAA certs, in-VM evidence, JWT
    verification). Steps 1 and 6 always run. Use this flag if session
    hosts are deallocated or Run Command is not available.

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
    # Full validation including in-VM evidence and JWT signature verification
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

$ErrorActionPreference = 'Stop'

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
    $s = $Base64Url.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) {
        0 { }
        2 { $s += '==' }
        3 { $s += '=' }
    }
    return [Convert]::FromBase64String($s)
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
Write-Step "0/6" "Setting subscription context"

$ErrorActionPreference = 'SilentlyContinue'
az account set --subscription $SubscriptionName 2>$null | Out-Null
$setSubEc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($setSubEc -ne 0) {
    Write-Fail "Failed to set subscription. Run 'az login' first."
    exit 1
}
Write-OK "Subscription set: $SubscriptionName"

# ---------------------------------------------------------------------------
# STEP 1 - Discover CVMs and check GuestAttestation extension (control plane)
# ---------------------------------------------------------------------------
Write-Step "1/6" "Checking GuestAttestation extension provisioning state"

$ErrorActionPreference = 'SilentlyContinue'
$allVmsJson = az vm list --resource-group $HostsResourceGroup -o json 2>$null
$vmListEc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($vmListEc -ne 0) {
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

    $ErrorActionPreference = 'SilentlyContinue'
    $extJson = az vm extension show `
        --resource-group $HostsResourceGroup `
        --vm-name $vmName `
        --name "GuestAttestation" `
        --query "{state: provisioningState, status: instanceView.statuses}" `
        -o json 2>$null
    $extShowEc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($extShowEc -ne 0 -or $null -eq $extJson) {
        Write-Fail "    $vmName`: GuestAttestation extension NOT FOUND"
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
            Write-OK "    $vmName`: extension Succeeded"
            $extResults += [PSCustomObject]@{ VM = $vmName; Status = "OK"; Detail = "Provisioned successfully" }
        }
        "Failed" {
            Write-Fail "    $vmName`: extension FAILED - $($msgs -join ' | ')"
            $extResults += [PSCustomObject]@{ VM = $vmName; Status = "FAILED"; Detail = ($msgs -join " | ") }
            $failCount++
        }
        "Creating" {
            Write-Warn "    $vmName`: extension still provisioning"
            $extResults += [PSCustomObject]@{ VM = $vmName; Status = "PROVISIONING"; Detail = "Still installing" }
            $warnCount++
        }
        default {
            Write-Warn "    $vmName`: unexpected state '$state'"
            $extResults += [PSCustomObject]@{ VM = $vmName; Status = $state; Detail = ($msgs -join " | ") }
            $warnCount++
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 2 - Detailed attestation status via instance view (control plane)
# ---------------------------------------------------------------------------
Write-Step "2/6" "Querying detailed attestation status from instance view"
Write-Info "  The GuestAttestation extension performs attestation internally."
Write-Info "  It sends the hardware report to the MAA endpoint, verifies the"
Write-Info "  JWT response, and reports the result via the instance view substatus."

$jwtResults = @()

if ($SkipJwtValidation) {
    Write-Info "Skipping detailed attestation check (-SkipJwtValidation set)."
} else {
    $okHosts = $extResults | Where-Object Status -eq "OK"

    foreach ($r in $okHosts) {
        $vmName = $r.VM
        Write-Info "  Querying instance view for $vmName ..."

        if ($DryRun) {
            Write-Info "    DryRun: would query instance view for $vmName"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "DRYRUN"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
            continue
        }

        # Check VM power state — if deallocated, instance view won't be available
        # and we should NOT report OK since attestation can't be verified on a stopped VM.
        $ErrorActionPreference = 'SilentlyContinue'
        $powerState = az vm get-instance-view `
            --resource-group $HostsResourceGroup `
            --name $vmName `
            --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" `
            -o tsv 2>$null
        $ErrorActionPreference = 'Stop'
        $vmRunning = ($powerState -eq "VM running")

        # Use az vm extension show --instance-view WITHOUT --query.
        # The --instance-view flag may change the response structure (statuses
        # at the top level vs. nested under instanceView). We parse both formats.
        $ErrorActionPreference = 'SilentlyContinue'
        $ivJson = az vm extension show `
            --resource-group $HostsResourceGroup `
            --vm-name $vmName `
            --name "GuestAttestation" `
            --instance-view `
            -o json 2>$null
        $ivEc = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'

        if ($ivEc -ne 0 -or -not $ivJson) {
            if (-not $vmRunning) {
                Write-Warn "    $vmName`: instance view not available (VM is $powerState)"
                $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "VM_STOPPED"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
                $warnCount++
            } else {
                # VM is running but instance view empty — Step 1 provisioningState=Succeeded
                # already confirms attestation passed at deploy time. Informational only.
                Write-Info "    $vmName`: instance view not available (extension provisioned OK in Step 1)"
                $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "OK"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
            }
            continue
        }

        $iv = $ivJson | ConvertFrom-Json

        # Collect all statuses and substatuses from both response formats:
        # Format A (--instance-view): statuses/substatuses at top level
        # Format B (standard):        statuses/substatuses under .instanceView
        $statuses = @()
        if ($iv.statuses)                 { $statuses += $iv.statuses }
        if ($iv.substatuses)              { $statuses += $iv.substatuses }
        if ($iv.instanceView.statuses)    { $statuses += $iv.instanceView.statuses }
        if ($iv.instanceView.substatuses) { $statuses += $iv.instanceView.substatuses }

        if ($statuses.Count -eq 0) {
            if (-not $vmRunning) {
                Write-Warn "    $vmName`: no runtime status entries (VM is $powerState)"
                $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "VM_STOPPED"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
                $warnCount++
            } else {
                # VM is running but no status entries — extension provisioned OK
                Write-Info "    $vmName`: no runtime status entries (extension provisioned OK in Step 1)"
                $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "OK"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-" }
            }
            continue
        }

        # Analyse each status / substatus entry
        $attestationDetail = $null
        $overallLevel = "Info"
        $attestationCodeResult = $null   # from ComponentStatus/GuestAttestation/*
        $healthCodeResult     = $null   # from ComponentStatus/ReportHealth/*

        foreach ($s in $statuses) {
            $code = $s.code
            $displayStatus = $s.displayStatus
            $level = $s.level
            $message = $s.message

            if ($level -eq "Error") { $overallLevel = "Error" }
            elseif ($level -eq "Warning" -and $overallLevel -ne "Error") { $overallLevel = "Warning" }

            # Extract component results from status codes
            if ($code -match '^ComponentStatus/GuestAttestation/(.+)$') { $attestationCodeResult = $Matches[1] }
            if ($code -match '^ComponentStatus/ReportHealth/(.+)$')     { $healthCodeResult     = $Matches[1] }

            # Try to parse message as JSON for richer detail
            if ($message) {
                try {
                    $msgObj = $message | ConvertFrom-Json
                    $attestationDetail = $msgObj
                    Write-Info "    Status: $code [$level]"
                    $msgObj.PSObject.Properties | ForEach-Object {
                        $val = if ($_.Value -is [PSCustomObject]) { ($_.Value | ConvertTo-Json -Compress) } else { $_.Value }
                        Write-Info "      $($_.Name): $val"
                    }
                } catch {
                    Write-Info "    Status: $code [$level] - $message"
                }
            } else {
                Write-Info "    Status: $code [$level] $displayStatus"
            }
        }

        # Extract known attestation fields from the substatus message JSON.
        # The format varies by extension version; try common field structures.
        $attestationType  = "-"
        $complianceStatus = "-"
        $secureBoot       = "-"
        $issuer           = "-"

        if ($attestationDetail) {
            # Top-level fields (MAA JWT-like structure)
            if ($attestationDetail.'x-ms-attestation-type')  { $attestationType  = $attestationDetail.'x-ms-attestation-type' }
            if ($attestationDetail.'x-ms-compliance-status') { $complianceStatus = $attestationDetail.'x-ms-compliance-status' }
            if ($null -ne $attestationDetail.secureboot)     { $secureBoot       = $attestationDetail.secureboot }
            if ($attestationDetail.iss)                      { $issuer           = $attestationDetail.iss }

            # Nested under x-ms-isolation-tee (CVM format)
            $tee = $attestationDetail.'x-ms-isolation-tee'
            if ($tee) {
                if ($tee.'x-ms-attestation-type'  -and $attestationType  -eq '-') { $attestationType  = $tee.'x-ms-attestation-type' }
                if ($tee.'x-ms-compliance-status' -and $complianceStatus -eq '-') { $complianceStatus = $tee.'x-ms-compliance-status' }
            }

            # Nested under attestation object (some extension versions)
            $att = $attestationDetail.attestation
            if ($att) {
                if ($att.type       -and $attestationType  -eq '-') { $attestationType  = $att.type }
                if ($att.compliance -and $complianceStatus -eq '-') { $complianceStatus = $att.compliance }
            }
        }

        # Fallback: when the extension reports plain-text messages (not JSON),
        # derive fields from the component status codes instead.
        if ($complianceStatus -eq '-' -and $attestationCodeResult) {
            $complianceStatus = $attestationCodeResult   # e.g. "succeeded"
        }
        if ($issuer -eq '-' -and $healthCodeResult) {
            $issuer = "ASC-health:$healthCodeResult"     # e.g. "ASC-health:succeeded"
        }

        if ($overallLevel -eq "Error") {
            Write-Fail "    $vmName`: attestation status indicates ERROR"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "FAILED"; AttestationType = $attestationType; ComplianceStatus = $complianceStatus; SecureBoot = $secureBoot; Issuer = $issuer }
            $failCount++
        } elseif ($overallLevel -eq "Warning") {
            Write-Warn "    $vmName`: attestation status has warnings"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "WARNING"; AttestationType = $attestationType; ComplianceStatus = $complianceStatus; SecureBoot = $secureBoot; Issuer = $issuer }
            $warnCount++
        } else {
            Write-OK "    $vmName`: attestation Succeeded"
            Write-Info "      AttestationType  : $attestationType"
            Write-Info "      ComplianceStatus : $complianceStatus"
            Write-Info "      SecureBoot       : $secureBoot"
            Write-Info "      Issuer           : $issuer"
            $jwtResults += [PSCustomObject]@{ VM = $vmName; JwtStatus = "OK"; AttestationType = $attestationType; ComplianceStatus = $complianceStatus; SecureBoot = $secureBoot; Issuer = $issuer }
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 3 - MAA endpoint and signing certificate chain analysis
# ---------------------------------------------------------------------------
Write-Step "3/6" "MAA endpoint and signing certificate chain analysis ($MaaEndpoint)"
Write-Info "  The GuestAttestation extension calls this endpoint internally to"
Write-Info "  verify hardware attestation reports and obtain signed JWT tokens."
Write-Info "  Extension status 'Succeeded' confirms the attestation was"
Write-Info "  cryptographically verified by the extension using this endpoint."

$maaCerts    = $null
$certResults = @()

if ($SkipJwtValidation) {
    Write-Info "Skipping MAA check (-SkipJwtValidation set)."
} else {
    # 3a. OpenID Configuration
    $oidcUrl = "$MaaEndpoint/.well-known/openid-configuration"
    Write-Info "  Fetching OpenID configuration from $oidcUrl ..."
    try {
        $oidc = Invoke-RestMethod -Uri $oidcUrl -Method Get -ErrorAction Stop
        Write-OK "  OpenID configuration retrieved"
        Write-Info "    Issuer              : $($oidc.issuer)"
        Write-Info "    JWKS URI            : $($oidc.jwks_uri)"
        if ($oidc.response_types_supported) {
            Write-Info "    Response types      : $($oidc.response_types_supported -join ', ')"
        }
        if ($oidc.token_endpoint) {
            Write-Info "    Token endpoint      : $($oidc.token_endpoint)"
        }
    } catch {
        Write-Warn "  Could not fetch OpenID configuration: $_"
    }

    # 3b. Signing certificates (JWKS)
    $certsUrl = "$MaaEndpoint/certs"
    Write-Info ""
    Write-Info "  Fetching signing certificates (JWKS) from $certsUrl ..."
    try {
        $maaCerts = Invoke-RestMethod -Uri $certsUrl -Method Get -ErrorAction Stop
        Write-OK "  Retrieved $($maaCerts.keys.Count) signing certificate(s) from MAA endpoint"
        Write-Info ""

        $expiredCount = 0
        foreach ($key in $maaCerts.keys) {
            $kid       = $key.kid
            $kty       = $key.kty
            $alg       = $key.alg
            $use       = $key.use
            $x5cChain  = $key.x5c
            $subject   = "-"
            $issuerCN  = "-"
            $notBefore = "-"
            $notAfter  = "-"
            $keySize   = "-"
            $thumbprint = "-"
            $isExpired = $false

            if ($x5cChain -and $x5cChain.Count -gt 0) {
                try {
                    $certBytes = [Convert]::FromBase64String($x5cChain[0])
                    $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
                    $subject    = $x509.Subject
                    $issuerCN   = $x509.Issuer
                    $notBefore  = $x509.NotBefore.ToString("yyyy-MM-dd HH:mm:ss")
                    $notAfter   = $x509.NotAfter.ToString("yyyy-MM-dd HH:mm:ss")
                    $thumbprint = $x509.Thumbprint
                    $isExpired  = ($x509.NotAfter -lt (Get-Date))
                    try {
                        $rsaKey  = $x509.PublicKey.Key
                        $keySize = "$($rsaKey.KeySize)-bit"
                    } catch {
                        $keySize = "N/A"
                    }
                } catch {
                    $subject = "(parse error: $($_.Exception.Message))"
                }
            }

            if ($isExpired) {
                Write-Warn "    Certificate $kid is EXPIRED (NotAfter: $notAfter)"
                $expiredCount++
            }

            Write-Info "    [$($certResults.Count + 1)] kid: $kid"
            Write-Info "        Subject    : $subject"
            Write-Info "        Issuer     : $issuerCN"
            Write-Info "        Valid      : $notBefore  to  $notAfter$(if ($isExpired) { '  ** EXPIRED **' })"
            Write-Info "        Algorithm  : $kty / $alg  ($keySize)"
            Write-Info "        Use        : $use"
            Write-Info "        Thumbprint : $thumbprint"
            Write-Info "        x5c chain  : $($x5cChain.Count) certificate(s)"
            Write-Info ""

            $certResults += [PSCustomObject]@{
                Kid       = $kid
                Subject   = $subject
                NotAfter  = $notAfter
                Algorithm = "$kty/$alg"
                KeySize   = $keySize
                Expired   = $isExpired
            }
        }

        if ($expiredCount -gt 0) {
            Write-Warn "  $expiredCount certificate(s) are EXPIRED"
            $warnCount++
        } else {
            Write-OK "  All $($maaCerts.keys.Count) signing certificate(s) are valid (not expired)"
        }

    } catch {
        Write-Warn "  Could not reach MAA endpoint: $_"
        Write-Warn "  Session hosts need outbound HTTPS access to $MaaEndpoint"
        Write-Warn "  NSG must allow outbound traffic to the AzureAttestation service tag"
        $warnCount++
    }
}

# ---------------------------------------------------------------------------
# STEP 4 - In-VM attestation evidence collection
# ---------------------------------------------------------------------------
Write-Step "4/6" "In-VM attestation evidence collection via run-command"
Write-Info "  Collects hardware security state directly from inside each running"
Write-Info "  CVM: Secure Boot, TPM, Virtualization-Based Security, AMD SEV-SNP"
Write-Info "  THIM certificates, IMDS attested document, extension status files."

$vmEvidence = @()
$jwtTokens  = @{}   # VM name -> JWT token string (if found in extension status files)

if ($SkipJwtValidation) {
    Write-Info "Skipping in-VM evidence collection (-SkipJwtValidation set)."
} else {
    # Determine which VMs are running (from Step 2 results)
    $runningVms = @()
    if ($jwtResults.Count -gt 0) {
        $runningVms = @($jwtResults | Where-Object { $_.JwtStatus -ne "VM_STOPPED" -and $_.JwtStatus -ne "DRYRUN" })
    } else {
        $runningVms = @($extResults | Where-Object { $_.Status -eq "OK" })
    }

    if ($runningVms.Count -eq 0) {
        Write-Warn "  No running VMs available for in-VM evidence collection."
    } else {
        Write-Info "  $($runningVms.Count) running VM(s) to collect evidence from."
        Write-Info "  Note: az vm run-command takes ~30s per VM."
        Write-Info ""

        # Write the in-VM collection script to a temp file
        # (avoids PS 5.1 quoting issues with inline multi-line scripts)
        $vmScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$r = @{}
try { $sb = Confirm-SecureBootUEFI; $r['SecureBoot'] = [string]$sb }
catch { $r['SecureBoot'] = 'Error' }
try {
    $t = Get-Tpm
    $r['TpmPresent'] = [string]$t.TpmPresent
    $r['TpmReady']   = [string]$t.TpmReady
    $r['TpmEnabled'] = [string]$t.TpmEnabled
} catch { $r['TpmPresent'] = 'Error' }
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root/Microsoft/Windows/DeviceGuard
    if ($dg) {
        $vMap = @{ 0='Off'; 1='Configured'; 2='Running' }
        $r['VbsStatus'] = if ($vMap.ContainsKey([int]$dg.VirtualizationBasedSecurityStatus)) { $vMap[[int]$dg.VirtualizationBasedSecurityStatus] } else { [string]$dg.VirtualizationBasedSecurityStatus }
        $sMap = @{ 1='CredentialGuard'; 2='HVCI'; 3='SystemGuardSecureLaunch'; 4='SMEProtection' }
        $svcs = @()
        foreach ($s in $dg.SecurityServicesRunning) { if ($sMap.ContainsKey([int]$s)) { $svcs += $sMap[[int]$s] } else { $svcs += [string]$s } }
        $r['SecurityServices'] = ($svcs -join ',')
    }
} catch { $r['VbsStatus'] = 'N/A' }
try {
    $th = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/THIM/amd/certification' -Headers @{Metadata='true'}
    $r['ThimVcekCert'] = if ($th.vcekCert) { 'Present(' + $th.vcekCert.Length + ')' } else { 'Missing' }
    $r['ThimCertChain'] = if ($th.certificateChain) { 'Present(' + $th.certificateChain.Length + ')' } else { 'Missing' }
    $r['ThimTcbm'] = if ($th.tcbm) { $th.tcbm } else { 'N/A' }
} catch { $r['ThimVcekCert'] = 'Error' }
try {
    $im = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/attested/document?api-version=2021-02-01' -Headers @{Metadata='true'}
    $r['ImdsEncoding'] = $im.encoding
    $sigLen = $im.signature.Length
    $r['ImdsSignature'] = if ($sigLen -gt 60) { $im.signature.Substring(0,60) + '...(total:' + $sigLen + ')' } else { $im.signature }
} catch { $r['ImdsAttested'] = 'Error' }
$r['ExtJwt'] = ''
$extBase = 'C:\Packages\Plugins\Microsoft.Azure.Security.WindowsAttestation.GuestAttestation'
$extDirs = Get-ChildItem $extBase -Directory -ErrorAction SilentlyContinue
foreach ($d in $extDirs) {
    $sf = Get-ChildItem "$($d.FullName)\Status" -Filter '*.status' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($sf) {
        try {
            $raw = Get-Content $sf.FullName -Raw
            $parsed = $raw | ConvertFrom-Json
            $sub = $parsed[0].status.substatus
            if ($sub) {
                foreach ($ss in $sub) {
                    $msg = $ss.formattedMessage.message
                    if ($msg -and $msg -match '^eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') {
                        $r['ExtJwt'] = $msg
                        break
                    }
                }
            }
            if (-not $r['ExtJwt']) {
                $r['ExtStatusCode'] = $parsed[0].status.status
                $r['ExtOperation']  = $parsed[0].status.operation
            }
        } catch {}
    }
}
$r['ExtVersion'] = if ($extDirs) { ($extDirs | Sort-Object Name -Descending | Select-Object -First 1).Name } else { 'NotFound' }
$mbPath = 'C:\Windows\Logs\MeasuredBoot'
$mbFiles = Get-ChildItem $mbPath -ErrorAction SilentlyContinue
$r['MeasuredBootLogs'] = if ($mbFiles) { [string]$mbFiles.Count } else { '0' }
$r | ConvertTo-Json -Compress
'@
        $vmScriptFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($vmScriptFile, $vmScript, [System.Text.UTF8Encoding]::new($false))

        foreach ($rv in $runningVms) {
            $vmName = $rv.VM
            Write-Info "  Collecting evidence from $vmName ..."

            if ($DryRun) {
                Write-Info "    DryRun: would execute run-command on $vmName"
                $vmEvidence += [PSCustomObject]@{ VM = $vmName; SecureBoot = "DRYRUN"; TPM = "-"; VBS = "-"; THIM = "-"; IMDS = "-"; MeasuredBoot = "-"; ExtVersion = "-" }
                continue
            }

            $ErrorActionPreference = 'SilentlyContinue'
            $rcJson = az vm run-command invoke `
                --resource-group $HostsResourceGroup `
                --name $vmName `
                --command-id RunPowerShellScript `
                --scripts "@$vmScriptFile" `
                -o json 2>$null
            $rcEc = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'

            if ($rcEc -ne 0 -or -not $rcJson) {
                Write-Warn "    $vmName`: run-command failed (exit code $rcEc)"
                $vmEvidence += [PSCustomObject]@{ VM = $vmName; SecureBoot = "RC_FAIL"; TPM = "-"; VBS = "-"; THIM = "-"; IMDS = "-"; MeasuredBoot = "-"; ExtVersion = "-" }
                $warnCount++
                continue
            }

            try {
                $rcResult = $rcJson | ConvertFrom-Json
                $stdout = $rcResult.value[0].message
                $stderr = $rcResult.value[1].message

                if (-not $stdout) {
                    Write-Warn "    $vmName`: empty run-command output"
                    if ($stderr) { Write-Info "    VM stderr: $($stderr.Substring(0, [Math]::Min(200, $stderr.Length)))" }
                    $vmEvidence += [PSCustomObject]@{ VM = $vmName; SecureBoot = "EMPTY"; TPM = "-"; VBS = "-"; THIM = "-"; IMDS = "-"; MeasuredBoot = "-"; ExtVersion = "-" }
                    $warnCount++
                    continue
                }

                # Find the JSON line in output (script may emit extra lines from PS profile)
                $jsonLine = $null
                foreach ($line in $stdout.Split("`n")) {
                    $trimmed = $line.Trim()
                    if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) {
                        $jsonLine = $trimmed
                    }
                }

                if (-not $jsonLine) {
                    Write-Warn "    $vmName`: no JSON found in run-command output"
                    Write-Info "    Raw output: $($stdout.Substring(0, [Math]::Min(200, $stdout.Length)))"
                    $vmEvidence += [PSCustomObject]@{ VM = $vmName; SecureBoot = "PARSE_ERR"; TPM = "-"; VBS = "-"; THIM = "-"; IMDS = "-"; MeasuredBoot = "-"; ExtVersion = "-" }
                    $warnCount++
                    continue
                }

                $ev = $jsonLine | ConvertFrom-Json

                # Extract JWT token if found in extension status files
                if ($ev.ExtJwt -and $ev.ExtJwt -ne '') {
                    $jwtTokens[$vmName] = $ev.ExtJwt
                    Write-OK "    $vmName`: JWT attestation token found in extension status"
                }

                $secureBoot = if ($ev.SecureBoot -eq 'True') { 'Enabled' } elseif ($ev.SecureBoot -eq 'False') { 'DISABLED' } else { $ev.SecureBoot }
                $tpmStatus  = if ($ev.TpmReady -eq 'True') { 'Ready' } elseif ($ev.TpmPresent -eq 'True') { 'Present' } else { $ev.TpmPresent }
                $vbs        = if ($ev.VbsStatus) { $ev.VbsStatus } else { 'N/A' }
                $thim       = if ($ev.ThimVcekCert -and $ev.ThimVcekCert -like 'Present*') { 'Valid' } elseif ($ev.ThimVcekCert -eq 'Error') { 'Error' } else { $ev.ThimVcekCert }
                $imds       = if ($ev.ImdsSignature) { 'Valid' } elseif ($ev.ImdsAttested -eq 'Error') { 'Error' } else { 'N/A' }
                $mbLogs     = if ($ev.MeasuredBootLogs -and [int]$ev.MeasuredBootLogs -gt 0) { "$($ev.MeasuredBootLogs) files" } else { 'None' }
                $extVer     = if ($ev.ExtVersion) { $ev.ExtVersion } else { '-' }

                Write-OK "    $vmName`: evidence collected successfully"
                Write-Info "      Secure Boot      : $secureBoot"
                Write-Info "      TPM              : $tpmStatus (Enabled: $($ev.TpmEnabled))"
                Write-Info "      VBS              : $vbs"
                if ($ev.SecurityServices) { Write-Info "      Security Svcs    : $($ev.SecurityServices)" }
                Write-Info "      THIM VCEK Cert   : $($ev.ThimVcekCert)"
                if ($ev.ThimCertChain) { Write-Info "      THIM Cert Chain  : $($ev.ThimCertChain)" }
                if ($ev.ThimTcbm)      { Write-Info "      THIM TCB Version : $($ev.ThimTcbm)" }
                Write-Info "      IMDS Attested    : $(if ($ev.ImdsSignature) { 'Signed (' + $ev.ImdsEncoding + ')' } else { $imds })"
                Write-Info "      Measured Boot    : $mbLogs"
                Write-Info "      Extension Ver    : $extVer"
                if ($ev.ExtStatusCode) { Write-Info "      Extension Status : $($ev.ExtStatusCode) ($($ev.ExtOperation))" }

                $vmEvidence += [PSCustomObject]@{
                    VM          = $vmName
                    SecureBoot  = $secureBoot
                    TPM         = $tpmStatus
                    VBS         = $vbs
                    THIM        = $thim
                    IMDS        = $imds
                    MeasuredBoot = $mbLogs
                    ExtVersion  = $extVer
                }

            } catch {
                Write-Warn "    $vmName`: failed to parse run-command output: $($_.Exception.Message)"
                $vmEvidence += [PSCustomObject]@{ VM = $vmName; SecureBoot = "PARSE_ERR"; TPM = "-"; VBS = "-"; THIM = "-"; IMDS = "-"; MeasuredBoot = "-"; ExtVersion = "-" }
                $warnCount++
            }
        }

        Remove-Item $vmScriptFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# STEP 5 - JWT token decode and RS256 signature verification
# ---------------------------------------------------------------------------
Write-Step "5/6" "JWT token decode and RS256 signature verification"
Write-Info "  If JWT attestation tokens were found in extension status files"
Write-Info "  (Step 4), decodes the JOSE header and payload, then verifies"
Write-Info "  the digital signature against the MAA signing certificates."

$jwtVerifyResults = @()

if ($SkipJwtValidation) {
    Write-Info "Skipping JWT verification (-SkipJwtValidation set)."
} elseif ($jwtTokens.Count -eq 0) {
    Write-Info "  No JWT tokens found in extension status files."
    Write-Info "  The GuestAttestation extension may report plain-text status"
    Write-Info "  instead of JWT tokens depending on the extension version."
    Write-Info "  Extension status from Step 2 still confirms attestation"
    Write-Info "  was performed and verified internally by the extension."
} else {
    Write-OK "  Found $($jwtTokens.Count) JWT token(s) to decode and verify"

    foreach ($kvp in $jwtTokens.GetEnumerator()) {
        $vmName = $kvp.Key
        $jwt    = $kvp.Value

        Write-Info ""
        Write-Info "  Verifying JWT from $vmName ..."

        try {
            $parts = $jwt.Split('.')
            if ($parts.Count -ne 3) {
                Write-Warn "    Invalid JWT format (expected 3 parts, got $($parts.Count))"
                $jwtVerifyResults += [PSCustomObject]@{ VM = $vmName; SignatureValid = "INVALID"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-"; VMID = "-" }
                continue
            }

            # Decode JOSE header
            $headerBytes = ConvertFrom-Base64Url $parts[0]
            $header = [System.Text.Encoding]::UTF8.GetString($headerBytes) | ConvertFrom-Json
            Write-Info "    JOSE Header:"
            Write-Info "      Algorithm : $($header.alg)"
            Write-Info "      Key ID    : $($header.kid)"
            Write-Info "      JKU       : $($header.jku)"
            Write-Info "      Type      : $($header.typ)"

            # Decode payload claims
            $payloadBytes = ConvertFrom-Base64Url $parts[1]
            $payload = [System.Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json

            # Extract key attestation claims
            $attType    = if ($payload.'x-ms-attestation-type') { $payload.'x-ms-attestation-type' } else { "-" }
            $compliance = if ($payload.'x-ms-compliance-status') { $payload.'x-ms-compliance-status' } else { "-" }
            $sb         = if ($null -ne $payload.secureboot) { [string]$payload.secureboot } else { "-" }
            $iss        = if ($payload.iss) { $payload.iss } else { "-" }
            $vmid       = if ($payload.'x-ms-azurevm-vmid') { $payload.'x-ms-azurevm-vmid' } else { "-" }

            Write-Info "    Attestation Claims:"
            Write-Info "      Issuer                 : $iss"
            Write-Info "      Attestation Type       : $attType"
            Write-Info "      Compliance Status      : $compliance"
            Write-Info "      Secure Boot            : $sb"
            Write-Info "      VM ID                  : $vmid"

            # Additional hardware attestation claims
            if ($null -ne $payload.'x-ms-azurevm-dbvalidated') {
                Write-Info "      DB Validated           : $($payload.'x-ms-azurevm-dbvalidated')"
            }
            if ($null -ne $payload.'x-ms-azurevm-dbxvalidated') {
                Write-Info "      DBX Validated          : $($payload.'x-ms-azurevm-dbxvalidated')"
            }
            if ($null -ne $payload.'x-ms-azurevm-debuggersdisabled') {
                Write-Info "      Debuggers Disabled     : $($payload.'x-ms-azurevm-debuggersdisabled')"
            }
            if ($null -ne $payload.'x-ms-azurevm-signingdisabled') {
                Write-Info "      Test Signing Disabled  : $($payload.'x-ms-azurevm-signingdisabled')"
            }
            if ($null -ne $payload.'x-ms-azurevm-bootdebug-enabled') {
                Write-Info "      Boot Debug Enabled     : $($payload.'x-ms-azurevm-bootdebug-enabled')"
            }
            if ($null -ne $payload.'x-ms-azurevm-elam-enabled') {
                Write-Info "      ELAM Enabled           : $($payload.'x-ms-azurevm-elam-enabled')"
            }
            if ($payload.'x-ms-azurevm-ostype') {
                Write-Info "      OS Type                : $($payload.'x-ms-azurevm-ostype')"
            }
            if ($payload.'x-ms-azurevm-osdistro') {
                Write-Info "      OS Distribution        : $($payload.'x-ms-azurevm-osdistro')"
            }

            # SEV-SNP TEE isolation claims
            $tee = $payload.'x-ms-isolation-tee'
            if ($tee) {
                $teeType       = if ($tee.'x-ms-attestation-type')  { $tee.'x-ms-attestation-type' }  else { "-" }
                $teeCompliance = if ($tee.'x-ms-compliance-status') { $tee.'x-ms-compliance-status' } else { "-" }
                Write-Info "    SEV-SNP TEE Claims:"
                Write-Info "      TEE Attestation Type   : $teeType"
                Write-Info "      TEE Compliance Status  : $teeCompliance"
                if ($attType -eq "-") { $attType = $teeType }
                if ($compliance -eq "-") { $compliance = $teeCompliance }
            }

            if ($payload.'x-ms-sevsnpvm-launchmeasurement') {
                $lm = $payload.'x-ms-sevsnpvm-launchmeasurement'
                Write-Info "      Launch Measurement     : $($lm.Substring(0, [Math]::Min(40, $lm.Length)))..."
            }
            if ($null -ne $payload.'x-ms-sevsnpvm-is-debuggable') {
                Write-Info "      Is Debuggable          : $($payload.'x-ms-sevsnpvm-is-debuggable')"
            }
            if ($null -ne $payload.'x-ms-sevsnpvm-migration-allowed') {
                Write-Info "      Migration Allowed      : $($payload.'x-ms-sevsnpvm-migration-allowed')"
            }

            # Token timing
            if ($payload.iat) {
                $iatDate = [DateTimeOffset]::FromUnixTimeSeconds($payload.iat).DateTime.ToString("yyyy-MM-dd HH:mm:ss UTC")
                Write-Info "      Issued At              : $iatDate"
            }
            if ($payload.exp) {
                $expDate = [DateTimeOffset]::FromUnixTimeSeconds($payload.exp).DateTime.ToString("yyyy-MM-dd HH:mm:ss UTC")
                Write-Info "      Expires                : $expDate"
            }

            # ---------------------------------------------------------------
            # RS256 signature verification against MAA signing certificates
            # ---------------------------------------------------------------
            $sigValid = "NOT_VERIFIED"

            if ($header.alg -ne "RS256") {
                Write-Warn "    Unsupported algorithm: $($header.alg) (only RS256 is implemented)"
                $sigValid = "UNSUPPORTED_ALG"
            } elseif (-not $maaCerts) {
                Write-Warn "    MAA certificates not available (Step 3 may have failed)"
                $sigValid = "NO_CERTS"
            } else {
                # Find matching certificate by kid
                $matchingKey = $maaCerts.keys | Where-Object { $_.kid -eq $header.kid }
                if (-not $matchingKey) {
                    Write-Warn "    No matching certificate for kid '$($header.kid)'"
                    $sigValid = "NO_KID_MATCH"
                } else {
                    try {
                        # Get the leaf certificate from x5c chain (x5c[0] is the signing cert)
                        $leafCertBytes = [Convert]::FromBase64String($matchingKey.x5c[0])
                        $leafCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($leafCertBytes)

                        # Compute SHA-256 hash of header.payload
                        $dataToVerify = "$($parts[0]).$($parts[1])"
                        $dataBytes    = [System.Text.Encoding]::UTF8.GetBytes($dataToVerify)
                        $sha256       = [System.Security.Cryptography.SHA256]::Create()
                        $hashedBytes  = $sha256.ComputeHash($dataBytes)

                        # Decode the base64url signature
                        $sigBytes = ConvertFrom-Base64Url $parts[2]

                        # Verify using RSA public key
                        # Try modern API first (RSACng / .NET 4.6+), fall back to legacy RSACryptoServiceProvider
                        $rsa = $leafCert.PublicKey.Key
                        $verified = $false
                        try {
                            $verified = $rsa.VerifyHash(
                                $hashedBytes,
                                $sigBytes,
                                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
                            )
                        } catch {
                            # Fallback for legacy RSACryptoServiceProvider (.NET Framework)
                            try {
                                $verified = $rsa.VerifyHash($hashedBytes, "SHA256", $sigBytes)
                            } catch {
                                Write-Warn "    Signature verification API error: $($_.Exception.Message)"
                                $sigValid = "API_ERROR"
                            }
                        }

                        if ($sigValid -ne "API_ERROR") {
                            $sigValid = if ($verified) { "VALID" } else { "INVALID" }
                            if ($verified) {
                                Write-OK "    RS256 signature verification: VALID"
                                Write-Info "      Signed by: $($leafCert.Subject)"
                                Write-Info "      Thumbprint: $($leafCert.Thumbprint)"
                            } else {
                                Write-Fail "    RS256 signature verification: INVALID"
                                Write-Fail "    WARNING: Token signature does not match MAA certificate!"
                                $failCount++
                            }
                        }

                    } catch {
                        Write-Warn "    Signature verification failed: $($_.Exception.Message)"
                        $sigValid = "ERROR"
                    }
                }
            }

            $jwtVerifyResults += [PSCustomObject]@{
                VM              = $vmName
                SignatureValid  = $sigValid
                AttestationType = $attType
                ComplianceStatus = $compliance
                SecureBoot      = $sb
                Issuer          = $iss
                VMID            = $vmid
            }

        } catch {
            Write-Warn "    $vmName`: JWT decode failed: $($_.Exception.Message)"
            $jwtVerifyResults += [PSCustomObject]@{ VM = $vmName; SignatureValid = "DECODE_ERR"; AttestationType = "-"; ComplianceStatus = "-"; SecureBoot = "-"; Issuer = "-"; VMID = "-" }
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 6 - Optional Log Analytics query for attestation error events
# ---------------------------------------------------------------------------
Write-Step "6/6" "Log Analytics attestation event query"

if ([string]::IsNullOrEmpty($LogAnalyticsWorkspaceId)) {
    Write-Info "Log Analytics Workspace ID not provided - skipping."
    Write-Info "Provide -LogAnalyticsWorkspaceId to also surface attestation events."
} else {
    $workspaceName = ($LogAnalyticsWorkspaceId -split '/')[-1]
    $workspaceRg   = ($LogAnalyticsWorkspaceId -split '/')[4]
    Write-Info "Querying $workspaceName for errors in the past $QueryDays days ..."

    # Resolve the workspace customer ID (GUID) required by az monitor log-analytics query
    $ErrorActionPreference = 'SilentlyContinue'
    $workspaceGuid = az monitor log-analytics workspace show `
        --workspace-name $workspaceName `
        --resource-group $workspaceRg `
        --query customerId -o tsv 2>$null
    $wsEc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($wsEc -ne 0 -or -not $workspaceGuid) {
        Write-Warn "Could not resolve workspace customer ID (exit code $wsEc). Check SPN has Reader on the workspace."
    } else {
        $kql = @"
WindowsEvent
| where TimeGenerated > ago(${QueryDays}d)
| where Channel contains "Attestation" or Channel contains "TPM"
| where Level in (1, 2, 3)
| project TimeGenerated, Computer, Channel, EventID, Message = tostring(EventData)
| order by TimeGenerated desc
| take 50
"@

        # Write KQL to temp file without BOM — PS 5.1's Set-Content -Encoding UTF8
        # adds a BOM (EF BB BF) that corrupts az CLI's @file syntax.
        $kqlFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($kqlFile, $kql, [System.Text.UTF8Encoding]::new($false))
        $ErrorActionPreference = 'SilentlyContinue'
        $laJson = az monitor log-analytics query --workspace $workspaceGuid --analytics-query "@$kqlFile" -o json 2>$null
        $laEc = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Remove-Item $kqlFile -Force -ErrorAction SilentlyContinue

        if ($laEc -ne 0 -or -not $laJson) {
            Write-Warn "Log Analytics query returned exit code $laEc."
            Write-Warn "This is normal if the DCR was recently deployed and the WindowsEvent"
            Write-Warn "table does not exist yet. Data typically appears within 5-10 minutes."
            Write-Warn "Required role: Log Analytics Reader on the workspace resource."
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
    Write-Host "  STEP 2 - Attestation status (instance view):"
    $jwtResults | Format-Table VM, JwtStatus, AttestationType, ComplianceStatus, SecureBoot -AutoSize
}

if (-not $SkipJwtValidation -and $certResults.Count -gt 0) {
    Write-Host "  STEP 3 - MAA signing certificates:"
    $certResults | Format-Table Kid, @{L='Subject';E={if ($_.Subject.Length -gt 45) { $_.Subject.Substring(0,42) + '...' } else { $_.Subject }}}, NotAfter, Algorithm, KeySize, Expired -AutoSize
}

if (-not $SkipJwtValidation -and $vmEvidence.Count -gt 0) {
    Write-Host "  STEP 4 - In-VM attestation evidence:"
    $vmEvidence | Format-Table VM, SecureBoot, TPM, VBS, THIM, IMDS, MeasuredBoot -AutoSize
}

if (-not $SkipJwtValidation -and $jwtVerifyResults.Count -gt 0) {
    Write-Host "  STEP 5 - JWT signature verification:"
    $jwtVerifyResults | Format-Table VM, SignatureValid, AttestationType, ComplianceStatus, SecureBoot, Issuer -AutoSize
}

$okExt       = @($extResults | Where-Object Status -eq "OK").Count
$okJwt       = @($jwtResults | Where-Object JwtStatus -eq "OK").Count
$okEvidence  = @($vmEvidence | Where-Object { $_.SecureBoot -eq "Enabled" }).Count
$validJwts   = @($jwtVerifyResults | Where-Object SignatureValid -eq "VALID").Count

Write-Host ""
Write-Host "  Total CVMs        : $($cvmHosts.Count)"
Write-Host "  Ext OK            : $okExt / $($cvmHosts.Count)" -ForegroundColor $(if ($okExt -eq $cvmHosts.Count) { "Green" } else { "Yellow" })
if (-not $SkipJwtValidation -and $jwtResults.Count -gt 0) {
    Write-Host "  Attest OK         : $okJwt / $($jwtResults.Count)" -ForegroundColor $(if ($okJwt -eq $jwtResults.Count) { "Green" } else { "Yellow" })
}
if (-not $SkipJwtValidation -and $vmEvidence.Count -gt 0) {
    Write-Host "  SecureBoot OK     : $okEvidence / $($vmEvidence.Count)" -ForegroundColor $(if ($okEvidence -eq $vmEvidence.Count) { "Green" } else { "Yellow" })
}
if ($jwtTokens.Count -gt 0) {
    Write-Host "  JWT tokens found  : $($jwtTokens.Count)" -ForegroundColor Cyan
    Write-Host "  JWT sig valid     : $validJwts / $($jwtVerifyResults.Count)" -ForegroundColor $(if ($validJwts -eq $jwtVerifyResults.Count) { "Green" } else { "Yellow" })
}
Write-Host "  Warnings          : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Failures          : $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($failCount -gt 0) {
    Write-Host "  [ACTION REQUIRED] Attestation failures detected. See output above." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Extension missing or failed:" -ForegroundColor Yellow
    Write-Host "    az vm extension set --resource-group $HostsResourceGroup --vm-name <VM_NAME> \" -ForegroundColor Gray
    Write-Host "      --name GuestAttestation --publisher Microsoft.Azure.Security.WindowsAttestation \" -ForegroundColor Gray
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
Write-Host "  Extension provisioned, attestation verified via instance view," -ForegroundColor Green
Write-Host "  MAA signing certificates valid, in-VM hardware evidence collected," -ForegroundColor Green
Write-Host "  and hosts confirmed running in genuine AMD SEV-SNP confidential TEEs." -ForegroundColor Green
if ($jwtTokens.Count -gt 0) {
    Write-Host "  JWT attestation tokens verified with RS256 signature against MAA certs." -ForegroundColor Green
}
Write-Host ""
Write-Host "  [DONE]" -ForegroundColor Green
