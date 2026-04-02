# AVD Image Infrastructure - Azure Compute Gallery

This folder contains the Bicep parameter files and orchestrator for deploying the Confidential Compute image infrastructure for the **sub-avd-images-prd** subscription.

## Resource Group

- **Subscription**: `sub-avd-images-prd` (`<SUBSCRIPTION_ID_IMAGES_PRD>`)
- **Resource Group**: `rg-avd-images-prd-image-weu-001`

## Structure

```
AzureComputeGallery/
├── main.bicep                          # Orchestrator - deploys gallery, CC definition, and identity
├── main.bicepparam                     # Parameters for orchestrator
├── README.md                           # This file
│
├── ManagedIdentity/
│   └── umi-imgt-avd-images-prd-intcoreapps-win.bicepparam   # User-Assigned Identity for AIB
│
├── galavdimagesprdweu001.bicepparam     # Primary gallery (westeurope)
│
├── ImageDefinitions/
│   └── imgd-avd-images-prd-cc-win11-25h2-001.bicepparam      # Confidential Compute (TrustedLaunch+CVM)
│
└── ImageTemplates/
    └── imgt-avd-images-prd-cc-win.bicepparam                 # CC (DC8as_v6, 3-region replication)
```

## Gallery

| Gallery Name | Location | Purpose |
|---|---|---|
| `galavdimagesprdweu001` | westeurope | Production gallery for CVM images |

## Image Template

| Template | Source Image | Key Features | VM Size | Target Gallery |
|---|---|---|---|---|
| **cc** | office-365/win11-25h2-avd-m365 | CC, RDP Shortpath | Standard_DC8as_v6 | galavdimagesprdweu001 |

## Confidential VM (CVM) Image Build

### Architecture

The CVM image build uses the Azure Image Builder (AIB) pipeline.
The key difference from standard images is the **target image definition**:

```
Source (marketplace)          Build VM            Target Image Definition              Session Host

office-365/win11-25h2   →   Standard_DC8as_v6 →  imgd-...-cc-win11-25h2-001        →  Standard_DC8as_v6
                              (TrustedLaunch)     SecurityType: TrustedLaunch          securityEncryption:
                                                    AndConfidentialVmSupported          DiskWithVMGuestState
```

### How it works

1. **AIB Build VM** - Uses `Standard_DC8as_v6` with TrustedLaunch.
   The AIB API (`2024-02-01`) does **not** expose a `securityProfile` on `vmProfile`;
   TrustedLaunch is enabled automatically when the target image definition requires it.

2. **Target Image Definition** - `imgd-avd-images-prd-cc-win11-25h2-001` in gallery
   `galavdimagesprdweu001` has `SecurityType: TrustedLaunchAndConfidentialVmSupported`.
   This makes the output image version compatible with both TrustedLaunch and CVM session hosts.

3. **Replication** - The CC image version is replicated to `westeurope`, `belgiumcentral`,
   and `northeurope` to support session host deployments in all regions.

4. **Session Hosts** - Deploy using `Standard_DC8as_v6` (DCasv6 series) with
   `securityEncryptionType: DiskWithVMGuestState` and the CVM image version from the gallery.

### ⚠️ Feature Flag: DC8as_v6

`Standard_DC8as_v6` requires the feature flag `Microsoft.Compute/DCav6Series`,
which cannot be self-registered and requires a Microsoft support ticket.
Ensure the feature flag is enabled on the subscription before deploying.

## Deployment

### Full infrastructure (orchestrator)

```bash
az deployment group create \
  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \
  --resource-group rg-avd-images-prd-image-weu-001 \
  --template-file main.bicep \
  --parameters @main.bicepparam
```

### Individual gallery

```bash
az deployment group create \
  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \
  --resource-group rg-avd-images-prd-image-weu-001 \
  --parameters @galavdimagesprdweu001.bicepparam
```

### Individual image template

```bash
az deployment group create \
  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \
  --resource-group rg-avd-images-prd-image-weu-001 \
  --parameters @ImageTemplates/imgt-avd-images-prd-cc-win.bicepparam
```

## Notes

- **Image Versions** and **Snapshots** are NOT included as Bicep resources - they are runtime artifacts created by Azure Image Builder during the build process.
- **Storage Accounts** (prefixed with random strings) are also AIB-generated artifacts.
- The **Managed Identity** (`umi-imgt-avd-images-prd-intcoreapps-win`) is shared across all image templates.
- All image templates use the common customization pipeline defined in `ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/Template/main.bicep`, with optional feature flags to enable/disable specific steps.
