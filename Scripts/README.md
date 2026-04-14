# Scripts

PowerShell scripts for managing Confidential AVD infrastructure, key operations, image builds, and attestation health.

## Scripts

| Script | Purpose |
|--------|---------|
| [`CreateHSM_CMK.ps1`](CreateHSM_CMK.ps1) | Create a Managed HSM key with Secure Key Release (SKR) policy for CVM disk encryption |
| [`Rotate-CMK.ps1`](Rotate-CMK.ps1) | Safely rotate a CMK key: drain session hosts, deallocate, rotate, restart |
| [`Get-AttestationStatus.ps1`](Get-AttestationStatus.ps1) | Query and report GuestAttestation extension health across all CVM session hosts |
| [`Get-AIBPackerLog.ps1`](Get-AIBPackerLog.ps1) | Retrieve Azure Image Builder Packer build logs for troubleshooting |
| [`Watch-AIBBuild.ps1`](Watch-AIBBuild.ps1) | Monitor Azure Image Builder build progress in real time |
| [`Register-CCFeatureFlags.ps1`](Register-CCFeatureFlags.ps1) | Register Confidential Compute feature flags on a subscription |
| [`PAWImageprep.ps1`](PAWImageprep.ps1) | Pre-sysprep remediation for PAW images |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| [`ImageCapture/`](ImageCapture/) | VM capture automation - creates image versions in Azure Compute Gallery |
| [`Sysprep/`](Sysprep/) | Sysprep finalization scripts |

## CMK Key Management

### Creating a new key

Use `CreateHSM_CMK.ps1` to create a new RSA-HSM key with the CVM Secure Key Release policy. The script validates prerequisites, creates the key with `--exportable` and `--default-cvm-policy`, and assigns the required role to the CVM Orchestrator service principal.

```powershell
.\CreateHSM_CMK.ps1 -HsmName "kvhsmmgmthubabc001" -KeyName "cmk-avd-prd-weu-001"
```

### Rotating an existing key

Use `Rotate-CMK.ps1` to safely rotate a CMK key. CVM does not support automatic key rotation, so this script handles the full sequence: drain users, deallocate VMs, update the DES key version, and restart hosts.

```powershell
.\Rotate-CMK.ps1 -HsmName "kvhsmmgmthubabc001" -KeyName "cmk-avd-prd-weu-001"
```

## Attestation Health

Use `Get-AttestationStatus.ps1` to validate that all Confidential VM session hosts have a healthy GuestAttestation extension. The script exits non-zero if any host has a failed or missing extension, making it suitable for use in Azure DevOps pipelines.

```powershell
.\Get-AttestationStatus.ps1 `
    -SubscriptionName "sub-avd-prd" `
    -HostsResourceGroup "rg-avd-prd-hosts" `
    -HostPoolName "hp-avd-prd-weu-001"
```

## References

- [Azure Confidential VMs](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview)
- [Azure Image Builder](https://learn.microsoft.com/en-us/azure/virtual-machines/image-builder-overview)
- [Key Vault key rotation](https://learn.microsoft.com/en-us/azure/key-vault/keys/how-to-configure-key-rotation)
