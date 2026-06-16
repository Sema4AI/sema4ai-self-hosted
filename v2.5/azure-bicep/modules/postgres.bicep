@description('Unique prefix used in resource names.')
param infraId string

@description('Azure region.')
param location string

@description('Subnet delegated to PostgreSQL Flexible Server (must hold no other resource).')
param dbSubnetId string

@description('VNet to link the private DNS zone to, so the server FQDN resolves inside it.')
param vnetId string

@description('Name of the deployment database created on the server.')
param databaseName string

@description('Flexible Server SKU name, e.g. Standard_B2s.')
param skuName string

@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param skuTier string

@description('Storage size in GB.')
param storageSizeGB int

@description('PostgreSQL major version. The application requires 17 or newer.')
param postgresVersion string = '17'

param administratorLogin string = 's4admin'

@secure()
param administratorPassword string

// Private DNS so the flexible server FQDN resolves inside the VNet.
resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: '${infraId}.private.postgres.database.azure.com'
  location: 'global'
}

resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: '${infraId}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: 'postgres-${infraId}'
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: postgresVersion
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    storage: {
      storageSizeGB: storageSizeGB
    }
    // Private access only: delegated into the VNet subnet with a private DNS
    // zone, no public endpoint.
    network: {
      delegatedSubnetResourceId: dbSubnetId
      privateDnsZoneArmResourceId: dnsZone.id
    }
  }
  dependsOn: [
    dnsLink
  ]
}

// Allow-list the uuid-ossp extension so the application can enable it. plpgsql
// is built in and needs no allow-listing.
resource extensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-12-01-preview' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: 'UUID-OSSP'
    source: 'user-override'
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    extensions
  ]
}

output host string = server.properties.fullyQualifiedDomainName
output user string = administratorLogin
output database string = databaseName
