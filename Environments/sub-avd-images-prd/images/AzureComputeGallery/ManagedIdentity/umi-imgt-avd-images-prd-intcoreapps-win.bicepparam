// ============================================================
// User-Assigned Managed Identity for Image Builder
// Name: umi-imgt-avd-images-prd-intcoreapps-win
// Resource Group: rg-avd-images-prd-image-weu-001
// Location: westeurope
// ============================================================

using '../../../../../ComponentLibrary/AzureVirtualDesktop/ManagedIdentity/main.bicep'

param identityName = 'umi-imgt-avd-images-prd-intcoreapps-win'
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
  purpose: 'image-builder'
}
