@description('Azure region for deployment')
param location string = resourceGroup().location

@description('VM Size for the imager VM - must be a confidential compute capable size (e.g., Standard_DC4as_v5, Standard_DC8as_v5, Standard_EC4as_v5)')
param vmSize string

@description('Subnet ID for the network interfaces')
param subnetId string

@description('VM local admin username')
@secure()
param adminUsername string

@description('VM local admin password')
@secure()
param adminPassword string

@description('Prefix for resource naming')
param vmNamePrefix string

@description('Whether secure boot should be enabled - required for confidential compute')
param secureBootEnabled bool = true

@description('Whether vTPM should be enabled - required for confidential compute')
param vtpmEnabled bool = true

@description('Resource ID of the user-assigned managed identity with Key Vault access')
param userAssignedIdentityId string

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

@description('Resource ID of the Disk Encryption Set backed by Managed HSM for confidential compute disk encryption')
param diskEncryptionSetId string

@description('Security encryption type for confidential compute OS disk. Use DiskWithVMGuestState for full disk encryption with VM guest state, VMGuestStateOnly for just guest state encryption, or NonPersistedTPM for non-persisted TPM')
@allowed([
  'DiskWithVMGuestState'
  'VMGuestStateOnly'
  'NonPersistedTPM'
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

// Network interface
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmNamePrefix}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Virtual Machine with Confidential Compute
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmNamePrefix
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    licenseType: 'Windows_Client'
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmNamePrefix
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: !empty(SharedImageId) ? {
        id: SharedImageId
      } : {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
      osDisk: {
        name: '${vmNamePrefix}-osdisk'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        diskSizeGB: osDiskSizeGB
        managedDisk: {
          storageAccountType: osDiskStorageAccountType
          // Security profile for confidential compute disk encryption
          // Note: Do NOT add a top-level diskEncryptionSet here - for Confidential VMs,
          // the DES must only be specified inside securityProfile. A top-level DES triggers
          // standard SSE-CMK which is incompatible with ConfidentialVmEncryptedWithCustomerKey.
          securityProfile: {
            securityEncryptionType: securityEncryptionType
            diskEncryptionSet: {
              id: diskEncryptionSetId
            }
          }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
    // Confidential Compute security profile
    // Note: encryptionAtHost must be false when using ConfidentialVmEncryptedWithCustomerKey
    // with DiskWithVMGuestState, as the DES-backed encryption handles disk protection.
    securityProfile: {
      encryptionAtHost: securityEncryptionType == 'DiskWithVMGuestState' ? false : true
      securityType: 'ConfidentialVM'
      uefiSettings: {
        secureBootEnabled: secureBootEnabled
        vTpmEnabled: vtpmEnabled
      }
    }
  }
}

// Outputs
output vmName string = vm.name
output vmId string = vm.id
output nicId string = nic.id
output confidentialComputeInfo object = {
  securityType: 'ConfidentialVM'
  securityEncryptionType: securityEncryptionType
  diskEncryptionSetId: diskEncryptionSetId
  secureBootEnabled: secureBootEnabled
  vtpmEnabled: vtpmEnabled
}
