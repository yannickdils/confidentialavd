targetScope = 'subscription'

@description('The name of the resource group to create')
param resourceGroupName string

@description('The location where the resource group should be created')
param location string

@description('The tags to apply to the resource group')
param tags object = {}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

output resourceGroupId string = resourceGroup.id
output resourceGroupName string = resourceGroup.name
