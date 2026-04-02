@description('Azure region for the Azure compute gallery')
param location string = resourceGroup().location

@description('Name of the existing Azure compute gallery')
param galleryName string

@description('Name of the image definition to be created')
param imageName string

@description('VM image definition security features. Use TrustedLaunchAndConfidentialVmSupported for images that need to work with both Trusted Launch and Confidential VMs.')
param features array =  [
  {
    name: 'SecurityType'
    value: 'TrustedLaunchAndConfidentialVmSupported'
  }
]

@description('Publisher of the image definition to be created')
param publisher string = '<ORGANIZATION_NAME>'

@description('Offer of the image definition to be created')
param offer string

@description('Sku of the image definition to be created')
param sku string

@description('Maximum recommended vCPU count for VMs using this image')
param maxCPUs int = 16

@description('Maximum recommended memory in GB for VMs using this image')
param maxMemory int = 32

param tags object

resource gallery 'Microsoft.Compute/galleries@2024-03-03' existing = {
  name: galleryName
}

resource imageDefinition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: imageName
  location: location
  tags: tags
  properties: {
    hyperVGeneration: 'V2'
    architecture: 'x64'
    features: features
    osType: 'Windows'
    osState: 'Generalized'
    identifier: {
      publisher: publisher
      offer: offer
      sku: sku
    }
    recommended: {
      vCPUs: {
        min: 1
        max: maxCPUs
      }
      memory: {
        min: 1
        max: maxMemory
      }
    }
  }
}

output imageID string = imageDefinition.id
output imageName string = imageDefinition.name
