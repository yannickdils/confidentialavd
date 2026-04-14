# GuestAttestation

Bicep modules for deploying **Guest Attestation** infrastructure for Confidential AVD session hosts. These resources provide cryptographic proof that session hosts are running inside a genuine AMD SEV-SNP or Intel TDX Trusted Execution Environment.

## What Gets Deployed

| Resource | Description |
|----------|-------------|
| **Attestation Provider** | Azure Attestation endpoint that CVM session hosts call to produce a signed attestation token |
| **Data Collection Rule** | CVM-specific DCR that collects attestation events, security events, and performance counters |

## Modules

### `attestation-provider.bicep`

Deploys an Azure Attestation Provider scoped to a region. One provider is sufficient per region - if you already have a shared provider in your tenant, you can reference it instead.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `attestationProviderName` | `string` | - | Name of the Attestation Provider |
| `location` | `string` | `resourceGroup().location` | Azure region |
| `policySigningCertificateData` | `string` | `''` | Base64-encoded PEM certificate for signed policies (empty = unsigned) |
| `tags` | `object` | - | Tags applied to all resources |

| Output | Description |
|--------|-------------|
| `attestationProviderUri` | Attestation endpoint URI |
| `attestationProviderId` | Resource ID of the provider |
| `attestationProviderName` | Name of the provider |

### `dcr-confidential-avd.bicep`

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

Use **`Pipelines/AVD-DeployAttestation.yml`** which deploys the Attestation Provider, DCR, validates extension health, and optionally deploys the Azure Policy definition.

### Standalone CLI deployment

```bash
# Deploy Attestation Provider
az deployment group create \
  --resource-group rg-avd-attest-prd-weu-001 \
  --template-file ComponentLibrary/GuestAttestation/attestation-provider.bicep \
  --parameters @ComponentLibrary/GuestAttestation/attestation-provider.parameters.json

# Deploy Data Collection Rule
az deployment group create \
  --resource-group rg-avd-attest-prd-weu-001 \
  --template-file ComponentLibrary/GuestAttestation/dcr-confidential-avd.bicep \
  --parameters @ComponentLibrary/GuestAttestation/dcr-confidential-avd.parameters.json
```

## Related Files

| File | Purpose |
|------|---------|
| [`attestation-provider.parameters.json`](attestation-provider.parameters.json) | Example parameter file for the attestation provider |
| [`dcr-confidential-avd.parameters.json`](dcr-confidential-avd.parameters.json) | Example parameter file for the DCR |
| [`Policy/policy-require-guest-attestation.bicep`](../Policy/policy-require-guest-attestation.bicep) | Azure Policy to audit VMs missing the GuestAttestation extension |
| [`Scripts/Get-AttestationStatus.ps1`](../../Scripts/Get-AttestationStatus.ps1) | Script to check attestation health across all session hosts |
| [`Queries/attestation-kql-queries.kql`](../../Queries/attestation-kql-queries.kql) | KQL queries for monitoring attestation events in Log Analytics |
| [`Pipelines/AVD-DeployAttestation.yml`](../../Pipelines/AVD-DeployAttestation.yml) | End-to-end attestation deployment pipeline |

## References

- [Azure Attestation overview](https://learn.microsoft.com/en-us/azure/attestation/overview)
- [Guest Attestation for Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/guest-attestation-confidential-vms)
- [Data Collection Rules](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview)
