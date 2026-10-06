// Alert-regler basert på tersklene i docs/baseline.md. Alerts i resource groupen plukkes
// opp av Azure SRE Agent (incident platform: Azure Monitor). Action groupen sender e-post.
param baseName string
param location string
param tags object
param workspaceId string
param appGatewayId string
param containerAppId string
param postgresId string
@description('E-post for varsling. Tom streng = ingen e-post (alerts fyrer likevel).')
param alertEmail string = ''

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${baseName}'
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: take(replace(baseName, '-', ''), 12)
    enabled: true
    emailReceivers: empty(alertEmail)
      ? []
      : [
          {
            name: 'email'
            emailAddress: alertEmail
            useCommonAlertSchema: true
          }
        ]
  }
}

var metricAlerts = [
  {
    name: 'agw-unhealthy-backend'
    description: 'Application Gateway rapporterer usunn backend (container appen). Baseline: UnhealthyHostCount = 0.'
    severity: 1
    scope: appGatewayId
    namespace: 'Microsoft.Network/applicationGateways'
    metric: 'UnhealthyHostCount'
    aggregation: 'Average'
    operator: 'GreaterThan'
    threshold: 0
    window: 'PT5M'
    frequency: 'PT1M'
  }
  {
    name: 'app-high-cpu'
    description: 'Container appen bruker over 80 % av CPU-grensen. Baseline: 3-4 % under normal trafikk.'
    severity: 2
    scope: containerAppId
    namespace: 'Microsoft.App/containerApps'
    metric: 'CpuPercentage'
    aggregation: 'Average'
    operator: 'GreaterThan'
    threshold: 80
    window: 'PT5M'
    frequency: 'PT1M'
  }
  {
    name: 'app-high-memory'
    description: 'Container appen bruker over 300 MB minne. Baseline: ~135 MB og flatt. Grensen er 1 GiB.'
    severity: 3
    scope: containerAppId
    namespace: 'Microsoft.App/containerApps'
    metric: 'WorkingSetBytes'
    aggregation: 'Average'
    operator: 'GreaterThan'
    threshold: 314572800
    window: 'PT5M'
    frequency: 'PT1M'
  }
  {
    name: 'db-high-cpu'
    description: 'PostgreSQL CPU over 80 %. Baseline: ~8 %.'
    severity: 2
    scope: postgresId
    namespace: 'Microsoft.DBforPostgreSQL/flexibleServers'
    metric: 'cpu_percent'
    aggregation: 'Average'
    operator: 'GreaterThan'
    threshold: 80
    window: 'PT10M'
    frequency: 'PT5M'
  }
  {
    name: 'db-low-cpu-credits'
    description: 'PostgreSQL (Burstable B1ms) har under 10 CPU-kreditter igjen og vil snart strupes. Baseline: ~40 og stigende.'
    severity: 2
    scope: postgresId
    namespace: 'Microsoft.DBforPostgreSQL/flexibleServers'
    metric: 'cpu_credits_remaining'
    aggregation: 'Average'
    operator: 'LessThan'
    threshold: 10
    window: 'PT15M'
    frequency: 'PT5M'
  }
  {
    name: 'db-high-connections'
    description: 'PostgreSQL har over 20 aktive tilkoblinger. Baseline: 9-11.'
    severity: 3
    scope: postgresId
    namespace: 'Microsoft.DBforPostgreSQL/flexibleServers'
    metric: 'active_connections'
    aggregation: 'Maximum'
    operator: 'GreaterThan'
    threshold: 20
    window: 'PT5M'
    frequency: 'PT1M'
  }
]

// Logg-alerts evalueres hvert 5. minutt over 10 minutter, slik at sen innlesing i
// Log Analytics ikke gjør at hendelser faller mellom to evalueringer.
var logAlerts = [
  {
    name: 'http-5xx-rate'
    description: 'Over 2 % av requests gjennom Application Gateway gir 5xx. Baseline: 0 %.'
    severity: 1
    query: '''
AGWAccessLogs
| summarize requests = count(), errors = countif(HttpStatus >= 500)
| extend errorPct = 100.0 * errors / requests
| where requests >= 5 and errorPct > 2
'''
  }
  {
    name: 'http-latency-p95'
    // 4xx ekskluderes: skannere fra internett gir trege 400-svar som ellers dominerer p95 ved lite trafikk.
    description: 'p95-latens gjennom Application Gateway over 300 ms (ekskl. 4xx). Baseline: ~26 ms.'
    severity: 2
    query: '''
AGWAccessLogs
| where HttpStatus !between (400 .. 499)
| summarize requests = count(), p95ms = percentile(TimeTaken, 95) * 1000
| where requests >= 20 and p95ms > 300
'''
  }
  {
    name: 'app-exceptions'
    description: 'Appen kaster uhåndterte exceptions. Baseline: 0.'
    severity: 2
    query: '''
AppExceptions
| summarize exceptions = sum(ItemCount)
| where exceptions > 0
'''
  }
  {
    name: 'db-dependency-degraded'
    description: 'Databasekall feiler eller har p95 over 200 ms. Baseline: 0 feil, p95 ~6 ms.'
    severity: 2
    query: '''
AppDependencies
| where DependencyType == "postgresql"
| summarize calls = sum(ItemCount), failed = sumif(ItemCount, Success == false), p95ms = percentile(DurationMs, 95)
| where failed > 0 or p95ms > 200
'''
  }
  {
    name: 'app-container-restart'
    description: 'Containeren er terminert, krasjer eller er OOMKilled utenom en vanlig deploy. Baseline: ingen.'
    severity: 2
    query: '''
ContainerAppSystemLogs
| where Reason in ("ContainerTerminated", "BackOff") or Log has "OOMKilled"
| where Log !has "ManuallyStopped"
'''
  }
]

resource metricAlertRules 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for a in metricAlerts: {
    name: 'alert-${baseName}-${a.name}'
    location: 'global'
    tags: tags
    properties: {
      description: a.description
      severity: a.severity
      enabled: true
      scopes: [
        a.scope
      ]
      evaluationFrequency: a.frequency
      windowSize: a.window
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: a.metric
            metricNamespace: a.namespace
            metricName: a.metric
            timeAggregation: a.aggregation
            operator: a.operator
            threshold: a.threshold
          }
        ]
      }
      actions: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
]

resource logAlertRules 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [
  for a in logAlerts: {
    name: 'alert-${baseName}-${a.name}'
    location: location
    tags: tags
    kind: 'LogAlert'
    properties: {
      displayName: 'alert-${baseName}-${a.name}'
      description: a.description
      severity: a.severity
      enabled: true
      scopes: [
        workspaceId
      ]
      evaluationFrequency: 'PT5M'
      windowSize: 'PT10M'
      autoMitigate: true
      criteria: {
        allOf: [
          {
            query: a.query
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
      actions: {
        actionGroups: [
          actionGroup.id
        ]
      }
    }
  }
]

output actionGroupId string = actionGroup.id
