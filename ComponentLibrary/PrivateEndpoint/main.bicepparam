using './main.bicep'

param privateEndpointName = ''
param privateLinkResource = ''
param targetSubResource = ''
param subnet = ''
param privateDnsZoneId = ''
param tags = {
  businessdomain: 'ItForDev'
  environment: 'hub'
  importance: 'medium'
  product: 'product'
  team: 'Enterprise Architecture'
  applicationowner: '<OWNER_EMAIL>'
  app: 'containerregistry'
  application: 'containerregistry'
  activeworkinghours: '24x7'
  activeworkingdays: '24x7'
  startstopenabled: 'false'
  owner: '<OWNER_EMAIL>'
}

