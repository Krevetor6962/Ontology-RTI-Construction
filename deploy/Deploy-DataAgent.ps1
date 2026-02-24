<#
.SYNOPSIS
    Deploy a Fabric Data Agent for the Oil & Gas Refinery Ontology.
.DESCRIPTION
    Creates a Data Agent in Microsoft Fabric and configures it with:
      - Data sources: Lakehouse (SQL endpoint), KQL Database, Semantic Model
      - Custom instructions for Oil & Gas refinery operations
    
    PREREQUISITES:
      - Workspace must be on a Fabric capacity F64 or higher (Trial/FTL64 NOT supported).
      - The "Data Agent" tenant setting must be enabled by the Fabric admin.
.PARAMETER WorkspaceId
    The Fabric workspace GUID.
.PARAMETER LakehouseSqlEndpointId
    The SQL Endpoint GUID for the Lakehouse.
.PARAMETER KqlDatabaseId
    The KQL Database GUID.
.PARAMETER SemanticModelId
    The Semantic Model GUID.
.PARAMETER AgentName
    Display name for the Data Agent (default: OilGasRefineryAgent).
#>
param(
    [Parameter(Mandatory=$true)]  [string]$WorkspaceId,
    [Parameter(Mandatory=$false)] [string]$LakehouseSqlEndpointId = "c66c4397-48cd-452f-9a65-0a1eda8ee927",
    [Parameter(Mandatory=$false)] [string]$KqlDatabaseId          = "734b6c9e-a93f-4992-b709-2ae257a1df5f",
    [Parameter(Mandatory=$false)] [string]$SemanticModelId        = "00a734ac-fbca-4297-959e-81afcbfa7135",
    [Parameter(Mandatory=$false)] [string]$AgentName              = "OilGasRefineryAgent"
)

# ── Authentication ──────────────────────────────────────────────────────────
$token = (Get-AzAccessToken -ResourceUrl "https://api.fabric.microsoft.com").Token
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

Write-Host "=== Deploying Data Agent: $AgentName ===" -ForegroundColor Cyan

# ── Step 1: Create the Data Agent ──────────────────────────────────────────
$createBody = @{
    displayName = $AgentName
    description = "AI Data Agent for Oil & Gas Refinery operations. Answers questions about production, equipment, sensors, maintenance, safety, and environmental data."
} | ConvertTo-Json -Depth 5

Write-Host "Creating Data Agent..." -ForegroundColor Yellow
$agentId = $null
try {
    $response = Invoke-WebRequest `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/dataAgents" `
        -Method POST -Headers $headers -Body $createBody -UseBasicParsing

    if ($response.StatusCode -eq 201) {
        $agent = $response.Content | ConvertFrom-Json
        $agentId = $agent.id
        Write-Host "[OK] Data Agent created: $agentId" -ForegroundColor Green
    }
    elseif ($response.StatusCode -eq 202) {
        $opUrl = $response.Headers['Location']
        Write-Host "LRO started, polling..." -ForegroundColor Yellow
        do {
            Start-Sleep -Seconds 3
            $poll = Invoke-RestMethod -Uri $opUrl -Headers $headers
            Write-Host "  Status: $($poll.status)"
        } while ($poll.status -notin @('Succeeded','Failed','Cancelled'))

        if ($poll.status -eq 'Succeeded') {
            # Retrieve the created item
            $resultUrl = $opUrl -replace '/operations/.*', "/result"
            try {
                $agentResult = Invoke-RestMethod -Uri $resultUrl -Headers $headers
                $agentId = $agentResult.id
            } catch {
                # Fallback: list items to find it
                $allItems = (Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items" -Headers $headers).value
                $agentItem = $allItems | Where-Object { $_.displayName -eq $AgentName -and $_.type -eq 'DataAgent' }
                $agentId = $agentItem.id
            }
            Write-Host "[OK] Data Agent created: $agentId" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Data Agent creation $($poll.status)" -ForegroundColor Red
            exit 1
        }
    }
}
catch {
    $sr = $_.Exception.Response
    if ($sr) {
        $stream = $sr.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $errBody = $reader.ReadToEnd()
        Write-Host "[ERROR] $([int]$sr.StatusCode): $errBody" -ForegroundColor Red

        if ($errBody -match 'UnsupportedCapacitySKU') {
            Write-Host ""
            Write-Host ">>> Data Agents require Fabric capacity F64 or higher." -ForegroundColor Magenta
            Write-Host ">>> Current workspace is on Trial (FTL64) which is not supported." -ForegroundColor Magenta
            Write-Host ">>> Move the workspace to an F64+ capacity and re-run this script." -ForegroundColor Magenta
        }
        elseif ($errBody -match 'FeatureNotAvailable') {
            Write-Host ""
            Write-Host ">>> The 'Data Agent' tenant setting must be enabled by your Fabric admin." -ForegroundColor Magenta
        }
    }
    else {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}

if (-not $agentId) {
    Write-Host "[ERROR] Could not retrieve Data Agent ID." -ForegroundColor Red
    exit 1
}

# ── Step 2: Update Data Agent Definition ───────────────────────────────────
# The definition configures data sources and custom instructions.
Write-Host "Configuring Data Agent definition..." -ForegroundColor Yellow

$agentDefinition = @{
    instructions = @"
You are an expert AI assistant for an Oil & Gas Refinery. You help operators, engineers, and managers analyze refinery data including:

**Data Available:**
- **Lakehouse (SQL)**: Contains 13 dimension and fact tables covering Wells, Pipelines, Refineries, Storage Tanks, Equipment, Products, Employees, Environmental Monitoring, Safety Incidents, Production data, and Inspections.
- **KQL Database (Real-Time)**: Contains 5 streaming tables — SensorReading, SensorAlert, EquipmentMaintenance, ProcessUnitStatus, and ProductionMetric — with real-time telemetry from refinery equipment.
- **Semantic Model**: OilGasRefinerySM — a Direct Lake semantic model with all 13 tables for analytical queries.

**Key Entity Relationships:**
- Wells → Pipelines → Refineries → Storage Tanks
- Equipment belongs to Refineries; Employees work at Refineries
- Environmental Monitoring and Safety Incidents are linked to Refineries
- Inspections reference Equipment
- Production records link Products to Refineries

**Guidelines:**
1. For real-time sensor data, equipment alerts, and maintenance queries, use the KQL Database.
2. For historical production, safety, environmental, and asset queries, use the Lakehouse SQL endpoint.
3. For aggregated business metrics and cross-domain analysis, use the Semantic Model.
4. Always provide units of measurement when reporting sensor values.
5. Flag any anomalous readings (values outside LowerThreshold/UpperThreshold).
6. Prioritize safety-related queries and highlight critical alerts.
7. When asked about maintenance, include cost impact and downtime estimates.
8. Support both natural language and technical KQL/SQL queries.
"@
    dataSources = @(
        @{
            type        = "sqlEndpoint"
            displayName = "OilGasRefineryLH (SQL)"
            itemId      = $LakehouseSqlEndpointId
            workspaceId = $WorkspaceId
        },
        @{
            type        = "kqlDatabase"
            displayName = "RefineryTelemetryEH (KQL)"
            itemId      = $KqlDatabaseId
            workspaceId = $WorkspaceId
        },
        @{
            type        = "semanticModel"
            displayName = "OilGasRefinerySM"
            itemId      = $SemanticModelId
            workspaceId = $WorkspaceId
        }
    )
}

$defJson = $agentDefinition | ConvertTo-Json -Depth 10 -Compress
$defB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($defJson))

$updateBody = @{
    definition = @{
        parts = @(
            @{
                path        = "dataAgent.json"
                payload     = $defB64
                payloadType = "InlineBase64"
            }
        )
    }
} | ConvertTo-Json -Depth 10

try {
    $updateResponse = Invoke-WebRequest `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/dataAgents/$agentId/updateDefinition" `
        -Method POST -Headers $headers -Body $updateBody -UseBasicParsing

    if ($updateResponse.StatusCode -in @(200,202)) {
        Write-Host "[OK] Data Agent definition updated." -ForegroundColor Green

        if ($updateResponse.StatusCode -eq 202) {
            $opUrl2 = $updateResponse.Headers['Location']
            Write-Host "  Definition update LRO started, polling..." -ForegroundColor Yellow
            do {
                Start-Sleep -Seconds 3
                $poll2 = Invoke-RestMethod -Uri $opUrl2 -Headers $headers
                Write-Host "  Status: $($poll2.status)"
            } while ($poll2.status -notin @('Succeeded','Failed','Cancelled'))
        }
    }
}
catch {
    $sr2 = $_.Exception.Response
    if ($sr2) {
        $s2 = $sr2.GetResponseStream()
        $rd2 = New-Object System.IO.StreamReader($s2)
        Write-Host "[WARN] Definition update: $([int]$sr2.StatusCode): $($rd2.ReadToEnd())" -ForegroundColor Yellow
        Write-Host "  The Data Agent was created but may need manual configuration in the UI." -ForegroundColor Yellow
    }
    else {
        Write-Host "[WARN] Definition update: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Data Agent Deployment Summary ===" -ForegroundColor Cyan
Write-Host "  Name:       $AgentName"
Write-Host "  Agent ID:   $agentId"
Write-Host "  Workspace:  $WorkspaceId"
Write-Host ""
Write-Host "Data Sources configured:" -ForegroundColor White
Write-Host "  1. OilGasRefineryLH (SQL Endpoint) - 13 tables"
Write-Host "  2. RefineryTelemetryEH (KQL Database) - 5 streaming tables"
Write-Host "  3. OilGasRefinerySM (Semantic Model) - Direct Lake"
Write-Host ""
Write-Host "Open the Data Agent in Fabric to test with questions like:" -ForegroundColor White
Write-Host '  - "What are the current sensor readings for Refinery R001?"'
Write-Host '  - "Show me active critical alerts"'
Write-Host '  - "What was the total production output last month?"'
Write-Host '  - "Which equipment has the highest maintenance cost?"'
Write-Host '  - "Are there any environmental compliance issues?"'
Write-Host ""
Write-Host "=== Data Agent Deployment Complete ===" -ForegroundColor Cyan
