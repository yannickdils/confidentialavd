#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Pre-sysprep remediation script: removes user-only AppX packages and verifies BitLocker status.

.DESCRIPTION
    Fixes sysprep blockers on Windows 11 (tested on build 26100 / 24H2):
      1. Verifies BitLocker is disabled on the OS volume.
      2. Detects AppX packages installed per-user but not provisioned for all users,
         excluding protected system apps and framework packages that cannot or should
         not be removed directly.
      3. Attempts removal via multiple strategies: AllUsers removal, per-user SID
         removal, deprovisioning (Remove-AppxProvisionedPackage), and DISM as a
         last resort.
      4. Provides a clear go / no-go summary at the end.

.NOTES
    After this script completes successfully, run sysprep with:
        C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$WhatIf,

    [Parameter()]
    [switch]$AutoDisable  # If set, attempt to disable BitLocker and wait for decryption
)

$ErrorActionPreference = 'Continue'
$WarningPreference     = 'Continue'

# ---------------------------------------------------------------------------
# Known paths that indicate a package is a protected Windows system component
# ---------------------------------------------------------------------------
$SystemAppPaths = @(
    "$env:SystemRoot\SystemApps",
    "$env:SystemRoot\ImmersiveControlPanel",
    "$env:SystemRoot\SystemApps\SxS"
)

# ---------------------------------------------------------------------------
# Well-known package name prefixes for Windows system components.
# These packages are managed by Windows itself and cannot / must not be
# removed via Remove-AppxPackage. They do not block sysprep when /mode:vm
# is used.
# ---------------------------------------------------------------------------
$SystemPackagePrefixes = @(
    'windows.immersivecontrolpanel',
    'Windows.CBSPreview',
    'Windows.PrintDialog',
    'Microsoft.AAD.BrokerPlugin',
    'Microsoft.AccountsControl',
    'Microsoft.AsyncTextService',
    'Microsoft.BioEnrollment',
    'Microsoft.CredDialogHost',
    'Microsoft.ECApp',
    'Microsoft.LockApp',
    'Microsoft.MicrosoftEdgeDevToolsClient',
    'Microsoft.Win32WebViewHost',
    'Microsoft.Windows.Apprep.ChxApp',
    'Microsoft.Windows.AssignedAccessLockApp',
    'Microsoft.Windows.AugLoop.CBS',
    'Microsoft.Windows.CapturePicker',
    'Microsoft.Windows.CloudExperienceHost',
    'Microsoft.Windows.ContentDeliveryManager',
    'Microsoft.Windows.NarratorQuickStart',
    'Microsoft.Windows.OOBENetworkCaptivePortal',
    'Microsoft.Windows.OOBENetworkConnectionFlow',
    'Microsoft.Windows.ParentalControls',
    'Microsoft.Windows.PeopleExperienceHost',
    'Microsoft.Windows.PinningConfirmationDialog',
    'Microsoft.Windows.PrintQueueActionCenter',
    'Microsoft.Windows.SecureAssessmentBrowser',
    'Microsoft.Windows.ShellExperienceHost',
    'Microsoft.Windows.StartMenuExperienceHost',
    'Microsoft.Windows.XGpuEjectDialog',
    'Microsoft.XboxGameCallableUI',
    'MicrosoftWindows.Client.CBS',
    'MicrosoftWindows.Client.Core',
    'MicrosoftWindows.Client.CoreAI',
    'MicrosoftWindows.Client.FileExp',
    'MicrosoftWindows.Client.OOBE',
    'MicrosoftWindows.Client.Photon',
    'MicrosoftWindows.Client.WebExperience',
    'MicrosoftWindows.CrossDevice',
    'MicrosoftWindows.UndockedDevKit',
    # Numeric-prefixed system packages (Taskbar, Speech, Input, etc.)
    'MicrosoftWindows.57242383',
    'MicrosoftWindows.59336768',
    'MicrosoftWindows.59337133',
    'MicrosoftWindows.59337145',
    'MicrosoftWindows.59379618',
    # GUID-named system packages (FilePicker, FileExplorer, AppResolverUX, etc.)
    '1527c705-839a-4832-9118-54d4Bd6a0c89',
    'c5e2524a-ea46-4f67-841f-6a9465d9d515',
    'E2A4F912-2574-4A75-9BB0-0D023378592B',
    'F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE'
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-Section {
    param([string]$Title)
    Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
    Write-Host "  $Title"      -ForegroundColor Cyan
    Write-Host "$('=' * 70)"   -ForegroundColor Cyan
}

function Write-Step { param([string]$m) Write-Host "`n  --> $m" -ForegroundColor Yellow }
function Write-OK   { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor DarkYellow }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info { param([string]$m) Write-Host "         $m" -ForegroundColor Gray }
function Write-Skip { param([string]$m) Write-Host "  [SKIP] $m" -ForegroundColor DarkGray }

function Test-IsSystemApp {
    <#
    .SYNOPSIS
        Returns $true if the package is a protected Windows system component
        that must not be removed via Remove-AppxPackage.
    #>
    param([Microsoft.Windows.Appx.PackageManager.Commands.AppxPackage]$Package)

    # 1. Check install location against known system paths
    foreach ($sysPath in $SystemAppPaths) {
        if ($Package.InstallLocation -like "$sysPath*") {
            return $true
        }
    }

    # 2. Check package name against known system package prefixes
    foreach ($prefix in $SystemPackagePrefixes) {
        if ($Package.Name -like "$prefix*") {
            return $true
        }
    }

    return $false
}

function Test-IsFrameworkPackage {
    <#
    .SYNOPSIS
        Returns $true if the package is a framework / dependency package.
    .NOTES
        Framework packages (VCLibs, UI.Xaml, WindowsAppRuntime, etc.) are
        shared dependencies. Attempting to remove them directly fails with a
        dependency error. They are cleaned up automatically when all packages
        that depend on them are removed.
    #>
    param([Microsoft.Windows.Appx.PackageManager.Commands.AppxPackage]$Package)
    return ($Package.IsFramework -eq $true)
}

# ---------------------------------------------------------------------------
# Well-known package name prefixes for Microsoft / Windows packages.
# Packages whose name starts with one of these are considered safe when
# provisioned. Anything else provisioned is treated as sideloaded.
# ---------------------------------------------------------------------------
$SafeProvisionedNamePrefixes = @(
    'Microsoft.',
    'MicrosoftCorporationII.',
    'MicrosoftWindows.',
    'Microsoft Corporation',
    'Clipchamp.',
    'windows.',
    'Windows.',
    # GUID-named system packages (FilePicker, FileExplorer, AppResolverUX, etc.)
    '1527c705-839a-4832-9118-54d4Bd6a0c89',
    'c5e2524a-ea46-4f67-841f-6a9465d9d515',
    'E2A4F912-2574-4A75-9BB0-0D023378592B',
    'F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE'
)

# ---------------------------------------------------------------------------
# Well-known Microsoft Publisher IDs (hash of the publisher certificate).
# These are unique and reliable identifiers - unlike the Publisher string
# which can be spoofed or contain common words like "Microsoft".
#   8wekyb3d8bbwe  = Microsoft Store apps (CN=Microsoft Corporation, ...)
#   cw5n1h2txyewy  = Windows system apps (CN=Microsoft Windows, ...)
# ---------------------------------------------------------------------------
$SafePublisherIds = @(
    '8wekyb3d8bbwe',
    'cw5n1h2txyewy'
)

function Test-IsSafeProvisionedPackage {
    <#
    .SYNOPSIS
        Returns $true if the package is a known Microsoft / Windows package
        that is safe to leave provisioned. Returns $false for sideloaded
        third-party MSIX packages that may block sysprep.
    .NOTES
        Sideloaded MSIX packages (e.g. NotepadPlusPlus) may appear in the
        provisioned package list but still cause sysprep error 0x80073cf2
        ("installed for a user, but not provisioned for all users").
        These must be deprovisioned and removed before sysprep.
    #>
    param([Microsoft.Windows.Appx.PackageManager.Commands.AppxPackage]$Package)

    # System apps are always safe
    if (Test-IsSystemApp -Package $Package) { return $true }

    # Framework packages are always safe
    if (Test-IsFrameworkPackage -Package $Package) { return $true }

    # Check package name against safe name prefixes
    foreach ($prefix in $SafeProvisionedNamePrefixes) {
        if ($Package.Name -like "$prefix*") {
            return $true
        }
    }

    # Check PublisherId (the hashed publisher certificate identifier)
    # This is far more reliable than checking the Publisher display string
    # which can contain "Microsoft" in third-party packages.
    if ($Package.PublisherId) {
        if ($SafePublisherIds -contains $Package.PublisherId) {
            return $true
        }
    }

    return $false
}

function Get-InstalledUserSids {
    <#
    .SYNOPSIS
        Returns an array of SID strings for users that have the package installed.
    .NOTES
        PackageUserInformation contains objects with two properties:
          - UserSecurityId  : string containing the SID (e.g. "S-1-5-21-...")
          - InstallState    : enum (Installed, Staged, NotInstalled, etc.)

        Earlier versions of this script compared the entire object instead of
        extracting the string property, causing "The security ID structure is
        invalid" errors. This function extracts and validates the SID string
        before returning it.
    #>
    param([Microsoft.Windows.Appx.PackageManager.Commands.AppxPackage]$Package)

    $sids = @()
    foreach ($userInfo in $Package.PackageUserInformation) {
        $sid = $userInfo.UserSecurityId          # Extract the string property
        if ($sid -and $sid -match '^S-\d-') {    # Validate SID format
            $installState = $userInfo.InstallState.ToString()
            if ($installState -eq 'Installed') {
                $sids += $sid
            }
        }
    }
    return $sids
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$remediationOK = $true

# -------------------------
# BitLocker helper functions
# -------------------------
function Get-BitLockerEncryptedVolumes {
    try {
        $volumes = Get-BitLockerVolume -ErrorAction Stop
        $encryptedVolumes = $volumes | Where-Object {
            $_.ProtectionStatus -eq 'On' -or
            $_.VolumeStatus -ne 'FullyDecrypted' -or
            ($_.EncryptionPercentage -gt 0)
        }
        return $encryptedVolumes
    } catch {
        Write-Warn "Get-BitLockerVolume failed: $($_.Exception.Message)"
        return @()
    }
}

function Disable-BitLockerOnVolume {
    param(
        [Parameter(Mandatory=$true)]
        [string]$MountPoint
    )

    try {
        $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
                        } catch {
                            Write-Warn "Could not query BitLocker for ${MountPoint}: $($_.Exception.Message)"   
                            return $false
                        }

    if ($volume.ProtectionStatus -eq 'On') {
        Write-Step "Suspending BitLocker protection on $MountPoint ..."
        if (-not $WhatIf) {
            try { Suspend-BitLocker -MountPoint $MountPoint -RebootCount 0 -ErrorAction Stop | Out-Null; Write-OK "Suspended protection on $MountPoint" } catch { Write-Warn "Suspend-BitLocker failed: $($_.Exception.Message)" }
        } else {
            Write-Warn "[WhatIf] Would Suspend-BitLocker -MountPoint $MountPoint"
        }
    }

    if ($volume.VolumeStatus -ne 'FullyDecrypted') {
        Write-Step "Disabling BitLocker on $MountPoint (starts decryption) ..."
        if (-not $WhatIf) {
            try { Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null; Write-OK "Disable-BitLocker issued for $MountPoint" } catch { Write-Warn "Disable-BitLocker failed: $($_.Exception.Message)"; return $false }
        } else {
            Write-Warn "[WhatIf] Would Disable-BitLocker -MountPoint $MountPoint"
        }
    } else {
        Write-Info "$MountPoint is already fully decrypted - removing protectors (if present)"
        if (-not $WhatIf) {
            try { Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null; Write-OK "Disable-BitLocker / protector removal issued for $MountPoint" } catch { Write-Warn "Disable-BitLocker failed: $($_.Exception.Message)"; return $false }
        } else {
            Write-Warn "[WhatIf] Would Disable-BitLocker (protectors) -MountPoint $MountPoint"
        }
    }

    return $true
}

function Wait-ForDecryptionCompletion {
    param(
        [int]$DecryptionCheckIntervalSeconds = 30,
        [int]$DecryptionTimeoutMinutes = 120
    )

    $timeoutTime = (Get-Date).AddMinutes($DecryptionTimeoutMinutes)
    Write-Step "Waiting for decryption to complete on all volumes (timeout: $DecryptionTimeoutMinutes minutes) ..."

    while ((Get-Date) -lt $timeoutTime) {
        try {
            $volumes = Get-BitLockerVolume -ErrorAction Stop
        } catch {
            Write-Warn "Get-BitLockerVolume failed while waiting: $($_.Exception.Message)"
            Start-Sleep -Seconds $DecryptionCheckIntervalSeconds
            continue
        }

        $still = $volumes | Where-Object { $_.VolumeStatus -eq 'DecryptionInProgress' -or $_.VolumeStatus -eq 'EncryptionInProgress' -or ($_.EncryptionPercentage -gt 0) }
        if (-not $still) {
            Write-OK "All volumes are fully decrypted"
            return $true
        }

        foreach ($v in $still) {
            Write-Info "$($v.MountPoint) - Status: $($v.VolumeStatus) | Encrypted: $($v.EncryptionPercentage)%"
        }

        Write-Info "Checking again in $DecryptionCheckIntervalSeconds seconds..."
        Start-Sleep -Seconds $DecryptionCheckIntervalSeconds
    }

    Write-Fail "Decryption did not complete within timeout ($DecryptionTimeoutMinutes minutes)"
    return $false
}

function Confirm-NoBitLockerActive {
    try {
        $volumes = Get-BitLockerVolume -ErrorAction Stop
    } catch {
        Write-Warn "Final BitLocker validation failed to query volumes: $($_.Exception.Message)"
        return $false
    }

    $issues = @()
    foreach ($vol in $volumes) {
        if ($vol.ProtectionStatus -ne 'Off') { $issues += "$($vol.MountPoint): Protection is $($vol.ProtectionStatus)" }
        if ($vol.VolumeStatus -ne 'FullyDecrypted') { $issues += "$($vol.MountPoint): VolumeStatus is $($vol.VolumeStatus)" }
        if ($vol.EncryptionPercentage -gt 0) { $issues += "$($vol.MountPoint): EncryptionPercentage is $($vol.EncryptionPercentage)%" }
        if ($vol.KeyProtector.Count -gt 0) { $issues += "$($vol.MountPoint): $($vol.KeyProtector.Count) key protector(s) present" }
    }

    if ($issues.Count -gt 0) {
        Write-Fail "BitLocker remnants detected:" 
        foreach ($i in $issues) { Write-Info "  - $i" }
        return $false
    }

    Write-OK "No BitLocker encryption or protection active on any volume"
    return $true
}

# ===========================================================================
Write-Section "PHASE 1: BitLocker Status Check"
# ===========================================================================

Write-Step "Querying BitLocker status on all volumes..."

try {
    $bitlockerVolumes = Get-BitLockerEncryptedVolumes
    if (-not $bitlockerVolumes -or $bitlockerVolumes.Count -eq 0) {
        Write-OK "No BitLocker-encrypted or partially encrypted volumes detected"
    } else {
        foreach ($vol in $bitlockerVolumes) {
            Write-Info "Volume      : $($vol.MountPoint)"
            Write-Info "Protection  : $($vol.ProtectionStatus)"
            Write-Info "Encryption  : $($vol.VolumeStatus) ($($vol.EncryptionPercentage)%)"
            Write-Host ""
        }

        # If AutoDisable is requested, attempt to disable on each volume and wait
        if ($AutoDisable) {
            Write-Step "AutoDisable requested - attempting to disable BitLocker on detected volumes"
            foreach ($vol in $bitlockerVolumes) {
                $mp = $vol.MountPoint
                if (-not (Disable-BitLockerOnVolume -MountPoint $mp)) {
                    Write-Fail "Failed to issue disable for $mp"
                    $remediationOK = $false
                }
            }

            if ($remediationOK) {
                $decryptionOk = Wait-ForDecryptionCompletion -DecryptionCheckIntervalSeconds 30 -DecryptionTimeoutMinutes 120
                if (-not $decryptionOk) { $remediationOK = $false }
                else { $validation = Confirm-NoBitLockerActive; if (-not $validation) { $remediationOK = $false } }
            }
        }
        else {
            Write-Warn "BitLocker detected. Set -AutoDisable to attempt automatic disable + wait, or disable manually (manage-bde -off <drive>)"
            $remediationOK = $false
        }
    }
} catch {
    Write-Warn "BitLocker check failed: $($_.Exception.Message)"
    $remediationOK = $false
}

# ===========================================================================
Write-Section "PHASE 2: Discover User-Only AppX Packages"
# ===========================================================================

Write-Step "Loading provisioned (all-user) packages..."
try {
    $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction Stop
    $provisionedNames    = $provisionedPackages | Select-Object -ExpandProperty DisplayName
    Write-OK "Found $($provisionedPackages.Count) provisioned packages"
} catch {
    Write-Fail "Failed to query provisioned packages: $($_.Exception.Message)"
    $provisionedNames    = @()
    $provisionedPackages = @()
}

# ---- Scan provisioned list directly for sideloaded (non-Microsoft) packages ----
# Sysprep validates the provisioned package store, so we must check it directly.
# A package can be provisioned but still cause sysprep error 0x80073cf2 if it
# was sideloaded (e.g. via Add-AppxProvisionedPackage) and is not a Microsoft
# Store / Windows system component.
#
# The PackageName in the provisioned list contains the publisher hash suffix:
#   e.g. NotepadPlusPlus_1.0.0.0_neutral__2247w0b46hfww
# We extract that hash and compare it against known Microsoft publisher hashes.

Write-Step "Scanning provisioned packages for sideloaded (non-Microsoft) entries..."

$sideloadedProvisioned = @()

foreach ($prov in $provisionedPackages) {
    $pkgName     = $prov.PackageName
    $displayName = $prov.DisplayName

    # Extract publisher hash from PackageName (part after __ or _~_)
    # Standard packages use __ (double underscore), provisioned bundles use _~_
    #   e.g. NotepadPlusPlus_1.0.0.0_neutral__2247w0b46hfww
    #   e.g. MicrosoftCorporationII.QuickAssist_2025.331.2057.0_neutral_~_8wekyb3d8bbwe
    $publisherHash = $null
    if ($pkgName -match '(?:__|_~_)([a-z0-9]+)$') {
        $publisherHash = $Matches[1]
    }

    # Check display name against safe name prefixes
    $isSafeName = $false
    foreach ($prefix in $SafeProvisionedNamePrefixes) {
        if ($displayName -like "$prefix*") {
            $isSafeName = $true
            break
        }
    }

    # Check display name against system package prefixes
    if (-not $isSafeName) {
        foreach ($prefix in $SystemPackagePrefixes) {
            if ($displayName -like "$prefix*") {
                $isSafeName = $true
                break
            }
        }
    }

    # Check publisher hash against known Microsoft hashes
    $isSafePublisher = $false
    if ($publisherHash -and ($SafePublisherIds -contains $publisherHash)) {
        $isSafePublisher = $true
    }

    if (-not $isSafeName -and -not $isSafePublisher) {
        Write-Warn "Sideloaded provisioned package: $displayName"
        Write-Info "  PackageName   : $pkgName"
        Write-Info "  PublisherHash : $publisherHash"
        $sideloadedProvisioned += $prov
    }
}

if ($sideloadedProvisioned.Count -eq 0) {
    Write-OK "No sideloaded provisioned packages found"
} else {
    Write-Warn "$($sideloadedProvisioned.Count) sideloaded provisioned package(s) detected - will be deprovisioned and removed"
}

Write-Step "Loading all installed packages across all users..."
try {
    $allInstalled = Get-AppxPackage -AllUsers -ErrorAction Stop
    Write-OK "Found $($allInstalled.Count) total installed packages"
} catch {
    Write-Fail "Failed to query installed packages: $($_.Exception.Message)"
    $allInstalled = @()
}

Write-Step "Categorising packages..."

$removable   = @()
$sideloaded  = @()   # Provisioned but non-Microsoft - sysprep blockers
$systemApps  = @()
$frameworks  = @()
$provisioned = @()

foreach ($pkg in $allInstalled) {

    # Check if the package appears in the provisioned list
    $isProvisioned = $provisionedNames -contains $pkg.Name

    if ($isProvisioned) {
        # Provisioned packages from Microsoft / Windows are safe to skip.
        # Sideloaded third-party MSIX packages that appear provisioned can
        # still cause sysprep error 0x80073cf2 and must be deprovisioned + removed.
        if (Test-IsSafeProvisionedPackage -Package $pkg) {
            $provisioned += $pkg
            continue
        } else {
            Write-Warn "Sideloaded provisioned package detected: $($pkg.Name)"
            Write-Info "  PublisherId: $($pkg.PublisherId) | Publisher: $($pkg.Publisher)"
            $sideloaded += $pkg
            continue
        }
    }

    # Only consider packages that actually have at least one per-user install
    $userSids = Get-InstalledUserSids -Package $pkg
    if ($userSids.Count -eq 0) { continue }

    if (Test-IsSystemApp -Package $pkg) {
        $systemApps += $pkg
    } elseif (Test-IsFrameworkPackage -Package $pkg) {
        $frameworks += $pkg
    } else {
        $removable += $pkg
    }
}

Write-Host ""
Write-Info "Provisioned (safe)        : $($provisioned.Count)"
Write-Info "Sideloaded (deprovision)  : $($sideloaded.Count)"
Write-Info "System apps (skip)        : $($systemApps.Count)"
Write-Info "Framework packages (skip) : $($frameworks.Count)"
Write-Info "Removable user-only       : $($removable.Count)"

if ($systemApps.Count -gt 0) {
    Write-Host ""
    Write-Warn "The following are protected Windows system components and will be SKIPPED."
    Write-Warn "They cannot be uninstalled via PowerShell and do NOT block sysprep when /mode:vm is used."
    foreach ($pkg in $systemApps) {
        Write-Info "  [SYSTEM] $($pkg.Name)"
        Write-Info "           Full name : $($pkg.PackageFullName)"
        Write-Info "           Location  : $($pkg.InstallLocation)"
    }
}

if ($frameworks.Count -gt 0) {
    Write-Host ""
    Write-Warn "The following are framework (dependency) packages and will be SKIPPED."
    Write-Warn "They are removed automatically when all packages that depend on them are removed."
    foreach ($pkg in $frameworks) {
        Write-Info "  [FRAMEWORK] $($pkg.Name) ($($pkg.PackageFullName))"
    }
}

if ($sideloaded.Count -gt 0) {
    Write-Host ""
    Write-Warn "The following are sideloaded (non-Microsoft) provisioned packages."
    Write-Warn "These WILL be deprovisioned and removed as they block sysprep (error 0x80073cf2)."
    foreach ($pkg in $sideloaded) {
        Write-Info "  [SIDELOADED] $($pkg.Name)  v$($pkg.Version)"
        Write-Info "               Full name  : $($pkg.PackageFullName)"
        Write-Info "               Location   : $($pkg.InstallLocation)"
        Write-Info "               Publisher  : $($pkg.Publisher)"
    }
}

# ---- Deep scan: find packages invisible to PowerShell cmdlets ----
# Sysprep uses AppxSysprep.dll which enumerates the Appx package store via
# internal APIs. Packages can exist in the store but be invisible to
# Get-AppxProvisionedPackage and Get-AppxPackage -AllUsers. We must check:
#   1. DISM /Online /Get-ProvisionedAppxPackages (command-line, may see more)
#   2. Get-AppxPackage (current user only, without -AllUsers)
#   3. AppxAllUserStore registry (the authoritative store sysprep checks)

Write-Step "Deep scan: searching for ghost packages not visible to PowerShell cmdlets..."

$ghostPackages = @()   # array of [PSCustomObject] with .PackageName, .Source

# --- Method 1: DISM enumeration ---
Write-Info "Checking DISM provisioned package list..."
try {
    $dismOutput = & dism.exe /Online /Get-ProvisionedAppxPackages 2>&1
    if ($LASTEXITCODE -eq 0) {
        # Parse DISM output to extract PackageName values
        $dismPackageNames = @()
        foreach ($line in $dismOutput) {
            if ($line -match '^\s*PackageName\s*:\s*(.+)$') {
                $dismPackageNames += $Matches[1].Trim()
            }
        }
        Write-Info "DISM found $($dismPackageNames.Count) provisioned packages"

        # Compare against PowerShell list - any DISM-only packages are ghosts
        $psProvisionedNames = $provisionedPackages | Select-Object -ExpandProperty PackageName

        foreach ($dismPkg in $dismPackageNames) {
            if ($psProvisionedNames -notcontains $dismPkg) {
                # Extract publisher hash
                $pubHash = $null
                if ($dismPkg -match '(?:__|_~_)([a-z0-9]+)$') { $pubHash = $Matches[1] }

                # Extract display name (part before the first underscore+version)
                $dispName = if ($dismPkg -match '^([^_]+)_') { $Matches[1] } else { $dismPkg }

                $isSafe = $false
                foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } }
                if (-not $isSafe) { foreach ($prefix in $SystemPackagePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } } }
                if (-not $isSafe -and $pubHash) { if ($SafePublisherIds -contains $pubHash) { $isSafe = $true } }

                if (-not $isSafe) {
                    Write-Warn "Ghost package found via DISM: $dismPkg"
                    $ghostPackages += [PSCustomObject]@{ PackageName = $dismPkg; DisplayName = $dispName; Source = 'DISM'; PublisherHash = $pubHash; RegistryKeyPath = $null }
                }
            }
        }
    } else {
        Write-Warn "DISM enumeration failed (exit code $LASTEXITCODE)"
    }
} catch {
    Write-Warn "DISM enumeration error: $($_.Exception.Message)"
}

# --- Method 2: Current-user package scan ---
Write-Info "Checking current-user package list..."
try {
    $currentUserPkgs = Get-AppxPackage -ErrorAction Stop  # no -AllUsers = current user only
    foreach ($pkg in $currentUserPkgs) {
        # Check if this package is already known from the AllUsers scan
        $alreadyKnown = $allInstalled | Where-Object { $_.PackageFullName -eq $pkg.PackageFullName }
        if (-not $alreadyKnown) {
            # Check if safe
            $isSafe = $false
            foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($pkg.Name -like "$prefix*") { $isSafe = $true; break } }
            if (-not $isSafe) { foreach ($prefix in $SystemPackagePrefixes) { if ($pkg.Name -like "$prefix*") { $isSafe = $true; break } } }
            if (-not $isSafe -and $pkg.PublisherId) { if ($SafePublisherIds -contains $pkg.PublisherId) { $isSafe = $true } }

            if (-not $isSafe) {
                Write-Warn "Ghost package found via current-user scan: $($pkg.PackageFullName)"
                $pubHash = $null
                if ($pkg.PackageFullName -match '(?:__|_~_)([a-z0-9]+)$') { $pubHash = $Matches[1] }
                $ghostPackages += [PSCustomObject]@{ PackageName = $pkg.PackageFullName; DisplayName = $pkg.Name; Source = 'CurrentUser'; PublisherHash = $pubHash; RegistryKeyPath = $null }
            }
        }
    }
} catch {
    Write-Warn "Current-user package scan error: $($_.Exception.Message)"
}

# --- Method 3: Registry scan of AppxAllUserStore ---
# This is the authoritative store that AppxSysprep.dll checks.
# Packages appear as subkeys under:
#   HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Staged
#   HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications
# and per-SID subkeys like S-1-5-21-...
$registryBasePaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Staged',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications'
)

# Also check per-user SID subkeys
$allUserStoreRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
try {
    $sidKeys = Get-ChildItem -Path $allUserStoreRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-\d+-' }
    foreach ($sidKey in $sidKeys) {
        $registryBasePaths += Join-Path $allUserStoreRoot $sidKey.PSChildName
    }
} catch { }

Write-Info "Checking AppxAllUserStore registry ($($registryBasePaths.Count) locations)..."

foreach ($regPath in $registryBasePaths) {
    try {
        if (-not (Test-Path $regPath)) { continue }
        $subkeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
        foreach ($subkey in $subkeys) {
            $regPkgName = $subkey.PSChildName

            # Check for NotepadPlusPlus or any non-Microsoft package
            $pubHash = $null
            if ($regPkgName -match '(?:__|_~_)([a-z0-9]+)$') { $pubHash = $Matches[1] }
            $dispName = if ($regPkgName -match '^([^_]+)_') { $Matches[1] } else { $regPkgName }

            $isSafe = $false
            foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } }
            if (-not $isSafe) { foreach ($prefix in $SystemPackagePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } } }
            if (-not $isSafe -and $pubHash) { if ($SafePublisherIds -contains $pubHash) { $isSafe = $true } }

            if (-not $isSafe) {
                # Avoid duplicates
                $alreadyFound = $ghostPackages | Where-Object { $_.PackageName -eq $regPkgName }
                if (-not $alreadyFound) {
                    # Build the full registry path to this specific package key
                    $fullKeyPath = Join-Path $regPath $regPkgName
                    Write-Warn "Ghost package found in registry: $regPkgName"
                    Write-Info "  Location: $fullKeyPath"
                    $ghostPackages += [PSCustomObject]@{
                        PackageName     = $regPkgName
                        DisplayName     = $dispName
                        Source          = 'Registry'
                        PublisherHash   = $pubHash
                        RegistryKeyPath = $fullKeyPath
                    }
                }
            }
        }
    } catch {
        Write-Warn "Registry scan error at ${regPath}: $($_.Exception.Message)"
    }
}

# --- Method 4: StateRepository database scan ---
# AppxSysprep.dll uses the Windows StateRepository (a SQLite database) as
# its source of truth. Packages can exist here even when invisible to all
# PowerShell cmdlets, DISM, and the registry. This is the authoritative store.
$stateRepoPath = "$env:ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd"
Write-Info "Checking StateRepository database ($stateRepoPath)..."

if (Test-Path $stateRepoPath) {
    try {
        # Helper function to process a StateRepository query result row
        function Add-GhostFromStateRepo {
            param([string]$FullName)
            if (-not $FullName -or $FullName -match '^Error') { return }
            $pubHash = $null
            if ($FullName -match '(?:__|_~_)([a-z0-9]+)$') { $pubHash = $Matches[1] }
            $dispName = if ($FullName -match '^([^_]+)_') { $Matches[1] } else { $FullName }
            # Skip known safe publishers
            if ($pubHash -and ($SafePublisherIds -contains $pubHash)) { return }
            $isSafe = $false
            foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } }
            if (-not $isSafe) { foreach ($prefix in $SystemPackagePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } } }
            if ($isSafe) { return }
            $alreadyFound = $ghostPackages | Where-Object { $_.PackageName -eq $FullName }
            if (-not $alreadyFound) {
                Write-Warn "Ghost package found in StateRepository: $FullName"
                $script:ghostPackages += [PSCustomObject]@{
                    PackageName     = $FullName
                    DisplayName     = $dispName
                    Source          = 'StateRepository'
                    PublisherHash   = $pubHash
                    RegistryKeyPath = $null
                }
            }
        }

        # Targeted query for the known problematic NotepadPlusPlus package
        $targetedQuery = @"
SELECT p.PackageFullName FROM Package p
WHERE p.PackageFullName LIKE '%2247w0b46hfww%'
   OR p.PackageFamilyName LIKE '%2247w0b46hfww%'
   OR p.PackageFullName LIKE '%NotepadPlusPlus%';
"@

        # Broad query for any non-Microsoft, non-inbox packages
        $broadQuery = @"
SELECT DISTINCT p.PackageFullName FROM Package p
WHERE p.PackageFullName NOT LIKE 'Microsoft%'
  AND p.PackageFullName NOT LIKE 'MicrosoftWindows%'
  AND p.PackageFullName NOT LIKE 'MicrosoftCorporationII%'
  AND p.PackageFullName NOT LIKE 'Clipchamp%'
  AND p.PackageFullName NOT LIKE 'windows%'
  AND p.PackageFullName NOT LIKE 'Windows%'
  AND p.PackageFullName NOT LIKE '1527c705%'
  AND p.PackageFullName NOT LIKE 'c5e2524a%'
  AND p.PackageFullName NOT LIKE 'E2A4F912%'
  AND p.PackageFullName NOT LIKE 'F46D4000%'
  AND p.IsInbox = 0;
"@

        # Copy the database to avoid locking issues with the StateRepository service
        $tempDb = Join-Path $env:TEMP "StateRepo-scan-$(Get-Random).srd"
        Copy-Item -Path $stateRepoPath -Destination $tempDb -Force -ErrorAction Stop

        $queryExecuted = $false
        try {
            # Attempt 1: sqlite3.exe (might be on PATH or in System32)
            $sqlite3Path = $null
            if (Get-Command 'sqlite3.exe' -ErrorAction SilentlyContinue) {
                $sqlite3Path = (Get-Command 'sqlite3.exe').Source
            } elseif (Test-Path "$env:SystemRoot\System32\sqlite3.exe") {
                $sqlite3Path = "$env:SystemRoot\System32\sqlite3.exe"
            }

            if ($sqlite3Path) {
                Write-Info "Using sqlite3.exe to query StateRepository..."
                foreach ($row in (& $sqlite3Path $tempDb $targetedQuery 2>&1)) {
                    if ($row -and $row.Trim()) { Add-GhostFromStateRepo -FullName ($row -split '\|')[0].Trim() }
                }
                foreach ($row in (& $sqlite3Path $tempDb $broadQuery 2>&1)) {
                    if ($row -and $row.Trim()) { Add-GhostFromStateRepo -FullName ($row -split '\|')[0].Trim() }
                }
                $queryExecuted = $true
            }

            # Attempt 2: winsqlite3.dll via P/Invoke - available on every Win10/11 install
            if (-not $queryExecuted) {
                Write-Info "sqlite3.exe not found - using winsqlite3.dll P/Invoke..."
                $winsqlitePath = "$env:SystemRoot\System32\winsqlite3.dll"
                if (Test-Path $winsqlitePath) {
                    # Define P/Invoke signatures for winsqlite3
                    if (-not ([System.Management.Automation.PSTypeName]'WinSqlite3').Type) {
                        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinSqlite3 {
    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_open_v2", CallingConvention=CallingConvention.Cdecl)]
    public static extern int Open(string filename, out IntPtr db, int flags, IntPtr vfs);

    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_prepare_v2", CallingConvention=CallingConvention.Cdecl)]
    public static extern int Prepare(IntPtr db, string sql, int nByte, out IntPtr stmt, IntPtr tail);

    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_step", CallingConvention=CallingConvention.Cdecl)]
    public static extern int Step(IntPtr stmt);

    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_text", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr ColumnText(IntPtr stmt, int col);

    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_finalize", CallingConvention=CallingConvention.Cdecl)]
    public static extern int Finalize(IntPtr stmt);

    [DllImport("winsqlite3.dll", EntryPoint="sqlite3_close", CallingConvention=CallingConvention.Cdecl)]
    public static extern int Close(IntPtr db);

    public const int SQLITE_OK = 0;
    public const int SQLITE_ROW = 100;
    public const int SQLITE_OPEN_READONLY = 1;
}
"@
                    }

                    $dbHandle = [IntPtr]::Zero
                    $rc = [WinSqlite3]::Open($tempDb, [ref]$dbHandle, [WinSqlite3]::SQLITE_OPEN_READONLY, [IntPtr]::Zero)
                    if ($rc -eq [WinSqlite3]::SQLITE_OK -and $dbHandle -ne [IntPtr]::Zero) {
                        try {
                            foreach ($query in @($targetedQuery, $broadQuery)) {
                                $stmtHandle = [IntPtr]::Zero
                                $rc = [WinSqlite3]::Prepare($dbHandle, $query, -1, [ref]$stmtHandle, [IntPtr]::Zero)
                                if ($rc -eq [WinSqlite3]::SQLITE_OK -and $stmtHandle -ne [IntPtr]::Zero) {
                                    while ([WinSqlite3]::Step($stmtHandle) -eq [WinSqlite3]::SQLITE_ROW) {
                                        $textPtr = [WinSqlite3]::ColumnText($stmtHandle, 0)
                                        if ($textPtr -ne [IntPtr]::Zero) {
                                            $fullName = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($textPtr)
                                            Add-GhostFromStateRepo -FullName $fullName
                                        }
                                    }
                                    [WinSqlite3]::Finalize($stmtHandle) | Out-Null
                                }
                            }
                            $queryExecuted = $true
                        } finally {
                            [WinSqlite3]::Close($dbHandle) | Out-Null
                        }
                    } else {
                        Write-Warn "winsqlite3.dll: failed to open database (rc=$rc)"
                    }
                } else {
                    Write-Warn "winsqlite3.dll not found at $winsqlitePath"
                }
            }

            if (-not $queryExecuted) {
                Write-Warn "StateRepository scan: no SQLite method available - skipping"
            }
        } finally {
            Remove-Item -Path $tempDb -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warn "StateRepository scan error: $($_.Exception.Message)"
    }
} else {
    Write-Info "StateRepository database not found at expected path"
}

# --- Method 5: PackageManager COM API ---
# The Windows.Management.Deployment.PackageManager API is what AppxSysprep.dll
# uses internally. Query it directly for a complete view of all packages.
Write-Info "Checking PackageManager API..."
try {
    $packageManager = [Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]::new()
    # FindPackages() returns all packages for all users
    $allManagedPkgs = $packageManager.FindPackages()
    $nonMsPackages  = @()

    foreach ($mp in $allManagedPkgs) {
        $mpFullName = $mp.Id.FullName
        $mpName     = $mp.Id.Name
        $mpPubId    = $mp.Id.PublisherId

        # Check if safe
        $isSafe = $false
        if ($mpPubId -and ($SafePublisherIds -contains $mpPubId)) { $isSafe = $true }
        if (-not $isSafe) {
            foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($mpName -like "$prefix*") { $isSafe = $true; break } }
        }
        if (-not $isSafe) {
            foreach ($prefix in $SystemPackagePrefixes) { if ($mpName -like "$prefix*") { $isSafe = $true; break } }
        }
        # Skip framework packages
        if (-not $isSafe -and $mp.IsFramework) { $isSafe = $true }

        if (-not $isSafe) {
            $nonMsPackages += $mp
        }
    }

    if ($nonMsPackages.Count -gt 0) {
        foreach ($nmp in $nonMsPackages) {
            $fullName = $nmp.Id.FullName
            $alreadyFound = $ghostPackages | Where-Object { $_.PackageName -eq $fullName }
            if (-not $alreadyFound) {
                Write-Warn "Ghost package found via PackageManager API: $fullName"
                Write-Info "  Publisher: $($nmp.Id.Publisher) | PublisherId: $($nmp.Id.PublisherId)"
                $pubHash = $nmp.Id.PublisherId
                $ghostPackages += [PSCustomObject]@{
                    PackageName     = $fullName
                    DisplayName     = $nmp.Id.Name
                    Source          = 'PackageManager'
                    PublisherHash   = $pubHash
                    RegistryKeyPath = $null
                }
            }
        }
    } else {
        Write-Info "PackageManager API: no non-Microsoft packages found"
    }
} catch {
    Write-Info "PackageManager API not available or failed: $($_.Exception.Message)"
}

if ($ghostPackages.Count -eq 0) {
    Write-OK "No ghost packages found"
} else {
    Write-Warn "$($ghostPackages.Count) ghost package(s) found that are invisible to standard PowerShell cmdlets:"
    foreach ($gp in $ghostPackages) {
        Write-Info "  [$($gp.Source)] $($gp.PackageName)  (publisher: $($gp.PublisherHash))"
    }
}

if ($removable.Count -eq 0 -and $sideloaded.Count -eq 0 -and $sideloadedProvisioned.Count -eq 0 -and $ghostPackages.Count -eq 0) {
    Write-Host ""
    Write-OK "No removable or sideloaded packages found"
} else {
    if ($removable.Count -gt 0) {
        Write-Host ""
        Write-Warn "The following user-only packages WILL be removed:"
        foreach ($pkg in $removable) {
            $userSids = Get-InstalledUserSids -Package $pkg
            Write-Info "  [REMOVE] $($pkg.Name)  v$($pkg.Version)"
            Write-Info "           Full name : $($pkg.PackageFullName)"
            Write-Info "           Location  : $($pkg.InstallLocation)"
            Write-Info "           User SIDs : $($userSids -join ', ')"
        }
    }
}

# ===========================================================================
Write-Section "PHASE 3: Remove Sideloaded and User-Only Packages"
# ===========================================================================

$successCount = 0
$failCount    = 0

# --- Step 0: Remove ghost packages (invisible to PowerShell cmdlets) --------
# These packages were found via DISM, current-user scan, or registry scan.
# Sysprep's AppxSysprep.dll sees them even though PowerShell cmdlets don't.

if ($ghostPackages.Count -gt 0) {
    Write-Step "Removing $($ghostPackages.Count) ghost package(s)..."

    foreach ($gp in $ghostPackages) {
        Write-Step "Removing ghost package: $($gp.PackageName)  (found via: $($gp.Source))"
        $ghostRemoved = $false

        # Try 1: DISM deprovision (works if package is in provisioned store)
        Write-Info "Attempting DISM deprovision..."
        try {
            if ($WhatIf) {
                Write-Warn "[WhatIf] Would DISM /Online /Remove-ProvisionedAppxPackage /PackageName:$($gp.PackageName)"
            } else {
                $dismResult = & dism.exe /Online /Remove-ProvisionedAppxPackage /PackageName:$($gp.PackageName) 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-OK "DISM deprovisioned: $($gp.PackageName)"
                    $ghostRemoved = $true
                } else {
                    Write-Info "DISM deprovision exit code $LASTEXITCODE (may not be provisioned)"
                }
            }
        } catch {
            Write-Info "DISM deprovision error: $($_.Exception.Message)"
        }

        # Try 2: Remove-AppxPackage for current user (no -AllUsers)
        Write-Info "Attempting current-user Remove-AppxPackage..."
        try {
            if ($WhatIf) {
                Write-Warn "[WhatIf] Would Remove-AppxPackage -Package $($gp.PackageName)"
            } else {
                Remove-AppxPackage -Package $gp.PackageName -ErrorAction Stop
                Write-OK "Removed from current user: $($gp.PackageName)"
                $ghostRemoved = $true
            }
        } catch {
            Write-Info "Current-user removal: $($_.Exception.Message)"
        }

        # Try 3: Remove-AppxPackage -AllUsers
        Write-Info "Attempting AllUsers Remove-AppxPackage..."
        try {
            if ($WhatIf) {
                Write-Warn "[WhatIf] Would Remove-AppxPackage -AllUsers -Package $($gp.PackageName)"
            } else {
                Remove-AppxPackage -Package $gp.PackageName -AllUsers -ErrorAction Stop
                Write-OK "Removed (AllUsers): $($gp.PackageName)"
                $ghostRemoved = $true
            }
        } catch {
            Write-Info "AllUsers removal: $($_.Exception.Message)"
        }

        # Try 4: PackageManager API removal
        # Use the same WinRT API that AppxSysprep.dll uses internally.
        if (-not $ghostRemoved) {
            Write-Info "Attempting removal via PackageManager API..."
            try {
                $pm = [Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]::new()
                $matchingPkgs = $pm.FindPackages() | Where-Object { $_.Id.FullName -eq $gp.PackageName -or $_.Id.Name -eq $gp.DisplayName }
                foreach ($mpkg in $matchingPkgs) {
                    Write-Info "Found via PackageManager: $($mpkg.Id.FullName)"
                    if (-not $WhatIf) {
                        $removeOp = $pm.RemovePackageAsync($mpkg.Id.FullName, [Windows.Management.Deployment.RemovalOptions]::RemoveForAllUsers)
                        # Wait for async operation
                        $null = [Windows.Foundation.IAsyncInfo].GetMethod('get_Status')
                        $timeout = [DateTime]::Now.AddSeconds(60)
                        while ($removeOp.Status -eq 0 -and [DateTime]::Now -lt $timeout) {
                            Start-Sleep -Milliseconds 500
                        }
                        if ($removeOp.Status -eq 1) {
                            Write-OK "Removed via PackageManager API: $($mpkg.Id.FullName)"
                            $ghostRemoved = $true
                        } else {
                            $errorText = if ($removeOp.ErrorCode) { $removeOp.ErrorCode.Message } else { "Status: $($removeOp.Status)" }
                            Write-Warn "PackageManager removal result: $errorText"
                        }
                    } else {
                        Write-Warn "[WhatIf] Would remove via PackageManager API: $($mpkg.Id.FullName)"
                    }
                }
            } catch {
                Write-Info "PackageManager API removal failed: $($_.Exception.Message)"
            }
        }

        # Try 5: Broad registry cleanup - ALWAYS run for ALL ghost sources
        # Even if previous methods succeeded, stale registry entries may persist.
        # AppxSysprep.dll checks these keys; removing them is critical.
        Write-Info "Performing broad registry cleanup for $($gp.PackageName)..."

        # First: remove the exact key path we found during scanning (if any)
        if ($gp.RegistryKeyPath -and (Test-Path $gp.RegistryKeyPath)) {
            try {
                if ($WhatIf) {
                    Write-Warn "[WhatIf] Would Remove-Item -Recurse $($gp.RegistryKeyPath)"
                } else {
                    Remove-Item -Path $gp.RegistryKeyPath -Recurse -Force -ErrorAction Stop
                    Write-OK "Removed stored registry key: $($gp.RegistryKeyPath)"
                    $ghostRemoved = $true
                }
            } catch {
                Write-Fail "Registry removal failed for stored path: $($_.Exception.Message)"
            }
        }

        # Second: broad scan - remove ALL occurrences across Staged, Applications, and per-SID
        $regCleanupRoots = @(
            (Join-Path $allUserStoreRoot 'Staged'),
            (Join-Path $allUserStoreRoot 'Applications')
        )
        try {
            $cleanupSidKeys = Get-ChildItem -Path $allUserStoreRoot -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^S-\d+-' }
            foreach ($csk in $cleanupSidKeys) {
                $regCleanupRoots += Join-Path $allUserStoreRoot $csk.PSChildName
            }
        } catch { }

        foreach ($rp in $regCleanupRoots) {
            $targetKey = Join-Path $rp $gp.PackageName
            if (Test-Path $targetKey) {
                try {
                    if ($WhatIf) {
                        Write-Warn "[WhatIf] Would Remove-Item -Recurse $targetKey"
                    } else {
                        Remove-Item -Path $targetKey -Recurse -Force -ErrorAction Stop
                        Write-OK "Removed registry key: $targetKey"
                        $ghostRemoved = $true
                    }
                } catch {
                    Write-Fail "Registry cleanup failed: $($_.Exception.Message)"
                }
            }
        }

        # Try 6: StateRepository database cleanup
        # The StateRepository-Machine.srd SQLite database is the ultimate source of truth
        # that AppxSysprep.dll queries. If the package exists there, sysprep will fail.
        if (-not $ghostRemoved) {
            $srdPath = "$env:ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd"
            if (Test-Path $srdPath) {
                Write-Info "Attempting StateRepository database cleanup..."
                try {
                    # Stop the StateRepository service to unlock the database
                    $svc = Get-Service -Name 'StateRepository' -ErrorAction SilentlyContinue
                    $svcWasRunning = $svc -and $svc.Status -eq 'Running'
                    if ($svcWasRunning) {
                        Stop-Service -Name 'StateRepository' -Force -ErrorAction Stop
                        Start-Sleep -Seconds 2
                    }
                    try {
                        $deleteCmd = "DELETE FROM Package WHERE PackageFullName = '$($gp.PackageName)';"
                        if ($WhatIf) {
                            Write-Warn "[WhatIf] Would execute: $deleteCmd"
                        } else {
                            $deleted = $false

                            # Attempt 1: sqlite3.exe
                            $sqlite3 = (Get-Command sqlite3.exe -ErrorAction SilentlyContinue).Source
                            if (-not $sqlite3 -and (Test-Path "$env:SystemRoot\System32\sqlite3.exe")) {
                                $sqlite3 = "$env:SystemRoot\System32\sqlite3.exe"
                            }
                            if ($sqlite3) {
                                $result = & $sqlite3 $srdPath $deleteCmd 2>&1
                                if ($LASTEXITCODE -eq 0) {
                                    Write-OK "Deleted from StateRepository (sqlite3.exe): $($gp.PackageName)"
                                    $ghostRemoved = $true; $deleted = $true
                                } else {
                                    Write-Warn "sqlite3 delete result: $result"
                                }
                            }

                            # Attempt 2: winsqlite3.dll P/Invoke
                            if (-not $deleted -and ([System.Management.Automation.PSTypeName]'WinSqlite3').Type) {
                                $dbHandle = [IntPtr]::Zero
                                # Open read-write (flags=2 = SQLITE_OPEN_READWRITE)
                                $rc = [WinSqlite3]::Open($srdPath, [ref]$dbHandle, 2, [IntPtr]::Zero)
                                if ($rc -eq 0 -and $dbHandle -ne [IntPtr]::Zero) {
                                    try {
                                        $stmtHandle = [IntPtr]::Zero
                                        $rc = [WinSqlite3]::Prepare($dbHandle, $deleteCmd, -1, [ref]$stmtHandle, [IntPtr]::Zero)
                                        if ($rc -eq 0 -and $stmtHandle -ne [IntPtr]::Zero) {
                                            $rc = [WinSqlite3]::Step($stmtHandle)
                                            [WinSqlite3]::Finalize($stmtHandle) | Out-Null
                                            # SQLITE_DONE = 101
                                            if ($rc -eq 101 -or $rc -eq 0) {
                                                Write-OK "Deleted from StateRepository (winsqlite3): $($gp.PackageName)"
                                                $ghostRemoved = $true; $deleted = $true
                                            } else {
                                                Write-Warn "winsqlite3 delete step returned: $rc"
                                            }
                                        }
                                    } finally {
                                        [WinSqlite3]::Close($dbHandle) | Out-Null
                                    }
                                }
                            }

                            if (-not $deleted) {
                                Write-Warn "No SQLite method available to delete from StateRepository"
                            }
                        }
                    } finally {
                        # Restart the service
                        if ($svcWasRunning) {
                            Start-Service -Name 'StateRepository' -ErrorAction SilentlyContinue
                        }
                    }
                } catch {
                    Write-Info "StateRepository cleanup failed: $($_.Exception.Message)"
                    # Ensure service is restarted
                    Start-Service -Name 'StateRepository' -ErrorAction SilentlyContinue
                }
            }
        }

        if ($ghostRemoved) {
            $successCount++
        } else {
            $failCount++
            $remediationOK = $false
        }
    }
}

# --- Step 1: Deprovision and remove sideloaded provisioned packages --------
# These were detected directly from the provisioned package list. They may not
# appear in Get-AppxPackage at all, but sysprep still rejects them.

if ($sideloadedProvisioned.Count -gt 0) {
    Write-Step "Deprovisioning $($sideloadedProvisioned.Count) sideloaded provisioned package(s)..."

    foreach ($prov in $sideloadedProvisioned) {
        Write-Step "Deprovisioning: $($prov.DisplayName)  ($($prov.PackageName))"
        $deprovOK = $false

        # Try Remove-AppxProvisionedPackage first
        try {
            if ($WhatIf) {
                Write-Warn "[WhatIf] Would Remove-AppxProvisionedPackage -PackageName $($prov.PackageName)"
            } else {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            }
            Write-OK "Deprovisioned: $($prov.PackageName)"
            $deprovOK = $true
        } catch {
            Write-Warn "PowerShell deprovision failed: $($_.Exception.Message)"
        }

        # DISM fallback
        if (-not $deprovOK) {
            Write-Info "Trying DISM deprovision..."
            try {
                if ($WhatIf) {
                    Write-Warn "[WhatIf] Would DISM /Online /Remove-ProvisionedAppxPackage /PackageName:$($prov.PackageName)"
                } else {
                    $dismResult = & dism.exe /Online /Remove-ProvisionedAppxPackage /PackageName:$($prov.PackageName) 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-OK "DISM deprovisioned: $($prov.PackageName)"
                        $deprovOK = $true
                    } else {
                        Write-Warn "DISM deprovision failed (exit code $LASTEXITCODE): $($dismResult -join ' ')"
                    }
                }
            } catch {
                Write-Warn "DISM deprovision also failed: $($_.Exception.Message)"
            }
        }

        # Also try to remove the installed package (if it exists in the installed list)
        $installedMatch = $allInstalled | Where-Object {
            $_.Name -eq $prov.DisplayName -or $_.PackageFullName -eq $prov.PackageName
        }
        if ($installedMatch) {
            foreach ($instPkg in $installedMatch) {
                Write-Info "Also removing installed instance: $($instPkg.PackageFullName)"
                try {
                    if (-not $WhatIf) {
                        Remove-AppxPackage -Package $instPkg.PackageFullName -AllUsers -ErrorAction Stop
                    }
                    Write-OK "Removed installed package: $($instPkg.PackageFullName)"
                } catch {
                    Write-Warn "Installed package removal failed (may already be gone): $($_.Exception.Message)"
                }
            }
        }

        if ($deprovOK) {
            $successCount++
        } else {
            $failCount++
            $remediationOK = $false
        }
    }
}

# --- Step 2: Process packages detected from Get-AppxPackage ----------------
# These are packages found via Get-AppxPackage -AllUsers that are either
# sideloaded (provisioned but non-Microsoft) or user-only (not provisioned).

$allToRemove = @()
if ($sideloaded.Count -gt 0)  { $allToRemove += $sideloaded }
if ($removable.Count -gt 0)   { $allToRemove += $removable }

if ($allToRemove.Count -eq 0 -and $sideloadedProvisioned.Count -eq 0) {
    Write-OK "Nothing to remove - skipping phase"
} elseif ($allToRemove.Count -eq 0) {
    Write-OK "No additional installed packages to remove"
} else {

    foreach ($pkg in $allToRemove) {
        $isSideloaded = $sideloaded -contains $pkg
        $label        = if ($isSideloaded) { "SIDELOADED" } else { "USER-ONLY" }
        Write-Step "Removing [$label]: $($pkg.Name)  ($($pkg.PackageFullName))"
        $removed = $false

        # For sideloaded packages: deprovision FIRST, then remove
        if ($isSideloaded) {
            $provisionedMatch = $provisionedPackages | Where-Object {
                $_.DisplayName -eq $pkg.Name -or $_.PackageName -eq $pkg.PackageFullName
            }

            if ($provisionedMatch) {
                foreach ($prov in $provisionedMatch) {
                    Write-Info "Deprovisioning: $($prov.PackageName)"
                    try {
                        if ($WhatIf) {
                            Write-Warn "[WhatIf] Would Remove-AppxProvisionedPackage -PackageName $($prov.PackageName)"
                        } else {
                            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                        }
                        Write-OK "Deprovisioned: $($prov.PackageName)"
                    } catch {
                        Write-Warn "Deprovision via PowerShell failed: $($_.Exception.Message)"
                        # Try DISM as fallback for deprovisioning
                        Write-Info "Trying DISM deprovision..."
                        try {
                            if (-not $WhatIf) {
                                $dismResult = & dism.exe /Online /Remove-ProvisionedAppxPackage /PackageName:$($prov.PackageName) 2>&1
                                if ($LASTEXITCODE -eq 0) {
                                    Write-OK "DISM deprovisioned: $($prov.PackageName)"
                                } else {
                                    Write-Warn "DISM deprovision failed (exit code $LASTEXITCODE): $($dismResult -join ' ')"
                                }
                            } else {
                                Write-Warn "[WhatIf] Would DISM /Online /Remove-ProvisionedAppxPackage /PackageName:$($prov.PackageName)"
                            }
                        } catch {
                            Write-Warn "DISM deprovision also failed: $($_.Exception.Message)"
                        }
                    }
                }
            } else {
                Write-Info "Package not found in provisioned list by name - may already be deprovisioned"
            }
        }

        # Attempt 1: AllUsers removal (fastest, works for most packages)
        if (-not $removed) {
            try {
                if ($WhatIf) {
                    Write-Warn "[WhatIf] Would Remove-AppxPackage -AllUsers $($pkg.PackageFullName)"
                } else {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                }
                Write-OK "Removed successfully (AllUsers)"
                $removed = $true
            } catch {
                Write-Warn "AllUsers removal failed: $($_.Exception.Message)"
            }
        }

        # Attempt 2: Per-user removal using correctly extracted SID strings
        if (-not $removed) {
            $userSids  = Get-InstalledUserSids -Package $pkg
            $perUserOK = $true

            if ($userSids.Count -eq 0) {
                Write-Warn "No valid user SIDs found - cannot attempt per-user removal"
                $perUserOK = $false
            }

            foreach ($sid in $userSids) {
                Write-Info "Attempting removal for SID: $sid"
                try {
                    if ($WhatIf) {
                        Write-Warn "[WhatIf] Would Remove-AppxPackage -User $sid $($pkg.PackageFullName)"
                    } else {
                        Remove-AppxPackage -Package $pkg.PackageFullName -User $sid -ErrorAction Stop
                    }
                    Write-OK "Removed for SID: $sid"
                } catch {
                    Write-Fail "Failed to remove for SID $sid : $($_.Exception.Message)"
                    $perUserOK = $false
                }
            }

            if ($perUserOK -and $userSids.Count -gt 0) {
                $removed = $true
            }
        }

        # Attempt 3 (non-sideloaded only): Deprovision then retry
        # Sideloaded packages were already deprovisioned above.
        if (-not $removed -and -not $isSideloaded) {
            Write-Warn "Standard removal failed - attempting deprovision + remove"

            $provisionedMatch = $provisionedPackages | Where-Object {
                $_.DisplayName -eq $pkg.Name -or $_.PackageName -eq $pkg.PackageFullName
            }

            if ($provisionedMatch) {
                foreach ($prov in $provisionedMatch) {
                    Write-Info "Deprovisioning: $($prov.PackageName)"
                    try {
                        if ($WhatIf) {
                            Write-Warn "[WhatIf] Would Remove-AppxProvisionedPackage -PackageName $($prov.PackageName)"
                        } else {
                            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                        }
                        Write-OK "Deprovisioned: $($prov.PackageName)"
                    } catch {
                        Write-Warn "Deprovision failed: $($_.Exception.Message)"
                    }
                }
            }

            try {
                if ($WhatIf) {
                    Write-Warn "[WhatIf] Would Remove-AppxPackage -AllUsers $($pkg.PackageFullName) (post-deprovision)"
                } else {
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                }
                Write-OK "Removed successfully after deprovisioning (AllUsers)"
                $removed = $true
            } catch {
                Write-Warn "Post-deprovision AllUsers removal failed: $($_.Exception.Message)"
            }
        }

        # Attempt 4: DISM-based removal as a last resort
        if (-not $removed) {
            Write-Warn "PowerShell removal failed - attempting DISM removal"
            try {
                if ($WhatIf) {
                    Write-Warn "[WhatIf] Would DISM /Online /Remove-ProvisionedAppxPackage /PackageName:$($pkg.PackageFullName)"
                } else {
                    $dismResult = & dism.exe /Online /Remove-ProvisionedAppxPackage /PackageName:$($pkg.PackageFullName) 2>&1
                    $dismExitCode = $LASTEXITCODE
                    if ($dismExitCode -eq 0) {
                        Write-OK "DISM deprovisioned: $($pkg.PackageFullName)"
                    } else {
                        Write-Info "DISM output: $($dismResult -join ' ')"
                        Write-Warn "DISM deprovision returned exit code $dismExitCode"
                    }

                    # Retry removal after DISM deprovision
                    Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                    Write-OK "Removed successfully after DISM deprovision"
                    $removed = $true
                }
            } catch {
                Write-Fail "DISM-based removal also failed: $($_.Exception.Message)"
            }
        }

        if ($removed) {
            $successCount++
        } else {
            $failCount++
            $remediationOK = $false
        }
    }

    Write-Host ""
    Write-Info "Removal results: $successCount succeeded, $failCount failed"
}

# ===========================================================================
Write-Section "PHASE 4: Post-Removal Verification"
# ===========================================================================

Write-Step "Re-scanning for remaining problematic packages..."

# Re-query provisioned packages (the list may have changed after deprovisioning)
try {
    $currentProvisioned      = Get-AppxProvisionedPackage -Online -ErrorAction Stop
    $currentProvisionedNames = $currentProvisioned | Select-Object -ExpandProperty DisplayName
} catch {
    Write-Warn "Could not re-query provisioned packages: $($_.Exception.Message)"
    $currentProvisioned      = @()
    $currentProvisionedNames = @()
}

# Check 1: Re-scan the provisioned list for remaining sideloaded packages
$remainingSideloaded = @()
foreach ($prov in $currentProvisioned) {
    $publisherHash = $null
    if ($prov.PackageName -match '(?:__|_~_)([a-z0-9]+)$') {
        $publisherHash = $Matches[1]
    }

    $isSafeName = $false
    foreach ($prefix in $SafeProvisionedNamePrefixes) {
        if ($prov.DisplayName -like "$prefix*") { $isSafeName = $true; break }
    }
    if (-not $isSafeName) {
        foreach ($prefix in $SystemPackagePrefixes) {
            if ($prov.DisplayName -like "$prefix*") { $isSafeName = $true; break }
        }
    }

    $isSafePublisher = $publisherHash -and ($SafePublisherIds -contains $publisherHash)

    if (-not $isSafeName -and -not $isSafePublisher) {
        $remainingSideloaded += $prov
    }
}

if ($remainingSideloaded.Count -gt 0) {
    Write-Fail "$($remainingSideloaded.Count) sideloaded provisioned package(s) still present:"
    foreach ($prov in $remainingSideloaded) {
        Write-Info "  - $($prov.PackageName)"
    }
    $remediationOK = $false
} else {
    Write-OK "No sideloaded provisioned packages remain"
}

# Check 2: Re-scan installed packages for remaining user-only blockers
try {
    $remaining = Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object {
        $pkg         = $_
        $isSystem    = Test-IsSystemApp      -Package $pkg
        $isFramework = Test-IsFrameworkPackage -Package $pkg
        $userSids    = Get-InstalledUserSids -Package $pkg

        # Skip system and framework - they are never removable
        if ($isSystem -or $isFramework) { return $false }

        $isProvisioned = $currentProvisionedNames -contains $pkg.Name
        if ($isProvisioned) {
            # Safe Microsoft provisioned packages are OK
            return -not (Test-IsSafeProvisionedPackage -Package $pkg)
        }

        # Non-provisioned packages with per-user installs are blockers
        return ($userSids.Count -gt 0)
    }

    if ($remaining.Count -eq 0) {
        Write-OK "No problematic installed packages remain"
    } else {
        Write-Fail "$($remaining.Count) sysprep-blocking installed package(s) still present:"
        foreach ($pkg in $remaining) {
            Write-Info "  - $($pkg.PackageFullName)"
        }
        $remediationOK = $false
    }
} catch {
    Write-Warn "Could not verify post-removal state: $($_.Exception.Message)"
}

# Check 3: Re-run DISM enumeration to verify no ghost packages remain
Write-Info "Re-checking DISM provisioned package list..."
try {
    $dismVerify = & dism.exe /Online /Get-ProvisionedAppxPackages 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dismVerifyNames = @()
        foreach ($line in $dismVerify) {
            if ($line -match '^\s*PackageName\s*:\s*(.+)$') {
                $dismVerifyNames += $Matches[1].Trim()
            }
        }
        $remainingGhosts = @()
        foreach ($dpkg in $dismVerifyNames) {
            $pubHash = $null
            if ($dpkg -match '(?:__|_~_)([a-z0-9]+)$') { $pubHash = $Matches[1] }
            $dispName = if ($dpkg -match '^([^_]+)_') { $Matches[1] } else { $dpkg }

            $isSafe = $false
            foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } }
            if (-not $isSafe) { foreach ($prefix in $SystemPackagePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } } }
            if (-not $isSafe -and $pubHash) { if ($SafePublisherIds -contains $pubHash) { $isSafe = $true } }

            if (-not $isSafe) { $remainingGhosts += $dpkg }
        }
        if ($remainingGhosts.Count -gt 0) {
            Write-Fail "$($remainingGhosts.Count) non-Microsoft package(s) still visible in DISM:"
            foreach ($rg in $remainingGhosts) { Write-Info "  - $rg" }
            $remediationOK = $false
        } else {
            Write-OK "DISM verification: no non-Microsoft provisioned packages remain"
        }
    }
} catch {
    Write-Warn "DISM verification error: $($_.Exception.Message)"
}

# Check 4: Re-scan AppxAllUserStore registry for remaining ghost entries
Write-Info "Re-checking AppxAllUserStore registry..."
$remainingRegGhosts = @()
$verifyRegPaths = @(
    (Join-Path $allUserStoreRoot 'Staged'),
    (Join-Path $allUserStoreRoot 'Applications')
)
try {
    $verifySidKeys = Get-ChildItem -Path $allUserStoreRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-\d+-' }
    foreach ($vsk in $verifySidKeys) {
        $verifyRegPaths += Join-Path $allUserStoreRoot $vsk.PSChildName
    }
} catch { }

foreach ($regPath in $verifyRegPaths) {
    try {
        if (-not (Test-Path $regPath)) { continue }
        $subkeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
        foreach ($subkey in $subkeys) {
            $regPkgName = $subkey.PSChildName
            $pubHash = $null
            if ($regPkgName -match '(?:__|_~_)([a-z0-9]+)$') { $pubHash = $Matches[1] }
            $dispName = if ($regPkgName -match '^([^_]+)_') { $Matches[1] } else { $regPkgName }

            $isSafe = $false
            foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } }
            if (-not $isSafe) { foreach ($prefix in $SystemPackagePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } } }
            if (-not $isSafe -and $pubHash) { if ($SafePublisherIds -contains $pubHash) { $isSafe = $true } }

            if (-not $isSafe) { $remainingRegGhosts += "$regPkgName (in $regPath)" }
        }
    } catch { }
}
if ($remainingRegGhosts.Count -gt 0) {
    Write-Fail "$($remainingRegGhosts.Count) non-Microsoft package(s) still in AppxAllUserStore registry:"
    foreach ($rg in $remainingRegGhosts) { Write-Info "  - $rg" }
    $remediationOK = $false
} else {
    Write-OK "Registry verification: no non-Microsoft ghost entries remain"
}

# Check 5: Re-scan StateRepository database for remaining ghost entries
Write-Info "Re-checking StateRepository database..."
$srdPath = "$env:ProgramData\Microsoft\Windows\AppRepository\StateRepository-Machine.srd"
if (Test-Path $srdPath) {
    try {
        $srdCopy = Join-Path $env:TEMP "StateRepo-verify-$(Get-Random).srd"
        Copy-Item -Path $srdPath -Destination $srdCopy -Force -ErrorAction Stop
        try {
            $verifyQuery = "SELECT PackageFullName FROM Package WHERE PackageFullName IS NOT NULL;"
            $allPkgs = @()

            # Try sqlite3.exe first, then winsqlite3.dll P/Invoke
            $sqlite3 = (Get-Command sqlite3.exe -ErrorAction SilentlyContinue).Source
            if (-not $sqlite3 -and (Test-Path "$env:SystemRoot\System32\sqlite3.exe")) {
                $sqlite3 = "$env:SystemRoot\System32\sqlite3.exe"
            }
            if ($sqlite3) {
                $allPkgs = (& $sqlite3 $srdCopy $verifyQuery 2>$null) -split "`n" | Where-Object { $_.Trim() }
            } elseif (([System.Management.Automation.PSTypeName]'WinSqlite3').Type) {
                $dbH = [IntPtr]::Zero
                $rc = [WinSqlite3]::Open($srdCopy, [ref]$dbH, [WinSqlite3]::SQLITE_OPEN_READONLY, [IntPtr]::Zero)
                if ($rc -eq 0 -and $dbH -ne [IntPtr]::Zero) {
                    try {
                        $stH = [IntPtr]::Zero
                        $rc = [WinSqlite3]::Prepare($dbH, $verifyQuery, -1, [ref]$stH, [IntPtr]::Zero)
                        if ($rc -eq 0 -and $stH -ne [IntPtr]::Zero) {
                            while ([WinSqlite3]::Step($stH) -eq [WinSqlite3]::SQLITE_ROW) {
                                $ptr = [WinSqlite3]::ColumnText($stH, 0)
                                if ($ptr -ne [IntPtr]::Zero) {
                                    $allPkgs += [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($ptr)
                                }
                            }
                            [WinSqlite3]::Finalize($stH) | Out-Null
                        }
                    } finally {
                        [WinSqlite3]::Close($dbH) | Out-Null
                    }
                }
            }

            $remainingSrd = @()
            foreach ($pfn in $allPkgs) {
                $pfn = "$pfn".Trim()
                if (-not $pfn) { continue }
                $pubHash = $null
                if ($pfn -match '(?:__|_~_)([a-z0-9]+)$') { $pubHash = $Matches[1] }
                $dispName = if ($pfn -match '^([^_]+)_') { $Matches[1] } else { $pfn }

                $isSafe = $false
                foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } }
                if (-not $isSafe) { foreach ($prefix in $SystemPackagePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } } }
                if (-not $isSafe -and $pubHash) { if ($SafePublisherIds -contains $pubHash) { $isSafe = $true } }

                if (-not $isSafe) { $remainingSrd += $pfn }
            }
            if ($remainingSrd.Count -gt 0) {
                Write-Fail "$($remainingSrd.Count) non-Microsoft package(s) still in StateRepository:"
                foreach ($sp in $remainingSrd) { Write-Info "  - $sp" }
                $remediationOK = $false
            } else {
                Write-OK "StateRepository verification: no non-Microsoft packages remain"
            }
        } finally {
            Remove-Item $srdCopy -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warn "StateRepository verification error: $($_.Exception.Message)"
    }
} else {
    Write-Info "StateRepository verification skipped (database not found)"
}

# Check 6: Re-scan via PackageManager API for remaining ghost entries
Write-Info "Re-checking via PackageManager API..."
try {
    $pm = [Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]::new()
    $remainingPM = @()
    foreach ($pkg in $pm.FindPackages()) {
        $pubHash = $null
        try { $pubHash = $pkg.Id.PublisherId } catch { }
        $dispName = try { $pkg.Id.Name } catch { $pkg.Id.FullName }

        $isSafe = $false
        foreach ($prefix in $SafeProvisionedNamePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } }
        if (-not $isSafe) { foreach ($prefix in $SystemPackagePrefixes) { if ($dispName -like "$prefix*") { $isSafe = $true; break } } }
        if (-not $isSafe -and $pubHash) { if ($SafePublisherIds -contains $pubHash) { $isSafe = $true } }

        if (-not $isSafe) { $remainingPM += $pkg.Id.FullName }
    }
    if ($remainingPM.Count -gt 0) {
        Write-Fail "$($remainingPM.Count) non-Microsoft package(s) still found via PackageManager API:"
        foreach ($pp in $remainingPM) { Write-Info "  - $pp" }
        $remediationOK = $false
    } else {
        Write-OK "PackageManager API verification: no non-Microsoft packages remain"
    }
} catch {
    Write-Warn "PackageManager API verification error: $($_.Exception.Message)"
}

# ===========================================================================
Write-Section "SUMMARY"
# ===========================================================================

Write-Host ""

if ($systemApps.Count -gt 0) {
    Write-Host "  NOTE: $($systemApps.Count) Windows system app(s) were detected but intentionally skipped." -ForegroundColor DarkGray
    Write-Host "        These are protected OS components that cannot be removed via PowerShell." -ForegroundColor DarkGray
    Write-Host "        If sysprep still fails on these, consider using the /mode:vm flag." -ForegroundColor DarkGray
    Write-Host ""
}

if ($remediationOK) {
    Write-Host "  ALL CHECKS PASSED - System is ready for sysprep" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Run:" -ForegroundColor White
    Write-Host "  C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown" -ForegroundColor White
} else {
    Write-Host "  ONE OR MORE ISSUES REMAIN - Resolve all [FAIL] items above before running sysprep." -ForegroundColor Red
}

Write-Host ""