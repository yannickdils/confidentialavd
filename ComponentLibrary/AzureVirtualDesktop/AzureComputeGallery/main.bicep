@description('Azure region for the Azure compute gallery')
param location string = resourceGroup().location

@description('Name of the Azure compute gallery')
@minLength(3)
@maxLength(80)
param galleryName string

param tags object

resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: galleryName
  location: location
  tags: tags
  properties: {
    identifier: {}
  }
}

output galleryId string = gallery.id
output galleryName string = gallery.name
