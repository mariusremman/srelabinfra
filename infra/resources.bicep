// Orkestrerer alle ressurser i resource groupen.
targetScope = 'resourceGroup'

param baseName string
param location string
param tags object
param containerImage string
param containerPort int
param healthProbePath string
param postgresAdminLogin string
@secure()
param postgresAdminPassword string
param databaseName string

// Kort, deterministisk suffiks for ressurser som krever globalt unike navn.
var suffix = take(uniqueString(resourceGroup().id), 6)
var compactName = replace(baseName, '-', '')

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    baseName: baseName
    location: location
    tags: tags
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    baseName: baseName
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
  }
}

// Identiteten container appen bruker mot ACR og Key Vault.
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${baseName}-app'
  location: location
  tags: tags
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    name: 'acr${compactName}${suffix}'
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    pullPrincipalId: appIdentity.properties.principalId
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    serverName: 'psql-${baseName}-${suffix}'
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    vnetId: network.outputs.vnetId
    subnetId: network.outputs.dbSubnetId
    adminLogin: postgresAdminLogin
    adminPassword: postgresAdminPassword
    databaseName: databaseName
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: 'kv-${baseName}-${suffix}'
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    readerPrincipalId: appIdentity.properties.principalId
    dbPassword: postgresAdminPassword
  }
}

module containerApps 'modules/containerapps.bicep' = {
  name: 'containerapps'
  params: {
    baseName: baseName
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    vnetId: network.outputs.vnetId
    subnetId: network.outputs.acaSubnetId
    identityId: appIdentity.id
    acrLoginServer: registry.outputs.loginServer
    containerImage: containerImage
    containerPort: containerPort
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    dbHost: postgres.outputs.fqdn
    dbName: databaseName
    dbUser: postgresAdminLogin
    dbPasswordSecretUri: keyVault.outputs.dbPasswordSecretUri
  }
}

module appGateway 'modules/appgateway.bicep' = {
  name: 'appgateway'
  params: {
    baseName: baseName
    location: location
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
    subnetId: network.outputs.appGwSubnetId
    backendFqdn: containerApps.outputs.appFqdn
    healthProbePath: healthProbePath
    dnsLabel: '${baseName}-${suffix}'
  }
}

output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output applicationInsightsName string = monitoring.outputs.appInsightsName
output acrName string = registry.outputs.name
output acrLoginServer string = registry.outputs.loginServer
output containerAppName string = containerApps.outputs.appName
output containerAppFqdn string = containerApps.outputs.appFqdn
output appGatewayPublicIp string = appGateway.outputs.publicIpAddress
output appUrl string = 'http://${appGateway.outputs.fqdn}'
output postgresFqdn string = postgres.outputs.fqdn
output keyVaultName string = keyVault.outputs.name
