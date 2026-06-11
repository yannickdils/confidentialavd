# Operations

Day-two operational playbooks for running Confidential AVD in production. These documents accompany [part 4 of the Confidential AVD series](https://www.tunecom.be/operating-confidential-avd-at-scale/).

Parts 1 to 3 of the series built the infrastructure. This folder covers what it takes to run it.

## Files

| File | Purpose |
|------|---------|
| [`monthly-patch-cycle.md`](monthly-patch-cycle.md) | Four-week cadence aligned with Patch Tuesday: review, build, test, rollout. Keeps attestation healthy through Windows updates and AIB image refreshes. |
| [`runbooks.md`](runbooks.md) | Four-tier incident runbooks (Minor / Moderate / Major / Severe). Each includes trigger, severity, RTO, step-by-step recovery, and verification criteria. |
| [`operational-maturity-checklist.md`](operational-maturity-checklist.md) | Self-assessment across four tiers (Deployed / Monitored / Operable / Resilient) with concrete binary criteria per tier. |
| [`figure1-operations.png`](figure1-operations.png) | Series diagram showing how parts 1 to 4 fit together. |

## How to use this folder

1. Read the blog post for context on why each document exists.
2. Walk the **operational maturity checklist** to honestly assess where your deployment sits today.
3. Adopt the **monthly patch cycle** as your default cadence. Compress it only for out-of-band security updates.
4. Bake the **runbooks** into your on-call rotation. Each tier should be walked through by the team before a real incident forces it.

## Related content

| File | Purpose |
|------|---------|
| [`Scripts/Invoke-SafeCMKRotation.ps1`](../Scripts/Invoke-SafeCMKRotation.ps1) | Wraps `Rotate-CMK.ps1` from part 2 with the autoscale exclusion-tag guard referenced in the runbooks |
| [`Scripts/Rotate-CMK.ps1`](../Scripts/Rotate-CMK.ps1) | Nine-step CMK rotation procedure (part 2) invoked by the safe-rotation wrapper |
| [`Scripts/Get-AttestationStatus.ps1`](../Scripts/Get-AttestationStatus.ps1) | Attestation health validation run after every image rollout (part 3) |
| [`ComponentLibrary/AzureVirtualDesktop/SessionHost/zone-aware-sessionhost.bicep`](../ComponentLibrary/AzureVirtualDesktop/SessionHost/zone-aware-sessionhost.bicep) | Single-zone session host module used by the zone failover pattern referenced in the Tier 2 runbook |
| [`Queries/attestation-kql-queries.kql`](../Queries/attestation-kql-queries.kql) | KQL saved searches referenced by the monthly patch cycle and the runbooks |

## Blog series

- [Part 1: Building Confidential AVD Images with Azure Image Builder](https://www.tunecom.be/how-to-build-confidential-avd-images-with-azure-image-builder/)
- [Part 2: Customer-Managed Keys for Confidential AVD](https://www.tunecom.be/customer-managed-keys-confidential-avd/)
- [Part 3: Guest Attestation for Confidential AVD](https://www.tunecom.be/guest-attestation-confidential-avd/)
- [Part 4: Operating Confidential AVD at Scale](https://www.tunecom.be/operating-confidential-avd-at-scale/)
