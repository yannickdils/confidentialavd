@description('Azure region for deployment')
param location string = resourceGroup().location

@description('VM Size for the imager VM - must be a confidential compute capable size (e.g., Standard_DC4as_v5, Standard_DC8as_v5, Standard_EC4as_v5)')
param vmSize string

@description('Subnet ID for the network interfaces')
param subnetId string

@description('VM local admin username secret name')
param LocalAdminAccountSecretName string

@description('VM local admin password secret name')
param LocalAdminPasswordSecretName string

@description('Prefix for resource naming')
param vmNamePrefix string

@description('Whether secure boot should be enabled - required for confidential compute')
param secureBootEnabled bool = true

@description('Whether vTPM should be enabled - required for confidential compute')
param vtpmEnabled bool = true

@description('Resource ID of the user-assigned managed identity with Key Vault access')
param userAssignedIdentityId string

@description('Resource ID of the Local Key Vault containing local admin secrets')
param LocalKeyVaultId string

@description('Image publisher for the VM (only required if not using Shared Image Gallery)')
param imagePublisher string = ''

@description('Image offer for the VM (only required if not using Shared Image Gallery)')
param imageOffer string = ''

@description('Image SKU for the VM (only required if not using Shared Image Gallery)')
param imageSku string = ''

@description('Image version for the VM (only required if not using Shared Image Gallery)')
param imageVersion string = ''

@description('Resource ID of the Shared Image Gallery image version (optional - if provided, overrides marketplace image parameters)')
param SharedImageId string = ''

@description('Resource ID of the Disk Encryption Set backed by Managed HSM (required for CMK, leave empty for PMK)')
param diskEncryptionSetId string = ''

@description('Security encryption type for confidential compute OS disk. Use DiskWithVMGuestState for CMK (requires DES) or VMGuestStateOnly for PMK (no DES needed)')
@allowed([
  'DiskWithVMGuestState'
  'VMGuestStateOnly'
])
param securityEncryptionType string = 'DiskWithVMGuestState'

@description('OS disk storage account type - must be Premium_LRS for confidential compute')
@allowed([
  'Premium_LRS'
])
param osDiskStorageAccountType string = 'Premium_LRS'

@description('OS disk size in GB (optional - if not specified, uses the image default size)')
param osDiskSizeGB int = 128

param tags object

//Variables to parse the Local Key Vault ID
var LocalKeyVaultIdTrimmed = trim(LocalKeyVaultId)
var LocalKeyVaultIdNormalized = startsWith(LocalKeyVaultIdTrimmed, '/') ? LocalKeyVaultIdTrimmed : '/${LocalKeyVaultIdTrimmed}'
var LocalKeyVaultIdParts = split(LocalKeyVaultIdNormalized, '/')
var LocalKeyVaultIdPartsCount = length(LocalKeyVaultIdParts)

// Validate the Key Vault ID format
var isValidLocalKeyVaultId = LocalKeyVaultIdPartsCount >= 9 && LocalKeyVaultIdParts[1] == 'subscriptions' && LocalKeyVaultIdParts[3] == 'resourceGroups' && LocalKeyVaultIdParts[5] == 'providers' && LocalKeyVaultIdParts[6] == 'Microsoft.KeyVault' && LocalKeyVaultIdParts[7] == 'vaults'

// Extract components with validation
var LocalkeyVaultName = isValidLocalKeyVaultId ? last(LocalKeyVaultIdParts) : ''
var LocalkeyVaultResourceGroup = isValidLocalKeyVaultId ? LocalKeyVaultIdParts[4] : ''
var LocalkeyVaultSubscriptionId = isValidLocalKeyVaultId ? LocalKeyVaultIdParts[2] : ''

// Reference to existing Local Key Vault
resource LocalkeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: LocalkeyVaultName
  scope: resourceGroup(LocalkeyVaultSubscriptionId, LocalkeyVaultResourceGroup)
}

// Deploy the imager VM using the confidential compute module
module sessionHosts './avd-imager-cc.bicep' = {
  name: 'deploy-avd-imager-cc-${vmNamePrefix}'
  params: {
    tags: tags
    location: location
    vmSize: vmSize
    subnetId: subnetId
    adminUsername: LocalkeyVault.getSecret(LocalAdminAccountSecretName)
    adminPassword: LocalkeyVault.getSecret(LocalAdminPasswordSecretName)
    vmNamePrefix: vmNamePrefix
    imageOffer: imageOffer
    imagePublisher: imagePublisher
    imageSku: imageSku
    imageVersion: imageVersion
    SharedImageId: SharedImageId
    secureBootEnabled: secureBootEnabled
    vtpmEnabled: vtpmEnabled
    userAssignedIdentityId: userAssignedIdentityId
    // Confidential Compute specific parameters
    diskEncryptionSetId: diskEncryptionSetId
    securityEncryptionType: securityEncryptionType
    osDiskStorageAccountType: osDiskStorageAccountType
    osDiskSizeGB: osDiskSizeGB
  }
}
