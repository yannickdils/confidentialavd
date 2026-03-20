// ============================================================
// Image Definition: imgd-avd-images-prd-cc-win11-25h2-001
// Gallery: galavdimagesprdweu001
// Security: TrustedLaunchAndConfidentialVmSupported
// Location: belgiumcentral
// ============================================================

using '../../../../../ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/main.bicep'

param galleryName = 'galavdimagesprdweu001'
param imageName = 'imgd-avd-images-prd-cc-win11-25h2-001'
param location = 'belgiumcentral'
param publisher = '<ORGANIZATION_NAME>'
param offer = 'Windows11-25H2'
param sku = 'CCMultiSession'
param features = [
  {
    name: 'SecurityType'
    value: 'TrustedLaunchAndConfidentialVmSupported'
  }
]
param maxCPUs = 16
param maxMemory = 32
param tags = {
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
