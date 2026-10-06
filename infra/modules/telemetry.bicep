// Capability "telemetry": Log Analytics plus workspace-based Application Insights. The apps of the environment (container
// apps and App Service alike) get APPLICATIONINSIGHTS_CONNECTION_STRING, and their OpenTelemetry SDK exports traces, logs
// and metrics to it with the Azure Monitor exporter; OTEL_SERVICE_NAME (<slug>-<deployable>) names each app's role.
// Turn it on by adding "telemetry" to the environment's capabilities in system.json.
targetScope = 'resourceGroup'

param slug string
param environmentName string
param location string
param tags object

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${slug}-${environmentName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: 1
    }
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${slug}-${environmentName}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

output connectionString string = insights.properties.ConnectionString
