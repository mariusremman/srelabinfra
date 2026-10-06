// VNet med tre subnett: Application Gateway, Container Apps-miljø og PostgreSQL.
param baseName string
param location string
param tags object
param workspaceId string
param addressPrefix string = '10.20.0.0/16'
param appGwSubnetPrefix string = '10.20.0.0/24'
param acaSubnetPrefix string = '10.20.2.0/23'
param dbSubnetPrefix string = '10.20.4.0/24'

resource nsgAppGw 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${baseName}-appgw'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        // Påkrevd for Application Gateway v2 sin kontrollplan.
        name: 'AllowGatewayManager'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'AllowHttpFromInternet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
        }
      }
    ]
  }
}

resource nsgAca 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${baseName}-aca'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource nsgDb 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${baseName}-db'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${baseName}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-appgw'
        properties: {
          addressPrefix: appGwSubnetPrefix
          networkSecurityGroup: {
            id: nsgAppGw.id
          }
          // Nye v2-gatewayer deployes med network isolation, som krever delegert subnett.
          delegations: [
            {
              name: 'appgw'
              properties: {
                serviceName: 'Microsoft.Network/applicationGateways'
              }
            }
          ]
        }
      }
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: acaSubnetPrefix
          networkSecurityGroup: {
            id: nsgAca.id
          }
          delegations: [
            {
              name: 'aca'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'snet-db'
        properties: {
          addressPrefix: dbSubnetPrefix
          networkSecurityGroup: {
            id: nsgDb.id
          }
          delegations: [
            {
              name: 'postgres'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource vnetDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: vnet
  properties: {
    workspaceId: workspaceId
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

resource nsgAppGwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: nsgAppGw
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource nsgAcaDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: nsgAca
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource nsgDbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: nsgDb
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output vnetId string = vnet.id
output appGwSubnetId string = vnet.properties.subnets[0].id
output acaSubnetId string = vnet.properties.subnets[1].id
output dbSubnetId string = vnet.properties.subnets[2].id
