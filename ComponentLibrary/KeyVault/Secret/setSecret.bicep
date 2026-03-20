@description('Name of the existing Key Vault')
param keyVaultName string

@description('Name of the secret')
param secretName string

@secure()
@description('Value of the secret')
param secretValue string
param tags object

@description('Current time used for secret expiry calculation. Do not override.')
param currentTime string = utcNow()

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: secretName
  tags: tags
  properties: {
    value: secretValue
    attributes: {
      enabled: true
      exp: dateTimeToEpoch(dateTimeAdd(currentTime, 'P1Y'))  // 1 year from now
    }
  }
}

output secretUri string = secret.properties.secretUri
