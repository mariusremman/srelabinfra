// Log alert rules for resources in this environment.
targetScope = 'resourceGroup'

param baseName string
param location string
param workspaceId string
param alertEmailAddress string
param tags object

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${baseName}'
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: take(replace(baseName, '-', ''), 12)
    enabled: true
    emailReceivers: [
      {
        name: 'email'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

resource appGatewayLatencyP95 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'alert-${baseName}-http-latency-p95'
  location: location
  kind: 'LogAlert'
  tags: tags
  properties: {
    displayName: 'alert-${baseName}-http-latency-p95'
    description: 'p95 latency for requests routed through Application Gateway exceeds 300 ms. Baseline: ~26 ms.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          // Ignore requests rejected by the App Gateway frontend before a backend is selected.
          query: '''
            AGWAccessLogs
            | where isnotempty(BackendPoolName) and isnotempty(BackendSettingName)
            | summarize requests = count(), p95ms = percentile(TimeTaken, 95) * 1000
            | where requests >= 5 and p95ms > 300
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}
