// ============================================================
// Image Template: Confidential Compute (CC)
// Gallery: galavdimagesprdweu001
// Image Definition: imgd-avd-images-prd-cc-win11-25h2-001
// Source: office-365 / win11-25h2-avd-m365
// Location: westeurope
// VM Size: Standard_DC8as_v6
// ============================================================
// NOTE: The build VM does NOT need a securityProfile.
// AIB uses TrustedLaunch automatically when the target image
// definition has SecurityType = TrustedLaunchAndConfidentialVmSupported.
// The output image inherits CVM compatibility from the definition.
// ============================================================

using '../../../../../ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/Template/main.bicep'

param location = 'westeurope'
param galleryName = 'galavdimagesprdweu001'
param imageDefinitionName = 'imgd-avd-images-prd-cc-win11-25h2-001'
param imageTemplateName = 'imgt-avd-images-prd-cc-win'
param userAssignedIdentityId = '/subscriptions/<SUBSCRIPTION_ID_IMAGES_PRD>/resourceGroups/rg-avd-images-prd-image-weu-001/providers/Microsoft.ManagedIdentity/userAssignedIdentities/umi-imgt-avd-images-prd-intcoreapps-win'

// Source Image: Windows 11 25H2 with Office 365
param sourcePublisher = 'microsoftwindowsdesktop'
param sourceOffer = 'office-365'
param sourceSku = 'win11-25h2-avd-m365'
param sourceType = 'PlatformImage'
param sourceVersion = 'latest'

// Build Configuration
param vmSize = 'Standard_DC8as_v6'
param osDiskSizeGB = 127
param buildTimeoutInMinutes = 960

// Distribution - replicate to all regions where CC session hosts may run
param replicationRegions = [
  'westeurope'
  'belgiumcentral'
  'northeurope'
]
param storageAccountType = 'Standard_ZRS'
param imageVersionNumber = '0.0.1'
param excludeFromLatest = true
param runOutputName = 'finalimage'

// Language Configuration - disabled
param enableLanguagePacks = false

// Optional Features
param enableRdpShortpath = true
param enableDotNet9 = false
param enableRemoveOfficeApps = true
param officeAppsToRemove = '"Access","OneNote","Outlook","PowerPoint","Publisher"'
param officeVersion = '64'
param enableRemoveOneDrive = false
param enableDisableAutoUpdates = true

param tags = {
  AVD_IMAGE_TEMPLATE: 'AVD_IMAGE_TEMPLATE'
  businessdomain: 'ItForIt'
  environment: 'prd'
  importance: 'critical'
  product: 'InfraStore'
  team: 'WIN-SYS'
  applicationowner: '<APPLICATION_OWNER_EMAIL>'
  owner: '<OWNER_EMAIL>'
  app: 'avd'
  application: 'avd'
  activeworkinghours: '24x7'
  activeworkingdays: 'fw'
  startstopenabled: 'false'
  workload: 'avd-images'
  imageType: 'confidential-compute'
}
