// Azure Local Factory - Phase 2 supporting Azure resource contract.
//
// Package 5 creates or validates only the Azure resource group.
// This template does not deploy Azure Local, create a cluster,
// register Arc, deploy a resource bridge, or modify an HCN.

targetScope = 'subscription'

@description('Approved Azure resource group for the future Azure Local cluster deployment.')
param resourceGroupName string

@description('Approved Azure Government deployment location.')
param location string = 'usgovvirginia'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
}

output resourceGroupId string = resourceGroup.id
output resourceGroupName string = resourceGroup.name
output resourceGroupLocation string = resourceGroup.location
