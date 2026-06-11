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
│   ├── DiskEncryptionSet/               # CC disk encryption (Managed HSM + Key Vault variants)
│   ├── EventGrid/                       # CMK key-expiry alerting (Event Grid + Azure Monitor)
│   ├── GuestAttestation/                # CVM Data Collection Rule for attestation monitoring
│   ├── KeyVault/                        # Secrets management
│   │   └── CMK/                         # CMK Key Vault, RSA key, rotation policy & private endpoint
│   ├── Policy/                          # Azure Policy for Guest Attestation compliance
│   ├── PrivateEndpoint/                 # Private endpoints
│   └── ResourceGroup/                   # Subscription-level resource group deployment
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
│   ├── AVD-DeployCMK.yml               # Deploy CMK Key Vault, DES & expiry alerts
│   ├── AVD-DeployIMAGER.yml             # Deploy imager VM
│   └── AVD-DeployAttestation.yml        # Deploy attestation infrastructure + policy
│
├── Queries/
│   └── attestation-kql-queries.kql      # KQL queries for attestation monitoring
│
├── Operations/                          # Day-two operational playbooks (part 4)
│   ├── monthly-patch-cycle.md           # Four-week cadence aligned with Patch Tuesday
│   ├── runbooks.md                      # Tier 1-4 incident runbooks
│   ├── operational-maturity-checklist.md # Self-assessment: Deployed → Resilient
│   └── figure1-operations.png           # Series diagram
│
└── Scripts/
    ├── CreateHSM_CMK.ps1                # Create Managed HSM key for CVM encryption
    ├── Rotate-CMK.ps1                   # Safely rotate CMK key (drain, deallocate, rotate, restart)
    ├── Invoke-SafeCMKRotation.ps1       # Autoscale-aware wrapper around Rotate-CMK.ps1
    ├── Get-AttestationStatus.ps1        # Check GuestAttestation extension health on all CVMs
    ├── Get-AIBPackerLog.ps1             # Retrieve AIB Packer build logs
    ├── Register-CCFeatureFlags.ps1      # Register CC feature flags
    ├── PAWImageprep.ps1                 # Pre-sysprep remediation
    ├── Watch-AIBBuild.ps1               # Monitor AIB build progress
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

### Step 3 - Deploy CMK Infrastructure (CMK only)

Deploy the Key Vault with CMK key, Disk Encryption Set, and key-expiry alerting:

Use pipeline: **AVD-DeployCMK.yml** - this pipeline has four stages:

1. **Approval Gate** - manual sign-off before any change
2. **Deploy CMK Key Vault** - Premium SKU vault, RSA key with rotation policy, private endpoint, UAMI
3. **Deploy Disk Encryption Set** - `ConfidentialVmEncryptedWithCustomerKey` linked to the Key Vault key
4. **Deploy Key Expiry Alerts** *(optional)* - Event Grid system topic + Azure Monitor alert for `KeyNearExpiry`

> **Skip this step entirely if you use PMK** (Platform-Managed Keys).

### Step 4 - Deploy Confidential Session Hosts

Deploy CC session hosts using the gallery image:

Use pipeline: **AVD-DeployAdditionalHosts.yml** with:
- `confidentialCompute: true`
- `customerManagedKeys: false` for **PMK** (no DES needed)
- `customerManagedKeys: true` for **CMK** (DES + Managed HSM required)

### Step 5 - Deploy Guest Attestation Infrastructure

Deploy the CVM-specific Data Collection Rule, validate GuestAttestation extension health on existing session hosts, and optionally deploy the Azure Policy definition that audits missing/failed GuestAttestation extensions. Session hosts use the Microsoft shared MAA endpoint (`https://sharedweu.weu.attest.azure.net`) automatically - no custom Attestation Provider is deployed.

Use pipeline: **AVD-DeployAttestation.yml** - this pipeline has four stages:

1. **Approval Gate** - human sign-off before any changes
2. **Deploy DCR** - CVM-specific Data Collection Rule
3. **Validate** - checks GuestAttestation extension health on all CVMs (runs `Scripts/Get-AttestationStatus.ps1`)
4. **Policy** *(optional)* - deploys the `require-guest-attestation-confidential-avd` policy definition

Run this pipeline once per environment before deploying your first CVM session hosts, or when adding attestation monitoring to an existing Confidential AVD deployment. See `ComponentLibrary/GuestAttestation/`, `ComponentLibrary/Policy/`, and `Queries/attestation-kql-queries.kql` for the underlying modules and monitoring queries.

### Step 6 - Operate the platform (day two)

Once parts 1 to 3 are deployed, the platform moves from a project into day-two operations. The [`Operations/`](Operations/README.md) folder holds the playbooks that make Confidential AVD actually runnable in production:

- **`monthly-patch-cycle.md`** - four-week cadence aligned with Patch Tuesday (review → build → test → rollout) that keeps Guest Attestation healthy through Windows updates and AIB image refreshes.
- **`runbooks.md`** - four severity tiers (Minor attestation failure → Moderate zone capacity exhaustion → Major HSM key expiry → Severe regional outage), each with trigger, RTO, recovery steps, and verification criteria.
- **`operational-maturity-checklist.md`** - honest self-assessment across four tiers (Deployed / Monitored / Operable / Resilient) with binary per-item criteria.

The runbooks reference [`Scripts/Invoke-SafeCMKRotation.ps1`](Scripts/Invoke-SafeCMKRotation.ps1), which wraps the nine-step `Rotate-CMK.ps1` rotation from part 2 with the AVD autoscale exclusion-tag guard so the two do not race during maintenance windows.

## ⚠️ Prerequisites

### For both PMK and CMK
- **Feature Flag**: `Microsoft.Compute/DCav6Series` must be registered (requires support ticket for some regions)
- **Service Connection**: Pipeline service principal with Contributor on images subscription
- **Compute Gallery**: Must exist before image builds (deployed in Step 1)
- **CC VM Size**: DC-series or EC-series VMs (e.g., `Standard_DC4as_v5`, `Standard_EC8as_v6`)

### For CMK only (skip these for PMK)
- **Managed HSM _or_ Key Vault (Premium)**: Key must exist for Disk Encryption Set (`ConfidentialVmEncryptedWithCustomerKey`)
  - **Managed HSM variant**: Use `CreateHSM_CMK.ps1` and `DiskEncryptionSet/main.bicep`
  - **Key Vault variant**: Use pipeline `AVD-DeployCMK.yml` which deploys `KeyVault/CMK/main.bicep` + `DiskEncryptionSet/cmk-kv.bicep`
- **UAMI for DES**: Must have `Crypto Service Encryption User` role on the key
- **Key Rotation**: CVM does **not** support automatic rotation. Use `Scripts/Rotate-CMK.ps1` to safely drain, deallocate, rotate, and restart session hosts
- **Key Expiry Alerting** *(optional)*: `EventGrid/cmk-key-expiry-alert.bicep` deploys Event Grid + Azure Monitor alerts that fire 30 days before the CMK key expires

## 📚 References

- [📝 Blog part 1: How to build and deploy confidential AVD images with Azure Image Builder](https://www.tunecom.be/how-to-build-confidential-avd-images-with-azure-image-builder/)
- [📝 Blog part 2: Customer-Managed Keys for Confidential AVD](https://www.tunecom.be/customer-managed-keys-confidential-avd/)
- [📝 Blog part 3: Guest Attestation for Confidential AVD](https://www.tunecom.be/guest-attestation-confidential-avd/)
- [📝 Blog part 4: Operating Confidential AVD at Scale](https://www.tunecom.be/operating-confidential-avd-at-scale/)
- [Azure Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview)
- [Azure Image Builder](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview)
- [Disk Encryption with Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-disk-encryption)