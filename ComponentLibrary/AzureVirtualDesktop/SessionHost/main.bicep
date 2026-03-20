// ============================================================
// AVD Session Host Orchestrator - Standard (Trusted Launch)
// ============================================================
// Retrieves secrets from Key Vault and deploys session hosts
// using the standard avd-sessionhosts.bicep module.
//
// For Confidential Compute session hosts, use main-cc.bicep.
// ============================================================

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

@description('VM Size for the session hosts')
param vmSize string

@description('Subnet ID for the network interfaces')
param subnetId string

@description('Whether to enable Intune management')
param intuneEnabled bool

@description('VM local admin username secret name')
param LocalAdminAccountSecretName string

@description('VM local admin password secret name')
param LocalAdminPasswordSecretName string

@description('Prefix for resource naming')
param vmNamePrefix string

@description('Whether secure boot should be enabled')
param secureBootEnabled bool = true

@description('Whether vTPM should be enabled')
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

@description('OS disk size in GB')
param osDiskSizeGB int = 128

@description('Availability zones to place VMs in (e.g., ["1"]). Leave empty to deploy without zone pinning.')
param availabilityZones array = []

param tags object

// Variables to parse the Domain Key Vault ID
var DomainKeyVaultIdTrimmed = trim(DomainKeyVaultId)
var DomainKeyVaultIdNormalized = startsWith(DomainKeyVaultIdTrimmed, '/') ? DomainKeyVaultIdTrimmed : '/${DomainKeyVaultIdTrimmed}'
var DomainKeyVaultIdParts = split(DomainKeyVaultIdNormalized, '/')
var DomainKeyVaultIdPartsCount = length(DomainKeyVaultIdParts)

var isValidDomainKeyVaultId = DomainKeyVaultIdPartsCount >= 9 && DomainKeyVaultIdParts[1] == 'subscriptions' && DomainKeyVaultIdParts[3] == 'resourceGroups' && DomainKeyVaultIdParts[5] == 'providers' && DomainKeyVaultIdParts[6] == 'Microsoft.KeyVault' && DomainKeyVaultIdParts[7] == 'vaults'

var keyVaultName = isValidDomainKeyVaultId ? last(DomainKeyVaultIdParts) : ''
var keyVaultResourceGroup = isValidDomainKeyVaultId ? DomainKeyVaultIdParts[4] : ''
var keyVaultSubscriptionId = isValidDomainKeyVaultId ? DomainKeyVaultIdParts[2] : ''

// Variables to parse the Local Key Vault ID
var LocalKeyVaultIdTrimmed = trim(LocalKeyVaultId)
var LocalKeyVaultIdNormalized = startsWith(LocalKeyVaultIdTrimmed, '/') ? LocalKeyVaultIdTrimmed : '/${LocalKeyVaultIdTrimmed}'
var LocalKeyVaultIdParts = split(LocalKeyVaultIdNormalized, '/')
var LocalKeyVaultIdPartsCount = length(LocalKeyVaultIdParts)

var isValidLocalKeyVaultId = LocalKeyVaultIdPartsCount >= 9 && LocalKeyVaultIdParts[1] == 'subscriptions' && LocalKeyVaultIdParts[3] == 'resourceGroups' && LocalKeyVaultIdParts[5] == 'providers' && LocalKeyVaultIdParts[6] == 'Microsoft.KeyVault' && LocalKeyVaultIdParts[7] == 'vaults'

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

// Deploy the session hosts using the standard Trusted Launch module
module sessionHosts './avd-sessionhosts.bicep' = {
  name: 'deploy-avd-sessionhosts-${vmNamePrefix}'
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
    osDiskSizeGB: osDiskSizeGB
    availabilityZones: availabilityZones
  }
}

output deploymentSummary object = {
  hostpoolName: hostpoolName
  sessionHostCount: sessionHostCount
  startingIndex: startingIndex
  vmSize: vmSize
  imageSource: !empty(SharedImageId) ? 'Shared Image Gallery' : 'Marketplace'
  SharedImageId: SharedImageId
  securityType: 'TrustedLaunch'
}
