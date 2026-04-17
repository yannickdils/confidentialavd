# GuestAttestation

Bicep modules for deploying **Guest Attestation monitoring** infrastructure for Confidential AVD session hosts. Guest Attestation itself provides cryptographic proof that session hosts are running inside a genuine AMD SEV-SNP or Intel TDX Trusted Execution Environment; the module here focuses on collecting and monitoring that attestation telemetry.

> **Note:** This module does **not** deploy a custom `Microsoft.Attestation/attestationProviders` resource. That resource type is not available in Belgium Central, and it is not required for Confidential AVD - session hosts call the Microsoft shared MAA endpoint (`https://sharedweu.weu.attest.azure.net`) by default, which applies Microsoft's baseline policy validating AMD SEV-SNP, Secure Boot, and vTPM state.

## What Gets Deployed

| Resource | Description |
|----------|-------------|
| **Data Collection Rule** | CVM-specific DCR that collects attestation events, security events, and performance counters |
| **Log Analytics Solutions** | Security and SecurityInsights solutions that provision the required tables |

## Modules

### `main.bicep`

Deploys a Data Collection Rule that collects three categories of data the standard AVD Insights DCR does not cover:

1. **Security events** - logon/logoff (4624/4634), vTPM key operations (5059/5061)
2. **Attestation events** - GuestAttestation extension logs, TPM driver events, boot events
3. **Performance counters** - standard AVD counters plus network connectivity metrics

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `dataCollectionRuleName` | `string` | - | Name of the DCR |
| `location` | `string` | `resourceGroup().location` | Azure region |
| `logAnalyticsWorkspaceId` | `string` | - | Resource ID of the Log Analytics Workspace |
| `tags` | `object` | - | Tags applied to all resources |

| Output | Description |
|--------|-------------|
| `dataCollectionRuleId` | Resource ID of the DCR |
| `dataCollectionRuleName` | Name of the DCR |

## Usage

### Via pipeline (recommended)

Use **`Pipelines/AVD-DeployAttestation.yml`** which deploys the DCR, validates GuestAttestation extension health on existing session hosts, and optionally deploys the Azure Policy definition.

### Standalone CLI deployment

```bash
az deployment group create \
  --resource-group rg-avd-attest-prd-weu-001 \
  --template-file ComponentLibrary/GuestAttestation/main.bicep \
  --parameters @ComponentLibrary/GuestAttestation/main.parameters.json
```

## Related Files

| File | Purpose |
|------|---------|
| [`main.parameters.json`](main.parameters.json) | Example parameter file for the DCR |
| [`solutions.bicep`](solutions.bicep) | Log Analytics solutions that provision SecurityEvent and WindowsEvent tables |
| [`Policy/policy-require-guest-attestation.bicep`](../Policy/policy-require-guest-attestation.bicep) | Azure Policy to audit VMs missing the GuestAttestation extension |
| [`Scripts/Get-AttestationStatus.ps1`](../../Scripts/Get-AttestationStatus.ps1) | Script to check attestation health across all session hosts |
| [`Queries/attestation-kql-queries.kql`](../../Queries/attestation-kql-queries.kql) | KQL queries for monitoring attestation events in Log Analytics |
| [`Pipelines/AVD-DeployAttestation.yml`](../../Pipelines/AVD-DeployAttestation.yml) | End-to-end attestation deployment pipeline |

## References

- [Azure Attestation overview](https://learn.microsoft.com/en-us/azure/attestation/overview)
- [Guest Attestation for Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/guest-attestation-confidential-vms)
- [Data Collection Rules](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview)
