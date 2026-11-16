// Resource-group-scope lab resources: ADLS Gen2 storage, Synapse workspace (serverless SQL),
// firewall rule, data-plane role assignments, and an optional Spark pool.

param location string
param prefix string
param clientIp string
param userObjectId string

@secure()
param sqlAdminPassword string

param deploySparkPool bool

var suffix = take(uniqueString(resourceGroup().id), 8)
var storageAccountName = toLower('${prefix}${suffix}')
var workspaceName = toLower('syn-${prefix}-${suffix}')

// Built-in role: Storage Blob Data Contributor
var blobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true // ADLS Gen2 hierarchical namespace, required for abfss:// paths
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

// Data container for landing/, bronze/, silver/, gold/ folders.
resource lakeContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'lake'
  properties: {
    publicAccess: 'None'
  }
}

// Workspace system filesystem, kept separate from the data.
resource synapseContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'synapse'
  properties: {
    publicAccess: 'None'
  }
}

resource workspace 'Microsoft.Synapse/workspaces@2021-06-01' = {
  name: workspaceName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    defaultDataLakeStorage: {
      accountUrl: storage.properties.primaryEndpoints.dfs
      filesystem: synapseContainer.name
      resourceId: storage.id
      createManagedPrivateEndpoint: false
    }
    sqlAdministratorLogin: 'sqladminuser'
    sqlAdministratorLoginPassword: sqlAdminPassword
    publicNetworkAccess: 'Enabled'
  }
}

resource firewallClient 'Microsoft.Synapse/workspaces/firewallRules@2021-06-01' = {
  parent: workspace
  name: 'AllowClientIp'
  properties: {
    startIpAddress: clientIp
    endIpAddress: clientIp
  }
}

// Make the person running the lab the Entra SQL admin for serverless SQL.
resource entraAdmin 'Microsoft.Synapse/workspaces/administrators@2021-06-01' = {
  parent: workspace
  name: 'activeDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: 'lab-admin'
    sid: userObjectId
    tenantId: subscription().tenantId
  }
}

// Disable SQL password logins once an Entra admin exists.
resource entraOnly 'Microsoft.Synapse/workspaces/azureADOnlyAuthentications@2021-06-01' = {
  parent: workspace
  name: 'default'
  properties: {
    azureADOnlyAuthentication: true
  }
  dependsOn: [
    entraAdmin
  ]
}

// Serverless SQL and Spark read storage as the caller (user) or the workspace identity,
// so both need data-plane access. Missing this is the usual cause of 403s on OPENROWSET.
resource workspaceBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, workspace.id, blobDataContributorRoleId)
  properties: {
    roleDefinitionId: blobDataContributorRoleId
    principalId: workspace.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource userBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, userObjectId, blobDataContributorRoleId)
  properties: {
    roleDefinitionId: blobDataContributorRoleId
    principalId: userObjectId
    principalType: 'User'
  }
}

resource sparkPool 'Microsoft.Synapse/workspaces/bigDataPools@2021-06-01' = if (deploySparkPool) {
  parent: workspace
  name: 'sparksmall'
  location: location
  properties: {
    sparkVersion: '3.4'
    nodeSizeFamily: 'MemoryOptimized'
    nodeSize: 'Small'
    nodeCount: 3
    autoScale: {
      enabled: false
    }
    autoPause: {
      enabled: true
      delayInMinutes: 5
    }
    dynamicExecutorAllocation: {
      enabled: false
    }
  }
}

output storageAccountName string = storage.name
output lakeUrl string = 'abfss://${lakeContainer.name}@${storage.name}.dfs.${environment().suffixes.storage}/'
output workspaceName string = workspace.name
output serverlessSqlEndpoint string = workspace.properties.connectivityEndpoints.sqlOnDemand
output studioUrl string = workspace.properties.connectivityEndpoints.web
