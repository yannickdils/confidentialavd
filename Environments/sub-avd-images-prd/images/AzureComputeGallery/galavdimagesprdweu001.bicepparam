// ============================================================
// Gallery: galavdimagesprdweu001
// Location: westeurope
// Resource Group: rg-avd-images-prd-image-weu-001
// ============================================================

using '../../../../ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/main.bicep'

param galleryName = 'galavdimagesprdweu001'
param location = 'westeurope'
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
}
