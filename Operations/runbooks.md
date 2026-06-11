# Operational runbooks for Confidential AVD

Operational playbooks for the four severity tiers introduced in [part 4 of the Confidential AVD series](https://www.tunecom.be/operating-confidential-avd-at-scale/).

Each runbook follows the same structure:

1. **Trigger**, what alert or symptom starts the runbook
2. **Severity**, user impact and urgency
3. **Recovery time objective**, how long you have to close the incident
4. **Steps**, the specific commands or pipelines to run
5. **Verification**, how to confirm the incident is resolved

---

## Tier 1, Minor: attestation extension fails on a single host

**Trigger.** Azure Monitor alert fires from KQL Query 1 (attestation health per host) with `ErrorCount > 0` for a single session host. No user reports yet.

**Severity.** Minor. Single host affected. Users currently on the host can continue working. New connections to this host still succeed because the GuestAttestation extension does not block logons by default.

**Recovery time objective.** 2 hours.

**Steps.**

1. Identify the affected host from the alert payload. Note the VM name and resource group.
2. Run `Get-AttestationStatus.ps1` scoped to this host to get the current validation state across all three levels.
3. Check NSG outbound rules for TCP 443 to `*.attest.azure.net`. Transient MAA endpoint issues typically resolve within 10 minutes.
4. If the NSG is correct and the issue persists, redeploy the GuestAttestation extension on the host:
   ```
   az vm extension set --resource-group <RG> --vm-name <VM> \
     --name GuestAttestation \
     --publisher Microsoft.Azure.Security.WindowsAttestation \
     --version 1.0 --enable-auto-upgrade true
   ```
5. Wait 5-10 minutes for the extension to run its first attestation cycle.
6. Re-run `Get-AttestationStatus.ps1` and confirm all three validation levels pass.

**Verification.** Alert clears within the next 15-minute Azure Monitor evaluation window. Query 1 shows the host back in HEALTHY state.

---

## Tier 2, Moderate: DC-series zone capacity exhausted during scale-out

**Trigger.** Autoscale or `AVD-DeployAdditionalHosts` pipeline fails with `SkuNotAvailable` or `AllocationFailed` errors. Some users are getting "no resources available" messages when connecting.

**Severity.** Moderate. Some users affected. Existing sessions continue to work but new connections during peak times may fail.

**Recovery time objective.** 30 minutes.

**Steps.**

1. Confirm the capacity issue with `az vm list-skus --location <REGION> --size dc --output table` to see current zone availability for DC-series.
2. If Zone 1 is exhausted, edit the `hostpool.template.json` config to set the preferred zone to the next available zone (Zone 2 or 3).
3. Re-run the `AVD-DeployAdditionalHosts` pipeline with the updated config. The pipeline's zone failover logic (documented in part 1) will route new hosts to the alternative zone automatically.
4. If all zones in the primary region are exhausted, escalate to the regional failover runbook (Tier 4 below).

**Verification.** New session hosts provision successfully in the target zone. Users can establish new connections. Monitor the scaling plan over the next 30 minutes to confirm normal behaviour resumes.

---

## Tier 3, Major: Managed HSM key expired without rotation

**Trigger.** KeyExpired Event Grid alert fires (configured in part 2). All deallocated VMs fail to start at disk attachment with a key-related error. New CVM deployments fail.

**Severity.** Major. All users whose sessions are deallocated overnight or during autoscale ramp-down cannot reconnect. Existing running sessions continue working (cached DEK in memory) but cannot be recreated.

**Recovery time objective.** 4 hours.

**Steps.**

1. **Do not panic-restart VMs**. Running VMs have a cached DEK and are still functional. Restarting them while the key is expired will make them unbootable.
2. Check the HSM key state:
   ```
   az keyvault key show --hsm-name <HSM> --name <KEY> --query "attributes.{enabled:enabled, expires:expires}"
   ```
3. If the key is `enabled=true` but `expires` is in the past, extend the expiry or create a new key version using the HSM admin role. See part 2's revocation recovery section for the full procedure.
4. If a new key version is needed, run `Invoke-SafeCMKRotation.ps1` inside a maintenance window. This handles the autoscale exclusion tag automatically.
5. Once the rotation completes, deallocated VMs can start normally. Trigger a scale-out via the autoscale plan to restore full capacity.
6. Verify attestation is still healthy by running `Get-AttestationStatus.ps1`.

**Verification.** Deallocated VMs can be started successfully. New session host deployments complete without disk attachment errors. Event Grid alerts return to normal KeyNearExpiry state with the new expiry date.

**Prevention.** The KeyNearExpiry Event Grid alert fires 30 days before expiry. Set up a Teams or email channel that the team checks daily. Do not rely solely on the portal.

---

## Tier 4, Severe: Belgium Central zone or regional outage

**Trigger.** Azure service health notification for Belgium Central. Multiple session hosts unreachable. Autoscale fails to provision replacement capacity in any zone.

**Severity.** Severe. All users in the affected zone or region unable to work. Customer-facing.

**Recovery time objective.** 8 hours for partial capacity, 24 hours for full capacity.

**Steps.**

1. **Pre-requisite check**: confirm that pre-positioned West Europe infrastructure exists. If the failover region was not prepared in advance, the RTO extends significantly. This is what Tier 4 preparation exists to prevent.
2. Start the regional failover pipeline (`AVD-FailoverToWEU.yml`, not covered in this series but follows the same pattern as the other pipelines).
3. The failover pipeline deploys a new host pool in West Europe using the same CVM image (pre-replicated across regions), the same CMK (Managed HSM cross-region replication must have been configured, see part 2), and the same DCR.
4. Run `Get-AttestationStatus.ps1` against the West Europe hosts with `-MaaEndpoint "https://sharedweu.weu.attest.azure.net"` to confirm attestation is healthy in the failover region.
5. Update the Front Door or Traffic Manager configuration to route users to the West Europe host pool.
6. Communicate status to users via the established communication channel.

**Verification.** Users can connect to the West Europe host pool. All attestation validation levels pass. Failover is clean and reversible.

**Prevention.** Pre-positioned West Europe infrastructure should exist and be tested quarterly in a planned drill. A failover that has never been rehearsed cannot be relied on in a real incident.

---

## What is NOT covered by these runbooks

Several scenarios fall outside the scope of infrastructure-level runbooks and need separate handling:

- **Compromised HSM administrator credentials**: this requires the HSM security domain recovery procedure, which is out of scope for this series.
- **Platform-wide Azure outage affecting both Belgium Central and West Europe**: regional failover assumes at least one European region is available.
- **FSLogix profile container corruption**: user profile issues are a separate operational concern. Currently not covered by the Confidential AVD series.
- **Application-level issues inside the session host**: RDP protocol problems, profile sync issues, and similar are handled by existing AVD runbooks rather than this one.

Each of these deserves its own runbook, separate from the infrastructure Confidential AVD concerns.
