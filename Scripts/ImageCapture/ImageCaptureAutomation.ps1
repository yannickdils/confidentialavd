#Requires -Modules Az.Compute, Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Automates the capture of a Windows Azure VM to create an image in an Azure Compute Gallery.

.DESCRIPTION
    This script automates the process of capturing a Windows VM image in Azure:
    1. Validates the source VM exists and meets requirements
    2. Validates or creates the target Azure Compute Gallery and Image Definition
    3. Optionally generalizes the VM (marks it as generalized after Sysprep has been run)
    4. Deallocates the VM if needed
    5. Creates a new image version in the Azure Compute Gallery

    IMPORTANT: Before running this script, ensure Sysprep has been run on the VM:
    - Connect to the VM via RDP
    - Delete C:\Windows\Panther if it exists: rd /s /q C:\Windows\Panther
    - Run: %windir%\system32\sysprep\sysprep.exe /generalize /shutdown
    - Wait for the VM to shut down

    References:
    - https://learn.microsoft.com/en-us/azure/virtual-machines/capture-image-portal
    - https://learn.microsoft.com/en-us/azure/virtual-machines/generalize

.PARAMETER SubscriptionId
    The Azure subscription ID where the source VM and gallery reside.

.PARAMETER ResourceGroupName
    The resource group name containing the source VM.

.PARAMETER VMName
    The name of the VM to capture.

.PARAMETER GalleryResourceGroupName
    The resource group name for the Azure Compute Gallery. Defaults to ResourceGroupName.

.PARAMETER GalleryName
    The name of the Azure Compute Gallery to store the image.

.PARAMETER ImageDefinitionName
    The name of the image definition within the gallery.

.PARAMETER ImageVersionName
    The version number for the new image (e.g., "1.0.0"). If not specified, auto-increments.

.PARAMETER TargetRegions
    Array of target regions for image replication. Defaults to the gallery's location.

.PARAMETER ReplicaCount
    The number of replicas per region. Defaults to 1.

.PARAMETER OsState
    The OS state for the image: 'Generalized' or 'Specialized'. Defaults to 'Generalized'.

.PARAMETER SkipGeneralize
    Skip the generalization step (use if VM is already generalized or creating specialized image).

.PARAMETER DeleteSourceVM
    Delete the source VM after successful image capture.

.PARAMETER ExcludeFromLatest
    Exclude this image version from being considered as the latest version.

.PARAMETER EndOfLifeDate
    The end of life date for the image version. Defaults to 1 year from now.

.PARAMETER Tags
    Hashtable of tags to apply to the image version.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:TEMP\ImageCapture\Logs.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\ImageCaptureAutomation.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -ResourceGroupName "rg-avd-images" -VMName "vm-avd-image-builder" `
        -GalleryName "gal_avd_images" -ImageDefinitionName "avd-win11-multisession"

.EXAMPLE
    .\ImageCaptureAutomation.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -ResourceGroupName "rg-avd-images" -VMName "vm-avd-image-builder" `
        -GalleryName "gal_avd_images" -ImageDefinitionName "avd-win11-multisession" `
        -ImageVersionName "1.2.0" -TargetRegions @("westeurope", "northeurope") `
        -ReplicaCount 2 -DeleteSourceVM

.NOTES
    Author: Azure Virtual Desktop Team
    Version: 1.0
    Requires: Az PowerShell modules (Az.Compute, Az.Accounts, Az.Resources)
    
    IMPORTANT PREREQUISITES:
    - Sysprep must be run on the VM BEFORE executing this script for generalized images
    - The CD/DVD-ROM must be enabled on the VM
    - BitLocker or other encryption must be disabled
    - Verify server roles are supported by Sysprep
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$GalleryResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GalleryName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ImageDefinitionName,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ImageVersionName,

    [Parameter(Mandatory = $false)]
    [string[]]$TargetRegions,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$ReplicaCount = 1,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Generalized', 'Specialized')]
    [string]$OsState = 'Generalized',

    [Parameter(Mandatory = $false)]
    [switch]$SkipGeneralize,

    [Parameter(Mandatory = $false)]
    [switch]$DeleteSourceVM,

    [Parameter(Mandatory = $false)]
    [switch]$ExcludeFromLatest,

    [Parameter(Mandatory = $false)]
    [datetime]$EndOfLifeDate = (Get-Date).AddYears(1),

    [Parameter(Mandatory = $false)]
    [hashtable]$Tags = @{},

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "$env:TEMP\ImageCapture\Logs",

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

#region Script Configuration
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ScriptVersion = '1.0'
$script:StartTime = Get-Date
$script:LogFile = $null

# Set GalleryResourceGroupName default if not provided
if (-not $GalleryResourceGroupName) {
    $GalleryResourceGroupName = $ResourceGroupName
}
#endregion

#region Logging Functions
function Initialize-Logging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory
    )
    
    try {
        if (-not (Test-Path -Path $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }
        
        $script:LogFile = Join-Path -Path $LogDirectory -ChildPath "ImageCapture_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        
        Write-Log -Message "========================================" -Level 'Info'
        Write-Log -Message "=== Image Capture Automation v$script:ScriptVersion ===" -Level 'Info'
        Write-Log -Message "========================================" -Level 'Info'
        Write-Log -Message "Log file initialized: $script:LogFile" -Level 'Info'
        Write-Log -Message "Computer: $env:COMPUTERNAME" -Level 'Info'
        Write-Log -Message "User: $env:USERNAME" -Level 'Info'
        Write-Log -Message "PowerShell Version: $($PSVersionTable.PSVersion)" -Level 'Info'
        Write-Log -Message "Start Time: $script:StartTime" -Level 'Info'
        
        return $true
    }
    catch {
        Write-Error "Failed to initialize logging: $_"
        return $false
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    if ($script:LogFile -and (Test-Path -Path (Split-Path $script:LogFile -Parent))) {
        Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    
    switch ($Level) {
        'Error'   { Write-Host $logEntry -ForegroundColor Red }
        'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
        'Success' { Write-Host $logEntry -ForegroundColor Green }
        'Debug'   { Write-Host $logEntry -ForegroundColor Cyan }
        default   { Write-Host $logEntry }
    }
}

function Write-LogSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )
    
    Write-Log -Message "" -Level 'Info'
    Write-Log -Message "--- $Title ---" -Level 'Info'
}
#endregion

#region Validation Functions
function Test-AzureConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )
    
    Write-LogSection -Title "Validating Azure Connection"
    
    try {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        
        if (-not $context) {
            Write-Log -Message "Not connected to Azure. Initiating login..." -Level 'Warning'
            Connect-AzAccount -ErrorAction Stop
            $context = Get-AzContext
        }
        
        Write-Log -Message "Connected to Azure as: $($context.Account.Id)" -Level 'Info'
        
        # Set subscription context
        if ($context.Subscription.Id -ne $SubscriptionId) {
            Write-Log -Message "Switching to subscription: $SubscriptionId" -Level 'Info'
            Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        }
        
        Write-Log -Message "Subscription context set successfully" -Level 'Success'
        return $true
    }
    catch {
        Write-Log -Message "Failed to connect to Azure: $_" -Level 'Error'
        return $false
    }
}

function Test-SourceVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory)]
        [string]$VMName,
        
        [Parameter(Mandatory)]
        [string]$OsState
    )
    
    Write-LogSection -Title "Validating Source VM"
    
    try {
        # Check if VM exists
        Write-Log -Message "Checking if VM '$VMName' exists in resource group '$ResourceGroupName'..." -Level 'Info'
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status -ErrorAction Stop
        
        if (-not $vm) {
            Write-Log -Message "VM '$VMName' not found in resource group '$ResourceGroupName'" -Level 'Error'
            return $null
        }
        
        Write-Log -Message "VM found: $($vm.Name)" -Level 'Success'
        
        # Get VM details
        $vmDetails = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
        
        # Validate OS type is Windows
        $osType = $vmDetails.StorageProfile.OsDisk.OsType
        Write-Log -Message "OS Type: $osType" -Level 'Info'
        
        if ($osType -ne 'Windows') {
            Write-Log -Message "This script is designed for Windows VMs. Detected OS: $osType" -Level 'Error'
            return $null
        }
        
        # Check VM power state
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus
        Write-Log -Message "VM Power State: $powerState" -Level 'Info'
        
        # For generalized images, VM should be stopped/deallocated
        if ($OsState -eq 'Generalized' -and $powerState -eq 'VM running') {
            Write-Log -Message "VM is running. For generalized images, the VM should be stopped after running Sysprep." -Level 'Warning'
            Write-Log -Message "Please ensure Sysprep was run with: sysprep.exe /generalize /shutdown" -Level 'Warning'
        }
        
        # Get VM size and location
        Write-Log -Message "VM Size: $($vmDetails.HardwareProfile.VmSize)" -Level 'Info'
        Write-Log -Message "VM Location: $($vmDetails.Location)" -Level 'Info'
        
        # Check if VM has a managed OS disk
        if (-not $vmDetails.StorageProfile.OsDisk.ManagedDisk) {
            Write-Log -Message "VM does not have a managed OS disk. Managed disks are required for image capture." -Level 'Error'
            return $null
        }
        
        Write-Log -Message "OS Disk: $($vmDetails.StorageProfile.OsDisk.Name)" -Level 'Info'
        
        # Get OS disk details for HyperVGeneration
        $osDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $vmDetails.StorageProfile.OsDisk.Name -ErrorAction SilentlyContinue
        
        if ($osDisk) {
            Write-Log -Message "Hyper-V Generation: $($osDisk.HyperVGeneration)" -Level 'Info'
            $vmDetails | Add-Member -NotePropertyName 'HyperVGeneration' -NotePropertyValue $osDisk.HyperVGeneration -Force
        }
        
        # Check for data disks
        $dataDisksCount = $vmDetails.StorageProfile.DataDisks.Count
        Write-Log -Message "Data Disks Count: $dataDisksCount" -Level 'Info'
        
        # Add power state to the returned object
        $vmDetails | Add-Member -NotePropertyName 'PowerState' -NotePropertyValue $powerState -Force
        
        Write-Log -Message "VM validation completed successfully" -Level 'Success'
        return $vmDetails
    }
    catch {
        Write-Log -Message "Failed to validate VM: $_" -Level 'Error'
        return $null
    }
}

function Test-AzureComputeGallery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory)]
        [string]$GalleryName,
        
        [Parameter(Mandatory)]
        [string]$ImageDefinitionName,
        
        [Parameter(Mandatory)]
        [object]$SourceVM,
        
        [Parameter(Mandatory)]
        [string]$OsState
    )
    
    Write-LogSection -Title "Validating Azure Compute Gallery"
    
    try {
        # Check if gallery exists
        Write-Log -Message "Checking if gallery '$GalleryName' exists..." -Level 'Info'
        $gallery = Get-AzGallery -ResourceGroupName $ResourceGroupName -Name $GalleryName -ErrorAction SilentlyContinue
        
        if (-not $gallery) {
            Write-Log -Message "Gallery '$GalleryName' not found in resource group '$ResourceGroupName'" -Level 'Error'
            Write-Log -Message "Please create the gallery first using Azure Portal or: New-AzGallery" -Level 'Info'
            return $null
        }
        
        Write-Log -Message "Gallery found: $($gallery.Name)" -Level 'Success'
        Write-Log -Message "Gallery Location: $($gallery.Location)" -Level 'Info'
        
        # Check if image definition exists
        Write-Log -Message "Checking if image definition '$ImageDefinitionName' exists..." -Level 'Info'
        $imageDefinition = Get-AzGalleryImageDefinition -ResourceGroupName $ResourceGroupName `
            -GalleryName $GalleryName -Name $ImageDefinitionName -ErrorAction SilentlyContinue
        
        if (-not $imageDefinition) {
            Write-Log -Message "Image definition '$ImageDefinitionName' not found" -Level 'Error'
            Write-Log -Message "Please create the image definition first or ensure the name is correct" -Level 'Info'
            
            # Provide helpful information for creating the definition
            Write-Log -Message "To create an image definition, use:" -Level 'Info'
            Write-Log -Message "New-AzGalleryImageDefinition -ResourceGroupName '$ResourceGroupName' -GalleryName '$GalleryName' -Name '$ImageDefinitionName' -Publisher '<Publisher>' -Offer '<Offer>' -Sku '<Sku>' -Location '$($gallery.Location)' -OsType Windows -OsState $OsState -HyperVGeneration '$($SourceVM.HyperVGeneration)'" -Level 'Info'
            return $null
        }
        
        Write-Log -Message "Image definition found: $($imageDefinition.Name)" -Level 'Success'
        Write-Log -Message "Publisher: $($imageDefinition.Identifier.Publisher)" -Level 'Info'
        Write-Log -Message "Offer: $($imageDefinition.Identifier.Offer)" -Level 'Info'
        Write-Log -Message "SKU: $($imageDefinition.Identifier.Sku)" -Level 'Info'
        Write-Log -Message "OS Type: $($imageDefinition.OsType)" -Level 'Info'
        Write-Log -Message "OS State: $($imageDefinition.OsState)" -Level 'Info'
        Write-Log -Message "Hyper-V Generation: $($imageDefinition.HyperVGeneration)" -Level 'Info'
        
        # Validate OS State matches
        if ($imageDefinition.OsState -ne $OsState) {
            Write-Log -Message "OS State mismatch! Image definition expects '$($imageDefinition.OsState)' but '$OsState' was specified" -Level 'Error'
            return $null
        }
        
        # Validate OS Type matches
        if ($imageDefinition.OsType -ne 'Windows') {
            Write-Log -Message "OS Type mismatch! Image definition is for '$($imageDefinition.OsType)' but source VM is Windows" -Level 'Error'
            return $null
        }
        
        # Validate Hyper-V generation matches
        if ($SourceVM.HyperVGeneration -and $imageDefinition.HyperVGeneration -ne $SourceVM.HyperVGeneration) {
            Write-Log -Message "Hyper-V Generation mismatch! Image definition: '$($imageDefinition.HyperVGeneration)', Source VM: '$($SourceVM.HyperVGeneration)'" -Level 'Error'
            return $null
        }
        
        Write-Log -Message "Gallery validation completed successfully" -Level 'Success'
        
        return @{
            Gallery = $gallery
            ImageDefinition = $imageDefinition
        }
    }
    catch {
        Write-Log -Message "Failed to validate gallery: $_" -Level 'Error'
        return $null
    }
}

function Get-NextImageVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory)]
        [string]$GalleryName,
        
        [Parameter(Mandatory)]
        [string]$ImageDefinitionName,
        
        [Parameter()]
        [string]$SpecifiedVersion
    )
    
    Write-LogSection -Title "Determining Image Version"
    
    try {
        if ($SpecifiedVersion) {
            Write-Log -Message "Using specified version: $SpecifiedVersion" -Level 'Info'
            
            # Check if version already exists
            $existingVersion = Get-AzGalleryImageVersion -ResourceGroupName $ResourceGroupName `
                -GalleryName $GalleryName -GalleryImageDefinitionName $ImageDefinitionName `
                -Name $SpecifiedVersion -ErrorAction SilentlyContinue
            
            if ($existingVersion) {
                Write-Log -Message "Version '$SpecifiedVersion' already exists!" -Level 'Error'
                return $null
            }
            
            return $SpecifiedVersion
        }
        
        # Get existing versions and auto-increment
        Write-Log -Message "Auto-detecting next version number..." -Level 'Info'
        $existingVersions = Get-AzGalleryImageVersion -ResourceGroupName $ResourceGroupName `
            -GalleryName $GalleryName -GalleryImageDefinitionName $ImageDefinitionName `
            -ErrorAction SilentlyContinue
        
        if (-not $existingVersions -or $existingVersions.Count -eq 0) {
            $nextVersion = "1.0.0"
            Write-Log -Message "No existing versions found. Starting with: $nextVersion" -Level 'Info'
        }
        else {
            # Parse versions and find the highest
            $versions = $existingVersions | ForEach-Object {
                $parts = $_.Name -split '\.'
                [PSCustomObject]@{
                    Major = [int]$parts[0]
                    Minor = [int]$parts[1]
                    Patch = [int]$parts[2]
                    Original = $_.Name
                }
            } | Sort-Object Major, Minor, Patch -Descending
            
            $highest = $versions[0]
            $nextVersion = "$($highest.Major).$($highest.Minor).$($highest.Patch + 1)"
            
            Write-Log -Message "Existing versions found. Highest: $($highest.Original)" -Level 'Info'
            Write-Log -Message "Next version will be: $nextVersion" -Level 'Info'
        }
        
        return $nextVersion
    }
    catch {
        Write-Log -Message "Failed to determine image version: $_" -Level 'Error'
        return $null
    }
}
#endregion

#region Core Functions
function Stop-SourceVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory)]
        [string]$VMName,
        
        [Parameter(Mandatory)]
        [string]$CurrentPowerState
    )
    
    Write-LogSection -Title "Stopping/Deallocating VM"
    
    try {
        if ($CurrentPowerState -eq 'VM deallocated') {
            Write-Log -Message "VM is already deallocated" -Level 'Success'
            return $true
        }
        
        if ($CurrentPowerState -eq 'VM stopped') {
            Write-Log -Message "VM is stopped but not deallocated. Deallocating..." -Level 'Info'
        }
        else {
            Write-Log -Message "Stopping and deallocating VM '$VMName'..." -Level 'Info'
        }
        
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -ErrorAction Stop
        
        Write-Log -Message "VM deallocated successfully" -Level 'Success'
        return $true
    }
    catch {
        Write-Log -Message "Failed to deallocate VM: $_" -Level 'Error'
        return $false
    }
}

function Set-VMGeneralized {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory)]
        [string]$VMName
    )
    
    Write-LogSection -Title "Marking VM as Generalized"
    
    try {
        Write-Log -Message "Setting VM '$VMName' as generalized..." -Level 'Info'
        Write-Log -Message "WARNING: After this operation, the VM cannot be restarted!" -Level 'Warning'
        
        Set-AzVm -ResourceGroupName $ResourceGroupName -Name $VMName -Generalized -ErrorAction Stop
        
        Write-Log -Message "VM marked as generalized successfully" -Level 'Success'
        return $true
    }
    catch {
        Write-Log -Message "Failed to mark VM as generalized: $_" -Level 'Error'
        Write-Log -Message "Ensure Sysprep was run on the VM before attempting to generalize" -Level 'Info'
        return $false
    }
}

function New-ImageVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GalleryResourceGroupName,
        
        [Parameter(Mandatory)]
        [string]$GalleryName,
        
        [Parameter(Mandatory)]
        [string]$ImageDefinitionName,
        
        [Parameter(Mandatory)]
        [string]$ImageVersionName,
        
        [Parameter(Mandatory)]
        [object]$SourceVM,
        
        [Parameter(Mandatory)]
        [string]$Location,
        
        [Parameter()]
        [string[]]$TargetRegions,
        
        [Parameter()]
        [int]$ReplicaCount = 1,
        
        [Parameter()]
        [switch]$ExcludeFromLatest,
        
        [Parameter()]
        [datetime]$EndOfLifeDate,
        
        [Parameter()]
        [hashtable]$Tags = @{}
    )
    
    Write-LogSection -Title "Creating Image Version"
    
    try {
        Write-Log -Message "Creating image version '$ImageVersionName' in gallery '$GalleryName'..." -Level 'Info'
        Write-Log -Message "This process can take 15-30 minutes depending on disk size and replication regions" -Level 'Info'
        
        # Build target region configurations
        $targetRegionConfigs = @()
        
        if ($TargetRegions -and $TargetRegions.Count -gt 0) {
            foreach ($region in $TargetRegions) {
                $targetRegionConfigs += @{
                    Name = $region
                    ReplicaCount = $ReplicaCount
                    StorageAccountType = 'Standard_LRS'
                }
            }
        }
        else {
            # Default to gallery location
            $targetRegionConfigs += @{
                Name = $Location
                ReplicaCount = $ReplicaCount
                StorageAccountType = 'Standard_LRS'
            }
        }
        
        Write-Log -Message "Target regions for replication:" -Level 'Info'
        foreach ($region in $targetRegionConfigs) {
            Write-Log -Message "  - $($region.Name) (Replicas: $($region.ReplicaCount))" -Level 'Info'
        }
        
        # Build the parameters
        $versionParams = @{
            ResourceGroupName = $GalleryResourceGroupName
            GalleryName = $GalleryName
            GalleryImageDefinitionName = $ImageDefinitionName
            Name = $ImageVersionName
            Location = $Location
            SourceImageId = $SourceVM.Id
            ReplicaCount = $ReplicaCount
            PublishingProfileExcludeFromLatest = $ExcludeFromLatest.IsPresent
            ErrorAction = 'Stop'
        }
        
        if ($TargetRegions -and $TargetRegions.Count -gt 0) {
            $versionParams.Add('TargetRegion', $targetRegionConfigs)
        }
        
        if ($EndOfLifeDate) {
            $versionParams.Add('PublishingProfileEndOfLifeDate', $EndOfLifeDate)
        }
        
        if ($Tags -and $Tags.Count -gt 0) {
            $versionParams.Add('Tag', $Tags)
        }
        
        # Create the image version
        $imageVersion = New-AzGalleryImageVersion @versionParams
        
        Write-Log -Message "Image version created successfully!" -Level 'Success'
        Write-Log -Message "Image Version ID: $($imageVersion.Id)" -Level 'Info'
        Write-Log -Message "Provisioning State: $($imageVersion.ProvisioningState)" -Level 'Info'
        
        return $imageVersion
    }
    catch {
        Write-Log -Message "Failed to create image version: $_" -Level 'Error'
        return $null
    }
}

function Remove-SourceVMAfterCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory)]
        [string]$VMName
    )
    
    Write-LogSection -Title "Cleaning Up Source VM"
    
    try {
        Write-Log -Message "Deleting source VM '$VMName'..." -Level 'Info'
        
        Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force -ErrorAction Stop
        
        Write-Log -Message "Source VM deleted successfully" -Level 'Success'
        Write-Log -Message "Note: Associated disks and NICs may still exist and need manual cleanup" -Level 'Warning'
        return $true
    }
    catch {
        Write-Log -Message "Failed to delete source VM: $_" -Level 'Error'
        return $false
    }
}
#endregion

#region Main Execution
function Start-ImageCapture {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    
    $exitCode = 0
    
    try {
        # Initialize logging
        if (-not (Initialize-Logging -LogDirectory $LogPath)) {
            throw "Failed to initialize logging"
        }
        
        # Log parameters
        Write-LogSection -Title "Parameters"
        Write-Log -Message "Subscription ID: $SubscriptionId" -Level 'Info'
        Write-Log -Message "Source Resource Group: $ResourceGroupName" -Level 'Info'
        Write-Log -Message "Source VM Name: $VMName" -Level 'Info'
        Write-Log -Message "Gallery Resource Group: $GalleryResourceGroupName" -Level 'Info'
        Write-Log -Message "Gallery Name: $GalleryName" -Level 'Info'
        Write-Log -Message "Image Definition: $ImageDefinitionName" -Level 'Info'
        Write-Log -Message "Requested Image Version: $(if ($ImageVersionName) { $ImageVersionName } else { 'Auto' })" -Level 'Info'
        Write-Log -Message "OS State: $OsState" -Level 'Info'
        Write-Log -Message "Target Regions: $(if ($TargetRegions) { $TargetRegions -join ', ' } else { 'Default (Gallery Location)' })" -Level 'Info'
        Write-Log -Message "Replica Count: $ReplicaCount" -Level 'Info'
        Write-Log -Message "Skip Generalize: $SkipGeneralize" -Level 'Info'
        Write-Log -Message "Delete Source VM: $DeleteSourceVM" -Level 'Info'
        Write-Log -Message "Exclude From Latest: $ExcludeFromLatest" -Level 'Info'
        Write-Log -Message "End of Life Date: $EndOfLifeDate" -Level 'Info'
        
        # Step 1: Validate Azure connection
        if (-not (Test-AzureConnection -SubscriptionId $SubscriptionId)) {
            throw "Azure connection validation failed"
        }
        
        # Step 2: Validate source VM
        $sourceVM = Test-SourceVM -ResourceGroupName $ResourceGroupName -VMName $VMName -OsState $OsState
        if (-not $sourceVM) {
            throw "Source VM validation failed"
        }
        
        # Step 3: Validate gallery and image definition
        $galleryInfo = Test-AzureComputeGallery -ResourceGroupName $GalleryResourceGroupName `
            -GalleryName $GalleryName -ImageDefinitionName $ImageDefinitionName `
            -SourceVM $sourceVM -OsState $OsState
        if (-not $galleryInfo) {
            throw "Gallery validation failed"
        }
        
        # Step 4: Determine image version
        $version = Get-NextImageVersion -ResourceGroupName $GalleryResourceGroupName `
            -GalleryName $GalleryName -ImageDefinitionName $ImageDefinitionName `
            -SpecifiedVersion $ImageVersionName
        if (-not $version) {
            throw "Failed to determine image version"
        }
        
        # Confirmation prompt
        if (-not $Force -and -not $PSCmdlet.ShouldProcess(
            "VM '$VMName' will be captured to image version '$version' in gallery '$GalleryName'. " +
            "$(if ($OsState -eq 'Generalized' -and -not $SkipGeneralize) { 'The VM will be marked as generalized and CANNOT be restarted afterward. ' })" +
            "$(if ($DeleteSourceVM) { 'The source VM will be DELETED after capture. ' })",
            "Capture Image",
            "Confirm Image Capture")) {
            Write-Log -Message "Operation cancelled by user" -Level 'Warning'
            return 1
        }
        
        # Step 5: Stop/Deallocate VM if needed
        if ($sourceVM.PowerState -ne 'VM deallocated') {
            if (-not (Stop-SourceVM -ResourceGroupName $ResourceGroupName -VMName $VMName -CurrentPowerState $sourceVM.PowerState)) {
                throw "Failed to deallocate VM"
            }
        }
        
        # Step 6: Generalize VM if needed
        if ($OsState -eq 'Generalized' -and -not $SkipGeneralize) {
            if (-not (Set-VMGeneralized -ResourceGroupName $ResourceGroupName -VMName $VMName)) {
                throw "Failed to generalize VM"
            }
        }
        
        # Step 7: Create image version
        $imageVersion = New-ImageVersion -GalleryResourceGroupName $GalleryResourceGroupName `
            -GalleryName $GalleryName -ImageDefinitionName $ImageDefinitionName `
            -ImageVersionName $version -SourceVM $sourceVM `
            -Location $galleryInfo.Gallery.Location -TargetRegions $TargetRegions `
            -ReplicaCount $ReplicaCount -ExcludeFromLatest:$ExcludeFromLatest `
            -EndOfLifeDate $EndOfLifeDate -Tags $Tags
        
        if (-not $imageVersion) {
            throw "Failed to create image version"
        }
        
        # Step 8: Delete source VM if requested
        if ($DeleteSourceVM) {
            Remove-SourceVMAfterCapture -ResourceGroupName $ResourceGroupName -VMName $VMName | Out-Null
        }
        
        # Summary
        Write-LogSection -Title "Summary"
        Write-Log -Message "Image capture completed successfully!" -Level 'Success'
        Write-Log -Message "Gallery: $GalleryName" -Level 'Success'
        Write-Log -Message "Image Definition: $ImageDefinitionName" -Level 'Success'
        Write-Log -Message "Image Version: $version" -Level 'Success'
        Write-Log -Message "Image Version Resource ID:" -Level 'Info'
        Write-Log -Message "  $($imageVersion.Id)" -Level 'Info'
        
        $duration = (Get-Date) - $script:StartTime
        Write-Log -Message "Total Duration: $($duration.ToString('hh\:mm\:ss'))" -Level 'Info'
    }
    catch {
        Write-Log -Message "Image capture failed: $_" -Level 'Error'
        Write-Log -Message "Stack Trace: $($_.ScriptStackTrace)" -Level 'Error'
        $exitCode = 1
    }
    finally {
        Write-LogSection -Title "Script Completed"
        Write-Log -Message "Exit Code: $exitCode" -Level $(if ($exitCode -eq 0) { 'Success' } else { 'Error' })
        Write-Log -Message "Log file: $script:LogFile" -Level 'Info'
    }
    
    return $exitCode
}

# Execute main function
$result = Start-ImageCapture
exit $result
#endregion
