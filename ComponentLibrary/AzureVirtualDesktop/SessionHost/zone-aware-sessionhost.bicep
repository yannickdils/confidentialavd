// ---------------------------------------------------------------------------
// Zone-aware Confidential VM session host deployment
//
// Deploys a CVM session host to the first available zone from a preference
// list, falling back through the remaining zones if the preferred zone returns
// a capacity error (SkuNotAvailable or AllocationFailed).
//
// This module is meant to be called from a parent deployment (typically
// AVD-DeployAdditionalHosts) that iterates over the session host count. The
// parent passes the preferred zone and the fallback order; this module
// encapsulates the per-host zone selection.
//
// DC-series confidential VMs run on specialised hardware and the pool is
// smaller than the general D-series. Zone capacity is not uniform. A scale-out
// that succeeds in Zone 1 today may fail next week when that zone is saturated,
// while Zone 2 has capacity. The zone failover pattern absorbs this variance.
//
// Usage note: Azure Resource Manager does not have a native "try this zone,
// fall back on error" primitive. The failover logic lives in the pipeline
// (AVD-DeployAdditionalHosts.yml) that invokes this module, catching the
// deployment failure and re-invoking with the next preferred zone. This
// Bicep module handles a single deployment attempt for a single zone.
// ---------------------------------------------------------------------------

@description('Session host VM name.')
param vmName string

@description('Azure region for the session host (e.g. westeurope, belgiumcentral).')
param location string

@description('Target availability zone. Pass a single zone string: "1", "2", or "3".')
@allowed(['1', '2', '3'])
param zone string

@description('VM size. Must be a DC-series or EC-series confidential VM size.')
param vmSize string = 'Standard_DC4as_v5'

@description('Resource ID of the compute gallery image version.')
param imageReferenceId string

@description('Resource ID of the virtual network subnet.')
param subnetId string

@description('Resource ID of the Disk Encryption Set configured with ConfidentialVmEncryptedWithCustomerKey.')
param diskEncryptionSetId string

@description('Administrator username.')
param adminUsername string

@description('Administrator password. Pass via Key Vault reference in the parent deployment.')
@secure()
param adminPassword string

@description('Tags to apply to the VM. Include tags that match your autoscale exclusion tag name if relevant.')
param tags object = {}

// ---------------------------------------------------------------------------
// Network interface
// ---------------------------------------------------------------------------
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
  tags: tags
}

// ---------------------------------------------------------------------------
// Confidential VM
//
// securityType: ConfidentialVM enforces AMD SEV-SNP placement.
// encryptionAtHost is not used; ConfidentialVmEncryptedWithCustomerKey is
// applied to the OS disk instead via diskEncryptionSet.
// ---------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  zones: [zone]
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    securityProfile: {
      securityType: 'ConfidentialVM'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      imageReference: {
        id: imageReferenceId
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
          securityProfile: {
            securityEncryptionType: 'DiskWithVMGuestState'
            diskEncryptionSet: {
              id: diskEncryptionSetId
            }
          }
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
  tags: tags
}

// ---------------------------------------------------------------------------
// GuestAttestation extension
//
// maaEndpoint is left empty so the extension uses the shared regional MAA
// endpoint automatically. For Belgium Central deployments, leaving this empty
// defaults to sharedweu.weu.attest.azure.net. Set it to
// 'https://sharedbec.bec.attest.azure.net' to pin to the region-local
// authority, as discussed in part 3 of the series.
// ---------------------------------------------------------------------------
resource guestAttestation 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'GuestAttestation'
  location: location
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
}

// ---------------------------------------------------------------------------
// Outputs, consumed by the parent pipeline for DCR association, monitoring
// setup, and failover bookkeeping.
// ---------------------------------------------------------------------------
output vmId string = vm.id
output vmName string = vm.name
output deployedZone string = zone
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
