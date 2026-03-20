# Confidential AVD

Infrastructure-as-Code repository for building **Confidential VM images** and deploying **Confidential Compute session hosts** for Azure Virtual Desktop.

## 📋 Scope

This repository focuses exclusively on:

1. **Confidential VM Image Build** - Azure Compute Gallery, Image Definitions (`TrustedLaunchAndConfidentialVmSupported`), Image Templates (AIB with `Standard_DC8as_v6`)
2. **Confidential VM Deployment** - Session hosts with AMD SEV-SNP / Intel TDX, supporting **two encryption modes**:
   - **Option A - Platform-Managed Keys (PMK)**: `VMGuestStateOnly` encryption, no DES or Managed HSM required
   - **Option B - Customer-Managed Keys (CMK)**: `DiskWithVMGuestState` encryption with Disk Encryption Set backed by Managed HSM
3. **Supporting Infrastructure** - Key Vault, Managed Identity, Disk Encryption Set, Private Endpoints

## 🔐 PMK vs CMK - Choosing Your Encryption Mode

| Aspect | PMK (Platform-Managed Keys) | CMK (Customer-Managed Keys) |
|--------|---------------------------|---------------------------|
| **Security Encryption Type** | `VMGuestStateOnly` | `DiskWithVMGuestState` |
| **What's encrypted** | VM guest state (vTPM, VMGS) | OS disk + VM guest state |
| **Managed HSM required** | ❌ No | ✅ Yes |
| **Disk Encryption Set required** | ❌ No | ✅ Yes |
| **RBAC on HSM key** | Not needed | `Crypto Service Encryption User` |
| **Pipeline parameter** | `confidentialCompute: true` + `customerManagedKeys: false` | `confidentialCompute: true` + `customerManagedKeys: true` |
| **`encryptionAtHost`** | `false` | `false` |
| **Best for** | Simpler setup, no key management overhead | Maximum control, regulatory requirements |

## 📁 Repository Structure

```
confidentialavd/
├── ComponentLibrary/                    # Reusable Bicep modules
│   ├── AzureVirtualDesktop/
│   │   ├── AzureComputeGallery/         # Gallery, Image Definition, Template, Version
│   │   ├── SessionHost/                 # CC & standard session host VMs
│   │   └── ManagedIdentity/             # User-Assigned Identity
│   ├── DiskEncryptionSet/               # CC disk encryption (Managed HSM)
│   ├── KeyVault/                        # Secrets management
│   └── PrivateEndpoint/                 # Private endpoints
│
├── Environments/
│   ├── sub-avd-images-prd/
│   │   └── images/
│   │       └── AzureComputeGallery/     # CC gallery orchestrator & params
│   └── Hostpools/                       # Host pool configuration template
│
├── Pipelines/
│   ├── AVD-GalleryInfrastructure.yml    # Deploy gallery + definitions
│   ├── AVD-ImageBuild.yml               # Build CC image via AIB
│   ├── AVD-DeployAdditionalHosts.yml    # Deploy CC session hosts
│   └── AVD-DeployIMAGER.yml             # Deploy imager VM
│
└── Scripts/
    ├── Register-CCFeatureFlags.ps1      # Register CC feature flags
    ├── PAWImageprep.ps1                 # Pre-sysprep remediation
    ├── ImageCapture/                    # VM capture automation
    └── Sysprep/                         # Sysprep finalization
```

## 🚀 Deployment Workflow

### Step 1 - Deploy Gallery Infrastructure

Deploy the Compute Gallery, Managed Identity, and CC Image Definition:

```bash
az deployment group create \
  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \
  --resource-group rg-avd-images-prd-image-weu-001 \
  --template-file Environments/sub-avd-images-prd/images/AzureComputeGallery/main.bicep \
  --parameters @Environments/sub-avd-images-prd/images/AzureComputeGallery/main.bicepparam
```

Or use pipeline: **AVD-GalleryInfrastructure.yml**

### Step 2 - Build Confidential VM Image

Deploy the AIB Image Template and trigger the build:

Use pipeline: **AVD-ImageBuild.yml** with `imageProfile: cc` and `imageType: cvm`

### Step 3 - Deploy Confidential Session Hosts

Deploy CC session hosts using the gallery image:

Use pipeline: **AVD-DeployAdditionalHosts.yml** with:
- `confidentialCompute: true`
- `customerManagedKeys: false` for **PMK** (no DES needed)
- `customerManagedKeys: true` for **CMK** (DES + Managed HSM required)

## ⚠️ Prerequisites

### For both PMK and CMK
- **Feature Flag**: `Microsoft.Compute/DCav6Series` must be registered (requires support ticket for some regions)
- **Service Connection**: Pipeline service principal with Contributor on images subscription
- **Compute Gallery**: Must exist before image builds (deployed in Step 1)
- **CC VM Size**: DC-series or EC-series VMs (e.g., `Standard_DC4as_v5`, `Standard_EC8as_v6`)

### For CMK only (skip these for PMK)
- **Managed HSM**: Key must exist for Disk Encryption Set (`ConfidentialVmEncryptedWithCustomerKey`)
- **UAMI for DES**: Must have `Crypto Service Encryption User` role on the Managed HSM key
- **`managedHsmKeyUrl`**: Full versioned key URL in the host pool JSON config

## 📚 References

- [Azure Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview)
- [Azure Image Builder](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview)
- [Disk Encryption with Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-disk-encryption)