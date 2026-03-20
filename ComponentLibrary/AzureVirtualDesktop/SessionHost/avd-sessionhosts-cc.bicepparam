using './avd-sessionhosts-cc.bicep'

// =====================================================
// AVD Session Hosts - Confidential Compute Parameters
// =====================================================
// This parameters file configures AVD session hosts with:
// - Confidential Compute (AMD SEV-SNP or Intel TDX)
// - Disk encryption using Disk Encryption Set backed by Managed HSM
// - Secure Boot and vTPM enabled
// =====================================================

// Hostpool Configuration
param hostpoolName = 'hp-avd-prd-cc-weu-001'
param hostpoolResourceGroup = 'rg-avd-prd-hostpools-weu-001'

// VM Configuration
param sessionHostCount = 2
param startingIndex = 1
param vmNamePrefix = 'avdccweu'

// Confidential Compute VM Size
// Note: Use DCasv5, DCadsv5, ECasv5, or ECadsv5 series for AMD SEV-SNP
// Or DCesv5, DCedsv5, ECesv5, or ECedsv5 series for Intel TDX
param vmSize = 'Standard_DC4as_v5'

// Network Configuration
param subnetId = '/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.Network/virtualNetworks/<vnet-name>/subnets/<subnet-name>'

// Security Configuration - Confidential Compute
param secureBootEnabled = true
param vtpmEnabled = true

// Disk Encryption Set backed by Managed HSM
// The DES must be configured with:
// - encryptionType: 'ConfidentialVmEncryptedWithCustomerKey'
// - Key stored in Managed HSM
param diskEncryptionSetId = '/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.Compute/diskEncryptionSets/<des-name>'

// Security Encryption Type for Confidential Compute
// - 'DiskWithVMGuestState': Encrypts both OS disk and VM guest state (recommended)
// - 'VMGuestStateOnly': Encrypts only VM guest state
// - 'NonPersistedTPM': Non-persisted TPM (no disk encryption)
param securityEncryptionType = 'DiskWithVMGuestState'

// OS Disk Configuration
param osDiskStorageAccountType = 'Premium_LRS'
param osDiskSizeGB = 128

// Authentication
param adminUsername = '<admin-username>'
param adminPassword = '<admin-password>'

// Identity Configuration
param userAssignedIdentityId = '/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity-name>'

// Domain Join Configuration
param AADJoin = true
param intuneEnabled = true
param domain = ''
param ouPath = ''
param domainjoinaccount = ''
param domainjoinaccountpassword = ''

// Monitoring Configuration
param dataCollectionRuleId = '/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.Insights/dataCollectionRules/<dcr-name>'

// Image Configuration - Use a confidential compute compatible image
// Option 1: Shared Image Gallery (recommended for custom images)
param SharedImageId = '/subscriptions/<subscription-id>/resourceGroups/<rg-name>/providers/Microsoft.Compute/galleries/<gallery-name>/images/<image-name>/versions/<version>'

// Option 2: Marketplace image (uncomment and set SharedImageId to '' if using marketplace)
// Note: Ensure the image supports confidential compute (Gen2, TrustedLaunch capable)
param imagePublisher = ''
param imageOffer = ''
param imageSku = ''
param imageVersion = ''

// Tags
param tags = {
  Environment: 'Production'
  Application: 'Azure Virtual Desktop'
  SecurityType: 'ConfidentialVM'
  CostCenter: '<cost-center>'
  Owner: '<owner>'
}
