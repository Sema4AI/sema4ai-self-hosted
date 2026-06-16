// Azure prerequisites for a Sema4.ai self-hosted deployment on a single VM
// (Replicated Embedded Cluster / KOTS), authored for a low-friction
// "Deploy to Azure" portal experience.
//
// Resource-group scoped: pick or create the resource group in the portal form;
// this template fills it. OIDC is intentionally NOT created here (no Microsoft
// Graph rights needed) — bring your own identity provider and paste its details
// into the KOTS admin console. The PostgreSQL admin password is generated and
// returned as a deployment output for you to copy into the console.

@minLength(3)
@maxLength(15)
@description('Unique lowercase DNS label used in resource names and as the VM public DNS label (3-15 chars, start with a letter).')
param infraId string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('SSH public key (OpenSSH format) authorized for the VM admin user. Generate with: ssh-keygen -t ed25519')
param adminSshPublicKey string

@description('Linux admin username on the VM.')
param adminUsername string = 's4admin'

@description('CIDR allowed inbound on port 22 (SSH). Defaults to anywhere — tighten for production.')
param adminSshCidr string = '0.0.0.0/0'

@description('Customer-facing FQDN. Leave blank to use the Azure-assigned VM FQDN. Point its DNS A record at the vmPublicIp output after deployment.')
param customHostname string = ''

@description('VM size. Standard_D4s_v6 (4 vCPU / 16 GiB) is the recommended floor.')
param vmSize string = 'Standard_D4s_v6'

@description('PostgreSQL Flexible Server SKU name. Default is the low-load Burstable B2s.')
param postgresSkuName string = 'Standard_B2s'

@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
@description('PostgreSQL SKU tier. Use GeneralPurpose or MemoryOptimized for production.')
param postgresSkuTier string = 'Burstable'

@description('PostgreSQL storage size in GB.')
param postgresStorageSizeGB int = 128

@secure()
@description('PostgreSQL admin password. Leave the default to auto-generate one (returned as an output to paste into the KOTS console).')
param postgresAdminPassword string = '${newGuid()}Aa1!'

var databaseName = replace(infraId, '-', '_')

// VM identity used to wrap/unwrap the KEK and reach blob storage.
resource vmIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'vm-identity'
  location: location
}

module networking 'modules/networking.bicep' = {
  name: 'networking'
  params: {
    infraId: infraId
    location: location
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    infraId: infraId
    location: location
    dbSubnetId: networking.outputs.dbSubnetId
    vnetId: networking.outputs.vnetId
    databaseName: databaseName
    skuName: postgresSkuName
    skuTier: postgresSkuTier
    storageSizeGB: postgresStorageSizeGB
    administratorPassword: postgresAdminPassword
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    infraId: infraId
    location: location
    vmSubnetId: networking.outputs.vmSubnetId
    identityPrincipalId: vmIdentity.properties.principalId
  }
}

module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    infraId: infraId
    location: location
    tenantId: subscription().tenantId
    identityPrincipalId: vmIdentity.properties.principalId
  }
}

module vm 'modules/vm.bicep' = {
  name: 'vm'
  params: {
    infraId: infraId
    location: location
    vmSubnetId: networking.outputs.vmSubnetId
    identityId: vmIdentity.id
    vmSize: vmSize
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    adminSshCidr: adminSshCidr
  }
}

var effectiveHostname = empty(customHostname) ? vm.outputs.vmPublicFqdn : customHostname

// ---------------------------------------------------------------------------
// Outputs — the values to enter on the KOTS admin console "Config" screen,
// plus the connection details to reach the VM. Read them after deployment in
// the portal (Deployment > Outputs) or with:
//   az deployment group show -g <rg> -n <deployment> --query properties.outputs
// ---------------------------------------------------------------------------

output vmPublicIp string = vm.outputs.vmPublicIp
output vmPublicFqdn string = vm.outputs.vmPublicFqdn
output sshCommand string = 'ssh ${adminUsername}@${effectiveHostname}'
output kotsAdminConsoleSshCommand string = 'ssh -L 8800:localhost:30000 ${adminUsername}@${effectiveHostname}'

// KOTS Config UI fields
output externalUrl string = 'https://${effectiveHostname}'
output infrastructurePlatform string = 'Microsoft Azure'
output storageAccountName string = storage.outputs.storageAccountName
output blobContainerName string = storage.outputs.storageContainerName
output blobKeyPrefix string = infraId
output keyVaultKeyUrl string = keyvault.outputs.keyVaultKeyUrl
output postgresHost string = postgres.outputs.host
output postgresPort string = '5432'
output postgresUser string = postgres.outputs.user
output postgresDatabase string = postgres.outputs.database

// Intentionally surfaced so the operator can copy it into the KOTS console.
// Read it from the deployment outputs and treat it as a secret. (Same trade-off
// as the Terraform reference; the linter warning is suppressed deliberately.)
#disable-next-line outputs-should-not-contain-secrets
output postgresPassword string = postgresAdminPassword

@description('OIDC is not provisioned by this template. Register an app with your IdP and fill these in the KOTS console.')
output oidcClientId string = 'REPLACE_ME'
output oidcClientSecret string = 'REPLACE_ME'
output oidcServer string = 'REPLACE_ME'
