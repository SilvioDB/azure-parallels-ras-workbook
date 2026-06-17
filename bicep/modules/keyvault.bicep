// Creates the Key Vault for RAS credentials and assigns Key Vault Secrets User
// to the collector Managed Identities.

param keyVaultName string
param location string
param collectorPrincipalIds array = []

// Role ID built-in: Key Vault Secrets User (verificato sulla subscription)
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
    publicNetworkAccess: 'Enabled'
  }
}

resource kvSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in collectorPrincipalIds: {
  name: guid(kv.id, principalId, kvSecretsUserRoleId)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]

output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
