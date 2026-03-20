@description('Name of the AVD Hostpool')
param hostpoolName string

@description('Name of the resource group containing the AVD Hostpool (if different from deployment resource group)')
param hostpoolResourceGroup string = ''

@description('Azure region for deployment')
param location string = resourceGroup().location

@description('Number of session hosts to deploy')
param sessionHostCount int

@description('Starting index for VM numbering (default is 1)')
param startingIndex int = 1

@description('VM Size for the session hosts - must be a confidential compute capable size (e.g., Standard_DC2as_v5, Standard_DC4as_v5, Standard_EC2as_v5)')
param vmSize string

@description('Subnet ID for the network interfaces')
param subnetId string

@description('Whether to enable Intune management')
param intuneEnabled bool

@description('VM local admin username')
param LocalAdminAccountSecretName string

@description('VM local admin password')
param LocalAdminPasswordSecretName string

@description('Prefix for resource naming')
param vmNamePrefix string

@description('Whether secure boot should be enabled - required for confidential compute')
param secureBootEnabled bool = true

@description('Whether vTPM should be enabled - required for confidential compute')
param vtpmEnabled bool = true

@description('Resource ID of the user-assigned managed identity with Key Vault access')
param userAssignedIdentityId string

@description('Resource ID of the Key Vault containing domain join secrets')
param DomainKeyVaultId string

@description('Resource ID of the Key Vault containing local admin secrets')
param LocalKeyVaultId string

@description('Name of the secret containing the domain join account username')
param domainJoinAccountSecretName string = 'domain-join-account'

@description('Name of the secret containing the domain join account password')
param domainJoinPasswordSecretName string = 'domain-join-password'

@description('Data Collection Rule ID for monitoring')
param dataCollectionRuleId string

@description('Whether to join VMs to Azure AD (true) or traditional AD domain (false)')
param AADJoin bool

@description('Traditional AD domain name (only required if AADJoin is false)')
param domain string = ''

@description('Organizational Unit path for domain join (only required if AADJoin is false)')
param ouPath string = ''

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

@description('Resource ID of the Disk Encryption Set backed by Managed HSM for confidential compute disk encryption. Required when securityEncryptionType is DiskWithVMGuestState (CMK path). Leave empty for VMGuestStateOnly (PMK path).')
param diskEncryptionSetId string = ''

@description('Security encryption type for confidential compute OS disk. Use DiskWithVMGuestState for full disk encryption with customer-managed keys (requires DES + Managed HSM), or VMGuestStateOnly for platform-managed key encryption (no DES needed).')
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

@description('Availability zones to place VMs in (e.g., ["1"]). Leave empty to deploy without zone pinning.')
param availabilityZones array = []

param tags object

// Variables to parse the Domain Key Vault ID
var DomainKeyVaultIdTrimmed = trim(DomainKeyVaultId)
var DomainKeyVaultIdNormalized = startsWith(DomainKeyVaultIdTrimmed, '/') ? DomainKeyVaultIdTrimmed : '/${DomainKeyVaultIdTrimmed}'
var DomainKeyVaultIdParts = split(DomainKeyVaultIdNormalized, '/')
var DomainKeyVaultIdPartsCount = length(DomainKeyVaultIdParts)

// Validate the Key Vault ID format
var isValidDomainKeyVaultId = DomainKeyVaultIdPartsCount >= 9 && DomainKeyVaultIdParts[1] == 'subscriptions' && DomainKeyVaultIdParts[3] == 'resourceGroups' && DomainKeyVaultIdParts[5] == 'providers' && DomainKeyVaultIdParts[6] == 'Microsoft.KeyVault' && DomainKeyVaultIdParts[7] == 'vaults'

// Extract components with validation
var keyVaultName = isValidDomainKeyVaultId ? last(DomainKeyVaultIdParts) : ''
var keyVaultResourceGroup = isValidDomainKeyVaultId ? DomainKeyVaultIdParts[4] : ''
var keyVaultSubscriptionId = isValidDomainKeyVaultId ? DomainKeyVaultIdParts[2] : ''

// Variables to parse the Local Key Vault ID
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

// Reference to existing Domain Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroup)
}

// Reference to existing Local Key Vault
resource LocalkeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: LocalkeyVaultName
  scope: resourceGroup(LocalkeyVaultSubscriptionId, LocalkeyVaultResourceGroup)
}

// Deploy the session hosts using the confidential compute module
module sessionHosts './avd-sessionhosts-cc.bicep' = {
  name: 'deploy-avd-sessionhosts-cc-${vmNamePrefix}'
  params: {
    tags: tags
    hostpoolName: hostpoolName
    hostpoolResourceGroup: hostpoolResourceGroup
    location: location
    sessionHostCount: sessionHostCount
    startingIndex: startingIndex
    vmSize: vmSize
    subnetId: subnetId
    intuneEnabled: intuneEnabled
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
    dataCollectionRuleId: dataCollectionRuleId
    AADJoin: AADJoin
    domain: domain
    ouPath: ouPath
    domainjoinaccount: AADJoin ? '' : keyVault.getSecret(domainJoinAccountSecretName)
    domainjoinaccountpassword: AADJoin ? '' : keyVault.getSecret(domainJoinPasswordSecretName)
    // Confidential Compute specific parameters
    diskEncryptionSetId: diskEncryptionSetId
    securityEncryptionType: securityEncryptionType
    osDiskStorageAccountType: osDiskStorageAccountType
    osDiskSizeGB: osDiskSizeGB
    availabilityZones: availabilityZones
  }
}

// Debug outputs
output debugOriginalDomainKeyVaultId string = DomainKeyVaultId
output debugNormalizedDomainKeyVaultId string = DomainKeyVaultIdNormalized
output debugDomainKeyVaultIdParts array = DomainKeyVaultIdParts
output debugKeyVaultName string = keyVaultName
output debugKeyVaultResourceGroup string = keyVaultResourceGroup
output debugKeyVaultSubscriptionId string = keyVaultSubscriptionId
output deploymentSummary object = {
  hostpoolName: hostpoolName
  sessionHostCount: sessionHostCount
  startingIndex: startingIndex
  vmSize: vmSize
  imageSource: !empty(SharedImageId) ? 'Shared Image Gallery' : 'Marketplace'
  SharedImageId: SharedImageId
  confidentialCompute: {
    securityType: 'ConfidentialVM'
    securityEncryptionType: securityEncryptionType
    encryptionMode: !empty(diskEncryptionSetId) ? 'CustomerManagedKey' : 'PlatformManagedKey'
    diskEncryptionSetId: !empty(diskEncryptionSetId) ? diskEncryptionSetId : 'N/A (Platform-Managed Keys)'
    secureBootEnabled: secureBootEnabled
    vtpmEnabled: vtpmEnabled
  }
}
