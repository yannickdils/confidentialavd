@description('Azure region for the managed identity')
param location string = resourceGroup().location

@description('Name of the user-assigned managed identity')
param identityName string

param tags object

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

output identityId string = managedIdentity.id
output identityPrincipalId string = managedIdentity.properties.principalId
output identityClientId string = managedIdentity.properties.clientId
output identityName string = managedIdentity.name
