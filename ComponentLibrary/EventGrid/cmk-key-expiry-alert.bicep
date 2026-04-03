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
// Azure Monitor Alert rule that listens to the Event Grid system topic and
// fires the Action Group when a KeyNearExpiry event arrives.
// Using the Event Grid - Azure Monitor Alerts integration so we do not need a
// separate Logic App or Azure Function just to send an email.
// ---------------------------------------------------------------------------
resource nearExpiryAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-cmk-key-near-expiry-${keyVaultName}'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: 'Fires 30 days before the CMK key in ${keyVaultName} expires. Take action: stop CVM session hosts, update DES key version, restart hosts.'
    scopes: [
      keyVaultId
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

// Event Grid subscription that routes KeyNearExpiry events to Azure Monitor
resource nearExpiryEventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = {
  name: 'sub-cmk-key-near-expiry'
  parent: eventGridTopic
  properties: {
    eventDeliverySchema: 'CloudEventSchemaV1_0'
    filter: {
      includedEventTypes: [
        'Microsoft.KeyVault.KeyNearExpiry'
        'Microsoft.KeyVault.KeyExpired'
        'Microsoft.KeyVault.KeyNewVersionCreated'
      ]
    }
    destination: {
      endpointType: 'AzureMonitorAlert'
      properties: {
        resourceId: nearExpiryAlert.id
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
