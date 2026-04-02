<#
.SYNOPSIS
  Retrieves Packer build logs after an AIB failure.

.DESCRIPTION
  Called from the AVD-ImageBuild pipeline when the AIB build task fails.
  Retrieves packer.log (from file share) and/or customization.log (from blob)
  from the AIB staging storage accounts, displays them in the pipeline output,
  and publishes them as pipeline artifacts.

.PARAMETER ImageTemplateName
  The name of the AIB image template resource.

.PARAMETER GalleryResourceGroup
  The resource group containing the image template and gallery.

.PARAMETER SubscriptionName
  The subscription name to set context to for Azure CLI calls.
#>
param(
  [Parameter(Mandatory)][string]$ImageTemplateName,
  [Parameter(Mandatory)][string]$GalleryResourceGroup,
  [Parameter(Mandatory)][string]$SubscriptionName
)

$ErrorActionPreference = 'Continue'
$WarningPreference = 'SilentlyContinue'
$env:AZURE_CORE_COLLECT_TELEMETRY = "false"

az account set --subscription "$SubscriptionName"

$galleryRg = $GalleryResourceGroup
$logFound = $false

# Helper: retrieve a storage account key (the SPN has Contributor which
# grants access to listKeys, but NOT the data-plane RBAC role
# 'Storage Blob Data Reader' that --auth-mode login requires).
function Get-StorageAccountKey {
  param([string]$AccountName, [string]$ResourceGroup)
  az storage account keys list `
    --account-name $AccountName `
    --resource-group $ResourceGroup `
    --query "[0].value" -o tsv 2>$null
}

# Helper: list and download customization.log from a storage account
function Get-PackerLog {
  param([string]$StorageAccount, [string]$StorageRg)

  $key = Get-StorageAccountKey -AccountName $StorageAccount -ResourceGroup $StorageRg
  if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Host "    Could not retrieve storage key for '$StorageAccount'. Trying --auth-mode login as fallback..."
    $authArgs = @('--auth-mode', 'login')
  } else {
    $authArgs = @('--account-key', $key)
  }

  $anyLogFound = $false

  # -- Part A: Check for packer.log on the file share (real-time, most granular) --
  # Note: file share data plane requires an account key (--auth-mode login is NOT
  # supported for Azure Files). Skip Part A if we only have login auth.
  if (-not [string]::IsNullOrWhiteSpace($key)) {
    $shares = az storage share list --account-name $StorageAccount @authArgs `
      --query "[?starts_with(name, 'vmimagebuilder-staging-fileshare-')].name" -o tsv 2>$null
    foreach ($share in ($shares -split "`n" | Where-Object { $_ })) {
      $fileExists = az storage file show --account-name $StorageAccount @authArgs `
        --share-name $share --path "packerOutput/packer.log" `
        --query "properties.contentLength" -o tsv 2>$null
      if (-not [string]::IsNullOrWhiteSpace($fileExists) -and $fileExists -ne '0') {
        Write-Host ""
        Write-Host "##[section]======== packer.log (file share: $StorageAccount/$share) ========"
        Write-Host ""

        $tempFile = Join-Path $env:TEMP "packer_fs_$(Get-Random).log"
        az storage file download --account-name $StorageAccount @authArgs `
          --share-name $share --path "packerOutput/packer.log" `
          --dest $tempFile --no-progress 2>$null | Out-Null

        if (Test-Path $tempFile) {
          $lines = Get-Content $tempFile
          if ($lines.Count -gt 300) {
            Write-Host "... (showing last 300 of $($lines.Count) lines) ..."
            Write-Host ""
            ($lines | Select-Object -Last 300) | ForEach-Object { Write-Host $_ }
          } else {
            $lines | ForEach-Object { Write-Host $_ }
          }

          $artifactDir = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY "packer-logs"
          New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
          Copy-Item $tempFile (Join-Path $artifactDir "packer.log")
          Write-Host ""
          Write-Host "Full packer.log saved to artifact directory."
          Remove-Item $tempFile -Force 2>$null
          $anyLogFound = $true
          break  # one packer.log is enough
        }
      }
    }
  } else {
    Write-Host "    Skipping file share check (account key unavailable; file shares require key auth)"
  }

  # -- Part B: Check for customization.log in blob storage (finalized after build) --

  $blobs = az storage blob list `
    --account-name $StorageAccount `
    --container-name "packerlogs" `
    @authArgs `
    --query "[?ends_with(name, 'customization.log')].name" -o tsv 2>$null

  if ([string]::IsNullOrWhiteSpace($blobs)) {
    Write-Host "    No customization.log found in packerlogs container."
  } else {
    foreach ($blobName in ($blobs -split "`n" | Where-Object { $_ })) {
      Write-Host ""
      Write-Host "##[section]======== customization.log ($StorageAccount/$blobName) ========"
      Write-Host ""

      $tempFile = Join-Path $env:TEMP "customization_$(Get-Random).log"
      az storage blob download `
        --account-name $StorageAccount `
        --container-name "packerlogs" `
        --name $blobName `
        --file $tempFile `
        @authArgs `
        --no-progress 2>$null

      if (Test-Path $tempFile) {
        $content = Get-Content $tempFile -Raw
        $lines = $content -split "`n"
        if ($lines.Count -gt 200) {
          Write-Host "... (showing last 200 of $($lines.Count) lines) ..."
          Write-Host ""
          ($lines | Select-Object -Last 200) | ForEach-Object { Write-Host $_ }
        } else {
          Write-Host $content
        }

        $artifactDir = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY "packer-logs"
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
        Copy-Item $tempFile (Join-Path $artifactDir "customization.log")
        Write-Host "Saved customization.log to artifact directory."

        Remove-Item $tempFile -Force 2>$null
        $anyLogFound = $true
        break  # first customization.log is enough
      } else {
        Write-Host "##vso[task.logissue type=warning]Failed to download customization.log from $StorageAccount"
      }
    }
  }

  # Publish artifact once if any logs were collected
  if ($anyLogFound) {
    $artifactDir = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY "packer-logs"
    if (Test-Path $artifactDir) {
      Write-Host ""
      Write-Host "##vso[artifact.upload artifactname=PackerLogs]$artifactDir"
      $collected = (Get-ChildItem $artifactDir -File).Name -join ', '
      Write-Host "Pipeline artifact published: PackerLogs ($collected)"
    }
  }

  return $anyLogFound
}

Write-Host "##[section]Retrieving Packer build logs for: $ImageTemplateName"

# -- Step 1: Get the lastRunStatus message which contains the staging RG/storage path --
$statusJson = az image builder show `
  --name "$ImageTemplateName" `
  --resource-group "$galleryRg" `
  --query "lastRunStatus" -o json 2>$null

if ([string]::IsNullOrWhiteSpace($statusJson) -or $statusJson -eq 'null') {
  $statusJson = az image builder show `
    --name "$ImageTemplateName" `
    --resource-group "$galleryRg" `
    --query "properties.lastRunStatus" -o json 2>$null
}

$errorMessage = ''
if (-not [string]::IsNullOrWhiteSpace($statusJson) -and $statusJson -ne 'null') {
  $statusObj = $statusJson | ConvertFrom-Json
  $errorMessage = $statusObj.message
  Write-Host "Build status : $($statusObj.runState)"
  Write-Host "Sub-status   : $($statusObj.runSubState)"
  Write-Host "Message      : $errorMessage"
  Write-Host ""
}

# -- Step 2: Try the exact storage account / RG from the AIB error message first --
# The error message contains the full resource ID of the storage account.
# Parse it to attempt a direct download before falling back to a broad scan.
if ($errorMessage -match '/resourceGroups/([^/]+)/providers/Microsoft.Storage/storageAccounts/([^/]+)/') {
  $directRg = $Matches[1]
  $directSa = $Matches[2]
  Write-Host "##[section]Attempting direct download from storage account referenced in error message"
  Write-Host "  Resource Group : $directRg"
  Write-Host "  Storage Account: $directSa"

  # The storage account lives in sub-avd-images-* (may differ from the SPN default subscription)
  if ($errorMessage -match '/subscriptions/([^/]+)/') {
    $storageSub = $Matches[1]
    az account set --subscription $storageSub 2>$null
  }

  $logFound = Get-PackerLog -StorageAccount $directSa -StorageRg $directRg

  # Switch back to the pipeline subscription for the broad scan
  az account set --subscription "$SubscriptionName" 2>$null
}

# -- Step 3: Broad scan of all AIB staging resource groups (fallback) --
if (-not $logFound) {
  Write-Host ""
  Write-Host "##[section]Scanning all AIB staging resource groups..."

  $stagingRgs = az group list `
    --query "[?starts_with(name, 'IT_${galleryRg}_')].name" -o tsv 2>$null

  if ([string]::IsNullOrWhiteSpace($stagingRgs)) {
    Write-Host "##vso[task.logissue type=warning]No AIB staging resource group found matching pattern 'IT_${galleryRg}_*'. It may have been cleaned up already."
    Write-Host "Check the error message above for the full storage path and download manually."
    exit 0
  }

  foreach ($stagingRg in ($stagingRgs -split "`n" | Where-Object { $_ })) {
    if ($logFound) { break }
    Write-Host "##[section]Scanning staging RG: $stagingRg"

    $storageAccounts = az storage account list `
      --resource-group "$stagingRg" `
      --query "[].name" -o tsv 2>$null

    foreach ($sa in ($storageAccounts -split "`n" | Where-Object { $_ })) {
      Write-Host "  Storage account: $sa"
      $logFound = Get-PackerLog -StorageAccount $sa -StorageRg $stagingRg
      if ($logFound) { break }
    }
  }
}

Write-Host ""
if ($logFound) {
  Write-Host "##[section]Troubleshooting complete. Review the log output above for the root cause."
} else {
  Write-Host "##[section]Could not retrieve packer.log or customization.log from any staging storage account."
  Write-Host ""
  Write-Host "Possible reasons:"
  Write-Host "  1. The AIB staging resource group was already cleaned up"
  Write-Host "  2. The log has not been flushed yet (file share or blob)"
  Write-Host "  3. The build failed before Packer started (e.g. ARM deployment error)"
  Write-Host ""
  Write-Host "Manual retrieval options:"
  Write-Host "  - File share: az storage file download --account-name <sa> --account-key <key> --share-name <share> --path packerOutput/packer.log --dest packer.log"
  Write-Host "  - Blob: az storage blob download --account-name <sa> --container-name packerlogs --name <guid>/customization.log --file customization.log --account-key <key>"
}
