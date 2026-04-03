# DiskEncryptionSet

Bicep modules for creating a **Disk Encryption Set** with `ConfidentialVmEncryptedWithCustomerKey` encryption type, used by Confidential AVD session hosts when Customer-Managed Keys (CMK) are enabled.

## Module Variants

This folder contains **two** Bicep templates — choose the one that matches your key store:

| File | Key Store | When to Use |
|------|-----------|-------------|
| [`main.bicep`](main.bicep) | **Managed HSM** | You already have a Managed HSM with an RSA-HSM key created via `Scripts/CreateHSM_CMK.ps1` |
| [`cmk-kv.bicep`](cmk-kv.bicep) | **Key Vault (Premium)** | You deploy the Key Vault via `KeyVault/CMK/main.bicep` (used by `AVD-DeployCMK.yml` pipeline) |

Both modules produce the same DES configuration — the only difference is the key source.

## Parameters

### `main.bicep` (Managed HSM variant)

| Parameter | Type | Description |
|-----------|------|-------------|
| `diskEncryptionSetName` | `string` | Name of the DES |
| `location` | `string` | Azure region |
| `userAssignedIdentityId` | `string` | UAMI resource ID with `Crypto Service Encryption User` on the HSM key |
| `keyUrl` | `string` | **Full versioned** key URL from Managed HSM |
| `tags` | `object` | Tags |

### `cmk-kv.bicep` (Key Vault variant)

| Parameter | Type | Description |
|-----------|------|-------------|
| `diskEncryptionSetName` | `string` | Name of the DES |
| `location` | `string` | Azure region |
| `userAssignedIdentityId` | `string` | UAMI resource ID with `Crypto Service Encryption User` on the Key Vault |
| `keyVaultKeyUri` | `string` | **Versionless** key URI from Key Vault (e.g. `https://<vault>.vault.azure.net/keys/<key>`) |
| `tags` | `object` | Tags |

## Outputs

Both variants export the same outputs:

| Output | Description |
|--------|-------------|
| `diskEncryptionSetId` | Resource ID of the DES |
| `diskEncryptionSetName` | Name of the DES |

## Key Differences

| Aspect | `main.bicep` (HSM) | `cmk-kv.bicep` (KV) |
|--------|--------------------|-----------------------|
| Key URL | **Versioned** — pinned to a specific key version | **Versionless** — DES auto-resolves to latest version |
| `rotationToLatestKeyVersionEnabled` | `false` | `false` |
| Key creation | Manual via `CreateHSM_CMK.ps1` | Automated by `KeyVault/CMK/main.bicep` |
| Pipeline | Standalone `az deployment` | `AVD-DeployCMK.yml` (stage 3) |

> ⚠️ Regardless of variant, `rotationToLatestKeyVersionEnabled` is `false` because CVM does **not** support automatic key rotation. See [`Scripts/Rotate-CMK.ps1`](../../Scripts/Rotate-CMK.ps1).

## Usage

### Key Vault variant (via pipeline)

The `Pipelines/AVD-DeployCMK.yml` pipeline passes the UAMI and versionless key URI from the Key Vault deployment stage to this module automatically.

### Managed HSM variant (standalone)

```bash
az deployment group create \
  --resource-group rg-avd-cmk-prd-weu-001 \
  --template-file ComponentLibrary/DiskEncryptionSet/main.bicep \
  --parameters @ComponentLibrary/DiskEncryptionSet/main.parameters.json
```

## Related Files

| File | Purpose |
|------|---------|
| [`main.parameters.json`](main.parameters.json) | Example parameters for the HSM variant |
| [`KeyVault/CMK/main.bicep`](../KeyVault/CMK/main.bicep) | CMK Key Vault module that outputs `cmkKeyVersionlessUri` and `desIdentityId` |
| [`Pipelines/AVD-DeployCMK.yml`](../../Pipelines/AVD-DeployCMK.yml) | Pipeline that chains KV → DES → Alerts |

## References

- [📝 Blog: How to build and deploy confidential AVD images with Azure Image Builder](https://www.tunecom.be/how-to-build-confidential-avd-images-with-azure-image-builder/)
- [Disk Encryption with Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-disk-encryption)
