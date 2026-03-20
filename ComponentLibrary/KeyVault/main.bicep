@description('The name of the key vault to be created.')
param keyVaultName string

@description('Azure region for the storage account')
param location string = resourceGroup().location

@description('The name of the managed identity to be created.')
param managedIdentityName string

@description('The SKU name of the key vault.')
param keyVaultSkuName string

@description('Specifies whether Azure Virtual Machines are permitted to retrieve certificates stored as secrets from the key vault.')
param enabledForDeployment bool

@description('Specifies whether Azure Disk Encryption is permitted to retrieve secrets from the vault and unwrap keys.')
param enabledForDiskEncryption bool

@description('Specifies whether Azure Resource Manager is permitted to retrieve secrets from the key vault.')
param enabledForTemplateDeployment bool

@description('Optional: Service Principal ID to grant Key Vault Secrets User role. Leave empty to skip this assignment.')
param additionalServicePrincipalId string

@description('The ID of the subnet where the Key Vault private endpoint will be created.')
param privateDnsZoneId string

@description('The ID of the subnet where the Key Vault private endpoint will be created.')
param PEPSubnetID string

@description('The target subresource for the private endpoint. Typically "vault" for Key Vault.')
param targetSubresource string

param publicNetworkAccess string

@description('Resource ID of the Log Analytics Workspace for diagnostic settings. Leave empty to skip diagnostic settings.')
param logAnalyticsWorkspaceId string = ''

param tags object

@secure()
param localadminpasswordValue string
param localadminuserValue string

// Create managed identity
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  tags: tags
  location: location
}

// Create Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  tags: tags
  location: location
  properties: {
    enabledForDeployment: enabledForDeployment
    enabledForDiskEncryption: enabledForDiskEncryption
    enabledForTemplateDeployment: enabledForTemplateDeployment
    enablePurgeProtection: true
    enableRbacAuthorization: true
    enableSoftDelete: true
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: keyVaultSkuName
    }
    accessPolicies: []
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

module privateEndpoint '../PrivateEndpoint/main.bicep' = {
  name: 'privateEndpoint'
  params: {
    tags: tags
    privateDnsZoneId: privateDnsZoneId
    privateEndpointName: keyVaultName
    privateLinkResource: keyVault.id
    subnet: PEPSubnetID
    targetSubResource: targetSubresource
    location: location
  }
}

// Diagnostic settings for the Key Vault - send all logs and metrics to Log Analytics
resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'AllLogs'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Assign Key Vault Secrets User role to managed identity
resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentity.id, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    ) // Key Vault Secrets User
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Conditionally assign Key Vault Secrets User role to additional Service Principal
resource additionalSpnKeyVaultSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(additionalServicePrincipalId)) {
  name: guid(keyVault.id, additionalServicePrincipalId, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    ) // Key Vault Secrets User
    principalId: additionalServicePrincipalId
    principalType: 'ServicePrincipal'
  }
}

module setLocalAdminPassword 'Secret/setSecret.bicep' = {
  name: 'setLocalAdminPassword'
  dependsOn: [
    keyVault
    privateEndpoint
    keyVaultSecretsUserRole
  ]
  params: {
    keyVaultName: keyVaultName
    secretName: 'local-admin-password'
    secretValue: localadminpasswordValue
    tags: tags
  }
}

module setLocalAdminAccount 'Secret/setSecret.bicep' = {
  name: 'setLocalAdminUser'
  dependsOn: [
    keyVault
    privateEndpoint
    keyVaultSecretsUserRole
  ]
  params: {
    keyVaultName: keyVaultName
    secretName: 'local-admin-user'
    secretValue: localadminuserValue
    tags: tags
  }
}

// Output the Key Vault and Managed Identity resource IDs
output keyVaultId string = keyVault.id
output managedIdentityId string = managedIdentity.id
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
output additionalSpnRoleAssignmentId string = !empty(additionalServicePrincipalId)
  ? additionalSpnKeyVaultSecretsUserRole.id
  : ''
