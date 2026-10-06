// Internt Container Apps-miljø (kun tilgjengelig i VNet) + selve container appen.
// Application Gateway er eneste inngang fra internett.
param baseName string
param location string
param tags object
param workspaceId string
param vnetId string
param subnetId string
param identityId string
param acrLoginServer string
param containerImage string
param containerPort int
@secure()
param appInsightsConnectionString string
param dbHost string
param dbName string
param dbUser string
#disable-next-line secure-secrets-in-params // Kun en URI til secreten, ikke selve verdien.
param dbPasswordSecretUri string
param minReplicas int = 1
param maxReplicas int = 3

// Første deploy (før app-repoet har pushet et image) bruker Microsofts hello-world-image på port 80.
var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'
var usePlaceholder = empty(containerImage)
var appName = 'ca-${baseName}'

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${baseName}'
  location: location
  tags: tags
  properties: {
    // 'azure-monitor' sender konsoll- og systemlogger via diagnostic setting under.
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    vnetConfiguration: {
      internal: true
      infrastructureSubnetId: subnetId
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

resource envDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: env
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Privat DNS slik at Application Gateway kan slå opp appens FQDN til miljøets interne IP.
module envDns 'aca-dns.bicep' = {
  name: 'aca-dns'
  params: {
    zoneName: env.properties.defaultDomain
    staticIp: env.properties.staticIp
    vnetId: vnetId
    tags: tags
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: env.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        // "external" i et internt miljø = tilgjengelig i VNet-et (for Application Gateway).
        external: true
        targetPort: usePlaceholder ? 80 : containerPort
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acrLoginServer
          identity: identityId
        }
      ]
      secrets: [
        {
          name: 'db-password'
          keyVaultUrl: dbPasswordSecretUri
          identity: identityId
        }
        {
          name: 'appinsights-connection-string'
          value: appInsightsConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'app'
          image: usePlaceholder ? placeholderImage : containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
            { name: 'OTEL_SERVICE_NAME', value: appName }
            { name: 'PORT', value: string(containerPort) }
            { name: 'DB_HOST', value: dbHost }
            { name: 'DB_PORT', value: '5432' }
            { name: 'DB_NAME', value: dbName }
            { name: 'DB_USER', value: dbUser }
            { name: 'DB_PASSWORD', secretRef: 'db-password' }
            { name: 'DB_SSLMODE', value: 'require' }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
}

resource appDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: app
  properties: {
    workspaceId: workspaceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output environmentName string = env.name
output appId string = app.id
output appName string = app.name
output appFqdn string = app.properties.configuration.ingress.fqdn
