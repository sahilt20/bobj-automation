# LCMCLI Command Reference — SAP BI 2025

Complete guide for using the LCMCLI (Lifecycle Management CLI) tool to export and import BOBJ content.

> [!IMPORTANT]
> LCMCLI uses a **properties file** to define all parameters. You pass the properties file path on the command line.
> Direct CLI flags like `-export -cms -user` are **not supported** — all config goes in the `.properties` file.

---

## Tool Location

```
Windows: C:\Program Files (x86)\SAP BusinessObjects\SAP BusinessObjects Enterprise XI 4.0\win64_x64\scripts\lcm\lcm_cli.bat
Linux:   /opt/sap/bobj/enterprise_xi40/linux_x64/scripts/lcm/lcm_cli.sh
```

## Basic Syntax

```bash
lcm_cli.bat -lcmproperty "C:\path\to\my_job.properties"
```

---

## Complete Export → Import Workflow

### Step 1: Create Export Properties File

Create `export.properties`:

```properties
# ===========================
# LCMCLI Export Configuration
# ===========================

# Action: export | promote
action=export

# CMS Connection
LCM_CMS=bobj-dev-cms.example.com:6400
LCM_userName=Administrator
LCM_password=YourPassword123
LCM_authentication=secEnterprise

# Output LCMBIAR file path
exportLocation=C:/exports/dev_export_20260211.lcmbiar

# What to export (CMS query language)
# Export everything from Public Folders
exportQuery1=select * from ci_Infoobjects where si_path like '/Public Folders%'

# Number of queries defined above
maxQueries=1

# Include security rights
exportSecurity=true
```

### Step 2: Run Export

```bash
lcm_cli.bat -lcmproperty "C:\exports\export.properties"
```

**Expected output:**
```
Connecting to CMS: bobj-dev-cms.example.com:6400
Authentication successful
Executing export query 1...
Found 47 objects to export
Exporting objects... 100%
Export completed successfully
LCMBIAR saved to: C:\exports\dev_export_20260211.lcmbiar
```

---

### Step 3: Create Import Properties File

Create `import.properties`:

```properties
# ===========================
# LCMCLI Import Configuration
# ===========================

# Action: promote (used for both import and live-to-live)
action=promote

# Target CMS Connection
Destination_CMS=bobj-qa-cms.example.com:6400
Destination_userName=Administrator
Destination_password=YourPassword123
Destination_authentication=secEnterprise

# Source LCMBIAR file
importLocation=C:/exports/dev_export_20260211.lcmbiar
```

### Step 4: Run Import

```bash
lcm_cli.bat -lcmproperty "C:\exports\import.properties"
```

---

## All Properties Reference

### Connection & Auth

| Property                     | Description                   | Example         |
| ---------------------------- | ----------------------------- | --------------- |
| `LCM_CMS`                    | CMS server:port (for export)  | `bobj-cms:6400` |
| `LCM_userName`               | Username (for export)         | `Administrator` |
| `LCM_password`               | Password (for export)         | `MyP@ss`        |
| `LCM_authentication`         | Auth type (for export)        | `secEnterprise` |
| `Source_CMS`                 | Source CMS (live-to-live)     | `dev-cms:6400`  |
| `Source_userName`            | Source user (live-to-live)    | `admin`         |
| `Source_password`            | Source pass (live-to-live)    | `pass`          |
| `Source_authentication`      | Source auth (live-to-live)    | `secEnterprise` |
| `Destination_CMS`            | Target CMS (import/promote)   | `qa-cms:6400`   |
| `Destination_userName`       | Target user                   | `admin`         |
| `Destination_password`       | Target pass                   | `pass`          |
| `Destination_authentication` | Target auth                   | `secEnterprise` |
| `LCM_systemID`               | SAP System ID (SAP auth only) | `SID`           |
| `LCM_clientID`               | SAP Client ID (SAP auth only) | `100`           |

### Export Parameters

| Property          | Description                | Example                 |
| ----------------- | -------------------------- | ----------------------- |
| `action`          | Must be `export`           | `export`                |
| `exportLocation`  | Output LCMBIAR path        | `C:/out/export.lcmbiar` |
| `exportQuery1..N` | CMS query for objects      | see examples below      |
| `maxQueries`      | Number of queries          | `3`                     |
| `exportSecurity`  | Include security           | `true` / `false`        |
| `lcmbiarpassword` | Encrypt LCMBIAR file       | `MyEncryptPass`         |
| `jobCUID`         | Export from saved job CUID | `AaBbCcDd...`           |

### Import/Promote Parameters

| Property          | Description         | Example                |
| ----------------- | ------------------- | ---------------------- |
| `action`          | Must be `promote`   | `promote`              |
| `importLocation`  | Source LCMBIAR path | `C:/in/export.lcmbiar` |
| `lcmbiarpassword` | Decrypt password    | `MyEncryptPass`        |

### Debug/Logging

| Property | Description          | Example |
| -------- | -------------------- | ------- |
| `trace`  | Enable trace logging | `true`  |
| `log`    | Show full log output | `true`  |

---

## Export Query Examples

### Export All Reports from Public Folders
```properties
exportQuery1=select * from ci_Infoobjects where si_path like '/Public Folders%'
maxQueries=1
```

### Export Only Web Intelligence Documents
```properties
exportQuery1=select * from ci_Infoobjects where si_kind='Webi'
maxQueries=1
```

### Export Only Crystal Reports
```properties
exportQuery1=select * from ci_Infoobjects where si_kind='CrystalReport'
maxQueries=1
```

### Export Specific Folder
```properties
exportQuery1=select * from ci_Infoobjects where si_path='/Public Folders/Finance Reports'
maxQueries=1
```

### Export Universes + Reports (Multiple Queries)
```properties
exportQuery1=select * from ci_Infoobjects where si_kind='Webi' and si_path like '/Public Folders%'
exportQuery2=select * from ci_Infoobjects where si_kind='Universe'
exportQuery3=select * from ci_Infoobjects where si_kind='Connection'
maxQueries=3
```

### Export Variants
```properties
exportQuery1=select top 10000 * from ci_appobjects where si_kind='BIVariant'
maxQueries=1
```

### Export by CUID (Specific Object)
```properties
exportQuery1=select * from ci_Infoobjects where si_cuid='Aa1Bb2Cc3Dd4Ee5Ff6'
maxQueries=1
```

---

## Live-to-Live Promotion (No LCMBIAR File)

Migrate directly between two BOBJ systems without creating an intermediate file:

```properties
# Direct Dev → QA promotion
action=promote

# Source system
Source_CMS=bobj-dev-cms:6400
Source_userName=Administrator
Source_password=DevPass123
Source_authentication=secEnterprise

# Target system
Destination_CMS=bobj-qa-cms:6400
Destination_userName=Administrator
Destination_password=QAPass123
Destination_authentication=secEnterprise

# What to promote (uses source system queries)
exportQuery1=select * from ci_Infoobjects where si_path like '/Public Folders/Finance%'
maxQueries=1
```

```bash
lcm_cli.bat -lcmproperty "C:\promote\dev_to_qa.properties"
```

---

## Full End-to-End Example (Dev → QA → Prod)

### 1. Export from Dev
```bash
# File: export_dev.properties
# action=export
# LCM_CMS=bobj-dev:6400 ...
lcm_cli.bat -lcmproperty "C:\lcm\export_dev.properties"
```

### 2. Import to QA
```bash
# File: import_qa.properties
# action=promote
# Destination_CMS=bobj-qa:6400
# importLocation=C:/lcm/dev_export.lcmbiar
lcm_cli.bat -lcmproperty "C:\lcm\import_qa.properties"
```

### 3. Backup Prod (Before Deploy)
```bash
# File: backup_prod.properties
# action=export
# LCM_CMS=bobj-prod:6400
# exportLocation=C:/lcm/backups/prod_backup.lcmbiar
lcm_cli.bat -lcmproperty "C:\lcm\backup_prod.properties"
```

### 4. Import to Prod
```bash
# File: import_prod.properties
# action=promote
# Destination_CMS=bobj-prod:6400
# importLocation=C:/lcm/dev_export.lcmbiar
lcm_cli.bat -lcmproperty "C:\lcm\import_prod.properties"
```

### 5. Rollback (If Needed)
```bash
# File: rollback_prod.properties
# action=promote
# Destination_CMS=bobj-prod:6400
# importLocation=C:/lcm/backups/prod_backup.lcmbiar
lcm_cli.bat -lcmproperty "C:\lcm\rollback_prod.properties"
```

---

## Troubleshooting

| Error                   | Fix                                                        |
| ----------------------- | ---------------------------------------------------------- |
| `OutOfMemoryError`      | Increase heap: edit `lcm_cli.bat`, set `-Xmx8g`            |
| `Authentication failed` | Check `LCM_authentication` type matches CMC config         |
| `CMS not reachable`     | Verify `telnet <cms-host> 6400` works                      |
| `No objects found`      | Check your `exportQuery` syntax in CMC Query Builder first |
| `LCMBIAR file corrupt`  | Re-export; check disk space on source server               |
