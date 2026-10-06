// Entry point. Deployes på subscription-nivå slik at workflowen kan opprette
// resource group og sende Activity Log til Log Analytics.
targetScope = 'subscription'

@description('Kort prefiks brukt i alle ressursnavn.')
@maxLength(10)
param namePrefix string = 'srelab'

@description('Miljønavn, f.eks. dev/test/prod.')
@maxLength(6)
param environmentName string = 'dev'

@description('Azure-region for alle ressurser.')
param location string = 'norwayeast'

@description('Container image for appen. Tom streng gir placeholder-image (første deploy).')
param containerImage string = ''

@description('Porten appen lytter på i containeren.')
param containerPort int = 8080

@description('Sti Application Gateway bruker til helseprobe mot appen.')
param healthProbePath string = '/'

@description('E-postmottaker for Azure Monitor-varsler.')
param alertEmailAddress string

@description('Admin-brukernavn for PostgreSQL.')
param postgresAdminLogin string = 'pgadmin'

@description('Admin-passord for PostgreSQL. Lagres i Key Vault og eksponeres til appen som secret.')
@secure()
param postgresAdminPassword string

@description('Navn på applikasjonsdatabasen.')
param databaseName string = 'appdb'

param tags object = {
  project: 'srelab'
  environment: environmentName
  managedBy: 'bicep'
}

var baseName = '${namePrefix}-${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${baseName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources-${baseName}'
  scope: rg
  params: {
    baseName: baseName
    location: location
    tags: tags
    containerImage: containerImage
    containerPort: containerPort
    healthProbePath: healthProbePath
    postgresAdminLogin: postgresAdminLogin
    postgresAdminPassword: postgresAdminPassword
    databaseName: databaseName
  }
}

// Activity Log (kontrollplan-hendelser for hele subscriptionen) til Log Analytics.
resource activityLog 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'activitylog-to-${baseName}'
  properties: {
    workspaceId: resources.outputs.logAnalyticsWorkspaceId
    logs: [
      for category in [
        'Administrative'
        'Security'
        'ServiceHealth'
        'Alert'
        'Recommendation'
        'Policy'
        'Autoscale'
        'ResourceHealth'
      ]: {
        category: category
        enabled: true
      }
    ]
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts-${baseName}'
  scope: rg
  params: {
    baseName: baseName
    location: location
    workspaceId: resources.outputs.logAnalyticsWorkspaceId
    alertEmailAddress: alertEmailAddress
    tags: tags
  }
}

output resourceGroupName string = rg.name
output logAnalyticsWorkspaceId string = resources.outputs.logAnalyticsWorkspaceId
output applicationInsightsName string = resources.outputs.applicationInsightsName
output acrName string = resources.outputs.acrName
output acrLoginServer string = resources.outputs.acrLoginServer
output containerAppName string = resources.outputs.containerAppName
output containerAppFqdn string = resources.outputs.containerAppFqdn
output appGatewayPublicIp string = resources.outputs.appGatewayPublicIp
output appUrl string = resources.outputs.appUrl
output postgresFqdn string = resources.outputs.postgresFqdn
output keyVaultName string = resources.outputs.keyVaultName
