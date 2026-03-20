@description('Name of the Disk Encryption Set')
param diskEncryptionSetName string

@description('Azure region for deployment')
param location string = resourceGroup().location

@description('Resource ID of the User Assigned Managed Identity that has Crypto Service Encryption User role on the Managed HSM key')
param userAssignedIdentityId string

@description('The full key URL from Managed HSM (e.g. https://<hsm-name>.managedhsm.azure.net/keys/<key-name>/<key-version>)')
param keyUrl string

@description('Tags to apply to the Disk Encryption Set')
param tags object

// Create the Disk Encryption Set for Confidential VM encryption
// This DES uses the UAMI to access the key in Managed HSM
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
      keyUrl: keyUrl
    }
    encryptionType: 'ConfidentialVmEncryptedWithCustomerKey'
    rotationToLatestKeyVersionEnabled: false
  }
}

// Outputs
output diskEncryptionSetId string = diskEncryptionSet.id
output diskEncryptionSetName string = diskEncryptionSet.name
