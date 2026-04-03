@description('Name of the Disk Encryption Set.')
param diskEncryptionSetName string

@description('Azure region for deployment.')
param location string = resourceGroup().location

@description('Resource ID of the User Assigned Managed Identity that has Key Vault Crypto Service Encryption User role on the CMK key.')
param userAssignedIdentityId string

@description('The versionless key URI from Key Vault (e.g. https://<vault>.vault.azure.net/keys/<key-name>). The DES will always resolve to the latest active version.')
param keyVaultKeyUri string

@description('Tags to apply to the Disk Encryption Set.')
param tags object

// ---------------------------------------------------------------------------
// Disk Encryption Set for Confidential VM CMK encryption (Key Vault variant)
//
// encryptionType must be ConfidentialVmEncryptedWithCustomerKey.
// rotationToLatestKeyVersionEnabled is set to false because CVM does NOT
// support automatic key rotation. Enabling it would cause the DES to update
// its key reference, but the VMs would not receive the new key until they are
// stopped and the DES is manually updated (see Rotate-CMK.ps1).
// Keeping it false makes the rotation intent explicit and avoids confusion.
// ---------------------------------------------------------------------------
resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2025-01-02' = {
  name: diskEncryptionSetName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    activeKey: {
      keyUrl: keyVaultKeyUri
    }
    encryptionType: 'ConfidentialVmEncryptedWithCustomerKey'
    rotationToLatestKeyVersionEnabled: false
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output diskEncryptionSetId string = diskEncryptionSet.id
output diskEncryptionSetName string = diskEncryptionSet.name
