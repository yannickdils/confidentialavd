@description('Name of the Data Collection Rule.')
param dataCollectionRuleName string

@description('Azure region for the DCR.')
param location string = resourceGroup().location

@description('Resource ID of the Log Analytics Workspace to send data to.')
param logAnalyticsWorkspaceId string

@description('Tags to apply to all resources.')
param tags object

// ---------------------------------------------------------------------------
// Data Collection Rule for Confidential AVD monitoring
//
// This DCR collects three categories of data that the standard AVD Insights
// DCR does not cover:
//
//   1. WindowsEvent - Security channel events including:
//      - Event 4624/4634 (logon/logoff) for session tracking
//      - Event 5059 (Key migration) - relevant for vTPM key operations
//      - System events from the GuestAttestation extension
//
//   2. WindowsEventLog - Guest Attestation extension logs
//      The GuestAttestation extension writes to the
//      Microsoft-Windows-Attestation operational log.
//
//   3. PerformanceCounters - CVM-specific perf counters
//      Standard AVD counters plus attestation health check intervals.
//
// The DCR is associated to each session host via the dcrAssociation resource
// in avd-sessionhosts-cc.bicep (the dataCollectionRuleId param).
// ---------------------------------------------------------------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    description: 'Data Collection Rule for Confidential AVD session hosts - collects attestation events, security events, and CVM performance counters.'
    dataSources: {
      windowsEventLogs: [
        {
          name: 'SecurityEvents'
          streams: ['Microsoft-SecurityEvent']
          xPathQueries: [
            // Logon and logoff events for session tracking
            'Security!*[System[(EventID=4624 or EventID=4634 or EventID=4647)]]'
            // vTPM key operations - important for CVM key health
            'Security!*[System[(EventID=5059 or EventID=5061)]]'
            // Credential manager events relevant to CVM attestation
            'Security!*[System[(EventID=5379 or EventID=5380)]]'
          ]
        }
        {
          name: 'AttestationEvents'
          streams: ['Microsoft-WindowsEvent']
          xPathQueries: [
            // GuestAttestation extension operational log
            'Microsoft-Windows-Attestation/Operational!*'
            // Trusted Platform Module driver events
            'Microsoft-Windows-TPM-WMI/Operational!*[System[(Level=1 or Level=2 or Level=3)]]'
            // Windows Boot events (boot measurement chain integrity)
            'Microsoft-Windows-Kernel-Boot/Operational!*[System[(Level=1 or Level=2)]]'
          ]
        }
        {
          name: 'SystemEvents'
          streams: ['Microsoft-WindowsEvent']
          xPathQueries: [
            // System-level errors that could indicate CVM health issues
            'System!*[System[(Level=1 or Level=2)]]'
          ]
        }
      ]
      performanceCounters: [
        {
          name: 'CvmPerformanceCounters'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            // Standard AVD counters
            '\\LogicalDisk(C:)\\% Free Space'
            '\\Memory\\Available MBytes'
            '\\Processor(_Total)\\% Processor Time'
            '\\Terminal Services\\Active Sessions'
            '\\Terminal Services\\Inactive Sessions'
            '\\Terminal Services\\Total Sessions'
            // Network - useful for detecting attestation endpoint connectivity issues
            '\\Network Interface(*)\\Bytes Total/sec'
            '\\TCPv4\\Connections Established'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'la-destination'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-SecurityEvent']
        destinations: ['la-destination']
        transformKql: 'source'
        outputStream: 'Microsoft-SecurityEvent'
      }
      {
        streams: ['Microsoft-WindowsEvent']
        destinations: ['la-destination']
        transformKql: 'source'
        outputStream: 'Microsoft-WindowsEvent'
      }
      {
        streams: ['Microsoft-Perf']
        destinations: ['la-destination']
        transformKql: 'source'
        outputStream: 'Microsoft-Perf'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output dataCollectionRuleId   string = dcr.id
output dataCollectionRuleName string = dcr.name
