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

@description('Domain join service account username (only required if AADJoin is false)')
@secure()
param domainjoinaccount string

@description('Domain join service account password (only required if AADJoin is false)')
@secure()
param domainjoinaccountpassword string

@description('Data Collection Rule ID for monitoring')
param dataCollectionRuleId string

@description('Whether to join VMs to Azure AD (true) or traditional AD domain (false)')
param AADJoin bool

@description('Traditional AD domain name (only required if AADJoin is false)')
param domain string

@description('Organizational Unit path for domain join (only required if AADJoin is false)')
param ouPath string

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

// Get existing hostpool for registration token
// Use hostpoolResourceGroup if specified, otherwise use the deployment resource group
resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' existing = {
  name: hostpoolName
  scope: resourceGroup(!empty(hostpoolResourceGroup) ? hostpoolResourceGroup : resourceGroup().name)
}

// Network interfaces
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    name: '${vmNamePrefix}${padLeft(startingIndex + i, 2, '0')}-nic'  // CHANGED: Removed hyphen before number
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
]

// Virtual Machines with Confidential Compute
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = [
  for i in range(0, sessionHostCount): {
    name: '${vmNamePrefix}${padLeft(startingIndex + i, 2, '0')}'
    location: location
    zones: !empty(availabilityZones) ? [availabilityZones[i % length(availabilityZones)]] : null
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
        computerName: '${vmNamePrefix}${padLeft(startingIndex + i, 2, '0')}'
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          patchSettings: {
            patchMode: 'AutomaticByPlatform'
            assessmentMode: 'AutomaticByPlatform'
            automaticByPlatformSettings: {
              bypassPlatformSafetyChecksOnUserSchedule: true
            }
          }
        }
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
          name: '${vmNamePrefix}${padLeft(startingIndex + i, 2, '0')}-osdisk'
          createOption: 'FromImage'
          caching: 'ReadWrite'
          diskSizeGB: osDiskSizeGB
          managedDisk: {
            storageAccountType: osDiskStorageAccountType
            // Security profile for confidential compute disk encryption
            // For CMK (DiskWithVMGuestState): DES is referenced inside securityProfile only.
            //   Do NOT add a top-level diskEncryptionSet - that triggers standard SSE-CMK
            //   which is incompatible with ConfidentialVmEncryptedWithCustomerKey.
            // For PMK (VMGuestStateOnly): No DES reference is needed at all.
            //   Platform-managed keys handle VM guest state encryption automatically.
            securityProfile: {
              securityEncryptionType: securityEncryptionType
              diskEncryptionSet: !empty(diskEncryptionSetId) ? {
                id: diskEncryptionSetId
              } : null
            }
          }
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: nic[i].id
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
      // Note: encryptionAtHost must be false when using Confidential VMs with either
      // DiskWithVMGuestState (CMK) or VMGuestStateOnly (PMK), as the confidential
      // disk encryption mechanism is incompatible with host-level encryption.
      securityProfile: {
        encryptionAtHost: false
        securityType: 'ConfidentialVM'
        uefiSettings: {
          secureBootEnabled: secureBootEnabled
          vTpmEnabled: vtpmEnabled
        }
      }
    }
  }
]

// Domain Join Extension - AAD or Traditional AD
resource domainJoin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    name: '${vm[i].name}/${AADJoin ? 'AADLoginForWindows' : 'JsonADDomainExtension'}'
    location: location
    tags: tags
    properties: AADJoin
      ? {
          // AAD Join Extension
          publisher: 'Microsoft.Azure.ActiveDirectory'
          type: 'AADLoginForWindows'
          typeHandlerVersion: '2.0'
          autoUpgradeMinorVersion: true
          settings: {
            mdmId: intuneEnabled ? '0000000a-0000-0000-c000-000000000000' : null // Microsoft Intune Guid
          }
        }
      : {
          // Traditional Domain Join Extension
          publisher: 'Microsoft.Compute'
          type: 'JsonADDomainExtension'
          typeHandlerVersion: '1.3'
          autoUpgradeMinorVersion: true
          settings: {
            name: domain
            ouPath: ouPath
            user: domainjoinaccount
            restart: 'true'
            options: '3'
            NumberOfRetries: '4'
            RetryIntervalInMilliseconds: '30000'
          }
          protectedSettings: {
            password: domainjoinaccountpassword
          }
        }
  }
]

// Intune MDM Auto-Enrollment via Device Credential (required for Entra ID joined VMs where no user signs in immediately)
// Sets the registry policy to enroll the device in Intune using its own Entra ID identity rather than waiting for a user login
resource mdmEnrollment 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [
  for i in range(0, sessionHostCount): if (AADJoin) {
    name: '${vm[i].name}/intuneMdmEnrollment'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Compute'
      type: 'CustomScriptExtension'
      typeHandlerVersion: '1.10'
      autoUpgradeMinorVersion: true
      settings: {
        commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -Command "New-Item -Path \'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CurrentVersion\\MDM\' -Force | Out-Null; Set-ItemProperty -Path \'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CurrentVersion\\MDM\' -Name \'AutoEnrollMDM\' -Value 1 -Type DWord; Set-ItemProperty -Path \'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CurrentVersion\\MDM\' -Name \'UseAADCredentialType\' -Value 2 -Type DWord; Write-Output \'MDM auto-enrollment configured with Device Credential type\'"'
      }
    }
    dependsOn: [
      domainJoin[i]
    ]
  }
]

// AVD Agent Extension
resource avdAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    name: '${vm[i].name}/Microsoft.PowerShell.DSC'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.83'
      autoUpgradeMinorVersion: true
      settings: {
        modulesUrl: 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_09-08-2022.zip'
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          hostPoolName: hostpoolName
          registrationInfoToken: first(hostPool.listRegistrationTokens().value).token
          aadJoin: AADJoin
        }
      }
    }
    dependsOn: [
      domainJoin[i]
      mdmEnrollment[i]
    ]
  }
]

// Azure Monitor Agent Extension - required for DCR
resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    name: '${vm[i].name}/AzureMonitorWindowsAgent'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Azure.Monitor'
      type: 'AzureMonitorWindowsAgent'
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: true
      settings: {
        authentication: {
          managedIdentity: {
            'identifier-name': 'mi_res_id'
            'identifier-value': userAssignedIdentityId
          }
        }
      }
    }
    dependsOn: [
      avdAgent[i]
    ]
  }
]

// Dependency Agent Extension - required for VM Insights (Map feature) with AMA
resource dependencyAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    name: '${vm[i].name}/DependencyAgentWindows'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Azure.Monitoring.DependencyAgent'
      type: 'DependencyAgentWindows'
      typeHandlerVersion: '9.10'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: true
      settings: {
        enableAMA: 'true'
      }
    }
    dependsOn: [
      azureMonitorAgent[i]
    ]
  }
]

// Guest Attestation Extension - required for Confidential VM integrity monitoring
resource guestAttestation 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = [
  for i in range(0, sessionHostCount): {
    name: '${vm[i].name}/GuestAttestation'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Azure.Security.WindowsAttestation'
      type: 'GuestAttestation'
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: true
      settings: {
        AttestationConfig: {
          MaaSettings: {
            maaEndpoint: ''
            maaTenantName: 'GuestAttestation'
          }
          AscSettings: {
            ascReportingEndpoint: ''
            ascReportingFrequency: ''
          }
          useCustomToken: 'false'
          disableAlerts: 'false'
        }
      }
    }
    dependsOn: [
      azureMonitorAgent[i]
    ]
  }
]

// DCR Association for each VM
resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [
  for i in range(0, sessionHostCount): {
    name: 'dcra-${guid(vm[i].id, dataCollectionRuleId)}'
    scope: vm[i]
    properties: {
      dataCollectionRuleId: dataCollectionRuleId
      description: 'Association of AVD session host with monitoring data collection rule'
    }
    dependsOn: [
      azureMonitorAgent[i]
    ]
  }
]

// Outputs
output vmResourceIds array = [for i in range(0, sessionHostCount): vm[i].id]
output deploymentInfo object = {
  hostpoolName: hostpoolName
  sessionHostCount: sessionHostCount
  startingIndex: startingIndex
  imageSource: !empty(SharedImageId) ? 'Shared Image Gallery' : 'Marketplace'
  imageDetails: !empty(SharedImageId) ? SharedImageId : '${imagePublisher}/${imageOffer}/${imageSku}/${imageVersion}'
  confidentialCompute: {
    securityType: 'ConfidentialVM'
    securityEncryptionType: securityEncryptionType
    encryptionMode: !empty(diskEncryptionSetId) ? 'CustomerManagedKey' : 'PlatformManagedKey'
    diskEncryptionSetId: !empty(diskEncryptionSetId) ? diskEncryptionSetId : 'N/A (Platform-Managed Keys)'
    secureBootEnabled: secureBootEnabled
    vtpmEnabled: vtpmEnabled
  }
}
