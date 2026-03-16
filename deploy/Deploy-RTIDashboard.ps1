<#
.SYNOPSIS
    Deploy a Real-Time Intelligence (KQL) Dashboard for Construction Building Site telemetry.
.DESCRIPTION
    Creates a KQLDashboard in Microsoft Fabric connected to the Eventhouse KQL database,
    with 12 pre-built tiles covering:
      1. Sensor Readings by Zone (line chart)
      2. Safety Incidents by Severity (pie chart)
      3. Incident Trend Over Time (line chart)
      4. Live Site Asset Map (map)
      5. Top Sensors by Alert Count (table)
      6. Dust & Noise Compliance (table)
      7. Material Deliveries Today (table)
      8. Work Progress per Zone (bar chart)
      9. Unacknowledged Safety Alerts (table)
     10. Asset Utilization Rate (bar chart)
     11. Overdue Inspections (table)
     12. Worker Activity on Site (stat card)

    Uses the Fabric REST API for KQLDashboard items with the standard
    RealTimeDashboard.json definition (schema version 20).

    PREREQUISITE: The tenant setting "Create Real-Time dashboards" must be
    enabled by the Fabric admin in the Admin Portal > Tenant settings.

.PARAMETER WorkspaceId
    The Fabric workspace GUID.
.PARAMETER KqlDatabaseId
    The KQL Database GUID (auto-detected if omitted).
.PARAMETER QueryServiceUri
    The Kusto query service URI (auto-detected from Eventhouse if omitted).
.PARAMETER DashboardName
    Display name for the dashboard (default: ConstructionSiteDashboard).
#>
param(
    [Parameter(Mandatory=$true)]  [string]$WorkspaceId,
    [Parameter(Mandatory=$false)] [string]$KqlDatabaseId,
    [Parameter(Mandatory=$false)] [string]$QueryServiceUri,
    [Parameter(Mandatory=$false)] [string]$DashboardName = "ConstructionSiteDashboard"
)

# ── Authentication ──────────────────────────────────────────────────────────
$token = (Get-AzAccessToken -ResourceUrl "https://api.fabric.microsoft.com").Token
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}
$apiBase = "https://api.fabric.microsoft.com/v1"

Write-Host "=== Deploying KQL Dashboard: $DashboardName ===" -ForegroundColor Cyan

# ── Auto-detect KQL Database and Eventhouse if not provided ─────────────────
if (-not $KqlDatabaseId -or -not $QueryServiceUri) {
    Write-Host "Auto-detecting KQL Database from workspace..." -ForegroundColor Yellow
    $allItems = (Invoke-RestMethod -Uri "$apiBase/workspaces/$WorkspaceId/items" -Headers $headers).value

    if (-not $KqlDatabaseId) {
        $kqlDb = $allItems | Where-Object { $_.type -eq 'KQLDatabase' } | Select-Object -First 1
        if ($kqlDb) {
            $KqlDatabaseId = $kqlDb.id
            Write-Host "  Found KQL Database: $($kqlDb.displayName) ($KqlDatabaseId)" -ForegroundColor Gray
        } else {
            Write-Host "[ERROR] No KQL Database found in workspace." -ForegroundColor Red
            exit 1
        }
    }

    if (-not $QueryServiceUri) {
        $eh = $allItems | Where-Object { $_.type -eq 'Eventhouse' } | Select-Object -First 1
        if ($eh) {
            $ehDetails = Invoke-RestMethod -Uri "$apiBase/workspaces/$WorkspaceId/eventhouses/$($eh.id)" -Headers $headers
            $QueryServiceUri = $ehDetails.properties.queryServiceUri
            Write-Host "  Query URI: $QueryServiceUri" -ForegroundColor Gray
        } else {
            Write-Host "[ERROR] No Eventhouse found. Please provide -QueryServiceUri." -ForegroundColor Red
            exit 1
        }
    }
}

# ── Get KQL Database name ──────────────────────────────────────────────────
$kqlDbDetails = Invoke-RestMethod -Uri "$apiBase/workspaces/$WorkspaceId/kqlDatabases/$KqlDatabaseId" -Headers $headers
$kqlDbName = $kqlDbDetails.displayName
Write-Host "  KQL Database: $kqlDbName" -ForegroundColor Gray

# ── Build Dashboard Definition ──────────────────────────────────────────────
# Schema: https://dataexplorer.azure.com/static/d/schema/20/dashboard.json
# Tiles are top-level, each references a pageId and dataSourceId.

$dataSourceId = [guid]::NewGuid().ToString()
$pageId       = [guid]::NewGuid().ToString()

# Helper to create visual options with inference
function New-VisualOptions {
    return @{
        xColumn             = @{ type = "infer" }
        yColumns            = @{ type = "infer" }
        yAxisMinimumValue   = @{ type = "infer" }
        yAxisMaximumValue   = @{ type = "infer" }
        seriesColumns       = @{ type = "infer" }
        hideLegend          = $false
        xColumnTitle        = ""
        yColumnTitle        = ""
        horizontalLine      = ""
        verticalLine        = ""
        xAxisScale          = "linear"
        yAxisScale          = "linear"
        crossFilterDisabled = $false
        hideTileTitle       = $false
        multipleYAxes       = @{
            base       = @{ id = "-1"; columns = @(); label = ""; yAxisMinimumValue = $null; yAxisMaximumValue = $null; yAxisScale = "linear"; horizontalLines = @() }
            additional = @()
        }
    }
}

$tiles = @(
    # ── Tile 1: Sensor Readings by Zone (line chart) ────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Sensor Readings by Zone"
        query         = @"
SiteSensorReading
| summarize AvgValue = avg(Value) by bin(Timestamp, 15m), ZoneId
| order by Timestamp asc
"@
        layout        = @{ x = 0; y = 0; width = 12; height = 6 }
        pageId        = $pageId
        visualType    = "line"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 2: Safety Incidents by Severity (pie) ──────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Safety Incidents by Severity"
        query         = @"
SafetyIncidentLog
| summarize Count = count() by Severity
| order by Count desc
"@
        layout        = @{ x = 12; y = 0; width = 6; height = 6 }
        pageId        = $pageId
        visualType    = "pie"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 3: Incident Trend Over Time (line) ────────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Incident Trend Over Time"
        query         = @"
SafetyIncidentLog
| summarize IncidentCount = count() by bin(Timestamp, 1h), Severity
| order by Timestamp asc
"@
        layout        = @{ x = 18; y = 0; width = 6; height = 6 }
        pageId        = $pageId
        visualType    = "line"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 4: Live Site Asset Map ─────────────────────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Live Site Asset Map"
        query         = @"
AssetStatusStream
| summarize arg_max(Timestamp, *) by AssetId
| project AssetId, Timestamp, Status, LocationLat, LocationLon, OperatorId, FuelLevel
"@
        layout        = @{ x = 0; y = 6; width = 8; height = 6 }
        pageId        = $pageId
        visualType    = "map"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 5: Top Sensors by Alert Count (table) ─────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Top Sensors by Alert Count"
        query         = @"
SiteSensorReading
| summarize Readings = count(),
            AvgValue = round(avg(Value), 2),
            MinValue = round(min(Value), 2),
            MaxValue = round(max(Value), 2)
        by SensorId, ReadingType, Unit
| top 20 by Readings desc
"@
        layout        = @{ x = 8; y = 6; width = 8; height = 6 }
        pageId        = $pageId
        visualType    = "table"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 6: Dust & Noise Compliance (table) ────────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Dust & Noise Compliance"
        query         = @"
SiteSensorReading
| where ReadingType in ("dust", "noise")
| summarize AvgValue = round(avg(Value), 2),
            MaxValue = round(max(Value), 2),
            Readings = count()
        by ZoneId, ReadingType, Unit
| order by MaxValue desc
"@
        layout        = @{ x = 16; y = 6; width = 8; height = 6 }
        pageId        = $pageId
        visualType    = "table"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 7: Material Deliveries Today (table) ──────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Material Deliveries Today"
        query         = @"
MaterialDeliveryEvent
| where Timestamp >= startofday(now())
| project Timestamp, DeliveryId, MaterialId, Quantity, SupplierId, ZoneId, ReceivedBy
| order by Timestamp desc
"@
        layout        = @{ x = 0; y = 12; width = 8; height = 5 }
        pageId        = $pageId
        visualType    = "table"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 8: Work Progress per Zone (bar chart) ─────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Work Progress per Zone"
        query         = @"
WorkProgressMetric
| summarize arg_max(Timestamp, *) by ZoneId, TaskName
| project ZoneId, TaskName, ProgressPercent, WorkerId, Notes
| order by ZoneId asc
"@
        layout        = @{ x = 8; y = 12; width = 8; height = 5 }
        pageId        = $pageId
        visualType    = "bar"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 9: Unacknowledged Safety Alerts (table) ───────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Unacknowledged Safety Alerts"
        query         = @"
SafetyIncidentLog
| where Status == "Open"
| project Timestamp, IncidentId, IncidentType, Severity, ZoneId, WorkerId, Description
| order by Timestamp desc
| take 50
"@
        layout        = @{ x = 16; y = 12; width = 8; height = 5 }
        pageId        = $pageId
        visualType    = "table"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 10: Asset Utilization Rate (bar chart) ────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Asset Utilization Rate"
        query         = @"
AssetStatusStream
| summarize TotalReadings = count(),
            OperatingReadings = countif(Status == "Operating")
        by AssetId
| extend UtilizationPct = round(100.0 * OperatingReadings / TotalReadings, 1)
| project AssetId, UtilizationPct, OperatingReadings, TotalReadings
| order by UtilizationPct desc
"@
        layout        = @{ x = 0; y = 17; width = 8; height = 5 }
        pageId        = $pageId
        visualType    = "bar"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 11: Overdue Inspections (table) ───────────────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Overdue Inspections"
        query         = @"
FactInspectionEvent
| where NextDueDate < now()
| project InspectionId, AssetId, InspectorId, InspectionDate, NextDueDate, Result, Notes
| order by NextDueDate asc
| take 50
"@
        layout        = @{ x = 8; y = 17; width = 8; height = 5 }
        pageId        = $pageId
        visualType    = "table"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    },

    # ── Tile 12: Worker Activity on Site (stat card) ───────────────────
    @{
        id            = [guid]::NewGuid().ToString()
        title         = "Worker Activity on Site"
        query         = @"
AssetStatusStream
| where Timestamp >= ago(24h)
| summarize ActiveWorkers = dcount(OperatorId)
"@
        layout        = @{ x = 16; y = 17; width = 8; height = 5 }
        pageId        = $pageId
        visualType    = "stat"
        dataSourceId  = $dataSourceId
        visualOptions = New-VisualOptions
        usedParamVariables = @()
    }
)

# ── Assemble full dashboard definition ──────────────────────────────────────
$dashboardDef = @{
    '$schema'      = "https://dataexplorer.azure.com/static/d/schema/20/dashboard.json"
    schema_version = "20"
    title          = $DashboardName
    autoRefresh    = @{
        enabled         = $true
        defaultInterval = "30s"
        minInterval     = "30s"
    }
    dataSources    = @(
        @{
            id         = $dataSourceId
            name       = $kqlDbName
            clusterUri = $QueryServiceUri
            database   = $kqlDbName
            kind       = "manual-kusto"
            scopeId    = "KustoDatabaseResource"
        }
    )
    pages      = @(
        @{
            id   = $pageId
            name = "Construction Site Overview"
        }
    )
    tiles      = $tiles
    parameters = @()
}

# Serialize to JSON
$dashJson = $dashboardDef | ConvertTo-Json -Depth 15 -Compress
$dashJsonB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($dashJson))

# ── Step A: Create KQLDashboard item ────────────────────────────────────────
Write-Host "Creating KQL Dashboard (type=KQLDashboard)..." -ForegroundColor Yellow

$createBody = @{
    displayName = $DashboardName
    type        = "KQLDashboard"
    description = "Real-Time Intelligence dashboard for Construction Building Site sensor telemetry, safety incidents, asset tracking, and work progress monitoring"
} | ConvertTo-Json -Depth 5

$dashboardId = $null
try {
    $response = Invoke-WebRequest `
        -Uri "$apiBase/workspaces/$WorkspaceId/items" `
        -Method POST -Headers $headers -Body $createBody -UseBasicParsing

    if ($response.StatusCode -eq 201) {
        $dash = $response.Content | ConvertFrom-Json
        $dashboardId = $dash.id
        Write-Host "[OK] KQL Dashboard created: $dashboardId" -ForegroundColor Green
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
            $allItems = (Invoke-RestMethod -Uri "$apiBase/workspaces/$WorkspaceId/items" -Headers $headers).value
            $dashItem = $allItems | Where-Object { $_.displayName -eq $DashboardName -and $_.type -eq 'KQLDashboard' }
            if ($dashItem) { $dashboardId = $dashItem.id }
            Write-Host "[OK] KQL Dashboard created: $dashboardId" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Dashboard creation: $($poll.status)" -ForegroundColor Red
        }
    }
}
catch {
    $sr = $_.Exception.Response
    if ($sr) {
        $stream = $sr.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $errorBody = $reader.ReadToEnd()
        Write-Host "[ERROR] $([int]$sr.StatusCode): $errorBody" -ForegroundColor Red

        if ($errorBody -match 'FeatureNotAvailable') {
            Write-Host ""
            Write-Host ">>> BLOCKED: The 'Create Real-Time dashboards' tenant setting is disabled." -ForegroundColor Magenta
            Write-Host ">>> Ask your Fabric admin to enable it in:" -ForegroundColor Magenta
            Write-Host ">>>   Admin Portal > Tenant settings > Real-Time Intelligence" -ForegroundColor Magenta
            Write-Host ">>>   Setting: 'Create Real-Time Dashboards (preview)'" -ForegroundColor Magenta
        }
        elseif ($errorBody -match 'ItemDisplayNameAlreadyInUse') {
            Write-Host "  Dashboard '$DashboardName' already exists. Will update definition..." -ForegroundColor Yellow
            $allItems = (Invoke-RestMethod -Uri "$apiBase/workspaces/$WorkspaceId/items" -Headers $headers).value
            $existing = $allItems | Where-Object { $_.displayName -eq $DashboardName -and $_.type -eq 'KQLDashboard' }
            if ($existing) {
                $dashboardId = $existing.id
                Write-Host "  Existing Dashboard ID: $dashboardId" -ForegroundColor Gray
            }
        }
    }
    else {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Step B: Upload dashboard definition ─────────────────────────────────────
if ($dashboardId) {
    Write-Host "Uploading dashboard definition ($($tiles.Count) tiles, data source: $kqlDbName)..." -ForegroundColor Yellow

    $updateBody = @{
        definition = @{
            parts = @(
                @{
                    path        = "RealTimeDashboard.json"
                    payload     = $dashJsonB64
                    payloadType = "InlineBase64"
                }
            )
        }
    } | ConvertTo-Json -Depth 10

    # Try type-specific endpoint first, then generic fallback
    $defApplied = $false
    foreach ($endpoint in @("$apiBase/workspaces/$WorkspaceId/kqlDashboards/$dashboardId/updateDefinition",
                            "$apiBase/workspaces/$WorkspaceId/items/$dashboardId/updateDefinition")) {
        if ($defApplied) { break }
        try {
            $updResp = Invoke-WebRequest -Uri $endpoint -Method POST -Headers $headers -Body $updateBody -UseBasicParsing

            if ($updResp.StatusCode -in @(200,202)) {
                if ($updResp.StatusCode -eq 202) {
                    $opUrl2 = $updResp.Headers['Location']
                    do {
                        Start-Sleep -Seconds 3
                        $poll2 = Invoke-RestMethod -Uri $opUrl2 -Headers $headers
                        Write-Host "  Definition update: $($poll2.status)"
                    } while ($poll2.status -notin @('Succeeded','Failed','Cancelled'))

                    if ($poll2.status -eq 'Succeeded') {
                        $defApplied = $true
                        Write-Host "[OK] Dashboard definition applied with $($tiles.Count) tiles." -ForegroundColor Green
                    } else {
                        Write-Host "[WARN] Definition update: $($poll2.status)" -ForegroundColor Yellow
                    }
                } else {
                    $defApplied = $true
                    Write-Host "[OK] Dashboard definition applied with $($tiles.Count) tiles." -ForegroundColor Green
                }
            }
        }
        catch {
            # Try next endpoint
        }
    }

    if (-not $defApplied) {
        Write-Host "[WARN] Definition update failed. Configure tiles manually in the UI." -ForegroundColor Yellow
        Write-Host "  Data source: $kqlDbName at $QueryServiceUri" -ForegroundColor Gray
    }
}
else {
    Write-Host ""
    Write-Host "[INFO] Dashboard item could not be created." -ForegroundColor Yellow
    Write-Host "  Once the tenant setting is enabled, re-run this script." -ForegroundColor Yellow
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== KQL Dashboard Deployment Summary ===" -ForegroundColor Cyan
Write-Host "  Name:           $DashboardName"
Write-Host "  Dashboard ID:   $dashboardId"
Write-Host "  KQL Database:   $kqlDbName ($KqlDatabaseId)"
Write-Host "  Query URI:      $QueryServiceUri"
Write-Host "  Tiles:          $($tiles.Count)"
Write-Host ""
Write-Host "Dashboard tiles:" -ForegroundColor White
foreach ($t in $tiles) {
    Write-Host "  - $($t.title) [$($t.visualType)]"
}
Write-Host ""
Write-Host "KQL Tables used:" -ForegroundColor White
Write-Host "  - SiteSensorReading      (SensorId, Timestamp, ReadingType, Value, Unit, ZoneId, Quality)"
Write-Host "  - SafetyIncidentLog      (IncidentId, Timestamp, IncidentType, Severity, ZoneId, WorkerId, Status, Description)"
Write-Host "  - AssetStatusStream      (AssetId, Timestamp, Status, LocationLat, LocationLon, OperatorId, FuelLevel)"
Write-Host "  - MaterialDeliveryEvent  (DeliveryId, Timestamp, MaterialId, Quantity, SupplierId, ZoneId, ReceivedBy)"
Write-Host "  - WorkProgressMetric     (ZoneId, Timestamp, TaskName, ProgressPercent, WorkerId, Notes)"
Write-Host "  - FactInspectionEvent    (Lakehouse table for Overdue Inspections tile)"
Write-Host ""
Write-Host "Open the dashboard in Fabric to view live data." -ForegroundColor White
Write-Host "=== KQL Dashboard Deployment Complete ===" -ForegroundColor Cyan
