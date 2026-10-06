// Application Gateway v2 (Standard) – offentlig inngang som videresender til container appen.
param baseName string
param location string
param tags object
param workspaceId string
param subnetId string
@description('FQDN til container appen (løses via privat DNS i VNet-et).')
param backendFqdn string
param healthProbePath string
param dnsLabel string
param minCapacity int = 0
param maxCapacity int = 2

var name = 'agw-${baseName}'
var agwId = resourceId('Microsoft.Network/applicationGateways', name)

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${baseName}-agw'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

resource agw 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
    }
    autoscaleConfiguration: {
      minCapacity: minCapacity
      maxCapacity: maxCapacity
    }
    gatewayIPConfigurations: [
      {
        name: 'gateway-ip'
        properties: {
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'public-frontend'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-80'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'containerapp'
        properties: {
          backendAddresses: [
            {
              fqdn: backendFqdn
            }
          ]
        }
      }
    ]
    probes: [
      {
        name: 'containerapp-probe'
        properties: {
          protocol: 'Https'
          path: healthProbePath
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'containerapp-https'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          // Container Apps ruter på Host-header, så den må være appens FQDN.
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
          probe: {
            id: '${agwId}/probes/containerapp-probe'
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'http-listener'
        properties: {
          frontendIPConfiguration: {
            id: '${agwId}/frontendIPConfigurations/public-frontend'
          }
          frontendPort: {
            id: '${agwId}/frontendPorts/port-80'
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'http-to-containerapp'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: '${agwId}/httpListeners/http-listener'
          }
          backendAddressPool: {
            id: '${agwId}/backendAddressPools/containerapp'
          }
          backendHttpSettings: {
            id: '${agwId}/backendHttpSettingsCollection/containerapp-https'
          }
        }
      }
    ]
  }
}

resource pipDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: pip
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

resource agwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: agw
  properties: {
    workspaceId: workspaceId
    // Ressursspesifikke tabeller (AGWAccessLogs, AGWPerformanceLogs, ...).
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

output publicIpAddress string = pip.properties.ipAddress
output fqdn string = pip.properties.dnsSettings.fqdn
