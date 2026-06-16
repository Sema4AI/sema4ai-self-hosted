@description('Unique prefix used in resource names.')
param infraId string

@description('Azure region. Key Vault must be in the same region as the VM.')
param location string

@description('Tenant ID for the Key Vault access policies.')
param tenantId string

@description('Principal ID of the VM managed identity (granted Get/WrapKey/UnwrapKey on the KEK).')
param identityPrincipalId string

// Key Vault holds ONLY the envelope-encryption key (KEK). The application wraps
// a locally generated AES DEK against this RSA key; Postgres and OIDC values go
// through the KOTS admin console, not Key Vault.
//
// The key is created as a control-plane resource (Microsoft.KeyVault/vaults/keys),
// so the deployer needs only Key Vault Contributor / Contributor — no data-plane
// access policy. The VM identity gets the data-plane access policy below.
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${infraId}'
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    accessPolicies: [
      {
        tenantId: tenantId
        objectId: identityPrincipalId
        permissions: {
          keys: ['get', 'wrapKey', 'unwrapKey']
        }
      }
    ]
  }
}

resource kek 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: vault
  name: 'envelope-encryption'
  properties: {
    kty: 'RSA'
    keySize: 2048
    keyOps: ['wrapKey', 'unwrapKey']
  }
}

output keyVaultName string = vault.name
output keyVaultKeyUrl string = kek.properties.keyUriWithVersion
