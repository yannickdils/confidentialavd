@description('Name of the Key Vault to monitor for CMK key expiry events.')
param keyVaultName string

@description('Resource ID of the Key Vault to monitor.')
param keyVaultId string

@description('Azure region for the Event Grid System Topic and alert resources.')
param location string = resourceGroup().location

@description('Name of the Action Group to notify when a key near-expiry event fires.')
param actionGroupName string

@description('Display name for the Action Group.')
param actionGroupShortName string

@description('Email addresses to notify when the CMK key is approaching expiry. Provide at least one.')
param notificationEmails array

@description('Optional: webhook URI to call on key near-expiry (e.g. Logic App, Power Automate). Leave empty to skip.')
param webhookUri string = ''

@description('Name of the Event Grid System Topic. Defaults to a name derived from the Key Vault name.')
param eventGridTopicName string = 'evgt-${keyVaultName}-cmk'

@description('Tags to apply to all resources.')
param tags object

// ---------------------------------------------------------------------------
// Action Group
// Collects the notification targets. We wire up email receivers from the
// notificationEmails array and optionally a webhook for pipeline automation.
// ---------------------------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: [
      for (email, i) in notificationEmails: {
        name: 'cmk-expiry-email-${i}'
        emailAddress: email
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: !empty(webhookUri)
      ? [
          {
            name: 'cmk-expiry-webhook'
            serviceUri: webhookUri
            useCommonAlertSchema: true
            useAadAuth: false
          }
        ]
      : []
  }
}

// ---------------------------------------------------------------------------
// Event Grid System Topic scoped to the Key Vault
// Azure fires Microsoft.KeyVault.KeyNearExpiry 30 days before the key expires.
// ---------------------------------------------------------------------------
resource eventGridTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' = {
  name: eventGridTopicName
  location: location
  tags: tags
  properties: {
    source: keyVaultId
    topicType: 'Microsoft.KeyVault.vaults'
  }
}

// ---------------------------------------------------------------------------
// Event Grid subscription that routes KeyNearExpiry / KeyExpired /
// KeyNewVersionCreated events directly to Azure Monitor as alerts.
// The MonitorAlert destination creates monitor alerts automatically and
// triggers the Action Group - no standalone Activity Log Alert is needed.
// ---------------------------------------------------------------------------
resource nearExpiryEventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = {
  name: 'sub-cmk-key-near-expiry'
  parent: eventGridTopic
  properties: {
    eventDeliverySchema: 'EventGridSchema'
    filter: {
      includedEventTypes: [
        'Microsoft.KeyVault.KeyNearExpiry'
        'Microsoft.KeyVault.KeyExpired'
        'Microsoft.KeyVault.KeyNewVersionCreated'
      ]
    }
    destination: {
      endpointType: 'MonitorAlert'
      properties: {
        actionGroups: [
          actionGroup.id
        ]
        description: 'CMK key event detected for Key Vault ${keyVaultName}. If nearing expiry: stop CVM session hosts, rotate the key (update DES key version), then restart hosts.'
        severity: 'Sev1'
      }
    }
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output actionGroupId string = actionGroup.id
output eventGridTopicId string = eventGridTopic.id
output eventGridTopicName string = eventGridTopic.name
