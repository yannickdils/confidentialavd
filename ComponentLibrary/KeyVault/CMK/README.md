# KeyVault / CMK

Bicep module that deploys a **Premium Key Vault** purpose-built for Customer-Managed Key (CMK) disk encryption of Confidential AVD session hosts.

## What Gets Deployed

| Resource | Description |
|----------|-------------|
| **User-Assigned Managed Identity** | Identity used by the Disk Encryption Set to access the Key Vault at runtime |
| **Key Vault (Premium SKU)** | RBAC-enabled vault with soft-delete, purge protection, public network access disabled |
| **Private Endpoint** | `vault` sub-resource private endpoint with DNS zone group |
| **Role Assignment** | `Key Vault Crypto Service Encryption User` on the vault for the DES identity |
| **RSA Key** | HSM-backed RSA key (3072-bit default) with rotation/notification policy |
| **Diagnostic Settings** | *(optional)* All logs + metrics to Log Analytics |

## ⚠️ CVM Key Rotation Caveat

Confidential VMs do **not** support automatic key rotation. The rotation policy on the key is configured to **notify only** — it fires `Microsoft.KeyVault.KeyNearExpiry` events so you can alert on them (see [`EventGrid/cmk-key-expiry-alert.bicep`](../../EventGrid/cmk-key-expiry-alert.bicep)).

Actual rotation requires all session hosts using the DES to be **stopped / deallocated** before updating the key version. Use [`Scripts/Rotate-CMK.ps1`](../../../Scripts/Rotate-CMK.ps1) for the full drain → deallocate → rotate → restart sequence.

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `keyVaultName` | `string` | — | Name of the Key Vault |
| `location` | `string` | `resourceGroup().location` | Azure region |
| `diskEncryptionSetIdentityName` | `string` | — | Name of the UAMI for the DES |
| `keyName` | `string` | — | Name of the CMK key |
| `keySize` | `int` | `3072` | RSA key size (2048 / 3072 / 4096) |
| `keyRotationPeriod` | `string` | `P1Y` | ISO 8601 duration for key expiry |
| `keyExpiryNotificationDays` | `int` | `30` | Days before expiry to fire notification |
| `logAnalyticsWorkspaceId` | `string` | `''` | Log Analytics workspace resource ID (empty = skip) |
| `pepSubnetId` | `string` | — | Subnet resource ID for the private endpoint |
| `privateDnsZoneId` | `string` | — | `privatelink.vaultcore.azure.net` DNS zone resource ID |
| `tags` | `object` | — | Tags applied to all resources |

## Outputs

| Output | Description |
|--------|-------------|
| `keyVaultId` | Resource ID of the Key Vault |
| `keyVaultName` | Name of the Key Vault |
| `keyVaultUri` | Vault URI (e.g. `https://<name>.vault.azure.net/`) |
| `cmkKeyId` | Resource ID of the RSA key |
| `cmkKeyName` | Name of the RSA key |
| `cmkKeyVersionlessUri` | Versionless key URI — use this as `activeKey.keyUrl` on the DES |
| `desIdentityId` | Resource ID of the UAMI for the DES |
| `desIdentityPrincipalId` | Object (principal) ID of the UAMI |

## Usage

### Via the CMK pipeline

The recommended deployment path is **`Pipelines/AVD-DeployCMK.yml`**, which chains this module with the DES and optional alert infrastructure.

### Standalone CLI deployment

```bash
az deployment group create \
  --resource-group rg-avd-cmk-prd-weu-001 \
  --template-file ComponentLibrary/KeyVault/CMK/main.bicep \
  --parameters @ComponentLibrary/KeyVault/CMK/main.parameters.json
```

## Related Files

| File | Purpose |
|------|---------|
| [`main.parameters.json`](main.parameters.json) | Example parameter file (placeholders only) |
| [`DiskEncryptionSet/cmk-kv.bicep`](../../DiskEncryptionSet/cmk-kv.bicep) | DES variant that references the versionless key URI from this module |
| [`EventGrid/cmk-key-expiry-alert.bicep`](../../EventGrid/cmk-key-expiry-alert.bicep) | Key-expiry alerting module |
| [`Pipelines/AVD-DeployCMK.yml`](../../../Pipelines/AVD-DeployCMK.yml) | End-to-end CMK deployment pipeline |
| [`Scripts/Rotate-CMK.ps1`](../../../Scripts/Rotate-CMK.ps1) | Key rotation script (supports both Key Vault and Managed HSM) |

## References

- [📝 Blog: How to build and deploy confidential AVD images with Azure Image Builder](https://www.tunecom.be/how-to-build-confidential-avd-images-with-azure-image-builder/)
- [Disk Encryption with Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-disk-encryption)
- [Key Vault key rotation](https://learn.microsoft.com/en-us/azure/key-vault/keys/how-to-configure-key-rotation)
