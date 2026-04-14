# EventGrid - CMK Key Expiry Alerting

Bicep module that deploys **Event Grid + Azure Monitor** infrastructure to alert when a CMK key stored in Key Vault is approaching expiry.

## Why This Exists

Confidential VMs do **not** support automatic key rotation. If the CMK key expires without action, new session host deployments will fail and existing disks cannot be unlocked after a deallocate. This module ensures your operations team gets notified well in advance.

## What Gets Deployed

| Resource | Description |
|----------|-------------|
| **Action Group** | Email receivers (+ optional webhook) for key-expiry notifications |
| **Event Grid System Topic** | Scoped to the Key Vault - captures `KeyNearExpiry`, `KeyExpired`, `KeyNewVersionCreated` |
| **Activity Log Alert** | Azure Monitor alert that fires the Action Group when a near-expiry event arrives |
| **Event Grid Subscription** | Routes the Key Vault events to the Azure Monitor alert (CloudEvents v1.0 schema) |

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `keyVaultName` | `string` | - | Name of the Key Vault to monitor |
| `keyVaultId` | `string` | - | Resource ID of the Key Vault |
| `location` | `string` | `resourceGroup().location` | Azure region |
| `actionGroupName` | `string` | - | Action Group name |
| `actionGroupShortName` | `string` | - | Action Group display short name |
| `notificationEmails` | `array` | - | Email addresses to notify |
| `webhookUri` | `string` | `''` | Optional webhook URI (e.g. Logic App / Power Automate) |
| `eventGridTopicName` | `string` | `evgt-<kvName>-cmk` | Event Grid System Topic name |
| `tags` | `object` | - | Tags applied to all resources |

## Outputs

| Output | Description |
|--------|-------------|
| `actionGroupId` | Resource ID of the Action Group |
| `eventGridTopicId` | Resource ID of the Event Grid System Topic |
| `eventGridTopicName` | Name of the Event Grid System Topic |

## Usage

This module is deployed as the **optional fourth stage** of `Pipelines/AVD-DeployCMK.yml` (controlled by the `deployAlerts` parameter, default `true`).

### Standalone CLI deployment

```bash
az deployment group create \
  --resource-group rg-avd-cmk-prd-weu-001 \
  --template-file ComponentLibrary/EventGrid/cmk-key-expiry-alert.bicep \
  --parameters @ComponentLibrary/EventGrid/cmk-key-expiry-alert.parameters.json \
  --parameters keyVaultId="/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.KeyVault/vaults/<KV>"
```

## Event Flow

```
Key Vault key nears expiry
  → KeyNearExpiry event (fired by Azure ~30 days before expiry)
  → Event Grid System Topic
  → Event Grid Subscription (filter: KeyNearExpiry / KeyExpired / KeyNewVersionCreated)
  → Azure Monitor Activity Log Alert
  → Action Group → email / webhook
```

## Related Files

| File | Purpose |
|------|---------|
| [`cmk-key-expiry-alert.parameters.json`](cmk-key-expiry-alert.parameters.json) | Example parameter file (placeholders only) |
| [`KeyVault/CMK/main.bicep`](../KeyVault/CMK/main.bicep) | The CMK Key Vault module that creates the key with a rotation / notify policy |
| [`Pipelines/AVD-DeployCMK.yml`](../../Pipelines/AVD-DeployCMK.yml) | Pipeline that deploys KV → DES → Alerts |
| [`Scripts/Rotate-CMK.ps1`](../../Scripts/Rotate-CMK.ps1) | Key rotation script to run when the alert fires |

## References

- [📝 Blog: How to build and deploy confidential AVD images with Azure Image Builder](https://www.tunecom.be/how-to-build-confidential-avd-images-with-azure-image-builder/)
- [Event Grid system topics for Key Vault](https://learn.microsoft.com/en-us/azure/event-grid/event-schema-key-vault)
- [Azure Monitor activity log alerts](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/activity-log-alerts)
