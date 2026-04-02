<#
.SYNOPSIS
  Polls an Azure Image Builder build for completion while tailing the Packer log in real-time.

.DESCRIPTION
  This script is called from the AVD-ImageBuild pipeline after triggering an AIB build.
  It polls the image template's lastRunStatus every 2 minutes and:
  - Discovers the AIB staging file share to tail packer.log (preferred, real-time)
  - Falls back to blob-based customization.log if no file share is found
  - Detects stale logs from previous builds and re-discovers
  - Shows error context when failures are detected in the log

.PARAMETER ImageTemplateName
  The name of the AIB image template resource.

.PARAMETER GalleryResourceGroup
  The resource group containing the image template and gallery.

.PARAMETER MaxWaitMinutes
  Maximum time to wait for the build to complete (default: 600 = 10 hours).

.PARAMETER PollIntervalSeconds
  Seconds between status checks (default: 120).
#>
param(
  [Parameter(Mandatory)][string]$ImageTemplateName,
  [Parameter(Mandatory)][string]$GalleryResourceGroup,
  [int]$MaxWaitMinutes = 600,
  [int]$PollIntervalSeconds = 120
)

$ErrorActionPreference = 'Continue'
$WarningPreference = 'SilentlyContinue'

# -- Live log tailing state --
$stagingSa = $null
$stagingRg = $null
$stagingKey = $null
$logBlobName = $null
$buildStart = $null
$lastLogLineCount = 0
$logCheckInterval = 5        # check log every N poll cycles (= every 10 min with 120s poll)
$pollCount = 0
$elapsed = 0
$discoveryAttempts = 0
$discoveryFallbackThreshold = 6  # after 6 failed attempts (~12 min), skip freshness filter
$galleryRg = $GalleryResourceGroup
# Track blobs confirmed to be from previous builds so we never re-lock onto them
$staleBlobKeys = [System.Collections.Generic.HashSet[string]]::new()
# File share packer log state (more granular, real-time output)
$fileShareSa = $null
$fileShareRg = $null
$fileShareKey = $null
$fileShareName = $null
$fileShareLogPath = $null
$lastFileShareLineCount = 0

# Helper: parse ISO 8601 timestamps reliably regardless of system culture.
function Parse-UtcDate {
  param([string]$DateString)
  if ([string]::IsNullOrWhiteSpace($DateString)) { return $null }
  $dto = [datetimeoffset]::MinValue
  if ([datetimeoffset]::TryParse($DateString, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dto)) {
    return $dto.UtcDateTime
  }
  $parsed = [datetime]::MinValue
  $cleaned = $DateString -replace '[+-]\d{2}:\d{2}$', '' -replace 'Z$', ''
  if ([datetime]::TryParse($cleaned, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
    return $parsed.ToUniversalTime()
  }
  return $null
}

function Discover-StagingStorage {
  param(
    [nullable[datetime]]$BuildStartedAt = $null,
    [bool]$SkipFreshnessFilter = $false,
    [System.Collections.Generic.HashSet[string]]$ExcludeBlobs = $null
  )
  $rgs = az group list --query "[?starts_with(name, 'IT_${galleryRg}_')].name" -o tsv 2>$null
  if ([string]::IsNullOrWhiteSpace($rgs)) {
    Write-Host "    No staging resource groups found matching 'IT_${galleryRg}_*'"
    return $null
  }
  $candidates = [System.Collections.Generic.List[hashtable]]::new()
  foreach ($rg in ($rgs -split "`n" | Where-Object { $_ })) {
    $sas = az storage account list --resource-group $rg --query "[].name" -o tsv 2>$null
    foreach ($sa in ($sas -split "`n" | Where-Object { $_ })) {
      $key = az storage account keys list --account-name $sa --resource-group $rg --query "[0].value" -o tsv 2>$null
      if ([string]::IsNullOrWhiteSpace($key)) { continue }
      $blobJson = az storage blob list --account-name $sa --container-name "packerlogs" --account-key $key `
        --query "[?ends_with(name, 'customization.log')].{name:name, lastModified:properties.lastModified}" -o json 2>$null
      if (-not [string]::IsNullOrWhiteSpace($blobJson) -and $blobJson -ne '[]') {
        $blobs = $blobJson | ConvertFrom-Json
        foreach ($blob in $blobs) {
          $candidates.Add(@{ ResourceGroup = $rg; AccountName = $sa; Key = $key; BlobName = $blob.name.Trim(); LastModified = $blob.lastModified })
        }
      }
    }
  }
  if ($candidates.Count -eq 0) {
    Write-Host "    No customization.log blobs found in any staging storage account"
    return $null
  }

  Write-Host "    Found $($candidates.Count) customization.log blob(s) across staging RGs"

  if ($ExcludeBlobs -and $ExcludeBlobs.Count -gt 0) {
    $before = $candidates.Count
    $candidates = [System.Collections.Generic.List[hashtable]]($candidates | Where-Object {
      -not $ExcludeBlobs.Contains("$($_.AccountName)/$($_.BlobName)")
    })
    if ($before -ne $candidates.Count) {
      Write-Host "    Excluded $($before - $candidates.Count) known-stale blob(s) from previous builds"
    }
    if ($candidates.Count -eq 0) {
      Write-Host "    All blobs are from previous builds -- current build's log has not appeared yet"
      return $null
    }
  }

  if ($null -ne $BuildStartedAt -and -not $SkipFreshnessFilter) {
    $buildStartUtc = $BuildStartedAt.ToUniversalTime()
    Write-Host "    Filtering for blobs modified after build start: $($buildStartUtc.ToString('o'))"
    $fresh = $candidates | Where-Object {
      $parsedDate = Parse-UtcDate $_.LastModified
      if ($null -eq $parsedDate) {
        Write-Host "    [WARN] Could not parse lastModified '$($_.LastModified)' for blob $($_.BlobName) in $($_.AccountName)"
        return $false
      }
      return $parsedDate -gt $buildStartUtc
    }
    if ($fresh) {
      $candidates = $fresh
    } else {
      foreach ($c in $candidates) {
        Write-Host "    [FILTERED] $($c.AccountName)/$($c.BlobName) lastModified=$($c.LastModified)"
      }
      Write-Host "    All $($candidates.Count) blob(s) were older than build start time -- will retry"
      return $null
    }
  } elseif ($SkipFreshnessFilter) {
    Write-Host "    Freshness filter SKIPPED (fallback mode) -- returning newest blob"
  }

  return $candidates | Sort-Object {
    $d = Parse-UtcDate $_.LastModified; if ($d) { $d } else { [datetime]::MinValue }
  } -Descending | Select-Object -First 1
}

function Discover-StagingFileShare {
  param(
    [nullable[datetime]]$BuildStartedAt = $null
  )
  $rgs = az group list --query "[?starts_with(name, 'IT_${galleryRg}_')].name" -o tsv 2>$null
  if ([string]::IsNullOrWhiteSpace($rgs)) { return $null }

  $candidates = [System.Collections.Generic.List[hashtable]]::new()
  foreach ($rg in ($rgs -split "`n" | Where-Object { $_ })) {
    $sas = az storage account list --resource-group $rg --query "[].name" -o tsv 2>$null
    foreach ($sa in ($sas -split "`n" | Where-Object { $_ })) {
      $key = az storage account keys list --account-name $sa --resource-group $rg --query "[0].value" -o tsv 2>$null
      if ([string]::IsNullOrWhiteSpace($key)) { continue }
      $shares = az storage share list --account-name $sa --account-key $key `
        --query "[?starts_with(name, 'vmimagebuilder-staging-fileshare-')].name" -o tsv 2>$null
      foreach ($share in ($shares -split "`n" | Where-Object { $_ })) {
        $fileInfo = az storage file show --account-name $sa --account-key $key `
          --share-name $share --path "packerOutput/packer.log" `
          --query "{size:properties.contentLength, modified:properties.lastModified}" -o json 2>$null
        if (-not [string]::IsNullOrWhiteSpace($fileInfo) -and $fileInfo -ne 'null') {
          $info = $fileInfo | ConvertFrom-Json
          $candidates.Add(@{
            ResourceGroup = $rg; AccountName = $sa; Key = $key
            ShareName = $share; LogPath = "packerOutput/packer.log"
            Size = $info.size; LastModified = $info.modified
          })
        }
      }
    }
  }

  if ($candidates.Count -eq 0) {
    Write-Host "    No file share packer logs found in staging RGs"
    return $null
  }

  Write-Host "    Found $($candidates.Count) file share packer log(s)"

  if ($null -ne $BuildStartedAt) {
    $buildStartUtc = $BuildStartedAt.ToUniversalTime()
    $fresh = $candidates | Where-Object {
      $parsedDate = Parse-UtcDate $_.LastModified
      $null -ne $parsedDate -and $parsedDate -gt $buildStartUtc
    }
    if ($fresh) { $candidates = @($fresh) }
  }

  return $candidates | Sort-Object {
    $d = Parse-UtcDate $_.LastModified; if ($d) { $d } else { [datetime]::MinValue }
  } -Descending | Select-Object -First 1
}

function Format-LogLine {
  param([string]$Line, [string]$Prefix = "    | ")
  if ($Line -match 'ui error:\s*(.+)$') {
    Write-Host "$Prefix[ERROR] $($Matches[1])"
  } elseif ($Line -match 'ui:\s*==> azure-arm:\s*(.+)$') {
    Write-Host "$Prefix$($Matches[1])"
  } elseif ($Line -match 'ui:\s*(.+)$') {
    Write-Host "$Prefix$($Matches[1])"
  } else {
    $cleaned = $Line -replace '^\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+[a-f0-9-]+:\s*', ''
    Write-Host "$Prefix$cleaned"
  }
}

function Show-FileShareLogTail {
  param([hashtable]$Storage, [int]$TailLines = 25, [int]$ErrorContext = 10)
  if (-not $Storage) { return 0 }
  $tempFile = Join-Path $env:TEMP "packer_fileshare_$(Get-Random).log"
  try {
    az storage file download --account-name $Storage.AccountName --account-key $Storage.Key `
      --share-name $Storage.ShareName --path $Storage.LogPath `
      --dest $tempFile --no-progress 2>$null | Out-Null
    if (-not (Test-Path $tempFile)) { return 0 }

    $lines = Get-Content $tempFile
    $totalLines = $lines.Count
    $relevantLines = $lines | Where-Object {
      $_ -match 'ui:|packer-provisioner|PACKER ERR|==> azure-arm:' -and $_ -notmatch '\[DEBUG\]'
    }
    if (-not $relevantLines) { return $totalLines }

    $tailSlice = $relevantLines | Select-Object -Last $TailLines

    $staleMarker = $tailSlice | Where-Object { $_ -match "Build 'azure-arm' (finished|errored)|==> Builds finished but no artifacts" }
    if ($staleMarker) {
      Write-Host "    (file share log is from a previous build -- ignoring)"
      return -1
    }

    $errorPatterns = 'PACKER ERR|ui error:|Provisioning step had errors|provisioner .+ errored|Script exited with non-zero exit status|exit status [1-9]|Upload failed:|Error running source script'
    $relevantArray = @($relevantLines)
    $firstErrorIdx = -1
    for ($i = 0; $i -lt $relevantArray.Count; $i++) {
      if ($relevantArray[$i] -match $errorPatterns) {
        $firstErrorIdx = $i
        break
      }
    }

    if ($firstErrorIdx -ge 0) {
      $errorStart = [Math]::Max(0, $firstErrorIdx - $ErrorContext)
      $errorEnd = [Math]::Min($relevantArray.Count - 1, $firstErrorIdx + $ErrorContext)
      Write-Host "    +--- PACKER LOG: FIRST ERROR (line $($firstErrorIdx + 1) of $($relevantArray.Count)) ---"
      for ($i = $errorStart; $i -le $errorEnd; $i++) {
        $marker = if ($i -eq $firstErrorIdx) { " >> " } else { "    " }
        Format-LogLine -Line $relevantArray[$i] -Prefix "  $marker| "
      }
      Write-Host "    +--- end error context ---"
      Write-Host ""
    }

    Write-Host "    +--- packer.log (file share) tail ($totalLines total lines) ---"
    foreach ($line in $tailSlice) {
      Format-LogLine -Line $line
    }
    Write-Host "    +---"
    return $totalLines
  } catch {
    Write-Host "    (could not tail file share log: $_)"
  } finally {
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue 2>$null
  }
  return 0
}

function Show-LogTail {
  param([hashtable]$Storage, [int]$TailLines = 20, [int]$ErrorContext = 10)
  if (-not $Storage) { return 0 }
  $tempFile = Join-Path $env:TEMP "customization_tail_$(Get-Random).log"
  try {
    az storage blob download --account-name $Storage.AccountName --container-name "packerlogs" `
      --name $Storage.BlobName --file $tempFile --account-key $Storage.Key --no-progress 2>$null | Out-Null
    if (Test-Path $tempFile) {
      $lines = Get-Content $tempFile
      $totalLines = $lines.Count
      $relevantLines = $lines | Where-Object {
        $_ -match 'ui:|packer-provisioner|PACKER ERR|==> azure-arm:' -and $_ -notmatch '\[DEBUG\]'
      }

      if ($relevantLines) {
        $tailSlice = $relevantLines | Select-Object -Last $TailLines

        $staleMarker = $tailSlice | Where-Object { $_ -match "Build 'azure-arm' (finished|errored)|==> Builds finished but no artifacts" }
        if ($staleMarker) {
          Write-Host "    (log is from a previous build -- will re-discover current build's log)"
          return -1
        }

        $errorPatterns = 'PACKER ERR|ui error:|Provisioning step had errors|provisioner .+ errored|Script exited with non-zero exit status|exit status [1-9]|Upload failed:|Error running source script'
        $relevantArray = @($relevantLines)
        $firstErrorIdx = -1
        for ($i = 0; $i -lt $relevantArray.Count; $i++) {
          if ($relevantArray[$i] -match $errorPatterns) {
            $firstErrorIdx = $i
            break
          }
        }

        if ($firstErrorIdx -ge 0) {
          $errorStart = [Math]::Max(0, $firstErrorIdx - $ErrorContext)
          $errorEnd = [Math]::Min($relevantArray.Count - 1, $firstErrorIdx + $ErrorContext)
          Write-Host "    +--- FIRST ERROR DETECTED (relevant line $($firstErrorIdx + 1) of $($relevantArray.Count)) ---"
          for ($i = $errorStart; $i -le $errorEnd; $i++) {
            $marker = if ($i -eq $firstErrorIdx) { " >> " } else { "    " }
            Format-LogLine -Line $relevantArray[$i] -Prefix "  $marker| "
          }
          Write-Host "    +--- end error context ---"
          Write-Host ""
        }

        Write-Host "    +--- customization.log tail ($totalLines lines total) ---"
        foreach ($line in $tailSlice) {
          Format-LogLine -Line $line
        }
        Write-Host "    +---"
      }
      return $totalLines
    }
  } catch {
    Write-Host "    (could not tail log: $_)"
  } finally {
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue 2>$null
  }
  return 0
}

# ── Main polling loop ──────────────────────────────────────────

do {
  Start-Sleep -Seconds $PollIntervalSeconds
  $elapsed += $PollIntervalSeconds
  $pollCount++

  $statusJson = az image builder show `
    --name "$ImageTemplateName" `
    --resource-group "$GalleryResourceGroup" `
    --query "lastRunStatus" -o json 2>$null

  if ([string]::IsNullOrWhiteSpace($statusJson) -or $statusJson -eq 'null') {
    $statusJson = az image builder show `
      --name "$ImageTemplateName" `
      --resource-group "$GalleryResourceGroup" `
      --query "properties.lastRunStatus" -o json 2>$null
  }

  $elapsedMin = [math]::Round($elapsed / 60, 0)
  $elapsedHrs = [math]::Round($elapsed / 3600, 1)

  if ([string]::IsNullOrWhiteSpace($statusJson) -or $statusJson -eq 'null') {
    Write-Host "[$elapsedMin min] Build status: Running (awaiting first status update)"
    continue
  }

  $statusObj = $statusJson | ConvertFrom-Json
  $status = $statusObj.runState
  $substatus = $statusObj.runSubState

  $progressLine = "[$elapsedMin min / ${elapsedHrs}h] Status: $status ($substatus)"
  if ($statusObj.startTime) {
    $parsedStart = Parse-UtcDate $statusObj.startTime
    if ($parsedStart) {
      $buildStart = $parsedStart
      $buildElapsed = (Get-Date).ToUniversalTime() - $buildStart.ToUniversalTime()
      $progressLine += " | Build time: $([math]::Round($buildElapsed.TotalMinutes, 0)) min"
    } else {
      $progressLine += " | Started: $($statusObj.startTime)"
    }
  }
  Write-Host $progressLine

  # -- Discover staging storage (blob -- fallback only when no file share) --
  if (-not $fileShareSa -and (-not $stagingSa -or -not $logBlobName) -and $status -eq 'Running' -and $elapsed -ge 300) {
    $discoveryAttempts++
    $skipFreshness = ($discoveryAttempts -ge $discoveryFallbackThreshold)
    if ($skipFreshness) {
      Write-Host "    Discovering staging storage account (attempt $discoveryAttempts -- freshness filter disabled)..."
    } else {
      Write-Host "    Discovering staging storage account (attempt $discoveryAttempts/$discoveryFallbackThreshold)..."
    }
    $storageInfo = Discover-StagingStorage -BuildStartedAt $buildStart -SkipFreshnessFilter $skipFreshness -ExcludeBlobs $staleBlobKeys
    if ($storageInfo) {
      $stagingSa = $storageInfo.AccountName
      $stagingRg = $storageInfo.ResourceGroup
      $stagingKey = $storageInfo.Key
      $logBlobName = $storageInfo.BlobName
      $lastLogLineCount = 0
      Write-Host "    [OK] Found staging SA: $stagingSa (RG: $stagingRg)"
      Write-Host "    [OK] Log blob: $logBlobName"
    } else {
      Write-Host "    No log blob from this build yet (will retry on next cycle)"
    }
  }

  # -- Discover file share packer log (real-time, more granular than blob) --
  if (-not $fileShareSa -and $status -eq 'Running' -and $elapsed -ge 300) {
    Write-Host "    Discovering file share packer log..."
    $fsInfo = Discover-StagingFileShare -BuildStartedAt $buildStart
    if ($fsInfo) {
      $fileShareSa = $fsInfo.AccountName
      $fileShareRg = $fsInfo.ResourceGroup
      $fileShareKey = $fsInfo.Key
      $fileShareName = $fsInfo.ShareName
      $fileShareLogPath = $fsInfo.LogPath
      $lastFileShareLineCount = 0
      Write-Host "    [OK] Found file share log: $fileShareSa/$fileShareName/$fileShareLogPath"
    }
  }

  # -- Tail the file share packer log (preferred, real-time) --
  if ($fileShareSa -and ($pollCount % $logCheckInterval -eq 0)) {
    $fsHash = @{ AccountName = $fileShareSa; Key = $fileShareKey; ShareName = $fileShareName; LogPath = $fileShareLogPath }
    $fsLineCount = Show-FileShareLogTail -Storage $fsHash -TailLines 20
    if ($fsLineCount -eq -1) {
      Write-Host "    File share log is stale -- clearing reference"
      $fileShareSa = $null
      $lastFileShareLineCount = 0
    } elseif ($fsLineCount -gt 0 -and $fsLineCount -ne $lastFileShareLineCount) {
      $newLines = $fsLineCount - $lastFileShareLineCount
      if ($lastFileShareLineCount -gt 0) {
        Write-Host "    (+$newLines new packer.log lines since last check)"
      }
      $lastFileShareLineCount = $fsLineCount
    }
  }

  # -- Tail the blob customization.log (fallback if file share not found) --
  if (-not $fileShareSa -and $stagingSa -and $logBlobName -and ($pollCount % $logCheckInterval -eq 0)) {
    $storageHash = @{ AccountName = $stagingSa; Key = $stagingKey; BlobName = $logBlobName }
    $currentLineCount = Show-LogTail -Storage $storageHash -TailLines 15
    if ($currentLineCount -eq -1) {
      $staleKey = "$stagingSa/$logBlobName"
      [void]$staleBlobKeys.Add($staleKey)
      Write-Host "    Stale blob '$staleKey' added to exclusion list ($($staleBlobKeys.Count) excluded total)"
      Write-Host "    Clearing stale blob reference. Will re-discover on next cycle."
      $stagingSa = $null
      $stagingRg = $null
      $stagingKey = $null
      $logBlobName = $null
      $lastLogLineCount = 0
    } elseif ($currentLineCount -gt 0 -and $currentLineCount -ne $lastLogLineCount) {
      $newLines = $currentLineCount - $lastLogLineCount
      if ($lastLogLineCount -gt 0) {
        Write-Host "    (+$newLines new log lines since last check)"
      }
      $lastLogLineCount = $currentLineCount
    }
  }

  if ($status -eq "Failed") {
    $message = $statusObj.message
    Write-Host "##vso[task.logissue type=error]AIB build failed: $message"
    exit 1
  }

  if ($status -eq "Canceled") {
    Write-Host "##vso[task.logissue type=error]AIB build was canceled."
    exit 1
  }

} while ($status -ne "Succeeded" -and $elapsed -lt ($MaxWaitMinutes * 60))

if ($status -ne "Succeeded") {
  Write-Host "##vso[task.logissue type=error]AIB build timed out after $MaxWaitMinutes minutes."
  exit 1
}

Write-Host ""
Write-Host "##[section]Image build completed successfully!"
Write-Host "Image Template: $ImageTemplateName"
Write-Host "Total build time: $elapsedMin minutes"
