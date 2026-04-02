# Image Capture Automation

Automates the capture of a Windows Azure VM to create an image version in an Azure Compute Gallery.

## What It Does

1. Validates the source VM exists and meets requirements
2. Validates or creates the target Azure Compute Gallery and Image Definition
3. Optionally generalizes the VM (marks it as generalized after Sysprep has been run)
4. Deallocates the VM if needed
5. Creates a new image version in the Azure Compute Gallery

## Prerequisites

- **PowerShell modules**: `Az.Compute`, `Az.Accounts`, `Az.Resources`
- **Sysprep** must be run on the VM **before** executing the script (for generalized images):
  1. Connect to the VM via RDP
  2. Delete `C:\Windows\Panther` if it exists: `rd /s /q C:\Windows\Panther`
  3. Run: `%windir%\system32\sysprep\sysprep.exe /generalize /shutdown`
  4. Wait for the VM to shut down
- CD/DVD-ROM must be enabled on the VM
- BitLocker or other encryption must be disabled

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `SubscriptionId` | Yes | Azure subscription ID where the source VM and gallery reside |
| `ResourceGroupName` | Yes | Resource group containing the source VM |
| `VMName` | Yes | Name of the VM to capture |
| `GalleryName` | Yes | Azure Compute Gallery name |
| `ImageDefinitionName` | Yes | Image definition name within the gallery |
| `GalleryResourceGroupName` | No | Resource group for the gallery (defaults to `ResourceGroupName`) |
| `ImageVersionName` | No | Semantic version (e.g. `1.0.0`); auto-increments if omitted |
| `TargetRegions` | No | Regions for image replication (defaults to gallery location) |
| `ReplicaCount` | No | Replicas per region (default `1`) |
| `OsState` | No | `Generalized` or `Specialized` (default `Generalized`) |
| `SkipGeneralize` | No | Skip the generalization step |
| `DeleteSourceVM` | No | Delete the source VM after successful capture |
| `ExcludeFromLatest` | No | Exclude this version from latest |
| `EndOfLifeDate` | No | End-of-life date (default 1 year from now) |
| `Tags` | No | Hashtable of tags for the image version |
| `LogPath` | No | Log directory (default `$env:TEMP\ImageCapture\Logs`) |
| `Force` | No | Skip confirmation prompts |

## Usage

```powershell
.\ImageCaptureAutomation.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" `
    -ResourceGroupName "rg-avd-images" -VMName "vm-avd-image-builder" `
    -GalleryName "gal_avd_images" -ImageDefinitionName "avd-win11-multisession"
```

With explicit version and multi-region replication:

```powershell
.\ImageCaptureAutomation.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" `
    -ResourceGroupName "rg-avd-images" -VMName "vm-avd-image-builder" `
    -GalleryName "gal_avd_images" -ImageDefinitionName "avd-win11-multisession" `
    -ImageVersionName "1.2.0" -TargetRegions @("westeurope", "northeurope") `
    -ReplicaCount 2 -DeleteSourceVM
```

## References

- [Capture an image of a VM in the portal](https://learn.microsoft.com/en-us/azure/virtual-machines/capture-image-portal)
- [Generalize a VM before capturing an image](https://learn.microsoft.com/en-us/azure/virtual-machines/generalize)