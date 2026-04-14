# Pipelines

Azure DevOps YAML pipeline definitions for building Confidential VM images, deploying session hosts, and managing CMK and attestation infrastructure.

## Pipeline Overview

| Pipeline | Purpose | When to Use |
|----------|---------|-------------|
| [`AVD-GalleryInfrastructure.yml`](AVD-GalleryInfrastructure.yml) | Deploy Compute Gallery, Managed Identity, and CC Image Definition | Initial setup or when adding new image definitions |
| [`AVD-ImageBuild.yml`](AVD-ImageBuild.yml) | Build a Confidential VM image via Azure Image Builder | When creating a new image version |
| [`AVD-DeployAdditionalHosts.yml`](AVD-DeployAdditionalHosts.yml) | Deploy Confidential Compute session hosts | Adding session hosts to a host pool |
| [`AVD-DeployCMK.yml`](AVD-DeployCMK.yml) | Deploy CMK Key Vault, Disk Encryption Set, and key-expiry alerts | CMK setup (skip for PMK) |
| [`AVD-DeployIMAGER.yml`](AVD-DeployIMAGER.yml) | Deploy an imager VM for manual image capture | When AIB is not suitable |
| [`AVD-DeployAttestation.yml`](AVD-DeployAttestation.yml) | Deploy Attestation Provider, DCR, validate extension health, and Azure Policy | Initial attestation setup or validation |

## Deployment Order

```
1. AVD-GalleryInfrastructure   (Gallery + Identity + Image Definition)
2. AVD-ImageBuild              (Build CC image via AIB)
3. AVD-DeployCMK               (CMK only: Key Vault + DES + Alerts)
4. AVD-DeployAdditionalHosts   (Deploy CC session hosts)
5. AVD-DeployAttestation       (Attestation Provider + DCR + Policy)
```

## CMK Pipeline Stages

`AVD-DeployCMK.yml` has four stages:

1. **Approval Gate** - manual sign-off before any change
2. **Deploy CMK Key Vault** - Premium SKU vault, RSA key with rotation policy, private endpoint, UAMI
3. **Deploy Disk Encryption Set** - `ConfidentialVmEncryptedWithCustomerKey` linked to the Key Vault key
4. **Deploy Key Expiry Alerts** *(optional)* - Event Grid system topic + Azure Monitor alert for `KeyNearExpiry`

## Attestation Pipeline Stages

`AVD-DeployAttestation.yml` has four stages:

1. **Approval Gate** - human sign-off before any changes
2. **Deploy** - Attestation Provider + CVM-specific Data Collection Rule
3. **Validate** - checks GuestAttestation extension health on all CVMs
4. **Policy** *(optional)* - deploys the Azure Policy definition

## Prerequisites

- **Service Connection**: Azure DevOps service principal with Contributor on the target subscription
- **Agent Pool**: Self-hosted or Microsoft-hosted agent pool
- **Approval Environment**: Azure DevOps environment with approval gates configured

## References

- [Azure Pipelines YAML schema](https://learn.microsoft.com/en-us/azure/devops/pipelines/yaml-schema)
- [Azure Image Builder](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview)
