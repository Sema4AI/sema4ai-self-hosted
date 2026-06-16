@description('Unique prefix used in resource names.')
param infraId string

@description('Azure region.')
param location string

@description('Subnet of the application VM, allowed to bypass the storage firewall.')
param vmSubnetId string

@description('Principal ID of the VM managed identity, granted Storage Blob Data Contributor.')
param identityPrincipalId string

// Storage account names: 3-24 chars, lowercase alphanumeric only.
var storageAccountName = toLower(take('${replace(infraId, '-', '')}files', 24))
var containerName = '${infraId}-agent-files'

// Built-in role: Storage Blob Data Contributor.
var blobContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_ZRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    encryption: {
      requireInfrastructureEncryption: true
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
    }
    // Deny by default; allow only the VM's subnet via the service endpoint.
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: vmSubnetId
          action: 'Allow'
        }
      ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

resource blobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, identityPrincipalId, blobContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRoleId)
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output storageAccountName string = storageAccount.name
output storageContainerName string = container.name
