// Alert-regler basert på tersklene i docs/baseline.md. Alerts i resource groupen plukkes
// opp av Azure SRE Agent (incident platform: Azure Monitor). Action groupen sender e-post.
//
// Alvorlighet skiller symptom fra årsak, slik at én hendelse gir én undersøkelse:
// - Sev1/Sev2: det brukerne merker (5xx, latens). Disse starter en undersøkelse i SRE Agent.
// - Sev3: årsaker og tidlige varsler. De gir e-post og er kontekst for undersøkelsen,
//   men starter ingen egen undersøkelse (response planen dekker Sev0-2).
param baseName string
param location string
param tags object
param workspaceId string
param appGatewayId string
param containerAppId string
param postgresId string
param appInsightsId string
@description('Offentlig FQDN for Application Gateway. Bare denne og Container App-FQDN-en regnes som støttet trafikk i gateway-alerten.')
param appGatewayFqdn string
@description('Container App-FQDN brukt av tilgjengelighetstesten gjennom Application Gateway.')
param containerAppFqdn string
@description('URL som tilgjengelighetstesten kaller. Bør sjekke databasen, slik /ready gjør.')
param availabilityUrl string
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
    severity: 3
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
    severity: 3
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
    severity: 3
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
    severity: 3
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
    // Skannere sender ofte ufullstendige forespørsler eller lukker umiddelbart. Behold 499 som varer minst ett sekund,
    // slik at ekte timeout-mønstre fra en treg avhengighet fortsatt varsles.
    description: 'Over 2 % av støttet trafikk gjennom Application Gateway feiler (5xx, eller 499 etter minst ett sekund). Baseline: 0 %.'
    severity: 1
    query: '''
AGWAccessLogs
| where Host in ('${appGatewayFqdn}', '${containerAppFqdn}')
| summarize requests = count(), errors = countif(HttpStatus >= 500 or (HttpStatus == 499 and TimeTaken >= 1))
| extend errorPct = 100.0 * errors / requests
| where requests >= 5 and errorPct > 2
'''
  }
  {
    name: 'http-latency-p95'
    // Bare requests som er rutet til backend. Skannere fra internett gir trege 400-svar som
    // gatewayen avviser selv, og som ellers dominerer p95 ved lite trafikk.
    description: 'p95-latens for requests rutet gjennom Application Gateway til appen over 300 ms. Baseline: ~26 ms.'
    severity: 2
    query: '''
AGWAccessLogs
| where isnotempty(BackendPoolName) and isnotempty(BackendSettingName)
| summarize requests = count(), p95ms = percentile(TimeTaken, 95) * 1000
| where requests >= 20 and p95ms > 300
'''
  }
  {
    name: 'app-exceptions'
    description: 'Appen kaster uhåndterte exceptions. Baseline: 0.'
    severity: 3
    query: '''
AppExceptions
| summarize exceptions = sum(ItemCount)
| where exceptions > 0
'''
  }
  {
    name: 'db-dependency-degraded'
    description: 'Databasekall feiler eller har p95 over 200 ms. Baseline: 0 feil, p95 ~6 ms.'
    severity: 3
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
    severity: 3
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

// Tilgjengelighet utenfra: kaller /ready (som sjekker databasen) fra tre regioner hvert 5. minutt.
// Fanger brudd også når det ikke kommer noen trafikk, og når requests henger i stedet for å feile.
var webTestName = 'webtest-${baseName}-ready'

resource availabilityTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: webTestName
  location: location
  // Koblingen til Application Insights kreves for at testen skal vises og rapportere dit.
  tags: union(tags, { 'hidden-link:${appInsightsId}': 'Resource' })
  kind: 'standard'
  properties: {
    SyntheticMonitorId: webTestName
    Name: '${baseName} /ready'
    Description: 'Sjekker at appen og databasen svarer via Application Gateway.'
    Enabled: true
    Frequency: 300
    Timeout: 30
    Kind: 'standard'
    RetryEnabled: true
    Locations: [
      { Id: 'emea-nl-ams-azr' }
      { Id: 'emea-gb-db3-azr' }
      { Id: 'emea-ru-msa-edge' }
    ]
    Request: {
      RequestUrl: availabilityUrl
      HttpVerb: 'GET'
      ParseDependentRequests: false
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: false
    }
  }
}

resource availabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${baseName}-availability-ready'
  location: 'global'
  tags: tags
  properties: {
    description: 'Tilgjengelighetstesten mot /ready feiler fra minst to av tre regioner. Tjenesten er nede for brukerne. Baseline: 100 % tilgjengelig.'
    severity: 1
    enabled: true
    scopes: [
      availabilityTest.id
      appInsightsId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestId: availabilityTest.id
      componentId: appInsightsId
      failedLocationCount: 2
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// Activity Log-alert når databasen stoppes. Activity Log-alerts har ingen alvorlighetsgrad og
// starter derfor ingen undersøkelse i SRE Agent, men gir årsaken som kontekst og sender e-post.
resource postgresStoppedAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-${baseName}-db-stopped'
  location: 'Global'
  tags: tags
  properties: {
    description: 'PostgreSQL-serveren er stoppet. Alle databasekall vil feile til den startes igjen.'
    enabled: true
    scopes: [
      resourceGroup().id
    ]
    condition: {
      allOf: [
        { field: 'category', equals: 'Administrative' }
        { field: 'resourceId', equals: postgresId }
        { field: 'operationName', equals: 'Microsoft.DBforPostgreSQL/flexibleServers/stop/action' }
        { field: 'status', equals: 'Succeeded' }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: actionGroup.id }
      ]
    }
  }
}

output actionGroupId string = actionGroup.id
