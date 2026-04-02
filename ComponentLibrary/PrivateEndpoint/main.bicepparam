using './main.bicep'

param privateEndpointName = ''
param privateLinkResource = ''
param targetSubResource = ''
param subnet = ''
param privateDnsZoneId = ''
param tags = {
  businessdomain: ''
  environment: ''
  importance: ''
  product: ''
  team: ''
  applicationowner: ''
  app: ''
  application: ''
  activeworkinghours: ''
  activeworkingdays: ''
  startstopenabled: ''
  owner: ''
}

