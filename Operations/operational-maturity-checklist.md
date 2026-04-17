# Operational maturity checklist for Confidential AVD

A self-assessment tool for platform leads and operations teams running Confidential AVD. Work through each tier in order. Do not skip ahead to a higher tier until the current one is truly complete.

Each item is either true or false for your deployment. No partial credit.

## Tier 1, Deployed

You have something running. This is where most organisations land six to eight weeks after starting with this series.

- [ ] CVM-compatible images are built by the AIB pipeline from part 1 and stored in a zone-replicated shared image gallery
- [ ] Session hosts deploy successfully as `securityType: ConfidentialVM` with AMD SEV-SNP, vTPM, and Secure Boot enabled
- [ ] The GuestAttestation extension is installed on every CVM session host
- [ ] Customer-managed keys are deployed with Managed HSM and the CVM-specific encryption type (part 2)
- [ ] The Disk Encryption Set is configured and associated with every CVM
- [ ] Rotate-CMK.ps1 has been tested in a non-production environment at least once

**If all boxes are ticked, you can claim "deployed."** Your infrastructure exists. You have not yet proven it is observable or operable, but it works.

## Tier 2, Monitored

You can see what is happening. This typically takes another two to four weeks after Tier 1.

- [ ] The CVM-specific DCR from part 3 is deployed and associated with all CVMs
- [ ] Log Analytics retention is set to at least 90 days
- [ ] All eight KQL queries from part 3 are saved as Saved Searches in the workspace
- [ ] An Azure Dashboard pinned Query 1 (attestation health per host) with 24-hour auto-refresh
- [ ] An Azure Monitor alert fires when `ErrorCount > 0` on Query 1, routed to a real Action Group
- [ ] The Action Group has at least one human recipient who has acknowledged receiving test alerts
- [ ] Event Grid alerts for KeyNearExpiry and KeyExpired are configured and tested
- [ ] The Azure Policy `require-guest-attestation-confidential-avd` is assigned in Audit mode
- [ ] Azure Policy compliance has been reviewed at least once

**If all boxes are ticked, you can claim "monitored."** You can detect problems. You have not yet proven you can act on them quickly.

## Tier 3, Operable

You can run the thing in production. This tier is where the gap between "works in a demo" and "runs a business" is closed. Expect two to three months to reach it.

- [ ] Autoscale is configured for the host pool with a realistic capacity threshold
- [ ] Autoscale uses the exclusion tag mechanism so CMK rotations do not conflict with scale-out
- [ ] `Invoke-SafeCMKRotation.ps1` has been tested in a non-production environment
- [ ] The monthly patch cycle from `monthly-patch-cycle.md` is established and followed
- [ ] Images are rebuilt at least monthly
- [ ] `Get-AttestationStatus.ps1` runs automatically after every image rollout
- [ ] The runbooks in `runbooks.md` for Tier 1 and Tier 2 incidents are current and have been walked through by the on-call team
- [ ] At least one incident at each of those severity tiers has actually been handled using the runbook
- [ ] DC-series zone availability is checked monthly and documented
- [ ] The cost per user per month is measured and trending within the expected range

**If all boxes are ticked, you can claim "operable."** You can run Confidential AVD in production with confidence. You have not yet proven you can survive a significant incident.

## Tier 4, Resilient

You can survive what actually breaks. This tier is the work of twelve months or more. Few organisations reach it in the first year. Many organisations do not need to.

- [ ] West Europe pre-positioned infrastructure exists as a failover region for Belgium Central
- [ ] CVM images are replicated to West Europe in the shared image gallery
- [ ] The Managed HSM is configured for cross-region availability or has a documented recovery path from backup
- [ ] A regional failover has been rehearsed at least once in a planned drill
- [ ] The failover procedure is documented and tested quarterly
- [ ] The HSM security domain backup is current and has been tested by restoring it to a separate HSM instance
- [ ] Tier 3 and Tier 4 incident runbooks have been walked through by the on-call team
- [ ] The Recovery Time Objective (RTO) and Recovery Point Objective (RPO) for Confidential AVD are explicitly documented and reviewed annually
- [ ] Platform updates that affect attestation (AMD microcode, extension versions) are tracked and validated on a test pool before production
- [ ] A chaos engineering exercise has been run at least once, for example randomly deallocating a session host mid-session to observe behaviour

**If all boxes are ticked, you can claim "resilient."** This is a mature operation.

## How to use this checklist

The checklist is not a badge. It is a diagnostic. Most organisations will be realistically at Tier 2 while describing themselves as Tier 3. That gap is where incidents happen.

Review the checklist quarterly. Add dated signatures when a tier is confirmed. When a box moves from ticked to unticked (for example because a Saved Search was deleted or an alert recipient left the team), note the date and plan the remediation.

The goal is not to reach Tier 4 as quickly as possible. The goal is to operate at a tier that matches the business value of the workload. A development host pool sitting at Tier 2 is fine. A production host pool serving a regulated workload at Tier 2 is not.
