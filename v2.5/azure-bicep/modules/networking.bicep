@description('Unique prefix used in resource names.')
param infraId string

@description('Azure region.')
param location string

// VNet with one subnet delegated to PostgreSQL Flexible Server (private access,
// no public endpoint) and one for the application VM. The VM subnet carries
// Storage and Key Vault service endpoints so the storage firewall can allow it.
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${infraId}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: '${infraId}-db-sn'
        properties: {
          addressPrefixes: ['10.0.2.0/24']
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
          delegations: [
            {
              name: 'fs'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
      {
        name: '${infraId}-vm-sn'
        properties: {
          addressPrefixes: ['10.0.16.0/24']
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
            { service: 'Microsoft.KeyVault' }
          ]
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output dbSubnetId string = vnet.properties.subnets[0].id
output vmSubnetId string = vnet.properties.subnets[1].id
