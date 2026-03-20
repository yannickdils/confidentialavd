# Confidential VM Image Infrastructure - Azure Compute Gallery# Confidential VM Image Infrastructure - Azure Compute Gallery# Confidential VM Image Infrastructure - Azure Compute Gallery# Confidential VM Image Infrastructure - Azure Compute Gallery# AVD Image Infrastructure - Azure Compute Gallery



This folder contains the Bicep parameter files and orchestrator for deploying the Confidential Compute image infrastructure for the **sub-avd-images-prd** subscription.



## Resource GroupThis folder contains the Bicep parameter files and orchestrator for deploying the Confidential Compute image infrastructure.



- **Subscription**: `sub-avd-images-prd` (`<SUBSCRIPTION_ID_IMAGES_PRD>`)

- **Resource Group**: `rg-avd-images-prd-image-weu-001`

## Resource GroupThis folder contains the Bicep parameter files and orchestrator for deploying the Confidential Compute image infrastructure.

## Structure



```

AzureComputeGallery/- **Subscription**: `sub-avd-images-prd` (`<SUBSCRIPTION_ID_IMAGES_PRD>`)

├── main.bicep                          # Orchestrator - deploys gallery, CC definition, and identity

├── main.bicepparam                     # Parameters for orchestrator- **Resource Group**: `rg-avd-images-prd-image-weu-001`

├── README.md                           # This file

│## Resource GroupThis folder contains the Bicep parameter files and orchestrator for deploying the Confidential Compute image infrastructure for the **sub-avd-images-prd** subscription.This folder contains the Bicep parameter files and orchestrator for deploying the complete Azure Image Builder infrastructure for the **sub-avd-images-prd** subscription.

├── ManagedIdentity/

│   └── umi-imgt-avd-images-prd-intcoreapps-win.bicepparam   # User-Assigned Identity for AIB## Structure

│

├── galavdimagesprdweu001.bicepparam     # Primary gallery (westeurope)

│

├── ImageDefinitions/```

│   └── imgd-avd-images-prd-cc-win11-25h2-001.bicepparam      # Confidential Compute (TrustedLaunch+CVM)

│AzureComputeGallery/- **Subscription**: `sub-avd-images-prd` (`<SUBSCRIPTION_ID_IMAGES_PRD>`)

└── ImageTemplates/

    └── imgt-avd-images-prd-cc-win.bicepparam                 # CC (DC8as_v6, 3-region replication)├── main.bicep                          # Orchestrator - deploys gallery, CC definition, and identity

```

├── main.bicepparam                     # Parameters for orchestrator- **Resource Group**: `rg-avd-images-prd-image-weu-001`

## Gallery

├── README.md                           # This file

| Gallery Name | Location | Purpose |

|---|---|---|│## Resource Group## Resource Group

| `galavdimagesprdweu001` | westeurope | Production gallery for CVM images |

├── ManagedIdentity/

## Image Template

│   └── umi-imgt-avd-images-prd-intcoreapps-win.bicepparam   # User-Assigned Identity for AIB## Structure

| Template | Source Image | Key Features | VM Size | Target Gallery |

|---|---|---|---|---|│

| **cc** | office-365/win11-25h2-avd-m365 | CC, RDP Shortpath | Standard_DC8as_v6 | galavdimagesprdweu001 |

├── galavdimagesprdweu001.bicepparam     # Primary gallery (westeurope)

## Confidential VM (CVM) Image Build

│

### Architecture

├── ImageDefinitions/```

The CVM image build uses the Azure Image Builder (AIB) pipeline.

The key difference from standard images is the **target image definition**:│   └── imgd-avd-images-prd-cc-win11-25h2-001.bicepparam      # Confidential Compute (TrustedLaunch+CVM)



```│AzureComputeGallery/- **Subscription**: `sub-avd-images-prd` (`<SUBSCRIPTION_ID_IMAGES_PRD>`)- **Subscription**: `sub-avd-images-prd` (`<SUBSCRIPTION_ID_IMAGES_PRD>`)

Source (marketplace)          Build VM            Target Image Definition              Session Host

office-365/win11-25h2   →   Standard_DC8as_v6 →  imgd-...-cc-win11-25h2-001        →  Standard_DC8as_v6└── ImageTemplates/

                              (TrustedLaunch)     SecurityType: TrustedLaunch          securityEncryption:

                                                    AndConfidentialVmSupported          DiskWithVMGuestState    └── imgt-avd-images-prd-cc-win.bicepparam                 # CC (DC8as_v6, 3-region replication)├── main.bicep                          # Orchestrator - deploys gallery, CC definition, and identity

```

```

### How it works

├── main.bicepparam                     # Parameters for orchestrator- **Resource Group**: `rg-avd-images-prd-image-weu-001`- **Resource Group**: `rg-avd-images-prd-image-weu-001`

1. **AIB Build VM** - Uses `Standard_DC8as_v6` with TrustedLaunch.

   The AIB API (`2024-02-01`) does **not** expose a `securityProfile` on `vmProfile`;## Gallery

   TrustedLaunch is enabled automatically when the target image definition requires it.

├── README.md                           # This file

2. **Target Image Definition** - `imgd-avd-images-prd-cc-win11-25h2-001` in gallery

   `galavdimagesprdweu001` has `SecurityType: TrustedLaunchAndConfidentialVmSupported`.| Gallery Name | Location | Purpose |

   This makes the output image version compatible with both TrustedLaunch and CVM session hosts.

|---|---|---|│

3. **Replication** - The CC image version is replicated to `westeurope`, `belgiumcentral`,

   and `northeurope` to support session host deployments in all regions.| `galavdimagesprdweu001` | westeurope | Production gallery for CVM images |



4. **Session Hosts** - Deploy using `Standard_DC8as_v6` (DCasv6 series) with├── ManagedIdentity/

   `securityEncryptionType: DiskWithVMGuestState` and the CVM image version from the gallery.

## Image Template

### ⚠️ Feature Flag: DC8as_v6

│   └── umi-imgt-avd-images-prd-intcoreapps-win.bicepparam   # User-Assigned Identity for AIB## Structure## Structure

`Standard_DC8as_v6` requires the feature flag `Microsoft.Compute/DCav6Series`,

which cannot be self-registered and requires a Microsoft support ticket.| Template | Source Image | Key Features | VM Size | Target Gallery |

Ensure the feature flag is enabled on the subscription before deploying.

|---|---|---|---|---|│

## Deployment

| **cc** | office-365/win11-25h2-avd-m365 | CC, RDP Shortpath | Standard_DC8as_v6 | galavdimagesprdweu001 |

### Full infrastructure (orchestrator)

├── galavdimagesprdweu001.bicepparam     # Primary gallery (westeurope)

```bash

az deployment group create \## Confidential VM (CVM) Image Build

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

  --resource-group rg-avd-images-prd-image-weu-001 \│

  --template-file main.bicep \

  --parameters @main.bicepparam### Architecture

```

├── ImageDefinitions/``````

### Individual gallery

The CVM image build uses the Azure Image Builder (AIB) pipeline.

```bash

az deployment group create \The key difference from standard images is the **target image definition**:│   └── imgd-avd-images-prd-cc-win11-25h2-001.bicepparam      # Confidential Compute (TrustedLaunch+CVM)

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

  --resource-group rg-avd-images-prd-image-weu-001 \

  --parameters @galavdimagesprdweu001.bicepparam

``````│AzureComputeGallery/AzureComputeGallery/



### Individual image templateSource (marketplace)          Build VM            Target Image Definition              Session Host



```bashoffice-365/win11-25h2   →   Standard_DC8as_v6 →  imgd-...-cc-win11-25h2-001        →  Standard_DC8as_v6└── ImageTemplates/

az deployment group create \

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \                              (TrustedLaunch)     SecurityType: TrustedLaunch          securityEncryption:

  --resource-group rg-avd-images-prd-image-weu-001 \

  --parameters @ImageTemplates/imgt-avd-images-prd-cc-win.bicepparam                                                    AndConfidentialVmSupported          DiskWithVMGuestState    └── imgt-avd-images-prd-cc-win.bicepparam                 # CC (DC8as_v6, 3-region replication)├── main.bicep                          # Orchestrator - deploys gallery, CC definition, and identity├── main.bicep                          # Orchestrator - deploys all galleries, definitions, and identity

```

```

## Notes

```

- **Image Versions** and **Snapshots** are NOT included as Bicep resources - they are runtime artifacts created by Azure Image Builder during the build process.

- **Storage Accounts** (prefixed with random strings) are also AIB-generated artifacts.### How it works

- The **Managed Identity** (`umi-imgt-avd-images-prd-intcoreapps-win`) is shared across all image templates.

- All image templates use the common customization pipeline defined in `ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/Template/main.bicep`, with optional feature flags to enable/disable specific steps.├── main.bicepparam                     # Parameters for orchestrator├── main.bicepparam                     # Parameters for orchestrator


1. **AIB Build VM** - Uses `Standard_DC8as_v6` with TrustedLaunch.

   The AIB API (`2024-02-01`) does **not** expose a `securityProfile` on `vmProfile`;## Gallery

   TrustedLaunch is enabled automatically when the target image definition requires it.

├── README.md                           # This file├── README.md                           # This file

2. **Target Image Definition** - `imgd-avd-images-prd-cc-win11-25h2-001` in gallery

   `galavdimagesprdweu001` has `SecurityType: TrustedLaunchAndConfidentialVmSupported`.| Gallery Name | Location | Purpose |

   This makes the output image version compatible with both TrustedLaunch and CVM session hosts.

|---|---|---|││

3. **Replication** - The CC image version is replicated to `westeurope`, `belgiumcentral`,

   and `northeurope` to support session host deployments in all regions.| `galavdimagesprdweu001` | westeurope | Production gallery for CVM images |



4. **Session Hosts** - Deploy using `Standard_DC8as_v6` (DCasv6 series) with├── ManagedIdentity/├── ManagedIdentity/

   `securityEncryptionType: DiskWithVMGuestState` and the CVM image version from the gallery.

## Image Template

### Feature Flag: DC8as_v6

│   └── umi-imgt-avd-images-prd-intcoreapps-win.bicepparam   # User-Assigned Identity for AIB│   └── umi-imgt-avd-images-prd-intcoreapps-win.bicepparam   # User-Assigned Identity for AIB

`Standard_DC8as_v6` requires the feature flag `Microsoft.Compute/DCav6Series`,

which cannot be self-registered and requires a Microsoft support ticket.| Template | Source Image | Key Features | VM Size | Target Gallery |

Ensure the feature flag is enabled on the subscription before deploying.

|---|---|---|---|---|││

## Deployment

| **cc** | office-365/win11-25h2-avd-m365 | CC, RDP Shortpath | Standard_DC8as_v6 | galavdimagesprdweu001 |

### Full infrastructure (orchestrator)

├── galavdimagesprdweu001.bicepparam     # Primary gallery (westeurope)├── galavdimagesprdweu001.bicepparam     # Primary gallery (westeurope)

```bash

az deployment group create \## Confidential VM (CVM) Image Build

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

  --resource-group rg-avd-images-prd-image-weu-001 \││

  --template-file main.bicep \

  --parameters @main.bicepparam### Architecture

```

├── ImageDefinitions/├── ImageDefinitions/

### Individual gallery

The CVM image build uses the Azure Image Builder (AIB) pipeline.

```bash

az deployment group create \The key difference from standard images is the **target image definition**:│   └── imgd-avd-images-prd-cc-win11-25h2-001.bicepparam      # Confidential Compute (TrustedLaunch+CVM)│   ├── imgd-avd-images-prd-win11-25h2-001.bicepparam         # Standard intcoreapps (TrustedLaunch)

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

  --resource-group rg-avd-images-prd-image-weu-001 \

  --parameters @galavdimagesprdweu001.bicepparam

``````││   ├── imgd-avd-images-prd-cc-win11-25h2-001.bicepparam      # Confidential Compute (TrustedLaunch+CVM)



### Individual image templateSource (marketplace)          Build VM            Target Image Definition              Session Host



```bashoffice-365/win11-25h2   →   Standard_DC8as_v6 →  imgd-...-cc-win11-25h2-001        →  Standard_DC8as_v6└── ImageTemplates/│   ├── imgd-avd-images-prd-paw-win11-25h2.bicepparam         # PAW (TrustedLaunch)

az deployment group create \

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \                              (TrustedLaunch)     SecurityType: TrustedLaunch          securityEncryption:

  --resource-group rg-avd-images-prd-image-weu-001 \

  --parameters @ImageTemplates/imgt-avd-images-prd-cc-win.bicepparam                                                    AndConfidentialVmSupported          DiskWithVMGuestState    └── imgt-avd-images-prd-cc-win.bicepparam                 # CC (DC8as_v6, 3-region replication)│   └── imgd-avd-images-prd-rpa-win11-25h2.bicepparam         # RPA (TrustedLaunch)

```

```

## Notes

```│

- **Image Versions** and **Snapshots** are NOT included as Bicep resources - they are runtime artifacts created by Azure Image Builder during the build process.

- The **Managed Identity** (`umi-imgt-avd-images-prd-intcoreapps-win`) is shared across all image templates.### How it works

- All image templates use the common customization pipeline defined in `ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/Template/main.bicep`, with optional feature flags.

└── ImageTemplates/

1. **AIB Build VM** - Uses `Standard_DC8as_v6` with TrustedLaunch.

   The AIB API (`2024-02-01`) does **not** expose a `securityProfile` on `vmProfile`;## Gallery    ├── imgt-avd-images-prd-intcoreapps-win.bicepparam        # Standard (D8as_v5, RDP Shortpath, DotNet9)

   TrustedLaunch is enabled automatically when the target image definition requires it.

    ├── imgt-avd-images-prd-intcoreapps-win-v6.bicepparam     # Standard v6 (D8as_v6, RDP Shortpath, DotNet9)

2. **Target Image Definition** - `imgd-avd-images-prd-cc-win11-25h2-001` in gallery

   `galavdimagesprdweu001` has `SecurityType: TrustedLaunchAndConfidentialVmSupported`.| Gallery Name | Location | Purpose |    ├── imgt-avd-images-prd-paw-win.bicepparam                # PAW (D8as_v5, windows-11 source)

   This makes the output image version compatible with both TrustedLaunch and CVM session hosts.

|---|---|---|    ├── imgt-avd-images-prd-rpa-win.bicepparam                # RPA (D8as_v5, Remove OneDrive)

3. **Replication** - The CC image version is replicated to `westeurope`, `belgiumcentral`,

   and `northeurope` to support session host deployments in all regions.| `galavdimagesprdweu001` | westeurope | Production gallery for CVM images |    └── imgt-avd-images-prd-cc-win.bicepparam                 # CC (DC8as_v6, 3-region replication)



4. **Session Hosts** - Deploy using `Standard_DC8as_v6` (DCasv6 series) with```

   `securityEncryptionType: DiskWithVMGuestState` and the CVM image version from the gallery.

## Image Template

### ⚠️ Feature Flag: DC8as_v6

## Galleries

`Standard_DC8as_v6` requires the feature flag `Microsoft.Compute/DCav6Series`,

which cannot be self-registered and requires a Microsoft support ticket.| Template | Source Image | Key Features | VM Size | Target Gallery |

Ensure the feature flag is enabled on the subscription before deploying.

|---|---|---|---|---|| Gallery Name | Location | Purpose |

## Deployment

| **cc** | office-365/win11-25h2-avd-m365 | CC, RDP Shortpath | Standard_DC8as_v6 | galavdimagesprdweu001 ||---|---|---|

### Full infrastructure (orchestrator)

| `galavdimagesprdweu001` | westeurope | Primary production gallery (standard + CVM images) |

```bash

az deployment group create \## Confidential VM (CVM) Image Build

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

  --resource-group rg-avd-images-prd-image-weu-001 \## Image Template Variants

  --template-file main.bicep \

  --parameters @main.bicepparam### Architecture

```

| Template | Source Image | Key Features | VM Size | Target Gallery |

### Individual gallery

The CVM image build uses the Azure Image Builder (AIB) pipeline.|---|---|---|---|---|

```bash

az deployment group create \The key difference from standard images is the **target image definition**:| **intcoreapps** | office-365/win11-25h2-avd-m365 | RDP Shortpath, DotNet9 | Standard_D8as_v5 | galavdimagesprdweu001 |

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

  --resource-group rg-avd-images-prd-image-weu-001 \| **intcoreapps-v6** | office-365/win11-25h2-avd-m365 | RDP Shortpath, DotNet9 | Standard_D8as_v6 | galavdimagesprdweu001 |

  --parameters @galavdimagesprdweu001.bicepparam

``````| **cc** | office-365/win11-25h2-avd-m365 | CC, RDP Shortpath, DotNet9 | Standard_DC8as_v6 | galavdimagesprdweu001 |



### Individual image templateSource (marketplace)          Build VM            Target Image Definition              Session Host| **paw** | windows-11/win11-25h2-avd | Minimal (no Office) | Standard_D8as_v5 | galavdimagesprdweu001 |



```bashoffice-365/win11-25h2   →   Standard_DC8as_v6 →  imgd-...-cc-win11-25h2-001        →  Standard_DC8as_v6| **rpa** | office-365/win11-25h2-avd-m365 | Remove OneDrive | Standard_D8as_v5 | galavdimagesprdweu001 |

az deployment group create \

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \                              (TrustedLaunch)     SecurityType: TrustedLaunch          securityEncryption:

  --resource-group rg-avd-images-prd-image-weu-001 \

  --parameters @ImageTemplates/imgt-avd-images-prd-cc-win.bicepparam                                                    AndConfidentialVmSupported          DiskWithVMGuestState## Confidential VM (CVM) Image Build

```

```

## Notes

### Architecture

- **Image Versions** and **Snapshots** are NOT included as Bicep resources - they are runtime artifacts created by Azure Image Builder during the build process.

- The **Managed Identity** (`umi-imgt-avd-images-prd-intcoreapps-win`) is shared across all image templates.### How it works

- All image templates use the common customization pipeline defined in `ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/Template/main.bicep`, with optional feature flags.

The CVM image build uses the same Azure Image Builder (AIB) pipeline as standard images.

1. **AIB Build VM** - Uses `Standard_DC8as_v6` with TrustedLaunch.The key difference is the **target image definition**, not the build VM configuration:

   The AIB API (`2024-02-01`) does **not** expose a `securityProfile` on `vmProfile`;

   TrustedLaunch is enabled automatically when the target image definition requires it.```

Source (marketplace)          Build VM            Target Image Definition              Session Host

2. **Target Image Definition** - `imgd-avd-images-prd-cc-win11-25h2-001` in galleryoffice-365/win11-25h2   →   Standard_DC8as_v6 →  imgd-...-cc-win11-25h2-001        →  Standard_DC8as_v6

   `galavdimagesprdweu001` has `SecurityType: TrustedLaunchAndConfidentialVmSupported`.                              (TrustedLaunch)     SecurityType: TrustedLaunch          securityEncryption:

   This makes the output image version compatible with both TrustedLaunch and CVM session hosts.                                                    AndConfidentialVmSupported          DiskWithVMGuestState

```

3. **Replication** - The CC image version is replicated to `westeurope`, `belgiumcentral`,

   and `northeurope` to support session host deployments in all regions.### How it works



4. **Session Hosts** - Deploy using `Standard_DC8as_v6` (DCasv6 series) with1. **AIB Build VM** - Uses `Standard_DC8as_v6` with TrustedLaunch.

   `securityEncryptionType: DiskWithVMGuestState` and the CVM image version from the gallery.   The AIB API (`2024-02-01`) does **not** expose a `securityProfile` on `vmProfile`;

   TrustedLaunch is enabled automatically when the target image definition requires it.

### ⚠️ Feature Flag: DC8as_v6

2. **Target Image Definition** - `imgd-avd-images-prd-cc-win11-25h2-001` in gallery

`Standard_DC8as_v6` requires the feature flag `Microsoft.Compute/DCav6Series`,   `galavdimagesprdweu001` has `SecurityType: TrustedLaunchAndConfidentialVmSupported`.

which cannot be self-registered and requires a Microsoft support ticket.   This makes the output image version compatible with both TrustedLaunch and CVM session hosts.

Ensure the feature flag is enabled on the subscription before deploying.

3. **Replication** - The CC image version is replicated to `westeurope`, `belgiumcentral`,

## Deployment   and `northeurope` to support session host deployments in all regions.



### Full infrastructure (orchestrator)4. **Session Hosts** - Deploy using `Standard_DC8as_v6` (DCasv6 series) with

   `securityEncryptionType: DiskWithVMGuestState` and the CVM image version from the gallery.

```bash

az deployment group create \### ⚠️ Feature Flag: DC8as_v6

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

  --resource-group rg-avd-images-prd-image-weu-001 \`Standard_DC8as_v6` requires the feature flag `Microsoft.Compute/DCav6Series`,

  --template-file main.bicep \which cannot be self-registered and requires a Microsoft support ticket.

  --parameters @main.bicepparamEnsure the feature flag is enabled on the subscription before deploying.

```

## Deployment

### Individual gallery

### Full infrastructure (orchestrator)

```bash

az deployment group create \```bash

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \az deployment group create \

  --resource-group rg-avd-images-prd-image-weu-001 \  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

  --parameters @galavdimagesprdweu001.bicepparam  --resource-group rg-avd-images-prd-image-weu-001 \

```  --template-file main.bicep \

  --parameters @main.bicepparam

### Individual image template```



```bash### Individual gallery

az deployment group create \

  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \```bash

  --resource-group rg-avd-images-prd-image-weu-001 \az deployment group create \

  --parameters @ImageTemplates/imgt-avd-images-prd-cc-win.bicepparam  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \

```  --resource-group rg-avd-images-prd-image-weu-001 \

  --parameters @galavdimagesprdweu001.bicepparam

## Notes```



- **Image Versions** and **Snapshots** are NOT included as Bicep resources - they are runtime artifacts created by Azure Image Builder during the build process.### Individual image template

- The **Managed Identity** (`umi-imgt-avd-images-prd-intcoreapps-win`) is shared across all image templates.

- All image templates use the common customization pipeline defined in `ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/Template/main.bicep`, with optional feature flags.```bash

az deployment group create \
  --subscription <SUBSCRIPTION_ID_IMAGES_PRD> \
  --resource-group rg-avd-images-prd-image-weu-001 \
  --parameters @ImageTemplates/imgt-avd-images-prd-intcoreapps-win.bicepparam
```

## Notes

- **Image Versions** and **Snapshots** are NOT included as Bicep resources - they are runtime artifacts created by Azure Image Builder during the build process.
- **Storage Accounts** (prefixed with random strings) are also AIB-generated artifacts.
- The **Managed Identity** (`umi-imgt-avd-images-prd-intcoreapps-win`) is shared across all image templates.
- All image templates use the common customization pipeline defined in `ComponentLibrary/AzureVirtualDesktop/AzureComputeGallery/Image/Template/main.bicep`, with optional feature flags to enable/disable specific steps.
