# Policy

Bicep module for deploying **Azure Policy definitions** that enforce Guest Attestation compliance on Confidential AVD session hosts.

## Module

### `policy-require-guest-attestation.bicep`

Deploys a custom Azure Policy definition that audits Confidential VMs missing a healthy GuestAttestation extension. Without this extension, there is no cryptographic proof that a session host is running in a genuine AMD SEV-SNP Trusted Execution Environment.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `policyDefinitionName` | `string` | `require-guest-attestation-confidential-avd` | Name for the policy definition |
| `policyDisplayName` | `string` | `Require Guest Attestation extension on Confidential AVD session hosts` | Display name in the Azure Portal |
| `policyDescription` | `string` | *(see module)* | Description shown in the Azure Portal |

| Output | Description |
|--------|-------------|
| `policyDefinitionId` | Resource ID of the policy definition |
| `policyDefinitionName` | Name of the policy definition |

## Policy Behaviour

- **Effect**: `AuditIfNotExists` (default) - audits VMs that are missing or have a failed GuestAttestation extension
- **Scope**: Target the subscription or resource group containing your AVD session hosts (not the image build subscription)
- **Targets**: Only Confidential VMs (`securityType = ConfidentialVM`)
- **Checks**: GuestAttestation extension must be present, published by `Microsoft.Azure.Security.WindowsAttestation`, and in `Succeeded` provisioning state

## Usage

### Via pipeline (recommended)

The policy is deployed as the optional fourth stage of **`Pipelines/AVD-DeployAttestation.yml`** (controlled by the `deployPolicy` parameter, default `true`).

### Standalone CLI deployment

```bash
az deployment group create \
  --resource-group rg-avd-attest-prd-weu-001 \
  --template-file ComponentLibrary/Policy/policy-require-guest-attestation.bicep
```

After deploying the definition, assign it in the Azure Portal:

1. Go to **Azure Portal > Policy > Assignments > Assign Policy**
2. Select: `require-guest-attestation-confidential-avd`
3. Scope: subscription or resource group containing your CVM session hosts

## Related Files

| File | Purpose |
|------|---------|
| [`GuestAttestation/attestation-provider.bicep`](../GuestAttestation/attestation-provider.bicep) | Attestation Provider that the GuestAttestation extension calls |
| [`Scripts/Get-AttestationStatus.ps1`](../../Scripts/Get-AttestationStatus.ps1) | Script to check attestation health (complements the policy) |
| [`Pipelines/AVD-DeployAttestation.yml`](../../Pipelines/AVD-DeployAttestation.yml) | Pipeline that deploys attestation infrastructure and this policy |

## References

- [Azure Policy overview](https://learn.microsoft.com/en-us/azure/governance/policy/overview)
- [Guest Attestation for Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/guest-attestation-confidential-vms)
