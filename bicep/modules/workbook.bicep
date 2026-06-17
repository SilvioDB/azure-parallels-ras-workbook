// Azure Workbook resource. Content (serializedData) is loaded from the JSON file
// generated from the original mockup.

@description('Region.')
param location string

@description('Nome visualizzato del Workbook.')
param displayName string = 'Parallels RAS - Infrastructure Overview'

@description('Resource ID del Log Analytics workspace (sourceId del workbook).')
param workspaceResourceId string

@description('GUID deterministico per il nome risorsa del workbook.')
param workbookGuid string

// Carica il JSON del workbook come stringa.
var serialized = loadTextContent('../../workbook/ras-overview.workbook.json')

resource wb 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookGuid
  location: location
  kind: 'shared'
  properties: {
    displayName: displayName
    category: 'workbook'
    sourceId: workspaceResourceId
    version: 'Notebook/1.0'
    serializedData: serialized
  }
}

output workbookId string = wb.id
