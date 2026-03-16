# Build-Ontology.ps1
# Builds the complete Construction Building Site Ontology definition for Microsoft Fabric
# Entity Types, Data Bindings (Lakehouse + KQL), Relationships, and Contextualizations
param(
    [string]$WorkspaceId,
    [string]$LakehouseId,
    [string]$KqlDatabaseId,
    [string]$KqlClusterUri,
    [string]$KqlDatabaseName,
    [string]$OntologyId,
    [string]$FabricToken
)

$headers = @{ Authorization = "Bearer $FabricToken"; "Content-Type" = "application/json" }

# ============================================================================
# Helper: encode JSON to Base64
# ============================================================================
function ToBase64([string]$text) {
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($text))
}

# Deterministic GUID from a seed string (ensures idempotent re-pushes)
function DeterministicGuid([string]$seed) {
    $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed))
    return ([guid]::new($hash)).ToString()
}

# ============================================================================
# ID Allocation Plan (unique 64-bit integers)
# Entity Type IDs:      1001 - 1011
# Property IDs:         2001 - 2999 (allocated per entity)
# Relationship IDs:     3001 - 3012
# Timeseries Prop IDs:  4001 - 4099
# ============================================================================

# ============================================================================
# 1. ENTITY TYPES + PROPERTIES
# ============================================================================

$entityTypes = @()

# --- DimBuildingSite (ID: 1001) ---
$entityTypes += @{
    id = "1001"; name = "BuildingSite"
    entityIdParts = @("2001")
    displayNamePropertyId = "2002"
    properties = @(
        @{ id = "2001"; name = "SiteId"; valueType = "String" },
        @{ id = "2002"; name = "ProjectName"; valueType = "String" },
        @{ id = "2003"; name = "City"; valueType = "String" },
        @{ id = "2004"; name = "Country"; valueType = "String" },
        @{ id = "2005"; name = "StartDate"; valueType = "String" },
        @{ id = "2006"; name = "EndDate"; valueType = "String" },
        @{ id = "2007"; name = "ContractValue"; valueType = "Double" },
        @{ id = "2008"; name = "Status"; valueType = "String" }
    )
    tableName = "dimbuildingsite"
}

# --- DimWorkZone (ID: 1002) ---
$entityTypes += @{
    id = "1002"; name = "WorkZone"
    entityIdParts = @("2101")
    displayNamePropertyId = "2102"
    properties = @(
        @{ id = "2101"; name = "ZoneId"; valueType = "String" },
        @{ id = "2102"; name = "ZoneName"; valueType = "String" },
        @{ id = "2103"; name = "ZoneType"; valueType = "String" },
        @{ id = "2104"; name = "SiteId"; valueType = "String" },
        @{ id = "2105"; name = "ProgressPercent"; valueType = "Double" },
        @{ id = "2106"; name = "StartDate"; valueType = "String" },
        @{ id = "2107"; name = "PlannedEndDate"; valueType = "String" }
    )
    tableName = "dimworkzone"
}

# --- DimConstructionAsset (ID: 1003) ---
$entityTypes += @{
    id = "1003"; name = "ConstructionAsset"
    entityIdParts = @("2201")
    displayNamePropertyId = "2202"
    properties = @(
        @{ id = "2201"; name = "AssetId"; valueType = "String" },
        @{ id = "2202"; name = "AssetName"; valueType = "String" },
        @{ id = "2203"; name = "AssetType"; valueType = "String" },
        @{ id = "2204"; name = "Manufacturer"; valueType = "String" },
        @{ id = "2205"; name = "Status"; valueType = "String" },
        @{ id = "2206"; name = "ZoneId"; valueType = "String" }
    )
    tableName = "dimconstructionasset"
}

# --- DimSupplyChain (ID: 1004) ---
$entityTypes += @{
    id = "1004"; name = "SupplyChain"
    entityIdParts = @("2301")
    displayNamePropertyId = "2301"
    properties = @(
        @{ id = "2301"; name = "SupplyId"; valueType = "String" },
        @{ id = "2302"; name = "MaterialId"; valueType = "String" },
        @{ id = "2303"; name = "OriginZoneId"; valueType = "String" },
        @{ id = "2304"; name = "DestinationZoneId"; valueType = "String" },
        @{ id = "2305"; name = "DeliveryDate"; valueType = "String" },
        @{ id = "2306"; name = "Quantity"; valueType = "Double" }
    )
    tableName = "dimsupplychain"
}

# --- DimRawMaterial (ID: 1005) ---
$entityTypes += @{
    id = "1005"; name = "RawMaterial"
    entityIdParts = @("2401")
    displayNamePropertyId = "2402"
    properties = @(
        @{ id = "2401"; name = "MaterialId"; valueType = "String" },
        @{ id = "2402"; name = "MaterialName"; valueType = "String" },
        @{ id = "2403"; name = "MaterialType"; valueType = "String" },
        @{ id = "2404"; name = "Supplier"; valueType = "String" },
        @{ id = "2405"; name = "UnitOfMeasure"; valueType = "String" },
        @{ id = "2406"; name = "UnitCost"; valueType = "Double" }
    )
    tableName = "dimrawmaterial"
}

# --- DimCompletedWork (ID: 1006) ---
$entityTypes += @{
    id = "1006"; name = "CompletedWork"
    entityIdParts = @("2501")
    displayNamePropertyId = "2502"
    properties = @(
        @{ id = "2501"; name = "WorkId"; valueType = "String" },
        @{ id = "2502"; name = "WorkName"; valueType = "String" },
        @{ id = "2503"; name = "ZoneId"; valueType = "String" },
        @{ id = "2504"; name = "CompletionDate"; valueType = "String" },
        @{ id = "2505"; name = "QualityGrade"; valueType = "String" },
        @{ id = "2506"; name = "InspectedBy"; valueType = "String" }
    )
    tableName = "dimcompletedwork"
}

# --- DimMaterialStorage (ID: 1007) ---
$entityTypes += @{
    id = "1007"; name = "MaterialStorage"
    entityIdParts = @("2601")
    displayNamePropertyId = "2602"
    properties = @(
        @{ id = "2601"; name = "StorageId"; valueType = "String" },
        @{ id = "2602"; name = "StorageName"; valueType = "String" },
        @{ id = "2603"; name = "Capacity"; valueType = "Double" },
        @{ id = "2604"; name = "CurrentLevel"; valueType = "Double" },
        @{ id = "2605"; name = "MaterialId"; valueType = "String" },
        @{ id = "2606"; name = "SiteId"; valueType = "String" }
    )
    tableName = "dimmaterialstorage"
}

# --- DimIoTSensor (ID: 1008) ---
$entityTypes += @{
    id = "1008"; name = "IoTSensor"
    entityIdParts = @("2701")
    displayNamePropertyId = "2702"
    properties = @(
        @{ id = "2701"; name = "SensorId"; valueType = "String" },
        @{ id = "2702"; name = "SensorName"; valueType = "String" },
        @{ id = "2703"; name = "SensorType"; valueType = "String" },
        @{ id = "2704"; name = "ZoneId"; valueType = "String" },
        @{ id = "2705"; name = "AssetId"; valueType = "String" },
        @{ id = "2706"; name = "Unit"; valueType = "String" },
        @{ id = "2707"; name = "Status"; valueType = "String" }
    )
    tableName = "dimiotsensor"
    timeseriesTable = "SensorReading"
    timeseriesProperties = @(
        @{ id = "4001"; name = "Timestamp"; valueType = "DateTime" },
        @{ id = "4002"; name = "ReadingValue"; valueType = "Double" },
        @{ id = "4003"; name = "QualityFlag"; valueType = "String" },
        @{ id = "4004"; name = "IsAnomaly"; valueType = "Boolean" }
    )
    timestampColumn = "Timestamp"
}

# --- DimWorker (ID: 1009) ---
$entityTypes += @{
    id = "1009"; name = "Worker"
    entityIdParts = @("2801")
    displayNamePropertyId = "2802"
    properties = @(
        @{ id = "2801"; name = "WorkerId"; valueType = "String" },
        @{ id = "2802"; name = "FirstName"; valueType = "String" },
        @{ id = "2803"; name = "LastName"; valueType = "String" },
        @{ id = "2804"; name = "Trade"; valueType = "String" },
        @{ id = "2805"; name = "ContractorCompany"; valueType = "String" },
        @{ id = "2806"; name = "CertificationExpiry"; valueType = "String" },
        @{ id = "2807"; name = "SiteId"; valueType = "String" }
    )
    tableName = "dimworker"
}

# --- FactInspectionEvent (ID: 1010) ---
$entityTypes += @{
    id = "1010"; name = "InspectionEvent"
    entityIdParts = @("2901")
    displayNamePropertyId = "2901"
    properties = @(
        @{ id = "2901"; name = "InspectionId"; valueType = "String" },
        @{ id = "2902"; name = "InspectionType"; valueType = "String" },
        @{ id = "2903"; name = "AssetId"; valueType = "String" },
        @{ id = "2904"; name = "InspectorId"; valueType = "String" },
        @{ id = "2905"; name = "Date"; valueType = "String" },
        @{ id = "2906"; name = "Result"; valueType = "String" },
        @{ id = "2907"; name = "NextDueDate"; valueType = "String" }
    )
    tableName = "factinspectionevent"
}

# --- FactSafetyIncident (ID: 1011) ---
$entityTypes += @{
    id = "1011"; name = "SafetyIncident"
    entityIdParts = @("2951")
    displayNamePropertyId = "2951"
    properties = @(
        @{ id = "2951"; name = "IncidentId"; valueType = "String" },
        @{ id = "2952"; name = "IncidentType"; valueType = "String" },
        @{ id = "2953"; name = "Severity"; valueType = "String" },
        @{ id = "2954"; name = "ZoneId"; valueType = "String" },
        @{ id = "2955"; name = "WorkerId"; valueType = "String" },
        @{ id = "2956"; name = "Timestamp"; valueType = "String" },
        @{ id = "2957"; name = "Status"; valueType = "String" }
    )
    tableName = "factsafetyincident"
}

# ============================================================================
# 2. RELATIONSHIPS
# ============================================================================

$relationships = @(
    @{ id = "3001"; name = "SiteContainsZone"; sourceId = "1001"; targetId = "1002" },
    @{ id = "3002"; name = "ZoneDeploysAsset"; sourceId = "1002"; targetId = "1003" },
    @{ id = "3003"; name = "SupplyToZone"; sourceId = "1004"; targetId = "1002" },
    @{ id = "3004"; name = "SupplyFromMaterial"; sourceId = "1004"; targetId = "1005" },
    @{ id = "3005"; name = "StorageAtSite"; sourceId = "1007"; targetId = "1001" },
    @{ id = "3006"; name = "StorageHoldsMaterial"; sourceId = "1007"; targetId = "1005" },
    @{ id = "3007"; name = "SensorMonitorsAsset"; sourceId = "1008"; targetId = "1003" },
    @{ id = "3008"; name = "IncidentInZone"; sourceId = "1011"; targetId = "1002" },
    @{ id = "3009"; name = "InspectionTargetsAsset"; sourceId = "1010"; targetId = "1003" },
    @{ id = "3010"; name = "InspectionByWorker"; sourceId = "1010"; targetId = "1009" },
    @{ id = "3011"; name = "WorkerAssignedToSite"; sourceId = "1009"; targetId = "1001" },
    @{ id = "3012"; name = "ZoneDeliversWork"; sourceId = "1002"; targetId = "1006" }
)

# ============================================================================
# 3. BUILD PARTS ARRAY
# ============================================================================

$parts = @()

# --- .platform ---
$platform = @"
{"metadata":{"type":"Ontology","displayName":"ConstructionSiteOntology","description":"Construction Building Site Ontology - entities, relationships, and telemetry for building site operations"},"config":{"version":"2.0","logicalId":"00000000-0000-0000-0000-000000000000"}}
"@
$parts += @{ path = ".platform"; payload = (ToBase64 $platform); payloadType = "InlineBase64" }

# --- definition.json (always empty) ---
$parts += @{ path = "definition.json"; payload = (ToBase64 "{}"); payloadType = "InlineBase64" }

# --- Entity Types ---
foreach ($et in $entityTypes) {
    # Build properties JSON array
    $propsJson = ($et.properties | ForEach-Object {
        '{"id":"' + $_.id + '","name":"' + $_.name + '","redefines":null,"baseTypeNamespaceType":null,"valueType":"' + $_.valueType + '"}'
    }) -join ','

    # Build timeseries properties if present
    $tsPropsJson = "[]"
    if ($et.timeseriesProperties) {
        $tsPropsJson = '[' + (($et.timeseriesProperties | ForEach-Object {
            '{"id":"' + $_.id + '","name":"' + $_.name + '","redefines":null,"baseTypeNamespaceType":null,"valueType":"' + $_.valueType + '"}'
        }) -join ',') + ']'
    }

    # Entity ID parts
    $idPartsJson = '[' + (($et.entityIdParts | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'

    $entityJson = '{"id":"' + $et.id + '","namespace":"usertypes","baseEntityTypeId":null,"name":"' + $et.name + '","entityIdParts":' + $idPartsJson + ',"displayNamePropertyId":"' + $et.displayNamePropertyId + '","namespaceType":"Custom","visibility":"Visible","properties":[' + $propsJson + '],"timeseriesProperties":' + $tsPropsJson + '}'

    $parts += @{ path = "EntityTypes/$($et.id)/definition.json"; payload = (ToBase64 $entityJson); payloadType = "InlineBase64" }

    # --- NonTimeSeries Data Binding (Lakehouse) ---
    $bindGuid = DeterministicGuid "NonTimeSeries-$($et.id)"
    $propBindings = ($et.properties | ForEach-Object {
        $colName = $_.name
        # Map property name to column name if mapping exists
        if ($et.columnMappings -and $et.columnMappings.ContainsKey($_.name)) {
            $colName = $et.columnMappings[$_.name]
        }
        '{"sourceColumnName":"' + $colName + '","targetPropertyId":"' + $_.id + '"}'
    }) -join ','

    $bindJson = '{"id":"' + $bindGuid + '","dataBindingConfiguration":{"dataBindingType":"NonTimeSeries","propertyBindings":[' + $propBindings + '],"sourceTableProperties":{"sourceType":"LakehouseTable","workspaceId":"' + $WorkspaceId + '","itemId":"' + $LakehouseId + '","sourceTableName":"' + $et.tableName + '","sourceSchema":"dbo"}}}'

    $parts += @{ path = "EntityTypes/$($et.id)/DataBindings/$bindGuid.json"; payload = (ToBase64 $bindJson); payloadType = "InlineBase64" }

    # --- TimeSeries Data Binding (Eventhouse/KQL) ---
    if ($et.timeseriesTable) {
        $tsBindGuid = DeterministicGuid "TimeSeries-$($et.id)"
        $tsBindings = ($et.timeseriesProperties | ForEach-Object {
            '{"sourceColumnName":"' + $_.name + '","targetPropertyId":"' + $_.id + '"}'
        }) -join ','
        # Add the entity ID column binding (SensorId -> SensorId property)
        $entityIdPropId = $et.entityIdParts[0]
        $entityIdPropName = ($et.properties | Where-Object { $_.id -eq $entityIdPropId }).name
        $tsBindings = '{"sourceColumnName":"' + $entityIdPropName + '","targetPropertyId":"' + $entityIdPropId + '"},' + $tsBindings

        $tsBindJson = '{"id":"' + $tsBindGuid + '","dataBindingConfiguration":{"dataBindingType":"TimeSeries","timestampColumnName":"' + $et.timestampColumn + '","propertyBindings":[' + $tsBindings + '],"sourceTableProperties":{"sourceType":"KustoTable","workspaceId":"' + $WorkspaceId + '","itemId":"' + $KqlDatabaseId + '","clusterUri":"' + $KqlClusterUri + '","databaseName":"' + $KqlDatabaseName + '","sourceTableName":"' + $et.timeseriesTable + '"}}}'

        $parts += @{ path = "EntityTypes/$($et.id)/DataBindings/$tsBindGuid.json"; payload = (ToBase64 $tsBindJson); payloadType = "InlineBase64" }
    }
}

# --- Relationship Types ---
foreach ($rel in $relationships) {
    $relJson = '{"namespace":"usertypes","id":"' + $rel.id + '","name":"' + $rel.name + '","namespaceType":"Custom","source":{"entityTypeId":"' + $rel.sourceId + '"},"target":{"entityTypeId":"' + $rel.targetId + '"}}'

    $parts += @{ path = "RelationshipTypes/$($rel.id)/definition.json"; payload = (ToBase64 $relJson); payloadType = "InlineBase64" }

    # --- Contextualization: find the FK column that links source and target entities ---
    $sourceEntity = $entityTypes | Where-Object { $_.id -eq $rel.sourceId }
    $targetEntity = $entityTypes | Where-Object { $_.id -eq $rel.targetId }
    $sourcePkPropId = $sourceEntity.entityIdParts[0]
    $sourcePkName = ($sourceEntity.properties | Where-Object { $_.id -eq $sourcePkPropId }).name
    $targetPkPropId = $targetEntity.entityIdParts[0]
    $targetPkName = ($targetEntity.properties | Where-Object { $_.id -eq $targetPkPropId }).name

    # Strategy 1: FK in source entity table (source has a column matching target PK)
    $fkProp = $sourceEntity.properties | Where-Object { $_.name -eq $targetPkName }
    if (-not $fkProp) {
        # Try common FK patterns like "DestinationZoneId", "InspectorWorkerId"
        $fkProp = $sourceEntity.properties | Where-Object { $_.name -like "*$targetPkName" }
    }

    if ($fkProp) {
        # FK is in source table - contextualization uses source entity's table
        $ctxGuid = DeterministicGuid "Ctx-$($rel.id)"
        $ctxJson = '{"id":"' + $ctxGuid + '","dataBindingTable":{"workspaceId":"' + $WorkspaceId + '","itemId":"' + $LakehouseId + '","sourceTableName":"' + $sourceEntity.tableName + '","sourceSchema":"dbo","sourceType":"LakehouseTable"},"sourceKeyRefBindings":[{"sourceColumnName":"' + $sourcePkName + '","targetPropertyId":"' + $sourcePkPropId + '"}],"targetKeyRefBindings":[{"sourceColumnName":"' + $fkProp.name + '","targetPropertyId":"' + $targetPkPropId + '"}]}'
        $parts += @{ path = "RelationshipTypes/$($rel.id)/Contextualizations/$ctxGuid.json"; payload = (ToBase64 $ctxJson); payloadType = "InlineBase64" }
    } else {
        # Strategy 2: FK in target entity table (target has a column matching source PK)
        # This handles "parent has children" relationships (e.g., SiteContainsZone)
        $fkPropInTarget = $targetEntity.properties | Where-Object { $_.name -eq $sourcePkName }
        if (-not $fkPropInTarget) {
            $fkPropInTarget = $targetEntity.properties | Where-Object { $_.name -like "*$sourcePkName" }
        }
        if ($fkPropInTarget) {
            $ctxGuid = DeterministicGuid "Ctx-$($rel.id)"
            $ctxJson = '{"id":"' + $ctxGuid + '","dataBindingTable":{"workspaceId":"' + $WorkspaceId + '","itemId":"' + $LakehouseId + '","sourceTableName":"' + $targetEntity.tableName + '","sourceSchema":"dbo","sourceType":"LakehouseTable"},"sourceKeyRefBindings":[{"sourceColumnName":"' + $fkPropInTarget.name + '","targetPropertyId":"' + $sourcePkPropId + '"}],"targetKeyRefBindings":[{"sourceColumnName":"' + $targetPkName + '","targetPropertyId":"' + $targetPkPropId + '"}]}'
            $parts += @{ path = "RelationshipTypes/$($rel.id)/Contextualizations/$ctxGuid.json"; payload = (ToBase64 $ctxJson); payloadType = "InlineBase64" }
        } else {
            Write-Warning "No FK found for relationship $($rel.name) ($($rel.id))"
        }
    }
}

Write-Host "Total parts: $($parts.Count)"
Write-Host "  Entity types: $($entityTypes.Count)"
Write-Host "  Relationships: $($relationships.Count)"

# ============================================================================
# 4. BUILD AND SEND UPDATE DEFINITION
# ============================================================================

$partsJson = ($parts | ForEach-Object {
    '{"path":"' + $_.path + '","payload":"' + $_.payload + '","payloadType":"InlineBase64"}'
}) -join ','

$bodyStr = '{"definition":{"parts":[' + $partsJson + ']}}'
Write-Host "Payload size: $($bodyStr.Length) chars"

try {
    $resp = Invoke-WebRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$OntologyId/updateDefinition" -Method POST -Headers $headers -Body $bodyStr -UseBasicParsing
    Write-Host "Update status: $($resp.StatusCode)"
    if ($resp.StatusCode -eq 200) {
        Write-Host "Ontology updated immediately!"
    } elseif ($resp.StatusCode -eq 202) {
        $opUrl = $resp.Headers["Location"]
        Write-Host "LRO: $opUrl"
        Write-Host "Waiting for completion..."
        $maxWait = 120; $waited = 0
        while ($waited -lt $maxWait) {
            Start-Sleep -Seconds 10
            $waited += 10
            $poll = Invoke-RestMethod -Uri $opUrl -Headers @{ Authorization = "Bearer $FabricToken" }
            if ($poll.status -eq "Succeeded") {
                Write-Host "Result: Succeeded ($waited`s)"
                break
            } elseif ($poll.status -eq "Failed") {
                Write-Host "Result: Failed ($waited`s)"
                if ($poll.error) { Write-Host "Error: $($poll.error.message)" }
                break
            }
            Write-Host "  Status: $($poll.status) ($waited`s)..."
        }
        if ($waited -ge $maxWait -and $poll.status -notin @("Succeeded","Failed")) {
            Write-Host "LRO timed out after $maxWait`s (status: $($poll.status))"
        }
    }
} catch {
    $sr = $_.Exception.Response
    if ($sr) {
        $stream = $sr.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        Write-Host "ERROR $([int]$sr.StatusCode): $($reader.ReadToEnd())"
    } else {
        Write-Host "ERROR: $($_.Exception.Message)"
    }
}
