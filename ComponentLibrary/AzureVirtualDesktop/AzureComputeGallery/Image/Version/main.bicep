@description('Azure region for the Azure compute gallery')
param location string = resourceGroup().location

@description('Name of the existing Azure Compute Gallery')
param galleryName string

@description('Name of the image definition in which to create the version')
param imageDefinitionName string

@description('Name of the image version to be created')
param imageVersionName string = '0.0.1'

@description('Resource ID of the source for the image version (managed image, VM, or snapshot)')
param sourceId string

@description('Target regions for image replication')
param targetRegions array = [
  {
    name: location
    regionalReplicaCount: 1
    storageAccountType: 'Standard_ZRS'
  }
]

@description('Exclude this version from being considered latest')
param excludeFromLatest bool = false

@description('Storage account type for the primary region')
param storageAccountType string = 'Standard_ZRS'

param tags object

resource gallery 'Microsoft.Compute/galleries@2024-03-03' existing = {
  name: galleryName
}

resource imageDefinition 'Microsoft.Compute/galleries/images@2024-03-03' existing = {
  parent: gallery
  name: imageDefinitionName
}

resource imageVersion 'Microsoft.Compute/galleries/images/versions@2024-03-03' = {
  parent: imageDefinition
  name: imageVersionName
  location: location
  tags: tags
  properties: {
    publishingProfile: {
      targetRegions: targetRegions
      replicaCount: 1
      excludeFromLatest: excludeFromLatest
      storageAccountType: storageAccountType
      replicationMode: 'Full'
    }
    storageProfile: {
      source: {
        id: sourceId
      }
    }
    safetyProfile: {
      allowDeletionOfReplicatedLocations: false
    }
  }
}

output imageVersionId string = imageVersion.id
output imageVersionName string = imageVersion.name
