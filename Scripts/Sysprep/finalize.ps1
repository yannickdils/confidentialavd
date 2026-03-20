#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Disables BitLocker, then runs Sysprep.

.DESCRIPTION
    This script performs the following:
    1. Detects and disables BitLocker on all encrypted volumes
    2. Waits for full decryption and validates no encryption remains
    3. Runs Sysprep with /oobe /generalize and the specified shutdown mode
    If Sysprep fails, review the Panther logs manually for troubleshooting.

.NOTES
    Author  : Yannick / Tunecom Consulting BV
    Date    : 2026-02-18
    Version : 2.1
    Run as  : Administrator

.PARAMETER DecryptionCheckIntervalSeconds
    How often (in seconds) to poll BitLocker decryption progress. Default: 30

.PARAMETER DecryptionTimeoutMinutes
    Maximum time (in minutes) to wait for BitLocker decryption. Default: 120

.PARAMETER SysprepShutdownMode
    Sysprep shutdown behavior: Shutdown or Reboot. Default: Shutdown

.PARAMETER WhatIf
    Dry-run mode. Shows what would happen without making changes.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$DecryptionCheckIntervalSeconds = 30,

    [Parameter()]
    [int]$DecryptionTimeoutMinutes = 120,

    [Parameter()]
    [ValidateSet("Shutdown", "Reboot")]
    [string]$SysprepShutdownMode = "Shutdown",

    [Parameter()]
    [switch]$WhatIf
)

#region --- Configuration ---

$SysprepPath = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
# Determine log file location: script directory if run as .ps1, otherwise C:\Windows\Temp
$logDir = if ($PSScriptRoot) { $PSScriptRoot } else { "$env:SystemRoot\Temp" }
$ScriptLogFile = Join-Path -Path $logDir -ChildPath "SysprepBitlocker_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

#endregion

#region --- Logging ---

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        "INFO"    = "Cyan"
        "WARN"    = "Yellow"
        "ERROR"   = "Red"
        "SUCCESS" = "Green"
    }

    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage -ForegroundColor $colors[$Level]
    $logMessage | Out-File -FilePath $ScriptLogFile -Append -Encoding UTF8
}

#endregion

#region --- BitLocker Functions ---

function Get-BitLockerEncryptedVolumes {
    try {
        $volumes = Get-BitLockerVolume -ErrorAction Stop
        $encryptedVolumes = $volumes | Where-Object {
            $_.ProtectionStatus -eq "On" -or
            $_.VolumeStatus -ne "FullyDecrypted" -or
            $_.EncryptionPercentage -gt 0
        }
        return $encryptedVolumes
    }
    catch {
        Write-Log "Failed to query BitLocker status: $_" -Level ERROR
        throw
    }
}

function Disable-BitLockerOnVolume {
    param(
        [Parameter(Mandatory)]
        [string]$MountPoint
    )

    $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop

    # Suspend protection first (safe approach)
    if ($volume.ProtectionStatus -eq "On") {
        Write-Log "Suspending BitLocker protection on $MountPoint ..." -Level INFO
        if (-not $WhatIf) {
            Suspend-BitLocker -MountPoint $MountPoint -RebootCount 0 -ErrorAction Stop | Out-Null
        }
        Write-Log "BitLocker protection suspended on $MountPoint" -Level SUCCESS
    }

    # Disable BitLocker (starts decryption)
    if ($volume.VolumeStatus -ne "FullyDecrypted") {
        Write-Log "Disabling BitLocker on $MountPoint (starting decryption) ..." -Level INFO
        if (-not $WhatIf) {
            Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null
        }
        Write-Log "BitLocker disable command issued for $MountPoint - decryption in progress" -Level SUCCESS
    }
    else {
        Write-Log "$MountPoint is already fully decrypted, removing protectors only ..." -Level INFO
        if (-not $WhatIf) {
            Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null
        }
        Write-Log "BitLocker protectors removed from $MountPoint" -Level SUCCESS
    }
}

function Wait-ForDecryptionCompletion {
    $timeoutTime = (Get-Date).AddMinutes($DecryptionTimeoutMinutes)
    Write-Log "Waiting for all volumes to fully decrypt (timeout: $DecryptionTimeoutMinutes minutes) ..." -Level INFO

    while ((Get-Date) -lt $timeoutTime) {
        $volumes = Get-BitLockerVolume -ErrorAction Stop
        $stillDecrypting = $volumes | Where-Object {
            $_.VolumeStatus -eq "DecryptionInProgress" -or
            $_.VolumeStatus -eq "EncryptionInProgress" -or
            $_.EncryptionPercentage -gt 0
        }

        if (-not $stillDecrypting) {
            Write-Log "All volumes are fully decrypted." -Level SUCCESS
            return $true
        }

        foreach ($vol in $stillDecrypting) {
            Write-Log "$($vol.MountPoint) - Status: $($vol.VolumeStatus) | Encrypted: $($vol.EncryptionPercentage)%" -Level WARN
        }

        Write-Log "Checking again in $DecryptionCheckIntervalSeconds seconds ..." -Level INFO
        Start-Sleep -Seconds $DecryptionCheckIntervalSeconds
    }

    Write-Log "TIMEOUT: Decryption did not complete within $DecryptionTimeoutMinutes minutes!" -Level ERROR
    return $false
}

function Confirm-NoBitLockerActive {
    Write-Log "Running final BitLocker validation ..." -Level INFO
    $volumes = Get-BitLockerVolume -ErrorAction Stop
    $issues = @()

    foreach ($vol in $volumes) {
        if ($vol.ProtectionStatus -ne "Off") {
            $issues += "$($vol.MountPoint): Protection is still $($vol.ProtectionStatus)"
        }
        if ($vol.VolumeStatus -ne "FullyDecrypted") {
            $issues += "$($vol.MountPoint): Volume status is $($vol.VolumeStatus)"
        }
        if ($vol.EncryptionPercentage -gt 0) {
            $issues += "$($vol.MountPoint): Encryption percentage is $($vol.EncryptionPercentage)%"
        }
        if ($vol.KeyProtector.Count -gt 0) {
            $issues += "$($vol.MountPoint): $($vol.KeyProtector.Count) key protector(s) still present"
        }
    }

    if ($issues.Count -gt 0) {
        Write-Log "VALIDATION FAILED - BitLocker remnants detected:" -Level ERROR
        foreach ($issue in $issues) {
            Write-Log "  - $issue" -Level ERROR
        }
        return $false
    }

    Write-Log "VALIDATION PASSED - No BitLocker encryption or protection active on any volume." -Level SUCCESS
    return $true
}

#endregion

#region --- Sysprep Functions ---

function Invoke-Sysprep {
    <#
    .SYNOPSIS
        Runs Sysprep with /oobe /generalize and the specified shutdown mode.
        If Sysprep fails, the script exits with an error and logs point to the
        Panther logs for manual troubleshooting.
    #>

    if (-not (Test-Path $SysprepPath)) {
        Write-Log "Sysprep executable not found at $SysprepPath" -Level ERROR
        throw "Sysprep not found"
    }

    $shutdownArg = switch ($SysprepShutdownMode) {
        "Shutdown" { "/shutdown" }
        "Reboot"   { "/reboot" }
    }

    $arguments = "/oobe /generalize $shutdownArg"
    Write-Log "Executing: $SysprepPath $arguments" -Level INFO

    if ($WhatIf) {
        Write-Log "[WhatIf] Would execute sysprep - skipping." -Level WARN
        return
    }

    $process = Start-Process -FilePath $SysprepPath -ArgumentList $arguments -Wait -NoNewWindow -PassThru
    Write-Log "Sysprep.exe exited with code: $($process.ExitCode)" -Level INFO

    if ($process.ExitCode -ne 0) {
        Write-Log "Sysprep failed with exit code $($process.ExitCode)." -Level ERROR
        Write-Log "Check the Panther logs for troubleshooting:" -Level ERROR
        Write-Log "  $env:SystemRoot\System32\Sysprep\Panther\setuperr.log" -Level ERROR
        Write-Log "  $env:SystemRoot\System32\Sysprep\Panther\setupact.log" -Level ERROR
        throw "Sysprep failed with exit code $($process.ExitCode)"
    }

    Write-Log "Sysprep completed successfully. System will $($SysprepShutdownMode.ToLower())." -Level SUCCESS
}

#endregion

#region --- Main Execution ---

try {
    Write-Log "================================================================" -Level INFO
    Write-Log "  BitLocker Disable + Sysprep Script v2.1" -Level INFO
    Write-Log "================================================================" -Level INFO
    Write-Log "Shutdown mode   : $SysprepShutdownMode" -Level INFO
    Write-Log "WhatIf          : $WhatIf" -Level INFO
    Write-Log "Log file        : $ScriptLogFile" -Level INFO
    Write-Log "" -Level INFO

    # ============================
    # PHASE 1: BitLocker
    # ============================
    Write-Log "========== PHASE 1: BitLocker Decryption ==========" -Level INFO

    $encryptedVolumes = Get-BitLockerEncryptedVolumes

    if (-not $encryptedVolumes) {
        Write-Log "No BitLocker-encrypted or protected volumes found." -Level SUCCESS
    }
    else {
        Write-Log "Found $($encryptedVolumes.Count) volume(s) with BitLocker active:" -Level WARN
        foreach ($vol in $encryptedVolumes) {
            Write-Log "  $($vol.MountPoint) - Protection: $($vol.ProtectionStatus) | Status: $($vol.VolumeStatus) | Encrypted: $($vol.EncryptionPercentage)%" -Level WARN
        }

        # Disable BitLocker on each volume
        Write-Log "" -Level INFO
        Write-Log "--- Disabling BitLocker on all volumes ---" -Level INFO
        foreach ($vol in $encryptedVolumes) {
            Disable-BitLockerOnVolume -MountPoint $vol.MountPoint
        }

        # Wait for decryption
        Write-Log "" -Level INFO
        Write-Log "--- Waiting for decryption to complete ---" -Level INFO
        $decryptionComplete = Wait-ForDecryptionCompletion

        if (-not $decryptionComplete) {
            throw "Decryption did not complete within the timeout period. Aborting."
        }
    }

    # Validate BitLocker is fully off
    Write-Log "" -Level INFO
    Write-Log "--- Final BitLocker validation ---" -Level INFO
    $validationPassed = Confirm-NoBitLockerActive

    if (-not $validationPassed) {
        throw "BitLocker validation failed. Cannot proceed with Sysprep."
    }

    # ============================
    # PHASE 2: Sysprep
    # ============================
    Write-Log "" -Level INFO
    Write-Log "========== PHASE 2: Sysprep Execution ==========" -Level INFO

    Invoke-Sysprep

    Write-Log "" -Level INFO
    Write-Log "================================================================" -Level SUCCESS
    Write-Log "  Script completed successfully." -Level SUCCESS
    Write-Log "  System will $($SysprepShutdownMode.ToLower())." -Level SUCCESS
    Write-Log "================================================================" -Level SUCCESS
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}

#endregion