<#
.SYNOPSIS
    Create KQL tables and ingest data into the Eventhouse KQL database.
.DESCRIPTION
    Creates 5 KQL tables for the RTI Dashboard and ingests:
      - SiteTelemetry.csv enriched into SiteSensorReading (joined with DimIoTSensor)
      - Sample SafetyIncidentLog, AssetStatusStream, MaterialDeliveryEvent, WorkProgressMetric data

    Uses the Kusto REST Management API (.create table, .ingest inline).

.PARAMETER WorkspaceId
    The Fabric workspace GUID.
.PARAMETER EventhouseId
    The Eventhouse GUID (auto-detected if omitted).
.PARAMETER KqlDatabaseId
    The KQL Database GUID (auto-detected if omitted).
.PARAMETER QueryServiceUri
    The Kusto query service URI (auto-detected from Eventhouse if omitted).
.PARAMETER DataFolder
    Path to the data/ folder containing CSV files.
#>
param(
    [Parameter(Mandatory=$true)]  [string]$WorkspaceId,
    [Parameter(Mandatory=$false)] [string]$EventhouseId,
    [Parameter(Mandatory=$false)] [string]$KqlDatabaseId,
    [Parameter(Mandatory=$false)] [string]$QueryServiceUri,
    [Parameter(Mandatory=$false)] [string]$KqlDatabaseName,
    [Parameter(Mandatory=$false)] [string]$DataFolder
)

$ErrorActionPreference = "Stop"

if (-not $DataFolder) {
    $DataFolder = Join-Path (Split-Path -Parent $PSScriptRoot) "data"
    if (-not (Test-Path $DataFolder)) {
        $DataFolder = Join-Path $PSScriptRoot "..\data"
    }
}

Write-Host "=== Deploying KQL Tables and Ingesting Data ===" -ForegroundColor Cyan

# ── Authentication ──────────────────────────────────────────────────────────
$fabricToken = (Get-AzAccessToken -ResourceUrl "https://api.fabric.microsoft.com").Token
$fabricHeaders = @{ "Authorization" = "Bearer $fabricToken"; "Content-Type" = "application/json" }
$apiBase = "https://api.fabric.microsoft.com/v1"

# ── Auto-detect Eventhouse, KQL Database, Query URI ─────────────────────────
if (-not $EventhouseId -or -not $KqlDatabaseId -or -not $QueryServiceUri) {
    Write-Host "Auto-detecting Eventhouse and KQL Database..." -ForegroundColor Yellow
    $allItems = (Invoke-RestMethod -Uri "$apiBase/workspaces/$WorkspaceId/items" -Headers $fabricHeaders).value

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

    if (-not $EventhouseId) {
        $eh = $allItems | Where-Object { $_.type -eq 'Eventhouse' } | Select-Object -First 1
        if ($eh) {
            $EventhouseId = $eh.id
            Write-Host "  Found Eventhouse: $($eh.displayName) ($EventhouseId)" -ForegroundColor Gray
        }
    }

    if (-not $QueryServiceUri -and $EventhouseId) {
        $ehDetails = Invoke-RestMethod -Uri "$apiBase/workspaces/$WorkspaceId/eventhouses/$EventhouseId" -Headers $fabricHeaders
        $QueryServiceUri = $ehDetails.properties.queryServiceUri
        Write-Host "  Query URI: $QueryServiceUri" -ForegroundColor Gray
    }
}

if (-not $QueryServiceUri) {
    Write-Host "[ERROR] Could not determine Kusto query service URI." -ForegroundColor Red
    exit 1
}

# ── Get KQL Database name ──────────────────────────────────────────────────
if (-not $KqlDatabaseName) {
    $kqlDbDetails = Invoke-RestMethod -Uri "$apiBase/workspaces/$WorkspaceId/kqlDatabases/$KqlDatabaseId" -Headers $fabricHeaders
    $KqlDatabaseName = $kqlDbDetails.displayName
    Write-Host "  KQL Database Name: $KqlDatabaseName" -ForegroundColor Gray
}

# ── Acquire Kusto token ────────────────────────────────────────────────────
# Fabric Eventhouse Kusto endpoints accept tokens scoped to the cluster URI
$kustoToken = $null
$tokenResources = @($QueryServiceUri, "https://kusto.kusto.windows.net", "https://help.kusto.windows.net", "https://api.fabric.microsoft.com")

foreach ($resource in $tokenResources) {
    try {
        $kustoToken = (Get-AzAccessToken -ResourceUrl $resource).Token
        Write-Host "  Kusto token acquired (resource: $resource)" -ForegroundColor Gray
        break
    } catch {
        Write-Host "  Token attempt failed for $resource - trying next..." -ForegroundColor DarkGray
    }
}
if (-not $kustoToken) {
    Write-Host "[ERROR] Could not acquire Kusto token." -ForegroundColor Red
    exit 1
}

# ── Helper: Execute Kusto management command ───────────────────────────────
function Invoke-KustoMgmt {
    param([string]$Command, [string]$Description)

    if ($Description) { Write-Host "  $Description" -ForegroundColor Gray }

    $body = @{
        db  = $KqlDatabaseName
        csl = $Command
    } | ConvertTo-Json -Depth 2

    $headers = @{
        "Authorization" = "Bearer $kustoToken"
        "Content-Type"  = "application/json; charset=utf-8"
    }

    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method Post `
                -Uri "$QueryServiceUri/v1/rest/mgmt" `
                -Headers $headers `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType "application/json; charset=utf-8"
            return $response
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($_.Exception.Response) {
                try {
                    $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $errBody = $sr.ReadToEnd(); $sr.Close()
                    $errMsg = "$errMsg | $errBody"
                } catch {}
            }
            if ($attempt -lt $maxRetries) {
                Write-Host "    Retry ${attempt}/${maxRetries}: $errMsg" -ForegroundColor DarkYellow
                Start-Sleep -Seconds (10 * $attempt)
            } else {
                throw "Kusto command failed after $maxRetries attempts: $errMsg"
            }
        }
    }
}

# ── Wait for KQL database to be ready ──────────────────────────────────────
Write-Host "`nWaiting for KQL database to be ready..." -ForegroundColor Yellow
$dbReady = $false
for ($wait = 1; $wait -le 6; $wait++) {
    try {
        Invoke-KustoMgmt -Command ".show database" -Description $null | Out-Null
        $dbReady = $true
        Write-Host "  KQL database is ready." -ForegroundColor Green
        break
    }
    catch {
        Write-Host "  Database not ready yet, waiting 15s... ($wait/6)" -ForegroundColor DarkYellow
        Start-Sleep -Seconds 15
    }
}
if (-not $dbReady) {
    Write-Host "[ERROR] KQL database did not become ready in time." -ForegroundColor Red
    exit 1
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 1: CREATE KQL TABLES
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 1] Creating KQL tables..." -ForegroundColor Cyan

$tableDefinitions = @(
    @{
        Name = "SiteSensorReading"
        Schema = "(SensorId:string, Timestamp:datetime, ReadingType:string, Value:real, Unit:string, ZoneId:string, Quality:string)"
    },
    @{
        Name = "SafetyIncidentLog"
        Schema = "(IncidentId:string, Timestamp:datetime, IncidentType:string, Severity:string, ZoneId:string, WorkerId:string, Status:string, Description:string)"
    },
    @{
        Name = "AssetStatusStream"
        Schema = "(AssetId:string, Timestamp:datetime, Status:string, LocationLat:real, LocationLon:real, OperatorId:string, FuelLevel:real)"
    },
    @{
        Name = "MaterialDeliveryEvent"
        Schema = "(DeliveryId:string, Timestamp:datetime, MaterialId:string, Quantity:real, SupplierId:string, ZoneId:string, ReceivedBy:string)"
    },
    @{
        Name = "WorkProgressMetric"
        Schema = "(ZoneId:string, Timestamp:datetime, TaskName:string, ProgressPercent:real, WorkerId:string, Notes:string)"
    }
)

foreach ($tbl in $tableDefinitions) {
    try {
        Invoke-KustoMgmt -Command ".create-merge table $($tbl.Name) $($tbl.Schema)" `
                         -Description "Creating table $($tbl.Name)..." | Out-Null
        Write-Host "  [OK] $($tbl.Name) created" -ForegroundColor Green
    }
    catch {
        Write-Host "  [WARN] $($tbl.Name): $_" -ForegroundColor Yellow
    }
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 2: ENRICH AND INGEST SiteTelemetry → SiteSensorReading
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 2] Enriching SiteTelemetry.csv → SiteSensorReading..." -ForegroundColor Cyan

# Build lookup table from DimIoTSensor to resolve ZoneId per sensor
$sensorLookup = @{}
Import-Csv -Path (Join-Path $DataFolder "DimIoTSensor.csv") | ForEach-Object {
    $sensorLookup[$_.SensorId] = $_.ZoneId
}

# Read and enrich telemetry data
$telemetryData = Import-Csv -Path (Join-Path $DataFolder "SiteTelemetry.csv")
$sensorReadingLines = @()

foreach ($row in $telemetryData) {
    $zoneId = $sensorLookup[$row.SensorId]
    if (-not $zoneId) { $zoneId = "UNKNOWN" }
    $sensorReadingLines += "$($row.SensorId),$($row.Timestamp),$($row.ReadingType),$($row.Value),$($row.Unit),$zoneId,$($row.Quality)"
}

Write-Host "  Enriched $($sensorReadingLines.Count) rows from SiteTelemetry.csv" -ForegroundColor Gray

# Ingest in batches (Kusto inline limit is ~64KB per command)
$batchSize = 50
for ($i = 0; $i -lt $sensorReadingLines.Count; $i += $batchSize) {
    $batch = $sensorReadingLines[$i..([Math]::Min($i + $batchSize - 1, $sensorReadingLines.Count - 1))]
    $inlineData = $batch -join "`n"
    $cmd = ".ingest inline into table SiteSensorReading with (format='csv') <|`n$inlineData"
    try {
        Invoke-KustoMgmt -Command $cmd -Description "  Ingesting SiteSensorReading rows $($i+1)-$($i+$batch.Count)..." | Out-Null
    }
    catch {
        Write-Host "    [WARN] Batch ingestion failed: $_" -ForegroundColor Yellow
    }
}

Write-Host "  [OK] SiteSensorReading ingested ($($sensorReadingLines.Count) rows)" -ForegroundColor Green

# ════════════════════════════════════════════════════════════════════════════
# STEP 3: GENERATE AND INGEST SafetyIncidentLog SAMPLE DATA
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 3] Ingesting SafetyIncidentLog sample data..." -ForegroundColor Cyan

$incidentData = @(
    "INC-K001,2025-12-01T06:15:00,FallRisk,Critical,ZONE-001,WKR-003,Open,Worker near unguarded excavation edge without harness"
    "INC-K002,2025-12-01T07:30:00,PPEViolation,Medium,ZONE-002,WKR-005,Resolved,Missing hard hat observed on framing level 3"
    "INC-K003,2025-12-01T08:45:00,EquipmentFailure,High,ZONE-003,WKR-008,Open,Crane hydraulic leak detected during lift"
    "INC-K004,2025-12-01T09:00:00,NearMiss,Low,ZONE-004,WKR-002,Resolved,Dropped tool from scaffolding - no injury"
    "INC-K005,2025-12-01T10:15:00,FireHazard,Critical,ZONE-005,WKR-011,Open,Hot works near combustible material storage"
    "INC-K006,2025-12-01T11:30:00,DustExposure,Medium,ZONE-006,WKR-001,Resolved,Silica dust above threshold during cutting"
    "INC-K007,2025-12-01T12:00:00,FallRisk,High,ZONE-007,WKR-009,Open,Scaffolding missing toe boards on north elevation"
    "INC-K008,2025-12-01T13:15:00,NoiseExposure,Medium,ZONE-008,WKR-014,Resolved,Prolonged exposure to piling noise above 85dB"
    "INC-K009,2025-12-01T14:30:00,StructuralRisk,Critical,ZONE-009,WKR-006,Open,Temporary shoring showing signs of displacement"
    "INC-K010,2025-12-01T15:00:00,ElectricalHazard,High,ZONE-010,WKR-012,Open,Exposed live wiring in wet conditions"
    "INC-K011,2025-12-02T06:00:00,PPEViolation,Low,ZONE-011,WKR-004,Resolved,Worker without hi-vis vest on active roadway"
    "INC-K012,2025-12-02T07:15:00,NearMiss,Medium,ZONE-012,WKR-007,Resolved,Excavator swing radius near pedestrian walkway"
    "INC-K013,2025-12-02T08:30:00,FallRisk,High,ZONE-013,WKR-010,Open,Unprotected roof edge during waterproofing"
    "INC-K014,2025-12-02T09:45:00,FireHazard,Medium,ZONE-014,WKR-013,Resolved,Welding sparks near timber stack"
    "INC-K015,2025-12-02T11:00:00,EquipmentFailure,High,ZONE-015,WKR-015,Open,Concrete pump blockage causing pressure build-up"
    "INC-K016,2025-12-02T12:30:00,DustExposure,Low,ZONE-001,WKR-002,Resolved,Dust suppression system temporarily offline"
    "INC-K017,2025-12-02T14:00:00,NearMiss,Medium,ZONE-003,WKR-005,Resolved,Load swinging near adjacent work zone"
    "INC-K018,2025-12-03T06:15:00,FallRisk,Critical,ZONE-005,WKR-008,Open,Ladder not secured at top on level 4"
    "INC-K019,2025-12-03T07:30:00,ElectricalHazard,High,ZONE-007,WKR-011,Open,Generator earthing fault detected"
    "INC-K020,2025-12-03T09:00:00,PPEViolation,Medium,ZONE-009,WKR-001,Resolved,Gloves not worn during rebar handling"
    "INC-K021,2025-12-03T10:15:00,StructuralRisk,High,ZONE-002,WKR-006,Open,Formwork deflecting beyond tolerance"
    "INC-K022,2025-12-03T11:30:00,NoiseExposure,Low,ZONE-004,WKR-009,Resolved,Background noise elevated during concrete pour"
    "INC-K023,2025-12-03T13:00:00,FireHazard,Medium,ZONE-006,WKR-012,Resolved,Oxyacetylene bottles stored in sunlight"
    "INC-K024,2025-12-04T06:00:00,NearMiss,High,ZONE-010,WKR-014,Open,Unsecured panel blown off by wind"
    "INC-K025,2025-12-04T08:30:00,FallRisk,Critical,ZONE-012,WKR-003,Open,Safety net gap found on south elevation"
)
$incidentInline = $incidentData -join "`n"
try {
    Invoke-KustoMgmt -Command ".ingest inline into table SafetyIncidentLog with (format='csv') <|`n$incidentInline" `
                     -Description "Ingesting 25 SafetyIncidentLog rows..." | Out-Null
    Write-Host "  [OK] SafetyIncidentLog ingested (25 rows)" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] SafetyIncidentLog ingestion failed: $_" -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 4: GENERATE AND INGEST AssetStatusStream SAMPLE DATA
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 4] Ingesting AssetStatusStream sample data..." -ForegroundColor Cyan

$assetData = @(
    "ASSET-001,2025-12-01T06:00:00,Operating,51.5074,-0.1278,WKR-003,82.5"
    "ASSET-001,2025-12-01T12:00:00,Operating,51.5074,-0.1278,WKR-003,65.0"
    "ASSET-001,2025-12-01T18:00:00,Idle,51.5074,-0.1278,WKR-003,58.2"
    "ASSET-002,2025-12-01T06:00:00,Operating,51.4545,-2.5879,WKR-005,90.0"
    "ASSET-002,2025-12-01T12:00:00,Operating,51.4545,-2.5879,WKR-005,72.3"
    "ASSET-002,2025-12-01T18:00:00,Maintenance,51.4545,-2.5879,WKR-005,70.0"
    "ASSET-003,2025-12-01T06:00:00,Operating,53.4808,-2.2426,WKR-008,95.0"
    "ASSET-003,2025-12-01T12:00:00,Operating,53.4808,-2.2426,WKR-008,78.5"
    "ASSET-004,2025-12-01T06:00:00,Idle,52.4862,-1.8904,WKR-002,100.0"
    "ASSET-004,2025-12-01T12:00:00,Operating,52.4862,-1.8904,WKR-002,85.0"
    "ASSET-005,2025-12-01T06:00:00,Operating,55.9533,-3.1883,WKR-011,60.0"
    "ASSET-005,2025-12-01T12:00:00,Operating,55.9533,-3.1883,WKR-011,42.5"
    "ASSET-005,2025-12-01T18:00:00,Refuelling,55.9533,-3.1883,WKR-011,15.0"
    "ASSET-006,2025-12-01T06:00:00,Operating,51.4816,-3.1791,WKR-001,88.0"
    "ASSET-006,2025-12-01T12:00:00,Idle,51.4816,-3.1791,WKR-001,87.5"
    "ASSET-007,2025-12-01T06:00:00,Operating,53.8008,-1.5491,WKR-009,75.0"
    "ASSET-007,2025-12-01T12:00:00,Operating,53.8008,-1.5491,WKR-009,55.0"
    "ASSET-008,2025-12-02T06:00:00,Operating,51.5074,-0.1278,WKR-014,92.0"
    "ASSET-008,2025-12-02T12:00:00,Maintenance,51.5074,-0.1278,WKR-014,91.0"
    "ASSET-009,2025-12-02T06:00:00,Operating,54.9783,-1.6178,WKR-006,80.0"
    "ASSET-009,2025-12-02T12:00:00,Operating,54.9783,-1.6178,WKR-006,62.0"
    "ASSET-010,2025-12-02T06:00:00,Operating,52.6309,-1.1398,WKR-012,70.0"
    "ASSET-010,2025-12-02T12:00:00,Idle,52.6309,-1.1398,WKR-012,68.0"
    "ASSET-011,2025-12-02T06:00:00,Operating,50.3755,-4.1427,WKR-004,55.0"
    "ASSET-012,2025-12-02T06:00:00,Operating,51.8787,-0.4200,WKR-007,98.0"
    "ASSET-013,2025-12-03T06:00:00,Maintenance,53.4084,-2.9916,WKR-010,45.0"
    "ASSET-014,2025-12-03T06:00:00,Operating,51.5200,-0.0800,WKR-013,85.0"
    "ASSET-015,2025-12-03T06:00:00,Operating,52.2053,-0.1218,WKR-015,77.0"
    "ASSET-001,2025-12-02T06:00:00,Operating,51.5074,-0.1278,WKR-003,95.0"
    "ASSET-003,2025-12-02T06:00:00,Operating,53.4808,-2.2426,WKR-008,88.0"
)
$assetInline = $assetData -join "`n"
try {
    Invoke-KustoMgmt -Command ".ingest inline into table AssetStatusStream with (format='csv') <|`n$assetInline" `
                     -Description "Ingesting 30 AssetStatusStream rows..." | Out-Null
    Write-Host "  [OK] AssetStatusStream ingested (30 rows)" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] AssetStatusStream ingestion failed: $_" -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 5: GENERATE AND INGEST MaterialDeliveryEvent SAMPLE DATA
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 5] Ingesting MaterialDeliveryEvent sample data..." -ForegroundColor Cyan

$deliveryData = @(
    "DEL-001,2025-12-01T07:00:00,MAT-001,25.0,SUP-HANSON,ZONE-001,WKR-003"
    "DEL-002,2025-12-01T07:30:00,MAT-002,8.5,SUP-TATA,ZONE-002,WKR-005"
    "DEL-003,2025-12-01T08:00:00,MAT-003,12.0,SUP-TRAVIS,ZONE-003,WKR-008"
    "DEL-004,2025-12-01T08:45:00,MAT-004,3.2,SUP-PILKINGTON,ZONE-004,WKR-002"
    "DEL-005,2025-12-01T09:30:00,MAT-005,40.0,SUP-BREEDON,ZONE-005,WKR-011"
    "DEL-006,2025-12-01T10:00:00,MAT-006,150.0,SUP-IBSTOCK,ZONE-006,WKR-001"
    "DEL-007,2025-12-01T10:30:00,MAT-007,6.0,SUP-CEMEX,ZONE-007,WKR-009"
    "DEL-008,2025-12-01T11:00:00,MAT-008,0.8,SUP-KINGSPAN,ZONE-008,WKR-014"
    "DEL-009,2025-12-01T11:30:00,MAT-009,2.5,SUP-SIKA,ZONE-009,WKR-006"
    "DEL-010,2025-12-01T12:00:00,MAT-010,18.0,SUP-POLYPIPE,ZONE-010,WKR-012"
    "DEL-011,2025-12-01T13:00:00,MAT-011,4.0,SUP-PRYSMIAN,ZONE-011,WKR-004"
    "DEL-012,2025-12-01T14:00:00,MAT-012,30.0,SUP-BREEDON,ZONE-012,WKR-007"
    "DEL-013,2025-12-02T07:00:00,MAT-013,1.5,SUP-JOIST,ZONE-013,WKR-010"
    "DEL-014,2025-12-02T07:30:00,MAT-014,20.0,SUP-CELOTEX,ZONE-014,WKR-013"
    "DEL-015,2025-12-02T08:00:00,MAT-015,500.0,SUP-FIXINGS,ZONE-015,WKR-015"
    "DEL-016,2025-12-02T09:00:00,MAT-001,30.0,SUP-HANSON,ZONE-001,WKR-003"
    "DEL-017,2025-12-02T09:30:00,MAT-002,10.0,SUP-TATA,ZONE-003,WKR-008"
    "DEL-018,2025-12-02T10:00:00,MAT-005,35.0,SUP-BREEDON,ZONE-005,WKR-011"
    "DEL-019,2025-12-02T10:30:00,MAT-003,15.0,SUP-TRAVIS,ZONE-007,WKR-009"
    "DEL-020,2025-12-03T07:00:00,MAT-001,28.0,SUP-HANSON,ZONE-002,WKR-005"
    "DEL-021,2025-12-03T08:00:00,MAT-006,200.0,SUP-IBSTOCK,ZONE-009,WKR-006"
    "DEL-022,2025-12-03T09:00:00,MAT-004,4.0,SUP-PILKINGTON,ZONE-011,WKR-004"
    "DEL-023,2025-12-03T10:00:00,MAT-008,1.2,SUP-KINGSPAN,ZONE-013,WKR-010"
    "DEL-024,2025-12-04T07:00:00,MAT-010,22.0,SUP-POLYPIPE,ZONE-014,WKR-013"
    "DEL-025,2025-12-04T08:00:00,MAT-007,8.0,SUP-CEMEX,ZONE-015,WKR-015"
)
$deliveryInline = $deliveryData -join "`n"
try {
    Invoke-KustoMgmt -Command ".ingest inline into table MaterialDeliveryEvent with (format='csv') <|`n$deliveryInline" `
                     -Description "Ingesting 25 MaterialDeliveryEvent rows..." | Out-Null
    Write-Host "  [OK] MaterialDeliveryEvent ingested (25 rows)" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] MaterialDeliveryEvent ingestion failed: $_" -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 6: GENERATE AND INGEST WorkProgressMetric SAMPLE DATA
# ════════════════════════════════════════════════════════════════════════════
Write-Host "`n[Step 6] Ingesting WorkProgressMetric sample data..." -ForegroundColor Cyan

$progressData = @(
    "ZONE-001,2025-12-01T08:00:00,Foundation Excavation,45.0,WKR-003,Bulk dig 60% complete"
    "ZONE-001,2025-12-01T16:00:00,Foundation Excavation,52.0,WKR-003,Shoring installed on east side"
    "ZONE-002,2025-12-01T08:00:00,Steel Framing Level 2,30.0,WKR-005,Columns erected to grid line D"
    "ZONE-002,2025-12-01T16:00:00,Steel Framing Level 2,38.0,WKR-005,Beam connections torqued"
    "ZONE-003,2025-12-01T08:00:00,Roof Truss Installation,15.0,WKR-008,First 4 trusses lifted into position"
    "ZONE-003,2025-12-01T16:00:00,Roof Truss Installation,22.0,WKR-008,Bracing installed on trusses 1-4"
    "ZONE-004,2025-12-01T08:00:00,Internal Blockwork,60.0,WKR-002,Ground floor partitions 60% laid"
    "ZONE-005,2025-12-01T08:00:00,First Fix Electrical,25.0,WKR-011,Cable runs in progress level 1"
    "ZONE-005,2025-12-01T16:00:00,First Fix Electrical,32.0,WKR-011,Consumer unit positions marked out"
    "ZONE-006,2025-12-01T08:00:00,External Brickwork,70.0,WKR-001,South elevation at DPC level"
    "ZONE-007,2025-12-01T08:00:00,Concrete Pour Slab B,0.0,WKR-009,Formwork and rebar check complete"
    "ZONE-007,2025-12-01T16:00:00,Concrete Pour Slab B,100.0,WKR-009,Pour complete - curing started"
    "ZONE-008,2025-12-02T08:00:00,Mechanical Ductwork,18.0,WKR-014,Main risers installed floors 1-2"
    "ZONE-009,2025-12-02T08:00:00,Window Installation,40.0,WKR-006,North elevation windows fitted"
    "ZONE-009,2025-12-02T16:00:00,Window Installation,55.0,WKR-006,East elevation 50% glazed"
    "ZONE-010,2025-12-02T08:00:00,Plumbing First Fix,35.0,WKR-012,Soil stacks in place floors 1-3"
    "ZONE-011,2025-12-02T08:00:00,Plastering,10.0,WKR-004,Skim coat started ground floor east wing"
    "ZONE-012,2025-12-02T08:00:00,Tiling and Finishes,5.0,WKR-007,Floor screed laid in block A"
    "ZONE-013,2025-12-03T08:00:00,External Drainage,50.0,WKR-010,Main run connected to manhole"
    "ZONE-013,2025-12-03T16:00:00,External Drainage,65.0,WKR-010,Percolation test passed"
    "ZONE-014,2025-12-03T08:00:00,Insulation Install,80.0,WKR-013,Cavity wall insulation complete north"
    "ZONE-014,2025-12-03T16:00:00,Insulation Install,90.0,WKR-013,Roof insulation boards laid"
    "ZONE-015,2025-12-03T08:00:00,Landscaping,20.0,WKR-015,Topsoil spread and graded"
    "ZONE-001,2025-12-02T08:00:00,Foundation Excavation,68.0,WKR-003,Trial hole inspection passed"
    "ZONE-004,2025-12-02T08:00:00,Internal Blockwork,75.0,WKR-002,First floor partitions started"
)
$progressInline = $progressData -join "`n"
try {
    Invoke-KustoMgmt -Command ".ingest inline into table WorkProgressMetric with (format='csv') <|`n$progressInline" `
                     -Description "Ingesting 25 WorkProgressMetric rows..." | Out-Null
    Write-Host "  [OK] WorkProgressMetric ingested (25 rows)" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] WorkProgressMetric ingestion failed: $_" -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "=== KQL Tables Deployment Summary ===" -ForegroundColor Cyan
Write-Host "  Eventhouse:    $EventhouseId" -ForegroundColor White
Write-Host "  KQL Database:  $KqlDatabaseName ($KqlDatabaseId)" -ForegroundColor White
Write-Host "  Query URI:     $QueryServiceUri" -ForegroundColor White
Write-Host ""
Write-Host "  Tables created and populated:" -ForegroundColor White
Write-Host "    - SiteSensorReading      ($($sensorReadingLines.Count) rows from SiteTelemetry.csv)" -ForegroundColor White
Write-Host "    - SafetyIncidentLog      (25 sample rows)" -ForegroundColor White
Write-Host "    - AssetStatusStream      (30 sample rows)" -ForegroundColor White
Write-Host "    - MaterialDeliveryEvent  (25 sample rows)" -ForegroundColor White
Write-Host "    - WorkProgressMetric     (25 sample rows)" -ForegroundColor White
Write-Host ""
Write-Host "  The RTI Dashboard tiles will now show data from these tables." -ForegroundColor Green
Write-Host "=== KQL Tables Deployment Complete ===" -ForegroundColor Cyan
