# Queries

KQL (Kusto Query Language) queries for monitoring Confidential AVD session host attestation health in Log Analytics.

## Files

### `attestation-kql-queries.kql`

A collection of 8 saved queries designed to be used in your Log Analytics workspace or as custom tiles in an AVD Insights workbook.

| Query | Purpose |
|-------|---------|
| **1. Attestation health per host** | Current GuestAttestation extension status across all CVM session hosts (last 24h) |
| **2. Attestation failures and warnings** | Level 1/2/3 events from attestation and TPM channels (last 7d) |
| **3. vTPM key operations** | Security events 5059/5061 for key migration monitoring (last 7d) |
| **4. Hosts with no attestation events** | Cross-reference to find hosts that have never sent attestation telemetry |
| **5. Attestation event trend** | Daily event counts by severity for time-chart visualization (last 30d) |
| **6. Logon activity per host** | User logon/logoff counts to prioritize investigation of busy hosts |
| **7. Performance baseline** | CPU, memory, disk, and session counts for CVM health overview (last 1h) |
| **8. Policy compliance events** | Azure Policy non-compliance events for the Guest Attestation policy (last 7d) |

## Prerequisites

- The GuestAttestation extension must be installed on all CVM session hosts
- The DCR from `ComponentLibrary/GuestAttestation/dcr-confidential-avd.bicep` must be associated to all session hosts
- The AzureMonitorWindowsAgent extension must be collecting data
- For query 8: Azure Policy diagnostic logs must be routed to the same Log Analytics Workspace

## Usage

1. Open your Log Analytics Workspace in the Azure Portal
2. Go to **Logs**
3. Paste individual queries from the `.kql` file
4. Optionally save them as **Saved Searches** or add them as custom tiles to your AVD Insights workbook

## Related Files

| File | Purpose |
|------|---------|
| [`ComponentLibrary/GuestAttestation/dcr-confidential-avd.bicep`](../ComponentLibrary/GuestAttestation/dcr-confidential-avd.bicep) | DCR that collects the data these queries operate on |
| [`Scripts/Get-AttestationStatus.ps1`](../Scripts/Get-AttestationStatus.ps1) | Script-based attestation health check (alternative to KQL) |
| [`ComponentLibrary/Policy/policy-require-guest-attestation.bicep`](../ComponentLibrary/Policy/policy-require-guest-attestation.bicep) | Policy definition that query 8 monitors |
