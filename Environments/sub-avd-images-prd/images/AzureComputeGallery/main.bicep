// ============================================================
// Confidential VM Image Infrastructure Orchestrator
// ============================================================
// Deploys the Azure Image Builder infrastructure for
// Confidential Compute images:
//   1. User-Assigned Managed Identity
//   2. Azure Compute Gallery
//   3. Confidential VM Image Definition
//
// Target Subscription : sub-avd-images-prd
//                       <SUBSCRIPTION_ID_IMAGES_PRD>
// Resource Group      : rg-avd-images-prd-image-weu-001
// ============================================================
// Deploy with:
//   az deployment group create \
//     --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \
//     --resource-group rg-avd-images-prd-image-weu-001 \
//     --template-file main.bicep \
//     --parameters @main.bicepparam
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────

@description('Primary Azure region')
param location string = 'westeurope'

@description('Azure region for the Confidential Compute image definition (must match existing resource)')
param ccLocation string = 'belgiumcentral'

@description('Tags applied to all resources')
param tags object = {
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

// ── 1. User-Assigned Managed Identity ────────────────────────

module managedIdentity '../../../../ComponentLibrary/AzureVirtualDesktop/ManagedIdentity/main.bicep' = {
  name: 'deploy-umi-imagebuilder'
  params: {
    identityName: 'umi-imgt-avd-images-prd-intcoreapps-win'
    location: location
    tags: tags
  }
}

// ── 2. Azure Compute Gallery ─────────────────────────────────

module galleryMain '../../../../ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/main.bicep' = {
  name: 'deploy-gal-main'
  params: {
    galleryName: 'galavdimagesprdweu001'
    location: location
    tags: tags
  }
}

// ── 3. Confidential Compute Image Definition ─────────────────

module imgDefCC '../../../../ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/main.bicep' = {
  name: 'deploy-imgd-cc'
  params: {
    galleryName: 'galavdimagesprdweu001'
    imageName: 'imgd-avd-images-prd-cc-win11-25h2-001'
    location: ccLocation
    publisher: '<ORGANIZATION_NAME>'
    offer: 'Windows11-25H2'
    sku: 'CCMultiSession'
    features: [
      { name: 'SecurityType', value: 'TrustedLaunchAndConfidentialVmSupported' }
    ]
    tags: union(tags, { imageType: 'confidential-compute' })
  }
  dependsOn: [galleryMain]
}

// ── Outputs ──────────────────────────────────────────────────

output managedIdentityId string = managedIdentity.outputs.identityId
output managedIdentityPrincipalId string = managedIdentity.outputs.identityPrincipalId

output galleryMainId string = galleryMain.outputs.galleryId
