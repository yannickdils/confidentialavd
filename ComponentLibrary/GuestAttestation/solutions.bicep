// ---------------------------------------------------------------------------
// Log Analytics Solutions for Confidential AVD monitoring
//
// Installs the solutions that create the solution-managed tables required
// by the CVM Data Collection Rule (main.bicep):
//   Security          -> SecurityEvent table
//   SecurityInsights  -> WindowsEvent table  (Microsoft Sentinel)
//
// These tables CANNOT be created via the tables REST API; they are
// provisioned automatically when their parent solution is installed.
// Deployment is idempotent -- re-deploying is a no-op if already installed.
// ---------------------------------------------------------------------------

@description('Name of the Log Analytics Workspace (not resource ID).')
param workspaceName string

@description('Resource ID of the Log Analytics Workspace.')
param workspaceResourceId string

@description('Azure region for the solutions.')
param location string = resourceGroup().location

@description('Tags to apply to all resources.')
param tags object

// ---------------------------------------------------------------------------
// Security solution  ->  SecurityEvent table
// ---------------------------------------------------------------------------
resource securitySolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'Security(${workspaceName})'
  location: location
  tags: tags
  plan: {
    name: 'Security(${workspaceName})'
    publisher: 'Microsoft'
    product: 'OMSGallery/Security'
    promotionCode: ''
  }
  properties: {
    workspaceResourceId: workspaceResourceId
  }
}

// ---------------------------------------------------------------------------
// SecurityInsights (Microsoft Sentinel)  ->  WindowsEvent table
// ---------------------------------------------------------------------------
resource sentinelSolution 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'SecurityInsights(${workspaceName})'
  location: location
  tags: tags
  plan: {
    name: 'SecurityInsights(${workspaceName})'
    publisher: 'Microsoft'
    product: 'OMSGallery/SecurityInsights'
    promotionCode: ''
  }
  properties: {
    workspaceResourceId: workspaceResourceId
  }
}
