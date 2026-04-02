# Component Library

This folder contains reusable Azure Bicep modules for building Confidential VM images and deploying Confidential Compute session hosts. These modules follow Azure best practices and are designed to be composed together.

## 📁 Module Overview

| Module | Description |
|--------|-------------|
| [AzureVirtualDesktop/](AzureVirtualDesktop/) | Compute Gallery, Image Definitions/Templates, CC Session Hosts, Managed Identity |
| [DiskEncryptionSet/](DiskEncryptionSet/) | Disk Encryption Set for Confidential VM encryption (Managed HSM backed) |
| [KeyVault/](KeyVault/) | Azure Key Vault for secrets management |
| [PrivateEndpoint/](PrivateEndpoint/) | Private endpoint configurations |
| [ResourceGroup/](ResourceGroup/) | Subscription-level resource group deployment |

## 🖥️ Azure Virtual Desktop Modules

The `AzureVirtualDesktop/` folder contains modules for Confidential VM image management and deployment:

| Module | Purpose |
|--------|---------|
| `AzureComputeGallery/` | Azure Compute Gallery, Image Definitions, Image Templates, Image Versions |
| `SessionHost/` | Confidential Compute session host and imager VM deployment |
| `ManagedIdentity/` | User-Assigned Managed Identity for AIB and Key Vault access |

## 🚀 Usage

### Referencing Modules in Bicep

```bicep
// Example: Deploy a Confidential Compute image definition
module imgDefCC 'ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/main.bicep' = {
  name: 'deploy-imgd-cc'
  params: {
    galleryName: 'galavdimagesprdweu001'
    imageName: 'imgd-avd-images-prd-cc-win11-25h2-001'
    location: 'belgiumcentral'
    publisher: '<ORGANIZATION_NAME>'
    offer: 'Windows11-25H2'
    sku: 'CCMultiSession'
    features: [
      { name: 'SecurityType', value: 'TrustedLaunchAndConfidentialVmSupported' }
    ]
    tags: tags
  }
}
```

### Using with Parameter Files

Each module supports parameter files (`.parameters.json` or `.bicepparam`) for environment-specific configurations:

```bash
# Deploy using Azure CLI
az deployment group create \
  --resource-group rg-avd-images-prd-image-weu-001 \
  --template-file Environments/sub-avd-images-prd/images/AzureComputeGallery/main.bicep \
  --parameters @Environments/sub-avd-images-prd/images/AzureComputeGallery/main.bicepparam
```

## 📋 Module Standards

All modules in this library follow these standards:

- **Naming**: Follow Azure naming conventions (`main.bicep` as entry point)
- **Parameters**: Use descriptive parameter names with validation where applicable
- **Outputs**: Export resource IDs and names for module chaining
- **Documentation**: Include inline comments for complex logic
- **Security**: Support Confidential Compute, Managed HSM, and Managed Identities

## 🔗 Deployment Order

Typical deployment order for Confidential VM image build and session host deployment:

```
1. ManagedIdentity       (User-Assigned Identity for AIB + Key Vault)
2. AzureComputeGallery   (Compute Gallery)
3. Image Definition      (CC image definition with TrustedLaunchAndConfidentialVmSupported)
4. Image Template        (AIB template with DC-series build VM)
5. Image Build           (AIB run → produces image version)
6. DiskEncryptionSet     (Managed HSM-backed DES for CC disk encryption) — only required for CMK, skip for PMK
7. KeyVault              (Secrets for admin credentials / domain join)
8. SessionHost (CC)      (Confidential Compute session hosts)
```

## 📚 Related Documentation

- [📝 Blog: How to build and deploy confidential AVD images with Azure Image Builder](https://www.tunecom.be/how-to-build-confidential-avd-images-with-azure-image-builder/)
- [Azure Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview)
- [Azure Image Builder](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview)
- [Azure Bicep Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)