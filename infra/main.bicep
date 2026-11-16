// Subscription-scope entry point: resource group, cost guardrail, then the lab resources.
targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'eastus2'

@description('Resource group that holds everything in the lab. Delete it to tear the lab down.')
param resourceGroupName string = 'rg-medallion-lab'

@description('Short lowercase prefix used in resource names (letters and numbers only).')
@minLength(3)
@maxLength(8)
param prefix string = 'medlab'

@description('Public IPv4 address allowed through the Synapse workspace firewall.')
param clientIp string

@description('Entra object ID of the person who gets data-plane access and SQL admin rights.')
param userObjectId string

@secure()
@description('SQL admin password. Generated at deploy time and never stored; Entra-only auth is enforced.')
param sqlAdminPassword string

@description('Create a small, auto-pausing Spark pool. Off by default because it bills per minute while running.')
param deploySparkPool bool = false

@description('Create a monthly cost budget on the subscription that alerts subscription Owners.')
param deployBudget bool = true

@description('Monthly budget amount in the subscription currency.')
param budgetAmount int = 10

@description('First day of the current month; budgets must start on the first of a month.')
param budgetStartDate string = utcNow('yyyy-MM-01')

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    project: 'medallion-synapse-lab'
  }
}

resource budget 'Microsoft.Consumption/budgets@2023-05-01' = if (deployBudget) {
  name: 'budget-medallion-lab'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    notifications: {
      actual50: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [] // alerts go to subscription Owners; no address in source
        contactRoles: [ 'Owner' ]
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: []
        contactRoles: [ 'Owner' ]
      }
    }
  }
}

module lakehouse 'modules/lakehouse.bicep' = {
  scope: rg
  name: 'lakehouse'
  params: {
    location: location
    prefix: prefix
    clientIp: clientIp
    userObjectId: userObjectId
    sqlAdminPassword: sqlAdminPassword
    deploySparkPool: deploySparkPool
  }
}

output resourceGroup string = rg.name
output storageAccountName string = lakehouse.outputs.storageAccountName
output lakeUrl string = lakehouse.outputs.lakeUrl
output workspaceName string = lakehouse.outputs.workspaceName
output serverlessSqlEndpoint string = lakehouse.outputs.serverlessSqlEndpoint
output studioUrl string = lakehouse.outputs.studioUrl
