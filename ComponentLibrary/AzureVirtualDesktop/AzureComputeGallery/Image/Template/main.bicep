@description('Azure region for the Azure compute gallery')
param location string = resourceGroup().location

@description('Regions in which to replicate this template')
param replicationRegions array = [location]

@description('Name of the existing Azure compute gallery')
param galleryName string

@description('Name of the image definition for which to create the template')
param imageDefinitionName string

@description('Name of the image template to be created')
param imageTemplateName string

@description('ID of the user managed identity to assign to this template')
param userAssignedIdentityId string

@description('Publisher of the source image this template is based on')
param sourcePublisher string = 'microsoftwindowsdesktop'

@description('Offer of the source image this template is based on')
param sourceOffer string = 'windows-11'

@description('Sku of the source image this template is based on')
param sourceSku string = 'win11-25h2-avd'

@description('Type of the source image this template is based on')
param sourceType string = 'PlatformImage'

@description('Version of the source image this template is based on')
param sourceVersion string = 'latest'

@description('VM size for the image template build VM. Use Standard_DC8as_v6 (or similar DC/EC series) for Confidential VM image builds.')
param vmSize string = 'Standard_DC8as_v6'

@description('OS disk size in GB for the image template build VM')
param osDiskSizeGB int = 127

@description('Build timeout in minutes')
param buildTimeoutInMinutes int = 960

@description('Image version number in the distribution target')
param imageVersionNumber string = '0.0.1'

@description('Storage account type for image replication')
param storageAccountType string = 'Standard_ZRS'

@description('Exclude image version from latest')
param excludeFromLatest bool = true

@description('Run output name for the distribution target')
param runOutputName string = 'finalimage'

// ── Language & Locale Configuration ─────────────────────────

@description('Languages to install (e.g. "English (United States)" or "French (France)","Dutch (Belgium)","English (United States)","German (Germany)")')
param languageList string = '"English (United States)"'

@description('Default language to set (e.g. "English (United States)" or "French (France)")')
param defaultLanguage string = '"English (United States)"'

// ── Optional Feature Flags ──────────────────────────────────

@description('Enable language pack installation and default language configuration')
param enableLanguagePacks bool = false

@description('Enable RDP Shortpath configuration')
param enableRdpShortpath bool = false

@description('Enable DotNet 9 Desktop Runtime installation')
param enableDotNet9 bool = false

@description('Enable removal of Office M365 Apps via ConfigureOfficeApps.ps1')
param enableRemoveOfficeApps bool = false

@description('Office applications to remove (comma-separated, e.g. Access,OneNote,Outlook,PowerPoint,Publisher)')
param officeAppsToRemove string = 'Access,OneNote,Outlook,PowerPoint,Publisher'

@description('Office bitness version (32 or 64)')
param officeVersion string = '64'

@description('Enable removal of OneDrive specifically')
param enableRemoveOneDrive bool = false

@description('Enable disable auto-updates step')
param enableDisableAutoUpdates bool = false

// ── VNet Configuration (required when build VM needs private endpoint access) ─

@description('Resource ID of the subnet the AIB build VM should be deployed into. Required when the build VM needs private endpoint access to storage accounts. Leave empty for default Azure-managed networking.')
param subnetId string = ''

@description('VM size for the optional proxy VM used by AIB when vnetConfig is set. A small SKU is sufficient.')
param proxyVmSize string = 'Standard_D2as_v5'

@description('FSLogix VHD size in MB')
param fslogixVHDSize string = '30000'

@description('Windows optimization options')
param windowsOptimizations string = '"WindowsMediaPlayer","ScheduledTasks","DefaultUserSettings","Autologgers","Services","NetworkOptimizations","LGPO","DiskCleanup","RemoveLegacyIE"'

@description('Appx packages to remove')
param appxPackages string = '"Clipchamp.Clipchamp","Microsoft.BingNews","Microsoft.BingWeather","Microsoft.GamingApp","Microsoft.Getstarted","Microsoft.MicrosoftOfficeHub","Microsoft.Office.OneNote","Microsoft.MicrosoftSolitaireCollection","Microsoft.MicrosoftStickyNotes","Microsoft.People","Microsoft.PowerAutomateDesktop","Microsoft.SkypeApp","Microsoft.Todos","Microsoft.WindowsAlarms","Microsoft.WindowsCamera","Microsoft.windowscommunicationsapps","Microsoft.WindowsFeedbackHub","Microsoft.WindowsMaps","Microsoft.WindowsSoundRecorder","Microsoft.Xbox.TCUI","Microsoft.XboxGameOverlay","Microsoft.XboxGamingOverlay","Microsoft.XboxIdentityProvider","Microsoft.XboxSpeechToTextOverlay","Microsoft.YourPhone","Microsoft.ZuneMusic","Microsoft.ZuneVideo","Microsoft.XboxApp"'

param tags object

// ── Resources ───────────────────────────────────────────────

resource gallery 'Microsoft.Compute/galleries@2024-03-03' existing = {
  name: galleryName
}

// ── Build Customization Steps ───────────────────────────────

// Core steps that are always included
var coreCustomizeSteps = [
  // 1. Timezone Redirection
  {
    name: 'avdBuiltInScript_timeZoneRedirection'
    runAsSystem: true
    runElevated: true
    scriptUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/TimezoneRedirection.ps1'
    sha256Checksum: 'b8dbc50b02f64cc7a99f6eeb7ada676673c9e431255e69f3e7a97a027becd8d5'
    type: 'PowerShell'
  }
  // 2. Disable Storage Sense
  {
    name: 'avdBuiltInScript_disableStorageSense'
    runAsSystem: true
    runElevated: true
    scriptUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/DisableStorageSense.ps1'
    sha256Checksum: '558180fc9d73ed3d7ccc922e38eff3f28e10eaeddca89e32b66e2ded7390ff5a'
    type: 'PowerShell'
  }
  // 3. Enable FSLogix
  {
    destination: 'C:\\AVDImage\\enableFslogix.ps1'
    name: 'avdBuiltInScript_enableFsLogix'
    sha256Checksum: '027ecbc0bccd42c6e7f8fc35027c55691fba7645d141c9f89da760fea667ea51'
    sourceUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/FSLogix.ps1'
    type: 'File'
  }
  {
    inline: [
      'C:\\AVDImage\\enableFslogix.ps1 -FSLogixInstaller "https://aka.ms/fslogix_download" -VHDSize "${fslogixVHDSize}"'
    ]
    name: 'avdBuiltInScript_enableFsLogix-parameter'
    runAsSystem: true
    runElevated: true
    type: 'PowerShell'
  }
]

// Language pack steps (optional)
var languagePackSteps = enableLanguagePacks ? [
  {
    destination: 'C:\\AVDImage\\installLanguagePacks.ps1'
    name: 'avdBuiltInScript_installLanguagePacks'
    sha256Checksum: '519f1dcb41c15dc1726f28c51c11fb60876304ab9eb9535e70015cdb704a61b2'
    sourceUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/InstallLanguagePacks.ps1'
    type: 'File'
  }
  {
    inline: [
      'C:\\AVDImage\\installLanguagePacks.ps1 -LanguageList ${languageList}'
    ]
    name: 'avdBuiltInScript_installLanguagePacks-parameter'
    runAsSystem: true
    runElevated: true
    type: 'PowerShell'
  }
  {
    name: 'avdBuiltInScript_installLanguagePacks-windowsUpdate'
    type: 'WindowsUpdate'
    updateLimit: 0
  }
  {
    name: 'avdBuiltInScript_installLanguagePacks-windowsRestart'
    restartTimeout: '10m'
    type: 'WindowsRestart'
  }
  {
    destination: 'C:\\AVDImage\\setDefaultLanguage.ps1'
    name: 'avdBuiltInScript_setDefaultLanguage'
    sha256Checksum: '3eec0ffb74a9a343cf1b38dd73d266bfc8c82b23f0fd2c3f7e9d29c975eb6bab'
    sourceUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/SetDefaultLang.ps1'
    type: 'File'
  }
  {
    inline: [
      'C:\\AVDImage\\setDefaultLanguage.ps1 -Language ${defaultLanguage}'
    ]
    name: 'avdBuiltInScript_setDefaultLanguage-parameter'
    runAsSystem: true
    runElevated: true
    type: 'PowerShell'
  }
  {
    name: 'avdBuiltInScript_setDefaultLanguage-windowsUpdate'
    type: 'WindowsUpdate'
    updateLimit: 0
  }
  {
    name: 'avdBuiltInScript_setDefaultLanguage-windowsRestart'
    restartTimeout: '5m'
    type: 'WindowsRestart'
  }
] : []

// RDP Shortpath step (optional)
var rdpShortpathSteps = enableRdpShortpath ? [
  {
    name: 'avdBuiltInScript_configureRdpShortpath'
    runAsSystem: true
    runElevated: true
    scriptUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/RDPShortpath.ps1'
    sha256Checksum: '24e9821ddcc63aceba2682286d03cd7042bcadcf08a74fb0a30a1a1cd0cbf910'
    type: 'PowerShell'
  }
] : []

// DotNet 9 Desktop Runtime step (optional)
var dotNet9Steps = enableDotNet9 ? [
  {
    inline: [
      '$ProgressPreference = \'SilentlyContinue\'; Invoke-WebRequest -Uri https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/9.0.4/windowsdesktop-runtime-9.0.4-win-x64.exe -OutFile C:\\AVDImage\\windowsdesktop-runtime-9.0.4-win-x64.exe; Start-Process -Wait -FilePath C:\\AVDImage\\windowsdesktop-runtime-9.0.4-win-x64.exe -ArgumentList \'/install\', \'/quiet\', \'/norestart\''
    ]
    name: 'Install_DotNet9_DesktopRuntime'
    runAsSystem: true
    runElevated: true
    type: 'PowerShell'
  }
] : []

// Windows Optimization steps (always included)
var windowsOptimizationSteps = [
  {
    destination: 'C:\\AVDImage\\windowsOptimization.ps1'
    name: 'avdBuiltInScript_windowsOptimization'
    sha256Checksum: '3a84266be0a3fcba89f2adf284f3cc6cc2ac41242921010139d6e9514ead126f'
    sourceUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/WindowsOptimization.ps1'
    type: 'File'
  }
  {
    inline: [
      'C:\\AVDImage\\windowsOptimization.ps1 -Optimizations ${windowsOptimizations}'
    ]
    name: 'avdBuiltInScript_windowsOptimization-parameter'
    runAsSystem: true
    runElevated: true
    type: 'PowerShell'
  }
  {
    name: 'avdBuiltInScript_windowsOptimization-windowsUpdate'
    type: 'WindowsUpdate'
    updateLimit: 0
  }
  {
    name: 'avdBuiltInScript_windowsOptimization-windowsRestart'
    type: 'WindowsRestart'
  }
]

// Disable Auto-Updates step (optional)
var disableAutoUpdatesSteps = enableDisableAutoUpdates ? [
  {
    name: 'avdBuiltInScript_disableAutoUpdates'
    runAsSystem: true
    runElevated: true
    scriptUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/DisableAutoUpdates.ps1'
    sha256Checksum: 'eafd5e46c628b685f2061146550287255d75b7cea63f1e9dd29827c4ff7c3cb4'
    type: 'PowerShell'
  }
] : []

// Remove Office M365 Apps step (optional) - uses ConfigureOfficeApps.ps1
var removeOfficeAppsSteps = enableRemoveOfficeApps ? [
  {
    destination: 'C:\\AVDImage\\OfficeApps.ps1'
    name: 'avdBuiltInScript_removeOfficeApps'
    sha256Checksum: '4465c784183c5224f4e963affa6eae8c70d39ea63c8a3fc212e5e97442c21659'
    sourceUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/ConfigureOfficeApps.ps1'
    type: 'File'
  }
  {
    inline: [
      'C:\\AVDImage\\OfficeApps.ps1 -Type "Remove" -Applications ${officeAppsToRemove} -Version "${officeVersion}"'
    ]
    name: 'avdBuiltInScript_removeOfficeApps-parameter'
    runAsSystem: true
    runElevated: true
    type: 'PowerShell'
  }
] : []

// Remove OneDrive step (optional)
var removeOneDriveSteps = enableRemoveOneDrive ? [
  {
    inline: [
      'Get-AppxPackage -Name "Microsoft.OneDrive" -AllUsers | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue; Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq "Microsoft.OneDrive" | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue'
    ]
    name: 'Remove_OneDrive'
    runAsSystem: true
    runElevated: true
    type: 'PowerShell'
  }
] : []

// Appx removal + Windows Update + SysPrep (always included)
var finalizeSteps = [
  {
    destination: 'C:\\AVDImage\\removeAppxPackages.ps1'
    name: 'avdBuiltInScript_removeAppxPackages'
    sha256Checksum: '422b4c7b961f4d8b4216f126d8f38b00da583748b2d65b835504c1e9a07b0ece'
    sourceUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/RemoveAppxPackages.ps1'
    type: 'File'
  }
  {
    inline: [
      'C:\\AVDImage\\removeAppxPackages.ps1 -AppxPackages ${appxPackages}'
    ]
    name: 'avdBuiltInScript_removeAppxPackages-parameter'
    runAsSystem: true
    runElevated: true
    type: 'PowerShell'
  }
  {
    name: 'avdBuiltInScript_windowsUpdate'
    type: 'WindowsUpdate'
    updateLimit: 0
  }
  {
    name: 'avdBuiltInScript_windowsUpdate-windowsRestart'
    type: 'WindowsRestart'
  }
  {
    name: 'avdBuiltInScript_adminSysPrep'
    runAsSystem: true
    runElevated: true
    scriptUri: 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/AdminSysPrep.ps1'
    sha256Checksum: '1dcaba4823f9963c9e51c5ce0adce5f546f65ef6034c364ef7325a0451bd9de9'
    type: 'PowerShell'
  }
]

// Assemble all customize steps in order (matches the blog's documented sequence):
//  1. Timezone Redirection (always)
//  2. Disable Storage Sense (always)
//  3. FSLogix Profile Containers (always)
//  4. Language Packs (optional)
//  5. RDP Shortpath (optional)
//  6. .NET 9 Desktop Runtime (optional)
//  7. Remove Office Apps (optional)
//  8. Remove OneDrive (optional)
//  9. Windows Optimization / VDOT (always)
// 10. Disable Auto-Updates (optional)
// 11. Appx Package Removal (always)
// 12. Windows Update (always)
// 13. SysPrep (always)
var customizeSteps = concat(
  coreCustomizeSteps,
  languagePackSteps,
  rdpShortpathSteps,
  dotNet9Steps,
  removeOfficeAppsSteps,
  removeOneDriveSteps,
  windowsOptimizationSteps,
  disableAutoUpdatesSteps,
  finalizeSteps
)

// ── Image Template Resource ─────────────────────────────────

resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: imageTemplateName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: buildTimeoutInMinutes
    customize: customizeSteps
    distribute: [
      {
        artifactTags: {}
        excludeFromLatest: excludeFromLatest
        galleryImageId: '${gallery.id}/images/${imageDefinitionName}/versions/${imageVersionNumber}'
        replicationRegions: replicationRegions
        runOutputName: runOutputName
        storageAccountType: storageAccountType
        type: 'SharedImage'
      }
    ]
    source: {
      offer: sourceOffer
      publisher: sourcePublisher
      sku: sourceSku
      type: sourceType
      version: sourceVersion
    }
    vmProfile: {
      osDiskSizeGB: osDiskSizeGB
      vmSize: vmSize
      vnetConfig: !empty(subnetId) ? {
        subnetId: subnetId
        proxyVmSize: proxyVmSize
      } : null
    }
  }
}

output imageTemplateId string = imageTemplate.id
output imageTemplateName string = imageTemplate.name
