@description('Name of the Key Vault to create.')
param keyVaultName string

@description('Azure region for deployment.')
param location string = resourceGroup().location

@description('Name of the User Assigned Managed Identity that the Disk Encryption Set will use to access this Key Vault.')
param diskEncryptionSetIdentityName string

@description('Name of the CMK key to create inside the Key Vault.')
param keyName string

@description('RSA key size. 3072 or 4096 recommended for CVM workloads.')
@allowed([2048, 3072, 4096])
param keySize int = 3072

@description('Key rotation period expressed as ISO 8601 duration (e.g. P1Y = 1 year, P6M = 6 months). Applied as the auto-rotate policy on the key.')
param keyRotationPeriod string = 'P1Y'

@description('Number of days before key expiry at which to notify via Event Grid / Azure Monitor.')
param keyExpiryNotificationDays int = 30

@description('Resource ID of the Log Analytics Workspace for Key Vault diagnostic settings. Leave empty to skip.')
param logAnalyticsWorkspaceId string = ''

@description('Subnet Resource ID for the Key Vault private endpoint.')
param pepSubnetId string

@description('Resource ID of the privatelink.vaultcore.azure.net Private DNS Zone.')
param privateDnsZoneId string

@description('Tags to apply to all resources.')
param tags object

// ---------------------------------------------------------------------------
// User Assigned Managed Identity for the Disk Encryption Set
// The DES needs its own UAMI so it can call Key Vault independently of the
// AIB / session host identity used elsewhere in the repo.
// ---------------------------------------------------------------------------
resource desIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: diskEncryptionSetIdentityName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Key Vault
// soft-delete + purge protection are MANDATORY for managed disk CMK.
// RBAC authorization is used so we can grant the DES identity the exact roles
// it needs without touching access policies.
// ---------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'premium' // Premium SKU required for HSM-backed keys
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true  // Required for managed disk CMK - cannot be disabled once set
    enabledForDeployment: false
    enabledForDiskEncryption: true
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

// ---------------------------------------------------------------------------
// Private Endpoint so the DES and pipelines can reach the vault
// ---------------------------------------------------------------------------
resource pepNic 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: '${keyVaultName}-pep'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: pepSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${keyVaultName}-plsc'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource pepDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  name: 'default'
  parent: pepNic
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Role assignments
// Key Vault Crypto Officer - needed by the deployment pipeline service principal
// to CREATE the key and set rotation policy.
// Key Vault Crypto Service Encryption User - needed by the DES identity at
// runtime to wrap/unwrap the data encryption key.
// ---------------------------------------------------------------------------
var cryptoOfficerRoleId = '14b46e9e-c2b7-41b4-b07b-48a6ebf60603' // Key Vault Crypto Officer
var cryptoServiceEncryptionUserRoleId = 'e147488a-f6f5-4113-8e2d-b22465e65bf6' // Key Vault Crypto Service Encryption User

resource desIdentityCryptoUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, desIdentity.id, cryptoServiceEncryptionUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cryptoServiceEncryptionUserRoleId)
    principalId: desIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// CMK RSA key with rotation policy
// Note: auto-rotation is NOT supported for Confidential VMs (CVM uses offline
// key rotation only). We still set a rotation policy here to get the
// "expiry approaching" events fired by Key Vault so we can alert on them.
// The rotationPolicy triggers a new key version but the DES update and VM
// drain/deallocate still need to happen manually (see Rotate-CMK.ps1).
// ---------------------------------------------------------------------------
resource cmkKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  name: keyName
  parent: keyVault
  tags: tags
  properties: {
    kty: 'RSA'
    keySize: keySize
    keyOps: [
      'wrapKey'
      'unwrapKey'
    ]
    attributes: {
      enabled: true
    }
    rotationPolicy: {
      attributes: {
        expiryTime: keyRotationPeriod
      }
      lifetimeActions: [
        {
          action: {
            // Notify only - do NOT set type to 'Rotate' because CVM does not
            // support automatic rotation. The notification fires the Event Grid
            // event that triggers our alerting runbook.
            type: 'Notify'
          }
          trigger: {
            timeBeforeExpiry: 'P${keyExpiryNotificationDays}D'
          }
        }
      ]
    }
  }
  dependsOn: [
    desIdentityCryptoUser
  ]
}

// ---------------------------------------------------------------------------
// Diagnostic settings
// ---------------------------------------------------------------------------
resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
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

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output cmkKeyId string = cmkKey.id
output cmkKeyName string = cmkKey.name
// The current key version URL is what the DES activeKey.keyUrl must point to.
// We output the versionless URI so the DES can use auto-version resolution,
// and also the versioned URI for operators who want to pin to a specific version.
output cmkKeyVersionlessUri string = '${keyVault.properties.vaultUri}keys/${keyName}'
output desIdentityId string = desIdentity.id
output desIdentityPrincipalId string = desIdentity.properties.principalId
