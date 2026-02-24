# Semantic Model Configuration Guide

This guide details how to create and configure the Power BI semantic model that drives the Oil & Gas Refinery ontology.

> **Automated Deployment**: If you used the `Deploy-OilGasOntology.ps1` script, the semantic model is already created in **TMDL format** (Direct Lake mode, 13 tables, 17 relationships) and you can skip this manual guide. The model definition files are in `deploy/SemanticModel/`.

---

## Step 1: Create the Semantic Model

1. Open the `OilGasRefineryLH` lakehouse in your Fabric workspace.
2. From the lakehouse ribbon, select **New semantic model**.
3. Configure:
   - **Name**: `OilGasRefineryModel`
   - **Workspace**: Your workspace (default)
4. Select **all 13 tables**:
   - `dimrefinery`
   - `dimprocessunit`
   - `dimequipment`
   - `dimpipeline`
   - `dimcrudeoil`
   - `dimrefinedproduct`
   - `dimstoragetank`
   - `dimsensor`
   - `dimemployee`
   - `factmaintenance`
   - `factsafetyalarm`
   - `factproduction`
   - `bridgecrudeoilprocessunit`
5. Click **Confirm**.

---

## Step 2: Define Relationships

Open the semantic model in **Editing mode**. From the ribbon, select **Manage relationships** > **+ New relationship**.

Create the following relationships:

### Core Asset Hierarchy

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter |
|---|---|---|---|---|---|
| `dimprocessunit` | `RefineryId` | `dimrefinery` | `RefineryId` | Many-to-one (*:1) | Single |
| `dimequipment` | `ProcessUnitId` | `dimprocessunit` | `ProcessUnitId` | Many-to-one (*:1) | Single |

### Pipeline Connections

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter | Active |
|---|---|---|---|---|---|---|
| `dimpipeline` | `FromProcessUnitId` | `dimprocessunit` | `ProcessUnitId` | Many-to-one (*:1) | Single | Yes |
| `dimpipeline` | `ToProcessUnitId` | `dimprocessunit` | `ProcessUnitId` | Many-to-one (*:1) | Single | No (inactive) |
| `dimpipeline` | `RefineryId` | `dimrefinery` | `RefineryId` | Many-to-one (*:1) | Single | Yes |

> **Note:** Two relationships from `dimpipeline` reference `dimprocessunit`. Only one can be active. Use DAX `USERELATIONSHIP()` for the inactive one.

### Storage

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter |
|---|---|---|---|---|---|
| `dimstoragetank` | `RefineryId` | `dimrefinery` | `RefineryId` | Many-to-one (*:1) | Single |
| `dimstoragetank` | `ProductId` | `dimrefinedproduct` | `ProductId` | Many-to-one (*:1) | Single |

### Monitoring

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter |
|---|---|---|---|---|---|
| `dimsensor` | `EquipmentId` | `dimequipment` | `EquipmentId` | Many-to-one (*:1) | Single |

### Operations - Maintenance

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter |
|---|---|---|---|---|---|
| `factmaintenance` | `EquipmentId` | `dimequipment` | `EquipmentId` | Many-to-one (*:1) | Single |
| `factmaintenance` | `PerformedByEmployeeId` | `dimemployee` | `EmployeeId` | Many-to-one (*:1) | Single |

### Operations - Safety

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter |
|---|---|---|---|---|---|
| `factsafetyalarm` | `SensorId` | `dimsensor` | `SensorId` | Many-to-one (*:1) | Single |
| `factsafetyalarm` | `AcknowledgedByEmployeeId` | `dimemployee` | `EmployeeId` | Many-to-one (*:1) | Single |

### Operations - Production

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter |
|---|---|---|---|---|---|
| `factproduction` | `ProcessUnitId` | `dimprocessunit` | `ProcessUnitId` | Many-to-one (*:1) | Single |
| `factproduction` | `ProductId` | `dimrefinedproduct` | `ProductId` | Many-to-one (*:1) | Single |

### Operations - Employee

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter |
|---|---|---|---|---|---|
| `dimemployee` | `RefineryId` | `dimrefinery` | `RefineryId` | Many-to-one (*:1) | Single |

### Crude Oil Feed (Bridge Table)

| From Table | From Column | To Table | To Column | Cardinality | Cross-filter |
|---|---|---|---|---|---|
| `bridgecrudeoilprocessunit` | `CrudeOilId` | `dimcrudeoil` | `CrudeOilId` | Many-to-one (*:1) | Single |
| `bridgecrudeoilprocessunit` | `ProcessUnitId` | `dimprocessunit` | `ProcessUnitId` | Many-to-one (*:1) | Single |

**Total: 17 relationships**

---

## Step 3: Relationship Diagram Overview

After creating all relationships, your model diagram should show a **star/snowflake** schema:

```
                            dimcrudeoil
                                |
                    bridgecrudeoilprocessunit
                                |
dimrefinery ←── dimprocessunit ←── factproduction ──→ dimrefinedproduct
    ↑               ↑     ↑                              ↑
    |               |     |                               |
dimemployee    dimpipeline |                        dimstoragetank
    ↑               dimequipment
    |                   ↑     ↑
factsafetyalarm     dimsensor  factmaintenance
(via dimemployee)       ↑
                   factsafetyalarm
```

---

## Step 4: Suggested Measures (Optional)

Add these DAX measures for richer analytics:

### Total Refining Capacity
```dax
Total Refining Capacity = 
SUM(dimrefinery[CapacityBPD])
```

### Total Production Output
```dax
Total Production = 
SUM(factproduction[OutputBarrels])
```

### Average Yield
```dax
Avg Yield Pct = 
AVERAGE(factproduction[YieldPercent])
```

### Total Maintenance Cost
```dax
Total Maintenance Cost = 
SUM(factmaintenance[CostUSD])
```

### Critical Alarm Count
```dax
Critical Alarms = 
CALCULATE(
    COUNTROWS(factsafetyalarm),
    factsafetyalarm[Severity] = "Critical"
)
```

### Tank Utilization
```dax
Avg Tank Utilization = 
DIVIDE(
    SUM(dimstoragetank[CurrentLevelBarrels]),
    SUM(dimstoragetank[CapacityBarrels]),
    0
)
```

### Equipment Availability
```dax
Equipment Availability = 
DIVIDE(
    CALCULATE(COUNTROWS(dimequipment), dimequipment[Status] = "Active"),
    COUNTROWS(dimequipment),
    0
)
```

### Mean Time Between Failures (simplified)
```dax
Avg Maintenance Duration = 
AVERAGE(factmaintenance[DurationHours])
```

---

## Step 5: Verify and Publish

1. **Verify** all relationships show green checkmarks.
2. **Test** by creating a quick visual:
   - Bar chart: `dimrefinery[RefineryName]` vs `factproduction[OutputBarrels]`
   - This validates the relationship chain works end-to-end.
3. The semantic model is now ready to **generate the ontology** (see [SETUP_GUIDE.md](SETUP_GUIDE.md), Step 4).

---

## Data Refresh

The semantic model uses **Direct Lake** mode, reading directly from the lakehouse Delta tables. No scheduled refresh is needed for the initial setup; data updates in the lakehouse tables are reflected automatically after a short sync period.

For the ontology graph, you need to manually **Refresh graph model** in the ontology preview experience after upstream data changes.

---

## TMDL vs BIM Format

The automated deployment uses **TMDL** (Tabular Model Definition Language) format, which is the modern standard for Fabric semantic models. The TMDL files are located in `deploy/SemanticModel/definition/` and include individual `.tmdl` files for each table and relationship.

A legacy `deploy/SemanticModel.bim` file is also provided for reference but is not used by the deployment script.
