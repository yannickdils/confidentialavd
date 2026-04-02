param privateEndpointName string
param privateLinkResource string
param targetSubResource string
param subnet string
param location string = resourceGroup().location
param privateDnsZoneId string
param tags object

var PEPname = 'pep-${privateEndpointName}-${targetSubResource}'
var NICName = 'nic-${privateEndpointName}-${targetSubResource}'

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  location: location
  name: PEPname
  properties: {
    subnet: {
      id: subnet
    }
    customNetworkInterfaceName: NICName
    privateLinkServiceConnections: [
      {
        name: '${PEPname}-link'
        properties: {
          privateLinkServiceId: privateLinkResource
          groupIds: [
            targetSubResource
          ]
        }
      }
    ]
  }
  tags: tags

  resource privateEndpointDns 'privateDnsZoneGroups' = {
    name: '${PEPname}-dns'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: '${PEPname}-dns-config'
          properties: {
            privateDnsZoneId: privateDnsZoneId
          }
        }
      ]
    }
  }
}
