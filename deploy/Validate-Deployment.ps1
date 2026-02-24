<#
.SYNOPSIS
    Validates that the Oil & Gas Refinery Ontology deployment completed successfully.

.DESCRIPTION
    Checks that all expected Fabric items exist in the target workspace:
    - Lakehouse with tables
    - Eventhouse
    - Semantic model
    - Ontology item

.PARAMETER WorkspaceId
    The GUID of the Fabric workspace to validate.

.EXAMPLE
    .\Validate-Deployment.ps1 -WorkspaceId "your-workspace-guid"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [string]$LakehouseName = "OilGasRefineryLH",
    [string]$EventhouseName = "RefineryTelemetryEH",
    [string]$SemanticModelName = "OilGasRefineryModel",
    [string]$OntologyName = "OilGasRefineryOntology"
)

$FabricApiBase = "https://api.fabric.microsoft.com/v1"

# ── Authenticate ──
$account = Get-AzContext
if (-not $account) {
    Write-Host "No active Azure session. Run 'Connect-AzAccount' first." -ForegroundColor Red
    exit 1
}

$tokenObj = Get-AzAccessToken -AsSecureString -ResourceUrl "https://api.fabric.microsoft.com"
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

$headers = @{ "Authorization" = "Bearer $token" }

function Check-Item {
    param([string]$ItemType, [string]$Endpoint, [string]$ExpectedName)
    
    try {
        $response = Invoke-RestMethod -Method Get -Uri "$FabricApiBase/workspaces/$WorkspaceId/$Endpoint" -Headers $headers
        $found = $response.value | Where-Object { $_.displayName -eq $ExpectedName }
        if ($found) {
            Write-Host "  [PASS] $ItemType '$ExpectedName' exists (ID: $($found.id))" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "  [FAIL] $ItemType '$ExpectedName' NOT found" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "  [WARN] Could not query $Endpoint : $_" -ForegroundColor Yellow
        return $false
    }
}

# ── Validation ──
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Deployment Validation - Oil & Gas Ontology" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Workspace: $WorkspaceId" -ForegroundColor Gray
Write-Host ""

$results = @()
$results += Check-Item "Lakehouse"      "lakehouses"     $LakehouseName
$results += Check-Item "Eventhouse"     "eventhouses"    $EventhouseName
$results += Check-Item "Semantic Model" "semanticModels" $SemanticModelName

# Check ontology via generic items endpoint (ontology-specific API may not exist yet)
try {
    $allItems = Invoke-RestMethod -Method Get -Uri "$FabricApiBase/workspaces/$WorkspaceId/items" -Headers $headers
    $ontology = $allItems.value | Where-Object { $_.displayName -eq $OntologyName }
    if ($ontology) {
        Write-Host "  [PASS] Ontology '$OntologyName' exists (ID: $($ontology.id), Type: $($ontology.type))" -ForegroundColor Green
        $results += $true
    }
    else {
        Write-Host "  [FAIL] Ontology '$OntologyName' NOT found" -ForegroundColor Red
        $results += $false
    }
}
catch {
    Write-Host "  [WARN] Could not query workspace items: $_" -ForegroundColor Yellow
    $results += $false
}

# ── Check Lakehouse Tables ──
Write-Host ""
Write-Host "  Checking Lakehouse Tables..." -ForegroundColor Cyan

$expectedTables = @(
    "dimrefinery", "dimprocessunit", "dimequipment", "dimpipeline",
    "dimcrudeoil", "dimrefinedproduct", "dimstoragetank", "dimsensor",
    "dimemployee", "factmaintenance", "factsafetyalarm", "factproduction",
    "bridgecrudeoilprocessunit"
)

try {
    $lakehouses = Invoke-RestMethod -Method Get -Uri "$FabricApiBase/workspaces/$WorkspaceId/lakehouses" -Headers $headers
    $lh = $lakehouses.value | Where-Object { $_.displayName -eq $LakehouseName } | Select-Object -First 1
    if ($lh) {
        $tables = Invoke-RestMethod -Method Get `
            -Uri "$FabricApiBase/workspaces/$WorkspaceId/lakehouses/$($lh.id)/tables" `
            -Headers $headers
        
        $tableNames = $tables.value | ForEach-Object { $_.name }
        $tableCount = 0
        foreach ($t in $expectedTables) {
            if ($tableNames -contains $t) {
                Write-Host "    [PASS] Table '$t'" -ForegroundColor Green
                $tableCount++
            }
            else {
                Write-Host "    [FAIL] Table '$t' missing" -ForegroundColor Red
            }
        }
        Write-Host ""
        Write-Host "  Tables: $tableCount / $($expectedTables.Count) present" -ForegroundColor $(if ($tableCount -eq $expectedTables.Count) { "Green" } else { "Yellow" })
    }
}
catch {
    Write-Host "  [WARN] Could not list lakehouse tables: $_" -ForegroundColor Yellow
    Write-Host "  Tables can only be verified after the notebook has been executed." -ForegroundColor Gray
}

# ── Summary ──
$passCount = ($results | Where-Object { $_ -eq $true }).Count
$totalCount = $results.Count

Write-Host ""
Write-Host "=============================================" -ForegroundColor $(if ($passCount -eq $totalCount) { "Green" } else { "Yellow" })
Write-Host "  Result: $passCount / $totalCount items validated" -ForegroundColor $(if ($passCount -eq $totalCount) { "Green" } else { "Yellow" })
Write-Host "=============================================" -ForegroundColor $(if ($passCount -eq $totalCount) { "Green" } else { "Yellow" })
Write-Host ""

if ($passCount -lt $totalCount) {
    Write-Host "  Some items are missing. Check the logs above and refer to SETUP_GUIDE.md" -ForegroundColor Yellow
    Write-Host "  for manual steps to complete the deployment." -ForegroundColor Yellow
    Write-Host ""
}
