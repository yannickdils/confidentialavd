# Monthly patch cycle for Confidential AVD

This document describes the recommended monthly cadence for patching and image refresh in a Confidential AVD deployment. It ties together the Azure Image Builder pipeline from [part 1](https://www.tunecom.be/how-to-build-confidential-avd-images-with-azure-image-builder/), the CMK rotation from [part 2](https://www.tunecom.be/customer-managed-keys-confidential-avd/), and the attestation validation from [part 3](https://www.tunecom.be/guest-attestation-confidential-avd/).

## Why Confidential AVD patching needs its own cadence

Patching a standard AVD deployment is routine. Patching Confidential AVD adds a layer because:

1. **vTPM measurements shift when firmware changes.** Windows updates change the boot chain, and each change updates the measurements recorded in the virtual TPM. Guest Attestation continues to work because Microsoft updates the MAA baseline in sync with Windows Update releases, but this relationship should be verified after each update cycle rather than assumed.
2. **The GuestAttestation extension itself receives updates.** Extension updates are managed by Azure's auto-upgrade mechanism when `enable-auto-upgrade` is set to true. The effect of these updates should be confirmed by re-running `Get-AttestationStatus.ps1` after each extension version bump.
3. **Image refreshes require full session host replacement.** CVMs cannot be re-imaged in place while preserving the security profile. Updating the image means deploying new session hosts and retiring the old ones, which interacts with autoscale scheduling.

## The recommended four-week cycle

This assumes Patch Tuesday on the second Tuesday of each month, which is the Microsoft release cadence.

### Week 1, Patch Tuesday week

**Monday (before Patch Tuesday).** Review the Windows Update release notes on the Azure update documentation. Note any KBs that mention SEV-SNP, vTPM, Secure Boot, or attestation. These deserve extra scrutiny.

**Tuesday (Patch Tuesday).** Microsoft releases the Windows cumulative update. Do nothing in production yet.

**Wednesday to Friday.** Monitor community channels and the Azure status page for reports of regression issues, particularly around CVM boot or attestation. If a blocking issue surfaces, pause the cycle for this month.

### Week 2, Image build and test

**Monday.** Trigger the AIB image build pipeline (`AVD-BuildImage.yml` from part 1) using the latest marketplace image as the base. The pipeline applies the new cumulative update, any application updates, and bakes the image into the shared image gallery across all zones.

**Tuesday to Thursday.** Deploy the new image to a test host pool. Run `Get-AttestationStatus.ps1` against the test hosts with the `-LogAnalyticsWorkspaceId` parameter to validate all six steps. All three critical claims must pass.

**Friday.** If test results are clean, the image is approved for production rollout. If any claim fails or a warning appears in the vTPM or Kernel Boot event channels, investigate before proceeding.

### Week 3, Production rollout

**Monday.** Communicate the maintenance window to users. Most organisations use a Tuesday evening or Wednesday early morning window.

**Tuesday evening.** Trigger the `AVD-DeployAdditionalHosts` pipeline with the new image as the source. The pipeline deploys replacement session hosts alongside the existing ones, so users with active sessions are not affected.

**Wednesday.** Old session hosts are placed in drain mode. Users on old hosts are signed out when they next disconnect or when the drain-mode grace period expires.

**Thursday.** Old session hosts are deallocated and removed. Run `Get-AttestationStatus.ps1` against the full pool to confirm all hosts pass validation. Review the attestation health dashboard (KQL Query 1) for any warnings.

**Friday.** Document the rollout outcome in the operations log. Note the image version, the KB numbers applied, and any warnings that appeared and were resolved.

### Week 4, Quiet week and CMK rotation slot

**Monday to Thursday.** Normal operations. No scheduled changes. This week is the buffer for any late-breaking issues from the Week 3 rollout.

**Friday (optional).** If CMK rotation is due (typically quarterly, see part 2), this is the safest week to schedule it. Use `Invoke-SafeCMKRotation.ps1` inside a maintenance window outside business hours. This avoids overlapping with the image rollout in Week 3, which reduces the number of variables if something goes wrong.

## What to watch for after each rollout

Re-run these checks in the 24 hours after a production image rollout:

- **KQL Query 1** (attestation health per host): all hosts should be in HEALTHY state. Any WARNING or ERROR state is worth investigating before the next autoscale cycle.
- **KQL Query 2** (hosts with no attestation events): any host in the pool not sending attestation events has something wrong at the extension level.
- **KQL Query 6** (vTPM key operations): should show zero unusual events. Event IDs 5059 and 5061 are normal during the rollout itself but should stop appearing within hours of the last host deployment.
- **Azure Policy compliance**: the `require-guest-attestation-confidential-avd` policy should remain at 100% compliance. Any drop indicates a new host was deployed without the extension, which is a pipeline configuration issue.

## Unscheduled patches

Some patches cannot wait for the monthly cycle:

- **Emergency security updates** (Microsoft's out-of-band releases).
- **AMD firmware updates** affecting SEV-SNP microcode. These are applied by Azure at the platform level, not via Windows Update. You will not trigger these yourself, but you may see attestation warnings during a platform update window.
- **GuestAttestation extension major version updates**, which occasionally change the expected JWT format.

For all three cases, the response pattern is the same:

1. Build a new image with the patch applied.
2. Roll out to a test host pool.
3. Run `Get-AttestationStatus.ps1` and verify all validation levels pass.
4. Proceed to production rollout.

The only difference is the timeline, which compresses from four weeks to two or three days.

## What this cycle does not cover

- **Application-layer patching** (the Office suite, browsers, line-of-business applications) follows its own cadence and is usually handled by the application teams rather than the AVD team.
- **FSLogix and user profile patching** is separate from session host patching.
- **Infrastructure patching** (AIB build VM, pipeline agents, Key Vault, Event Grid) follows normal Azure patching and is out of scope.
