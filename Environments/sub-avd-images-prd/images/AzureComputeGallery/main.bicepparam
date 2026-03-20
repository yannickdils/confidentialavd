// ============================================================
// Parameters for AVD Image Infrastructure Orchestrator
// Target: sub-avd-images-prd / rg-avd-images-prd-image-weu-001
// ============================================================

using './main.bicep'

param location = 'westeurope'
param ccLocation = 'belgiumcentral'
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
  managedBy: 'bicep'
}
