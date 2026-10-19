<#
.SYNOPSIS
    ODS Dataverse to SQL Sync - a free tool from Org Data Solutions.
    Copies Dataverse / Dynamics 365 tables into a SQL Server or Azure SQL
    database you own, and keeps them up to date incrementally.

.DESCRIPTION
    Features:
    1. Prefix-based table discovery (sync every table matching prefixes such
       as new_ or cr123_), plus explicitly listed tables.
    2. Friendly-name SQL views (vw_<table>) built from Dataverse metadata.
    3. Data dictionary tables: ods_datadictionary_tables, _columns and
       _relationships.
    4. ExcludeTables config: skip specific tables by logical name.
    5. Parallel sync: up to N tables at once (default 5) via PowerShell runspaces.
    6. Optional soft-delete reconcile pass (-ReconcileDeletes, or bundled with
       a refresh via -IncludeReconcile).
    7. Entity-set names and primary keys read from Dataverse metadata, so
       irregular plurals and non-standard keys sync correctly.
    8. Manual overrides: -Table (only these tables, then a source-vs-target
       row-count check), -FullLoad (ignore the watermark), -Force (bypass the
       single-instance guard).

    Data flows from your Dataverse environment to your SQL database only.
    Nothing is sent to Org Data Solutions.

    Requirements: PowerShell 7.2 or later, an Entra ID app registration that
    is an Application User on the environment, and a SQL login that can
    create tables in the target database. Copy config.example.xml to
    config.xml next to this script and fill it in. The sql\ folder holds the
    optional ops-schema scripts (run logs, SQL-backed watermarks, soft-delete
    columns). See README.md.

.EXAMPLE
    .\Sync-DataverseToSql.ps1 -TestConnection
        Check the Dataverse and SQL connections, then exit.

.EXAMPLE
    .\Sync-DataverseToSql.ps1
        Incremental data sync (schedule hourly).

.EXAMPLE
    .\Sync-DataverseToSql.ps1 -Mode Refresh
        Data sync plus data dictionary and friendly views (schedule daily).

.EXAMPLE
    .\Sync-DataverseToSql.ps1 -Mode Refresh -IncludeReconcile
        Daily refresh, then the soft-delete reconcile pass, in one scheduled task.

.EXAMPLE
    .\Sync-DataverseToSql.ps1 -ReconcileDeletes -DryRun
        Show which rows have disappeared from Dataverse, without changing SQL.

.EXAMPLE
    .\Sync-DataverseToSql.ps1 -Table contact -FullLoad
        Reload one table in full, then compare Dataverse and SQL row counts
        for it. Add -Force only when the single-instance lock is held by a run
        you know is not touching that table.

.NOTES
    Copyright (c) 2026 Org Data Solutions. MIT License (see LICENSE).
#>
#Requires -Version 7.2

# =============================================================================
# Note on parameter typing
# =============================================================================
# Standalone helper functions in this script (Resolve-TableList,
# Build-DataDictionary, Build-FriendlyViews, Invoke-ReconcileDeletes) accept
# their connector/logger arguments as plain $name with no class-type
# annotation, even though they expect SQLConnector / DataverseConnector /
# SyncLogger / OpsRunLog instances.
#
# Why: PowerShell class types are scoped to their parse session. When this
# script is run multiple times in the same PowerShell session (especially
# during dev -- failed param attempts that partially parse, then a retry that
# re-parses), the runtime ends up with two SQLConnector types with the same
# name but distinct identity. A function with `[SQLConnector]$SQL` captures
# one identity at parse time; an instance constructed in a later parse has
# the other identity. PowerShell then fails with the unhelpful error:
#     "Cannot convert SQLConnector to SQLConnector".
# Untyped parameters sidestep this -- method dispatch on the object is
# duck-typed and doesn't care about class identity.
#
# Class methods *inside* class bodies (e.g. SQLConnector.BulkUpsert with its
# [SyncLogger]$logger parameter) are unaffected -- they parse atomically with
# the class definition, so the captured identity always matches.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = "$PSScriptRoot\config.xml",

    [Parameter(Mandatory=$false)]
    [switch]$TestConnection,

    # Sync       -- data only (hourly).
    # Refresh    -- data + dictionary + views (daily).
    # DictionaryOnly -- dictionary + views; skip the data sync. For after a
    #                  CRM schema deployment when you want fresh metadata
    #                  without re-running the data load.
    [Parameter(Mandatory=$false)]
    [ValidateSet('Sync', 'Refresh', 'DictionaryOnly')]
    [string]$Mode = 'Sync',

    # When set, runs the soft-delete reconcile pass instead of the sync.
    # Each replica table's PKs are compared against Dataverse; rows missing
    # in Dataverse are marked is_active=0; rows that have reappeared are
    # marked is_active=1. No physical deletes. Schedule daily, separate
    # window from the hourly sync.
    [Parameter(Mandatory=$false)]
    [switch]$ReconcileDeletes,

    # Reconcile-only: prints what would change without writing.
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    # Reconcile-only: safety threshold. If more than this fraction of a
    # table's active rows would be flagged as missing in a single pass,
    # that table is skipped and routed to ops.review_queue. 0.75 default
    # (raised from 0.5 after first real run had 4 false positives on
    # legitimately high-churn replicas).
    [Parameter(Mandatory=$false)]
    [double]$MaxMissingPct = 0.75,

    # Reconcile-only: the percentage threshold is only applied to tables
    # with at least this many active rows. Below this floor, the percentage
    # is meaningless (3 of 4 missing = 75% but no real risk).
    [Parameter(Mandatory=$false)]
    [int]$MinRowCountForThreshold = 10,

    # When set with -Mode Refresh (or Sync/DictionaryOnly), runs the
    # reconcile-deletes pass after the main work completes. Bundles two
    # daily jobs into one task. The reconcile runs as its own runlog row
    # (pipeline = CRMReconcileDeletes) so failures don't taint the
    # Refresh status. Ignored when -ReconcileDeletes is also set
    # (-ReconcileDeletes is the standalone-mode override).
    [Parameter(Mandatory=$false)]
    [switch]$IncludeReconcile,

    # Manual override: restrict the run to one or more logical names, ignoring
    # config/prefix/syncAll discovery. e.g. -Table product  (or -Table product,contact).
    # Names are Dataverse *logical* names (singular: product, not products).
    [Parameter(Mandatory=$false)]
    [string[]]$Table,

    # Manual override: ignore the saved watermark and re-fetch every record for
    # the tables in this run (a complete reload). The watermark still advances
    # afterward, so the next scheduled run resumes incremental. Pair with -Table
    # for a targeted single-table full sync.
    [Parameter(Mandatory=$false)]
    [switch]$FullLoad,

    # Manual override: bypass the single-instance mutex. Use for a targeted
    # manual run when a scheduled instance (often running as another account,
    # which makes the Global mutex un-openable -> "Access denied") holds the
    # lock. Only safe when you know the manual run won't collide with the
    # in-flight run on the same tables.
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# Strict Mode 2.0 catches typos but requires safe property access
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# Shared bulk upsert / schema-evolve helpers. Same module is imported by each
# parallel runspace so both call paths share one implementation.
$script:OdsModulePath = Join-Path $PSScriptRoot "Modules\Ods.SqlUpsert.psm1"
Import-Module $script:OdsModulePath -Force

# ==============================================================================
# REGION: SINGLE-INSTANCE GUARD
# ==============================================================================
# Several schedules usually invoke this script: a frequent incremental sync
# (e.g. hourly) and a daily -Mode Refresh. They share one watermark store
# (ops.crm_sync_watermark / state.json) and the same target tables, so two
# concurrent runs can race the watermark and deadlock the MERGEs. A global mutex
# ensures only one Sync-DataverseToSql runs at a time; a second run logs and
# skips this cycle (the in-flight run, or the next scheduled run, covers the data).
# Connectivity tests (-TestConnection) are exempt. We never call ReleaseMutex:
# the mutex is released when this pwsh process exits, and the next run treats the
# resulting AbandonedMutexException as a normal hand-off.
$script:OdsRunMutex = $null
if (-not $TestConnection -and -not $Force) {
    try {
        $script:OdsRunMutex = [System.Threading.Mutex]::new($false, 'Global\ODS-DataverseToSql-SingleInstance')
        $haveLock = $false
        try {
            $haveLock = $script:OdsRunMutex.WaitOne([TimeSpan]::Zero)
        } catch [System.Threading.AbandonedMutexException] {
            $haveLock = $true
        }
        if (-not $haveLock) {
            Write-Host "Another Sync-DataverseToSql instance is already running; skipping this run." -ForegroundColor Yellow
            exit 0
        }
    } catch [System.UnauthorizedAccessException] {
        # The Global mutex exists but was created by another account (e.g. a
        # scheduled task running as SYSTEM), so this session cannot open it.
        # That almost always means an instance is already running. Skip rather
        # than crash; the operator can override with -Force when they know it's
        # safe (e.g. a targeted single-table manual run).
        Write-Host "Single-instance mutex is owned by another account (Access denied) -- another instance is likely running. Skipping. Re-run with -Force to override." -ForegroundColor Yellow
        exit 0
    }
}
elseif ($Force -and -not $TestConnection) {
    Write-Host "-Force specified: bypassing single-instance guard." -ForegroundColor Yellow
}

# ==============================================================================
# REGION: CLASSES
# ==============================================================================

class SyncLogger {
    [string]$LogPath
    [string]$BaseLogDir
    [string]$TableName

    SyncLogger([string]$path) { 
        $this.LogPath = [System.IO.Path]::GetFullPath($path)
        $this.BaseLogDir = Split-Path -Parent $this.LogPath
        $this.TableName = ""
        if (-not (Test-Path $this.BaseLogDir)) { New-Item -ItemType Directory -Path $this.BaseLogDir -Force | Out-Null }
    }
    
    [void]Log([string]$message, [string]$level) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $tag = if ($this.TableName) { " [$($this.TableName)]" } else { "" }
        $entry = "$timestamp | $($level.PadRight(7)) |$tag $message"
        
        $color = switch ($level) {
            "ERROR"   { "Red" }
            "WARN"    { "Yellow" }
            "SUCCESS" { "Green" }
            default   { "Cyan" }
        }
        Write-Host "[$level]$tag $message" -ForegroundColor $color

        try {
            $entry | Out-File -FilePath $this.LogPath -Append -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
    }

    [void]Info([string]$msg) { $this.Log($msg, "INFO") }
    [void]Warn([string]$msg) { $this.Log($msg, "WARN") }
    [void]Error([string]$msg) { $this.Log($msg, "ERROR") }
    [void]Success([string]$msg) { $this.Log($msg, "SUCCESS") }

    # Per-table logger: writes to logs\tables\<tableName>.log (flat directory)
    [SyncLogger]ForTable([string]$tableName) {
        $tableLogDir = Join-Path $this.BaseLogDir "tables"
        if (-not (Test-Path $tableLogDir)) { New-Item -ItemType Directory -Path $tableLogDir -Force | Out-Null }
        $tableLogPath = Join-Path $tableLogDir "$tableName.log"
        $tableLogger = [SyncLogger]::new($tableLogPath)
        $tableLogger.TableName = $tableName
        return $tableLogger
    }
}

class StateManager {
    [string]$StatePath
    [hashtable]$State

    StateManager([string]$path) {
        $this.StatePath = [System.IO.Path]::GetFullPath($path)
        $dir = Split-Path -Parent $this.StatePath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        
        if (Test-Path $this.StatePath) {
            try { $this.State = Get-Content $this.StatePath -Raw | ConvertFrom-Json -AsHashtable }
            catch { $this.State = @{} }
        } else {
            $this.State = @{}
        }
    }

    [datetime]GetLastSync([string]$entity) {
        if ($this.State.ContainsKey($entity)) { 
            try { return [datetime]$this.State[$entity] } catch {}
        }
        return [datetime]::MinValue
    }

    [void]SetLastSync([string]$entity, [datetime]$time) {
        $this.State[$entity] = $time.ToString("o")
        try {
            $this.State | ConvertTo-Json -Depth 5 | Set-Content $this.StatePath -Encoding UTF8
        } catch { Write-Warning "Failed to save state file: $_" }
    }
}

class WatermarkStore {
    # Reads/writes per-entity incremental-sync watermarks in ops.crm_sync_watermark.
    # JSON file (StatePath) is consulted only when SQL has no row for the entity
    # yet -- i.e. as a one-time bootstrap source. SQL is otherwise the only
    # source of truth.
    [string]$ConnString
    [string]$JsonFallbackPath
    [bool]$SqlAvailable

    WatermarkStore([string]$cs, [string]$jsonFallbackPath) {
        $this.ConnString = $cs
        $this.JsonFallbackPath = $jsonFallbackPath
        $this.SqlAvailable = $this.TestSql()
        if (-not $this.SqlAvailable) {
            Write-Warning "WatermarkStore: ops.crm_sync_watermark not found; falling back to JSON file. Run sql\0001_ops_schema.sql to enable SQL-backed watermarks."
        }
    }

    hidden [bool]TestSql() {
        try {
            $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnString)
            $conn.Open()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT OBJECT_ID('ops.crm_sync_watermark', 'U')"
                $r = $cmd.ExecuteScalar()
                return ($null -ne $r) -and ($r -isnot [System.DBNull])
            } finally { $conn.Dispose() }
        } catch { return $false }
    }

    # One-time bootstrap: insert each entity from the JSON file into SQL,
    # skipping any that are already present. Returns the number of rows
    # actually inserted (so the operator sees the migration progress).
    [int]BootstrapFromJson() {
        if (-not $this.SqlAvailable) { return 0 }
        if (-not (Test-Path $this.JsonFallbackPath)) { return 0 }

        $data = $null
        try {
            $data = Get-Content $this.JsonFallbackPath -Raw | ConvertFrom-Json -AsHashtable
        } catch { return 0 }
        if (-not $data -or $data.Count -eq 0) { return 0 }

        $migrated = 0
        try {
            $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnString)
            $conn.Open()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM ops.crm_sync_watermark WHERE logical_name = @e)
    INSERT INTO ops.crm_sync_watermark (logical_name, last_modified_utc, run_id, updated_utc)
    VALUES (@e, @t, NULL, SYSUTCDATETIME());
"@
                foreach ($k in $data.Keys) {
                    try {
                        $cmd.Parameters.Clear()
                        $cmd.Parameters.AddWithValue("@e", $k) | Out-Null
                        $cmd.Parameters.AddWithValue("@t", [datetime]$data[$k]) | Out-Null
                        $rows = $cmd.ExecuteNonQuery()
                        if ($rows -gt 0) { $migrated++ }
                    } catch {
                        Write-Warning "WatermarkStore.BootstrapFromJson($k): $($_.Exception.Message)"
                    }
                }
            } finally { $conn.Dispose() }
        } catch {
            Write-Warning "WatermarkStore.BootstrapFromJson: $($_.Exception.Message)"
        }
        return $migrated
    }

    [datetime]Get([string]$entity) {
        if ($this.SqlAvailable) {
            try {
                $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnString)
                $conn.Open()
                try {
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = "SELECT last_modified_utc FROM ops.crm_sync_watermark WHERE logical_name = @e"
                    $cmd.Parameters.AddWithValue("@e", $entity) | Out-Null
                    $r = $cmd.ExecuteScalar()
                    if (($null -ne $r) -and ($r -isnot [System.DBNull])) {
                        return [datetime]$r
                    }
                } finally { $conn.Dispose() }
            } catch {}
        }
        return $this.GetFromJson($entity)
    }

    hidden [datetime]GetFromJson([string]$entity) {
        if (-not (Test-Path $this.JsonFallbackPath)) { return [datetime]::MinValue }
        try {
            $data = Get-Content $this.JsonFallbackPath -Raw | ConvertFrom-Json -AsHashtable
            if ($data.ContainsKey($entity)) { return [datetime]$data[$entity] }
        } catch {}
        return [datetime]::MinValue
    }

    [void]Set([string]$entity, [datetime]$time, [long]$runId) {
        if (-not $this.SqlAvailable) {
            Write-Warning "WatermarkStore.Set($entity): SQL unavailable; watermark NOT advanced. Next run will re-fetch since the JSON snapshot date."
            return
        }
        try {
            $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnString)
            $conn.Open()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
MERGE ops.crm_sync_watermark AS T
USING (SELECT @e AS logical_name) AS S ON T.logical_name = S.logical_name
WHEN MATCHED THEN
    UPDATE SET last_modified_utc = @t, run_id = @run_id, updated_utc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (logical_name, last_modified_utc, run_id, updated_utc)
    VALUES (@e, @t, @run_id, SYSUTCDATETIME());
"@
                $cmd.Parameters.AddWithValue("@e", $entity) | Out-Null
                $cmd.Parameters.AddWithValue("@t", $time) | Out-Null
                if ($runId -le 0) {
                    $cmd.Parameters.AddWithValue("@run_id", [DBNull]::Value) | Out-Null
                } else {
                    $cmd.Parameters.AddWithValue("@run_id", $runId) | Out-Null
                }
                $cmd.ExecuteNonQuery() | Out-Null
            } finally { $conn.Dispose() }
        } catch {
            Write-Warning "WatermarkStore.Set($entity): $($_.Exception.Message)"
        }
    }
}

class OpsRunLog {
    # Writes pipeline observability to ops.runlog / ops.run_table_log.
    # Fails open -- if the ops.* tables don't exist (sql\0001_ops_schema.sql not run),
    # the sync continues without logging.
    [string]$ConnString
    [string]$Pipeline
    [long]$RunId        # 0 = unset
    [bool]$Enabled

    OpsRunLog([string]$cs, [string]$pipeline) {
        $this.ConnString = $cs
        $this.Pipeline = $pipeline
        $this.RunId = 0
        $this.Enabled = $true
    }

    [void]Start([string]$notes) {
        if (-not $this.Enabled) { return }
        try {
            $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnString)
            $conn.Open()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
INSERT INTO ops.runlog (pipeline, host_name, status, notes)
VALUES (@pipeline, @host, 'running', @notes);
SELECT CAST(SCOPE_IDENTITY() AS BIGINT);
"@
                $cmd.Parameters.AddWithValue("@pipeline", $this.Pipeline) | Out-Null
                $cmd.Parameters.AddWithValue("@host", [Environment]::MachineName) | Out-Null
                if ([string]::IsNullOrWhiteSpace($notes)) {
                    $cmd.Parameters.AddWithValue("@notes", [DBNull]::Value) | Out-Null
                } else {
                    $cmd.Parameters.AddWithValue("@notes", $notes) | Out-Null
                }
                $id = $cmd.ExecuteScalar()
                $this.RunId = [long]$id
            }
            finally { $conn.Dispose() }
        } catch {
            $this.Enabled = $false
            Write-Warning "OpsRunLog: could not open ops.runlog ($($_.Exception.Message)). Continuing without run logging."
        }
    }

    [void]LogTable([string]$tableName, [string]$action, [long]$rows, [int]$durationMs, [string]$status, [string]$errorMsg) {
        if (-not $this.Enabled -or $this.RunId -eq 0) { return }
        try {
            $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnString)
            $conn.Open()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
INSERT INTO ops.run_table_log (run_id, table_name, action, rows, duration_ms, status, error_msg)
VALUES (@run_id, @table, @action, @rows, @ms, @status, @err);
"@
                $cmd.Parameters.AddWithValue("@run_id", $this.RunId) | Out-Null
                $cmd.Parameters.AddWithValue("@table", $tableName) | Out-Null
                $cmd.Parameters.AddWithValue("@action", $action) | Out-Null
                $cmd.Parameters.AddWithValue("@rows", $rows) | Out-Null
                $cmd.Parameters.AddWithValue("@ms", $durationMs) | Out-Null
                $cmd.Parameters.AddWithValue("@status", $status) | Out-Null
                if ([string]::IsNullOrWhiteSpace($errorMsg)) {
                    $cmd.Parameters.AddWithValue("@err", [DBNull]::Value) | Out-Null
                } else {
                    # truncate to keep error messages reasonable
                    $msg = if ($errorMsg.Length -gt 4000) { $errorMsg.Substring(0, 4000) } else { $errorMsg }
                    $cmd.Parameters.AddWithValue("@err", $msg) | Out-Null
                }
                $cmd.ExecuteNonQuery() | Out-Null
            }
            finally { $conn.Dispose() }
        } catch {
            Write-Warning "OpsRunLog.LogTable($tableName): $($_.Exception.Message)"
        }
    }

    [void]Complete([string]$status, [long]$rowsIn, [long]$rowsOut, [long]$rowsError) {
        if (-not $this.Enabled -or $this.RunId -eq 0) { return }
        try {
            $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnString)
            $conn.Open()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
UPDATE ops.runlog
   SET ended_utc  = SYSUTCDATETIME(),
       status     = @status,
       rows_in    = @ri,
       rows_out   = @ro,
       rows_error = @re
 WHERE run_id = @id;
"@
                $cmd.Parameters.AddWithValue("@status", $status) | Out-Null
                $cmd.Parameters.AddWithValue("@ri", $rowsIn) | Out-Null
                $cmd.Parameters.AddWithValue("@ro", $rowsOut) | Out-Null
                $cmd.Parameters.AddWithValue("@re", $rowsError) | Out-Null
                $cmd.Parameters.AddWithValue("@id", $this.RunId) | Out-Null
                $cmd.ExecuteNonQuery() | Out-Null
            }
            finally { $conn.Dispose() }
        } catch {
            Write-Warning "OpsRunLog.Complete: $($_.Exception.Message)"
        }
    }
}

class DataverseConnector {
    [string]$EnvironmentUrl
    [hashtable]$Headers
    [int]$PageSize
    [string]$ClientId
    [string]$TenantId
    [string]$ClientSecret

    DataverseConnector([string]$url, [int]$pageSize, [string]$cId, [string]$tId, [string]$secret) {
        $this.EnvironmentUrl = $url.TrimEnd('/') + "/"
        $this.PageSize = $pageSize
        $this.ClientId = $cId
        $this.TenantId = $tId
        $this.ClientSecret = $secret
        $this.Authenticate()
    }

    [void]Authenticate() {
        $useInteractive = [string]::IsNullOrWhiteSpace($this.ClientSecret) -or $this.ClientSecret -eq "INTERACTIVE"
        $token = $null

        if (-not $useInteractive) {
            $authUrl = "https://login.microsoftonline.com/$($this.TenantId)/oauth2/v2.0/token"
            $scope = $this.EnvironmentUrl + ".default"
            $body = @{
                client_id     = $this.ClientId
                client_secret = $this.ClientSecret
                scope         = $scope
                grant_type    = "client_credentials"
            }
            $response = Invoke-RestMethod -Uri $authUrl -Method Post -Body $body -ErrorAction Stop
            $token = $response.access_token
        }
        else {
            if (-not (Get-Module -Name Az.Accounts)) { Import-Module Az.Accounts -ErrorAction Stop }
            $context = Get-AzContext
            if (-not $context) { $context = Connect-AzAccount }
            $tokenObj = Get-AzAccessToken -ResourceUrl $this.EnvironmentUrl
            $token = $tokenObj.Token
        }

        if ([string]::IsNullOrWhiteSpace($token)) { throw "Failed to acquire Access Token." }

        $this.Headers = @{
            Authorization        = "Bearer $token"
            Accept               = "application/json"
            "OData-MaxVersion"   = "4.0"
            "OData-Version"      = "4.0"
            Prefer               = "odata.maxpagesize=$($this.PageSize)"
            "User-Agent"         = "DataverseSqlSync/3.0"
        }
    }

    hidden [PSObject]InvokeApiCall([string]$url) {
        $maxRetries = 5
        $retryCount = 0
        $baseWaitSeconds = 2

        do {
            try {
                return Invoke-RestMethod -Uri $url -Headers $this.Headers -Method Get -ErrorAction Stop
            }
            catch {
                $statusCode = 0
                if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
                
                if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)) {
                    $retryCount++
                    if ($retryCount -gt $maxRetries) { throw $_ }
                    
                    $wait = ($baseWaitSeconds * [Math]::Pow(2, $retryCount)) + (Get-Random -Minimum 0 -Maximum 1000) / 1000
                    if ($_.Exception.Response.Headers["Retry-After"]) {
                        $headerWait = [int]$_.Exception.Response.Headers["Retry-After"].Value
                        if ($headerWait -gt $wait) { $wait = $headerWait }
                    }

                    Write-Host " [API Throttled/Error ($statusCode)]. Retrying in $($wait.ToString('N1'))s..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $wait
                }
                else {
                    throw $_ 
                }
            }
        } while ($retryCount -le $maxRetries)
        return $null
    }

    # Fetch only the lookup attributes for an entity, with their Targets
    # (i.e. which entity logical name(s) each lookup points to). Used to
    # populate ods_datadictionary_relationships and the is_lookup flag.
    # Cast to LookupAttributeMetadata so $select=Targets is legal.
    [System.Collections.Generic.List[PSObject]]FetchLookupAttributes([string]$entityName) {
        $records = [System.Collections.Generic.List[PSObject]]::new()
        $url = "$($this.EnvironmentUrl)api/data/v9.2/EntityDefinitions(LogicalName='$entityName')/Attributes/Microsoft.Dynamics.CRM.LookupAttributeMetadata?`$select=LogicalName,SchemaName,Targets"

        do {
            try {
                $response = $this.InvokeApiCall($url)
            } catch {
                Write-Warning "FetchLookupAttributes($entityName): $($_.Exception.Message)"
                return $records
            }
            if ($response.value) {
                foreach ($a in $response.value) {
                    $records.Add([PSCustomObject]@{
                        LogicalName = $a.LogicalName
                        SchemaName  = $a.SchemaName
                        Targets     = $a.Targets
                    })
                }
            }
            $url = $null
            if ($response.PSObject.Properties['@odata.nextLink']) {
                $url = $response.'@odata.nextLink'
            }
        } while ($url)

        return $records
    }

    # PK-only fetch used by the reconcile-deletes pass. ~100x lighter than
    # FetchRecords because we $select only the primary key column.
    [System.Collections.Generic.HashSet[guid]]FetchAllPrimaryKeys([string]$entityName, [string]$primaryKey) {
        $plural = if ($entityName.EndsWith("y")) { $entityName.TrimEnd("y") + "ies" }
                  elseif ($entityName.EndsWith("s")) { $entityName + "es" }
                  else { $entityName + "s" }

        $pks = [System.Collections.Generic.HashSet[guid]]::new()
        $url = "$($this.EnvironmentUrl)api/data/v9.2/$plural`?`$select=$primaryKey"

        do {
            $response = $this.InvokeApiCall($url)
            if ($response.value) {
                foreach ($r in $response.value) {
                    $v = $r.($primaryKey)
                    if ($null -ne $v) {
                        try { $pks.Add([guid]$v) | Out-Null } catch {}
                    }
                }
            }
            $url = $null
            if ($response.PSObject.Properties['@odata.nextLink']) {
                $url = $response.'@odata.nextLink'
            }
        } while ($url)

        return $pks
    }

    # Entity-set-aware PK fetch for the post-run row comparison. Unlike
    # FetchAllPrimaryKeys (which guesses the plural and silently drops nulls),
    # this takes the resolved EntitySetName directly and reports the raw total
    # plus how many rows had a null/empty PK, so the comparison can attribute a
    # reason code. Keys are returned as case-insensitive strings to line up with
    # however SQL stored the GUID.
    [PSObject]FetchPrimaryKeySet([string]$entitySet, [string]$primaryKey) {
        $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $total = 0
        $nullCount = 0
        $url = "$($this.EnvironmentUrl)api/data/v9.2/$entitySet`?`$select=$primaryKey"

        do {
            $response = $this.InvokeApiCall($url)
            if ($response.value) {
                foreach ($r in $response.value) {
                    $total++
                    $v = $r.($primaryKey)
                    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) {
                        $nullCount++
                    } else {
                        $keys.Add([string]$v) | Out-Null
                    }
                }
            }
            $url = $null
            if ($response.PSObject.Properties['@odata.nextLink']) {
                $url = $response.'@odata.nextLink'
            }
        } while ($url)

        return [PSCustomObject]@{ Total = $total; Keys = $keys; NullCount = $nullCount }
    }

    [System.Collections.Generic.List[PSObject]]FetchRecords([string]$entityName, [string]$filter) {
        $records = [System.Collections.Generic.List[PSObject]]::new()
        
        $plural = if ($entityName.EndsWith("y")) { $entityName.TrimEnd("y") + "ies" } 
                  elseif ($entityName.EndsWith("s")) { $entityName + "es" } 
                  else { $entityName + "s" }

        $url = "$($this.EnvironmentUrl)api/data/v9.2/$plural"
        if (-not [string]::IsNullOrWhiteSpace($filter)) { $url += "?`$filter=$filter" }

        do {
            $response = $this.InvokeApiCall($url)
            if ($response.value) { 
                $castedItems = [PSObject[]]$response.value
                $records.AddRange($castedItems) 
            }
            
            $url = $null
            if ($response.PSObject.Properties['@odata.nextLink']) {
                $url = $response.'@odata.nextLink'
            }
        } while ($url)

        return $records
    }

    # === Discover all entity logical names from Dataverse ===
    [System.Collections.Generic.List[string]]FetchAllEntityLogicalNames() {
        $names = [System.Collections.Generic.List[string]]::new()
        $url = "$($this.EnvironmentUrl)api/data/v9.2/EntityDefinitions?`$select=LogicalName"
        
        do {
            $response = $this.InvokeApiCall($url)
            foreach ($e in $response.value) {
                $names.Add($e.LogicalName)
            }
            $url = $null
            if ($response.PSObject.Properties['@odata.nextLink']) {
                $url = $response.'@odata.nextLink'
            }
        } while ($url)

        return $names
    }

    # === Map logicalName -> { EntitySetName, PrimaryIdAttribute } ===
    # The sync worker otherwise guesses the OData entity-set name from naive
    # plural rules and the PK as "<logicalname>id". Both fail on a large slice
    # of the system catalog: irregular plurals and intersect/relationship
    # entities 404, and base entities like activitypointer (PK = activityid)
    # hit "Invalid column name". Pulling EntitySetName + PrimaryIdAttribute from
    # metadata replaces both guesses with the authoritative values. One paged
    # metadata call; cheap relative to the data sync.
    [hashtable]FetchEntitySetMap() {
        $map = @{}
        $url = "$($this.EnvironmentUrl)api/data/v9.2/EntityDefinitions?`$select=LogicalName,EntitySetName,PrimaryIdAttribute"

        do {
            $response = $this.InvokeApiCall($url)
            foreach ($e in $response.value) {
                if (-not [string]::IsNullOrWhiteSpace($e.LogicalName)) {
                    $map[$e.LogicalName.ToLowerInvariant()] = [PSCustomObject]@{
                        EntitySetName      = $e.EntitySetName
                        PrimaryIdAttribute = $e.PrimaryIdAttribute
                    }
                }
            }
            $url = $null
            if ($response.PSObject.Properties['@odata.nextLink']) {
                $url = $response.'@odata.nextLink'
            }
        } while ($url)

        return $map
    }

    # === SPECIAL FETCH: Global & Local OptionSets ===
    [System.Collections.Generic.List[PSObject]]FetchAllOptionSets([array]$configuredTables) {
        $records = [System.Collections.Generic.List[PSObject]]::new()
        $processedKeys = [System.Collections.Generic.HashSet[string]]::new()

        # 1. Global OptionSets
        $url = "$($this.EnvironmentUrl)api/data/v9.2/GlobalOptionSetDefinitions"
        try {
            $response = $this.InvokeApiCall($url)
            foreach ($os in $response.value) {
                if ($os.PSObject.Properties['Options'] -and $null -ne $os.Options) {
                    foreach ($opt in $os.Options) {
                        $id = "$($os.Name)-$($opt.Value)"
                        if ($processedKeys.Add($id)) {
                            $lbl = if ($opt.Label -and $opt.Label.UserLocalizedLabel) { $opt.Label.UserLocalizedLabel.Label } else { "" }
                            
                            $records.Add([PSCustomObject]@{
                                globalchoiceid = $id; optionsetname = $os.Name; value = $opt.Value
                                label = $lbl
                                modifiedon = [datetime]::UtcNow
                            })
                        }
                    }
                }
            }
        } catch { Write-Warning "Global OptionSet fetch error: $_" }

        # 2. Local OptionSets
        foreach ($tbl in $configuredTables) {
            $eName = $null
            if ($tbl -is [string]) { $eName = $tbl }
            elseif ($tbl.PSObject.Properties['LogicalName']) { $eName = $tbl.LogicalName }
            else { continue }

            if ($eName -eq "GlobalChoices" -or $eName -like "ods_*") { continue }
            
            $url = "$($this.EnvironmentUrl)api/data/v9.2/EntityDefinitions(LogicalName='$eName')/Attributes/Microsoft.Dynamics.CRM.PicklistAttributeMetadata?`$expand=OptionSet"
            try {
                $resp = $this.InvokeApiCall($url)
                foreach ($attr in $resp.value) {
                    if ($attr.OptionSet -and $attr.OptionSet.Options) {
                        foreach ($opt in $attr.OptionSet.Options) {
                            $scopedName = "${eName}_$($attr.LogicalName)"
                            $id = "$scopedName-$($opt.Value)"
                            if ($processedKeys.Add($id)) {
                                $lbl = if ($opt.Label -and $opt.Label.UserLocalizedLabel) { $opt.Label.UserLocalizedLabel.Label } else { "" }

                                $records.Add([PSCustomObject]@{
                                    globalchoiceid = $id; optionsetname = $scopedName; value = $opt.Value
                                    label = $lbl
                                    modifiedon = [datetime]::UtcNow
                                })
                            }
                        }
                    }
                }
            } catch {}
        }
        return $records
    }

    # === SPECIAL FETCH: Entity Definitions (ods_metadata) ===
    [System.Collections.Generic.List[PSObject]]FetchEntityDefinitions() {
        $records = [System.Collections.Generic.List[PSObject]]::new()
        $url = "$($this.EnvironmentUrl)api/data/v9.2/EntityDefinitions?`$select=LogicalName,SchemaName,DisplayName,MetadataId"
        
        do {
            $response = $this.InvokeApiCall($url)
            foreach ($e in $response.value) {
                $dName = $e.SchemaName
                if ($e.DisplayName -and $e.DisplayName.UserLocalizedLabel) {
                    $dName = $e.DisplayName.UserLocalizedLabel.Label
                }

                $records.Add([PSCustomObject]@{
                    entityid = $e.MetadataId
                    logicalname = $e.LogicalName
                    schemaname = $e.SchemaName
                    displayname = $dName
                    modifiedon = [datetime]::UtcNow
                })
            }
            
            $url = $null
            if ($response.PSObject.Properties['@odata.nextLink']) {
                $url = $response.'@odata.nextLink'
            }
        } while ($url)
        return $records
    }

    # === SPECIAL FETCH: Attribute Definitions (ods_metadata_columns) ===
    [System.Collections.Generic.List[PSObject]]FetchAttributeDefinitions([array]$configuredTables) {
        $records = [System.Collections.Generic.List[PSObject]]::new()
        
        foreach ($tbl in $configuredTables) {
            $eName = $null
            if ($tbl -is [string]) { $eName = $tbl }
            elseif ($tbl.PSObject.Properties['LogicalName']) { $eName = $tbl.LogicalName }
            else { continue }

            if ($eName -like "ods_*" -or $eName -eq "GlobalChoices") { continue }

            # MaxLength + Description removed -- see Build-DataDictionary comment.
            $url = "$($this.EnvironmentUrl)api/data/v9.2/EntityDefinitions(LogicalName='$eName')/Attributes?`$select=LogicalName,SchemaName,DisplayName,MetadataId,AttributeType,RequiredLevel"
            try {
                $response = $this.InvokeApiCall($url)
                foreach ($a in $response.value) {
                    $dName = $a.SchemaName
                    if ($a.DisplayName -and $a.DisplayName.UserLocalizedLabel) {
                        $dName = $a.DisplayName.UserLocalizedLabel.Label
                    }
                    $desc = ""
                    if ($a.PSObject.Properties['Description'] -and $a.Description -and $a.Description.UserLocalizedLabel) {
                        $desc = $a.Description.UserLocalizedLabel.Label
                    }
                    $maxLen = 0
                    if ($a.PSObject.Properties['MaxLength'] -and $null -ne $a.MaxLength) {
                        $maxLen = [int]$a.MaxLength
                    }
                    $reqLevel = ""
                    if ($a.PSObject.Properties['RequiredLevel'] -and $null -ne $a.RequiredLevel) {
                        $reqLevel = $a.RequiredLevel.Value
                    }

                    $records.Add([PSCustomObject]@{
                        columnid            = $a.MetadataId
                        entitylogicalname   = $eName
                        logicalname         = $a.LogicalName
                        schemaname          = $a.SchemaName
                        displayname         = $dName
                        attributetype       = $a.AttributeType
                        requiredlevel       = $reqLevel
                        maxlength           = $maxLen
                        description         = $desc
                        modifiedon          = [datetime]::UtcNow
                    })
                }
            } catch {
                $detail = ""
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    $detail = $_.ErrorDetails.Message
                    if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) + "..." }
                    $detail = " | body: $detail"
                }
                Write-Warning "Could not fetch columns for $eName : $($_.Exception.Message)$detail"
            }
        }
        return $records
    }
}

class SQLConnector {
    [string]$ConnectionString
    [int]$BatchSize

    SQLConnector([string]$connString, [int]$batchSize) {
        $this.ConnectionString = $connString
        $this.BatchSize = $batchSize
    }

    [void]TestConnection() {
        $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnectionString)
        try {
            $conn.Open()
            Write-Host "SQL Connection Successful to $($conn.DataSource)" -ForegroundColor Green
        }
        finally { $conn.Dispose() }
    }

    [void]BulkUpsert([string]$tableName, [string]$primaryKey, [System.Collections.Generic.List[PSObject]]$records, [SyncLogger]$logger) {
        # Delegates to Modules\Ods.SqlUpsert.psm1 so the parallel runspaces
        # (which can't reach this class instance) call the same code.
        $info    = { param($m) $logger.Info($m)    }.GetNewClosure()
        $warn    = { param($m) $logger.Warn($m)    }.GetNewClosure()
        $success = { param($m) $logger.Success($m) }.GetNewClosure()
        $errfn   = { param($m) $logger.Error($m)   }.GetNewClosure()

        Invoke-OdsSqlBulkUpsert `
            -ConnString  $this.ConnectionString `
            -TableName   $tableName `
            -PrimaryKey  $primaryKey `
            -Records     $records `
            -BatchSize   $this.BatchSize `
            -LogInfo     $info `
            -LogWarn     $warn `
            -LogSuccess  $success `
            -LogError    $errfn | Out-Null
    }

    # === Execute arbitrary SQL and return results ===
    [PSObject]ExecuteQuery([string]$sql) {
        $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnectionString)
        try {
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $sql
            $cmd.CommandTimeout = 300
            $reader = $cmd.ExecuteReader()
            $results = [System.Collections.Generic.List[PSObject]]::new()
            while ($reader.Read()) {
                $row = @{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                }
                $results.Add([PSCustomObject]$row)
            }
            $reader.Close()
            return $results
        }
        finally { $conn.Dispose() }
    }

    [void]ExecuteNonQuery([string]$sql) {
        $conn = [System.Data.SqlClient.SqlConnection]::new($this.ConnectionString)
        try {
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $sql
            $cmd.CommandTimeout = 300
            $cmd.ExecuteNonQuery() | Out-Null
        }
        finally { $conn.Dispose() }
    }
}

# ==============================================================================
# REGION: HELPER FUNCTIONS
# ==============================================================================

function Get-XmlProp {
    param($Node, $PropName, $DefaultValue = $null)

    if ($Node.HasAttribute -and $Node.HasAttribute($PropName)) {
        return $Node.GetAttribute($PropName)
    }
    if ($Node[$PropName]) {
        return $Node[$PropName].InnerText
    }
    if ($Node.PSObject.Properties[$PropName]) {
        return $Node.$PropName
    }
    return $DefaultValue
}

function Get-PipelineConfigOverride {
    <#
    .SYNOPSIS
        Reads ops.pipeline_config for a (pipeline, key) override.
        Returns $DefaultValue if no row, table missing, or any SQL error.
        Caller casts the result -- strings, integers, decimals all flow through.

        To override a runtime knob without editing the XML:
            MERGE ops.pipeline_config AS t
            USING (SELECT 'CRMToSQL' p, 'BatchSize' k, '10000' v) AS s
              ON t.pipeline = s.p AND t.config_key = s.k
            WHEN MATCHED THEN UPDATE SET config_value = s.v, updated_utc = SYSUTCDATETIME()
            WHEN NOT MATCHED THEN INSERT (pipeline, config_key, config_value)
              VALUES (s.p, s.k, s.v);
    #>
    param(
        [string]$ConnString,
        [string]$Pipeline,
        [string]$ConfigKey,
        $DefaultValue,
        $Logger = $null
    )

    try {
        $conn = [System.Data.SqlClient.SqlConnection]::new($ConnString)
        $conn.Open()
        try {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT config_value FROM ops.pipeline_config WHERE pipeline = @p AND config_key = @k"
            $cmd.Parameters.AddWithValue("@p", $Pipeline) | Out-Null
            $cmd.Parameters.AddWithValue("@k", $ConfigKey) | Out-Null
            $r = $cmd.ExecuteScalar()
            if ($null -ne $r -and $r -isnot [System.DBNull]) {
                if ($null -ne $Logger) { $Logger.Info("Config override [$Pipeline.$ConfigKey] = $r (XML default was $DefaultValue)") }
                return $r
            }
        } finally { $conn.Dispose() }
    } catch {}
    return $DefaultValue
}

# ==============================================================================
# REGION: FEATURE 1 - PREFIX-BASED TABLE DISCOVERY
# ==============================================================================

function Select-RequestedTables {
    <#
    .SYNOPSIS
        Applies the manual -Table override: keeps only resolved tables whose
        logical name is in $Requested (case-insensitive). Returns the list
        unchanged when no -Table was supplied. Logical names are matched as-is
        (singular Dataverse logical names, e.g. "product").
    #>
    param(
        [System.Collections.Generic.List[hashtable]]$Resolved,
        [string[]]$Requested,
        $Logger
    )
    # -NoEnumerate: a function returning a List gets unrolled by PowerShell, so a
    # single-table result would arrive at the caller as a bare hashtable (and a
    # multi-table one as object[]). Keep it a List so .Count and List-typed
    # parameters downstream stay correct.
    if (-not $Requested -or $Requested.Count -eq 0) { Write-Output -NoEnumerate $Resolved; return }

    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tn in $Requested) {
        if (-not [string]::IsNullOrWhiteSpace($tn)) { $wanted.Add($tn.Trim()) | Out-Null }
    }

    $filtered = [System.Collections.Generic.List[hashtable]]::new()
    $keptNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rt in $Resolved) {
        if ($wanted.Contains($rt.LogicalName)) {
            $filtered.Add($rt)
            $keptNames.Add($rt.LogicalName) | Out-Null
        }
    }

    # @(...) keeps .Count valid under StrictMode when a single name is missing.
    $missing = @($wanted | Where-Object { -not $keptNames.Contains($_) })
    $Logger.Info("-Table override: kept $($filtered.Count) of $($wanted.Count) requested table(s): $($wanted -join ', ')")
    if ($missing.Count -gt 0) {
        $Logger.Warn("-Table override: $($missing.Count) requested name(s) not in discovered set: $($missing -join ', '). Check the logical name (singular) or config discovery.")
    }
    Write-Output -NoEnumerate $filtered
}

function Invoke-RowCountCompare {
    <#
    .SYNOPSIS
        After a targeted (-Table) sync, compares source (Dataverse) row counts
        against the target (SQL) tables and reports matched / missing / extra.
        When any source rows are absent from the target, writes a per-table
        report under logs\compare\ listing the missing primary keys and a
        reason code, so an operator can see exactly what didn't land and why.
    #>
    param(
        # $Dataverse: [DataverseConnector]; $SQL: [SQLConnector]; $Logger:
        # [SyncLogger] -- untyped per the class-identity note at top of file.
        $Dataverse,
        $SQL,
        # Untyped: accepts a List[hashtable] or a single/array of hashtables
        # without PowerShell trying to coerce a lone hashtable into a List
        # (which fails on the read-only Capacity/LogicalName binding).
        $TableList,
        [string]$SqlPrefix,
        $Logger,
        [string]$LogBaseDir,
        [string]$RunStamp
    )

    $Logger.Info("=== Row-count comparison (source vs target) ===")
    $compareDir = Join-Path $LogBaseDir "compare"
    if (-not (Test-Path $compareDir)) { New-Item -ItemType Directory -Path $compareDir -Force | Out-Null }

    foreach ($tblInfo in $TableList) {
        $entityName = $tblInfo.LogicalName
        if ($entityName -eq "GlobalChoices" -or $entityName -like "ods_*") { continue }

        $sqlTableName = if ($tblInfo.SqlTableName) { $SqlPrefix + $tblInfo.SqlTableName } else { $SqlPrefix + $entityName }
        $pk = if ($tblInfo.PrimaryKey) { $tblInfo.PrimaryKey } else { $entityName + "id" }

        # Same EntitySetName resolution as the sync worker: metadata first, guess after.
        $entitySet = $null
        if ($tblInfo.ContainsKey('EntitySetName')) { $entitySet = $tblInfo.EntitySetName }
        if ([string]::IsNullOrWhiteSpace($entitySet)) {
            $entitySet = if ($entityName.EndsWith("y")) { $entityName.TrimEnd("y") + "ies" }
                         elseif ($entityName.EndsWith("s")) { $entityName + "es" }
                         else { $entityName + "s" }
        }

        try {
            $exists = $SQL.ExecuteQuery("SELECT COUNT(*) AS cnt FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$sqlTableName'")
            if (-not $exists -or $exists[0].cnt -eq 0) {
                $Logger.Warn("Compare [$entityName]: target table [$sqlTableName] does not exist; skipping.")
                continue
            }

            $src = $Dataverse.FetchPrimaryKeySet($entitySet, $pk)

            # Target PK set
            $targetKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $tgtRows = $SQL.ExecuteQuery("SELECT [$pk] AS k FROM [$sqlTableName] WHERE [$pk] IS NOT NULL")
            foreach ($row in $tgtRows) {
                if ($null -ne $row.k) { $targetKeys.Add([string]$row.k) | Out-Null }
            }
            $targetCount = $targetKeys.Count

            $missing = [System.Collections.Generic.List[string]]::new()
            foreach ($k in $src.Keys) {
                if (-not $targetKeys.Contains($k)) { $missing.Add($k) }
            }

            $matched = $src.Keys.Count - $missing.Count
            $extra   = $targetCount - $matched   # rows in SQL not in source (old/soft-deleted/reconcile)
            $Logger.Info("Compare [$entityName]: source=$($src.Total) (usablePK=$($src.Keys.Count), nullPK=$($src.NullCount)) | target=$targetCount | matched=$matched | missing=$($missing.Count) | extraInTarget=$extra")

            if ($missing.Count -gt 0 -or $src.NullCount -gt 0) {
                $reportPath = Join-Path $compareDir "$($entityName)_missing_$RunStamp.log"
                $sb = [System.Text.StringBuilder]::new()
                [void]$sb.AppendLine("Row comparison report")
                [void]$sb.AppendLine("Entity (logical) : $entityName")
                [void]$sb.AppendLine("Entity set       : $entitySet")
                [void]$sb.AppendLine("Target table     : $sqlTableName")
                [void]$sb.AppendLine("Primary key      : $pk")
                [void]$sb.AppendLine("Generated (UTC)  : $([datetime]::UtcNow.ToString('u'))")
                [void]$sb.AppendLine("Source total     : $($src.Total)")
                [void]$sb.AppendLine("Source usable PK : $($src.Keys.Count)")
                [void]$sb.AppendLine("Source null PK   : $($src.NullCount)")
                [void]$sb.AppendLine("Target rows      : $targetCount")
                [void]$sb.AppendLine("Matched          : $matched")
                [void]$sb.AppendLine("Missing in target: $($missing.Count)")
                [void]$sb.AppendLine("Extra in target  : $extra")
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("reason_code`tprimary_key")
                foreach ($k in $missing) {
                    [void]$sb.AppendLine("NOT_IN_TARGET`t$k")
                }
                if ($src.NullCount -gt 0) {
                    [void]$sb.AppendLine("NULL_OR_EMPTY_PK`t($($src.NullCount) source row(s) had no usable primary key; not addressable by PK)")
                }
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("Reason codes:")
                [void]$sb.AppendLine("  NOT_IN_TARGET    Source row has a valid PK but no matching target row after sync.")
                [void]$sb.AppendLine("                   Usually a failed/partial upsert batch -- see logs\tables\$entityName.log.")
                [void]$sb.AppendLine("  NULL_OR_EMPTY_PK Source row returned no usable primary-key value; cannot be keyed into SQL.")

                # UTF-8 with BOM so the report opens correctly in any editor / 5.1.
                [System.IO.File]::WriteAllText($reportPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($true))
                $Logger.Warn("Compare [$entityName]: $($missing.Count) missing + $($src.NullCount) null-PK. Report: $reportPath")
            } else {
                $Logger.Success("Compare [$entityName]: target matches source ($matched rows).")
            }
        } catch {
            $Logger.Error("Compare [$entityName] failed: $($_.Exception.Message)")
        }
    }
}

function Resolve-TableList {
    <#
    .SYNOPSIS
        Builds the final list of table logical names to sync by combining:
        - Explicitly listed <Table> entries from config
        - Prefix-matched tables discovered via Dataverse API
        - SyncAllTables flag (sync everything)
        
        Per-table log files go to logs\tables\<tableName>.log automatically.
        No per-table config file is needed for prefix/syncAll tables.
    #>
    param(
        [xml]$ConfigXml,
        # $Dataverse expected to be a [DataverseConnector]; $Logger a [SyncLogger].
        # Types intentionally not declared -- see comment at top of script re:
        # class-identity drift across repeated runs in the same session.
        $Dataverse,
        $Logger
    )

    $cfg = $ConfigXml.Config
    $finalTables = [System.Collections.Generic.List[hashtable]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. Read explicitly configured tables (preserve custom SqlTableName, PrimaryKey, etc.)
    $explicitTables = @()
    if ($cfg.Tables -and $cfg.Tables.Table) {
        $explicitTables = @($cfg.Tables.Table)
    }
    foreach ($tbl in $explicitTables) {
        $name = (Get-XmlProp $tbl "LogicalName").Trim()
        if ($seen.Add($name)) {
            $finalTables.Add(@{
                LogicalName  = $name
                SqlTableName = Get-XmlProp $tbl "SqlTableName"
                PrimaryKey   = Get-XmlProp $tbl "PrimaryKey"
                Source       = "Explicit"
            })
        }
    }

    # 2. Check for SyncAllTables flag
    $syncAll = $false
    if ($cfg.Tables.PSObject.Properties['SyncAllTables'] -or $cfg.Tables['SyncAllTables']) {
        $syncAllVal = Get-XmlProp $cfg.Tables "SyncAllTables" "false"
        $syncAll = $syncAllVal -eq "true" -or $syncAllVal -eq "1"
    }

    # 3. Check for Prefix entries
    $prefixes = @()
    if ($cfg.Tables['Prefixes'] -and $cfg.Tables.Prefixes['Prefix']) {
        $prefixes = @(@($cfg.Tables.Prefixes.Prefix) | ForEach-Object {
            if ($_ -is [string]) { $_ } elseif ($_.InnerText) { $_.InnerText } elseif ($_.'#text') { $_.'#text' } else { $_.ToString() }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    # 4. If we need discovery, fetch all entity names from Dataverse
    if ($syncAll -or $prefixes.Count -gt 0) {
        $Logger.Info("Discovering tables from Dataverse API...")
        $allNames = $Dataverse.FetchAllEntityLogicalNames()
        $Logger.Info("Found $($allNames.Count) total entities in Dataverse.")

        $matched = [System.Collections.Generic.List[string]]::new()

        if ($syncAll) {
            $Logger.Info("SyncAllTables=true: including all entities.")
            $matched = $allNames
        }
        else {
            foreach ($entityName in $allNames) {
                foreach ($pfx in $prefixes) {
                    if ($entityName.StartsWith($pfx, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $matched.Add($entityName)
                        break
                    }
                }
            }
            $Logger.Info("Prefix match found $($matched.Count) tables for prefixes: $($prefixes -join ', ')")
        }

        foreach ($name in $matched) {
            if ($seen.Add($name)) {
                $finalTables.Add(@{
                    LogicalName  = $name
                    SqlTableName = $null
                    PrimaryKey   = $null
                    Source       = if ($syncAll) { "SyncAll" } else { "Prefix" }
                })
            }
        }
    }

    # 5. Apply ExcludeTables filter
    $excludeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($cfg.Tables['ExcludeTables'] -and $cfg.Tables.ExcludeTables['Table']) {
        $excludeEntries = @($cfg.Tables.ExcludeTables.Table)
        foreach ($ex in $excludeEntries) {
            $exName = $null
            if ($ex -is [string]) { $exName = $ex.Trim() }
            elseif ($ex.InnerText) { $exName = $ex.InnerText.Trim() }
            elseif ($ex.'#text') { $exName = $ex.'#text'.Trim() }
            elseif ($ex.PSObject.Properties['LogicalName']) { $exName = $ex.LogicalName.Trim() }
            else { $exName = $ex.ToString().Trim() }

            if (-not [string]::IsNullOrWhiteSpace($exName)) {
                $excludeNames.Add($exName) | Out-Null
            }
        }
    }

    if ($excludeNames.Count -gt 0) {
        $removedNames  = [System.Collections.Generic.List[string]]::new()
        $filteredTables = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($t in $finalTables) {
            if ($excludeNames.Contains($t.LogicalName)) {
                $removedNames.Add($t.LogicalName)
            } else {
                $filteredTables.Add($t)
            }
        }
        $finalTables = $filteredTables
        # @(...) forces an array -- Where-Object unwraps to a scalar on a single match,
        # which would break `.Count` under StrictMode 2.0.
        $notDiscovered = @($excludeNames | Where-Object { $removedNames -notcontains $_ })
        $Logger.Info("ExcludeTables removed $($removedNames.Count) of $($excludeNames.Count) listed table(s): $($removedNames -join ', ')")
        if ($notDiscovered.Count -gt 0) {
            $Logger.Info("ExcludeTables: $($notDiscovered.Count) name(s) not in discovered set (no-op): $($notDiscovered -join ', ')")
        }
    }

    # 6. Enrich with authoritative EntitySetName + PrimaryIdAttribute from
    #    metadata. This is what turns the avoidable 404 (wrong plural) and
    #    "Invalid column name" (wrong PK) failures into successful pulls, so a
    #    full/syncAll run captures every queryable populated table -- not just
    #    the ones whose names happen to match the guessing rules. Fails open:
    #    if the metadata call errors, each table keeps its name-based guess.
    try {
        $metaMap = $Dataverse.FetchEntitySetMap()
        $enriched = 0
        foreach ($t in $finalTables) {
            $key = $t.LogicalName.ToLowerInvariant()
            if ($metaMap.ContainsKey($key)) {
                $m = $metaMap[$key]
                $t['EntitySetName'] = $m.EntitySetName
                # Only fill PrimaryKey when the config didn't pin one explicitly.
                if ([string]::IsNullOrWhiteSpace($t['PrimaryKey']) -and -not [string]::IsNullOrWhiteSpace($m.PrimaryIdAttribute)) {
                    $t['PrimaryKey'] = $m.PrimaryIdAttribute
                }
                $enriched++
            }
        }
        $Logger.Info("Metadata enrichment: $enriched of $($finalTables.Count) tables matched EntitySetName/PrimaryKey ($($metaMap.Count) entities in map).")
    } catch {
        $Logger.Warn("Metadata enrichment failed ($($_.Exception.Message)); worker will fall back to name-based plural/PK guessing.")
    }

    $Logger.Info("Total tables to sync: $($finalTables.Count)")
    return $finalTables
}

# ==============================================================================
# REGION: FEATURE 2 - VIEWS (exact CRM column names, only columns with data)
# ==============================================================================

function Get-ColumnSortKey {
    <#
    .SYNOPSIS
        Returns a sortable string that groups columns logically:
        PK -> name fields -> regular columns (alphabetical, which groups address1_*, etc.)
        -> lookup _value cols -> owner/state -> audit/system cols last.
    #>
    param(
        [string]$ColName,
        [string]$PrimaryKey
    )

    $l = $ColName.ToLower()
    $pk = if ($PrimaryKey) { $PrimaryKey.ToLower() } else { "" }

    # 0. Primary key always first
    if ($l -eq $pk) { return "0_$l" }

    # 1. Common "name" fields right after PK
    $nameFields = @('name','fullname','firstname','lastname','middlename','yominame','title','subject','accountnumber','contactnumber')
    if ($nameFields -contains $l) { return "1_$l" }

    # 8. Owner / state / status near the end (right before audit)
    $ownerFields = @('ownerid','owninguser','owningteam','owningbusinessunit','statecode','statuscode')
    if ($ownerFields -contains $l) { return "8_$l" }

    # 9. Audit / system columns last
    $auditFields = @(
        'createdby','createdbyname','createdbyyominame','createdon',
        'createdonbehalfby','createdonbehalfbyname','createdonbehalfbyyominame',
        'modifiedby','modifiedbyname','modifiedbyyominame','modifiedon',
        'modifiedonbehalfby','modifiedonbehalfbyname','modifiedonbehalfbyyominame',
        'overriddencreatedon','importsequencenumber',
        'timezoneruleversionnumber','utcconversiontimezonecode','versionnumber'
    )
    if ($auditFields -contains $l) { return "9_$l" }

    # 6. Lookup columns Dataverse exposes as _xxx_value
    if ($l.StartsWith('_') -and $l.EndsWith('_value')) { return "6_$l" }

    # 5. Regular columns -- alphabetical, which naturally groups
    #    address1_* together, address2_* together, etc.
    return "5_$l"
}

function Build-FriendlyViews {
    <#
    .SYNOPSIS
        Builds vw_<table> for each synced table:
          - Aliases each column to its CRM display label
          - Only includes columns with data (read from ods_datadictionary_columns)
          - Orders columns logically: PK -> name -> regular (alpha-grouped) -> lookups -> owner -> audit
    #>
    param(
        # $SQL: [SQLConnector]; $Logger: [SyncLogger] -- see top-of-file note re class identity.
        $SQL,
        [string]$SqlPrefix,
        [System.Collections.Generic.List[hashtable]]$TableList,
        $Logger
    )

    $Logger.Info("=== Building Views (display names, grouped, data-only) ===")

    foreach ($tblInfo in $TableList) {
        $entityName = $tblInfo.LogicalName
        if ($entityName -eq "GlobalChoices" -or $entityName -like "ods_*") { continue }

        $sqlTableName = if ($tblInfo.SqlTableName) { $SqlPrefix + $tblInfo.SqlTableName } else { $SqlPrefix + $entityName }
        $pk = if ($tblInfo.PrimaryKey) { $tblInfo.PrimaryKey } else { $entityName + "id" }

        try {
            # Confirm table exists
            $exists = $SQL.ExecuteQuery("SELECT COUNT(*) AS cnt FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$sqlTableName'")
            if (-not $exists -or $exists[0].cnt -eq 0) { continue }

            # Pull display names + has_data from the dictionary built in the previous step.
            # This avoids re-running the per-column COUNT(DISTINCT) probe -- much faster.
            $dictRows = $SQL.ExecuteQuery(@"
                SELECT sql_column_name, displayname, has_data
                FROM ods_datadictionary_columns
                WHERE entitylogicalname = '$entityName'
"@)

            $dictMap = @{}
            foreach ($r in $dictRows) {
                if ($r.sql_column_name) {
                    $dictMap[$r.sql_column_name.ToString().ToLower()] = $r
                }
            }

            # Real columns currently in the SQL table
            $sqlColumns = $SQL.ExecuteQuery("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$sqlTableName'")
            if (-not $sqlColumns -or $sqlColumns.Count -eq 0) { continue }

            # Detect soft-delete columns so we can filter (and hide them from the projection).
            $hasIsActive = $false
            foreach ($c in $sqlColumns) {
                if ($c.COLUMN_NAME -eq 'is_active') { $hasIsActive = $true; break }
            }

            $cols = [System.Collections.Generic.List[PSObject]]::new()
            foreach ($c in $sqlColumns) {
                $colName = $c.COLUMN_NAME
                if ($colName -match '^@' -or $colName -match '^_.*_value@') { continue }
                # Soft-delete columns are pipeline metadata, not user data. They
                # are excluded from vw_* and instead surfaced via the WHERE clause.
                if ($colName -eq 'is_active' -or $colName -eq 'detected_missing_utc') { continue }

                $key = $colName.ToLower()
                $hasData = $true
                $displayName = $colName

                if ($dictMap.ContainsKey($key)) {
                    $info = $dictMap[$key]
                    if ($null -ne $info.has_data) { $hasData = [bool]$info.has_data }
                    if ($info.displayname) { $displayName = $info.displayname.ToString() }
                }

                # Always keep the PK even if dictionary somehow flagged it as no-data
                if ($colName -eq $pk) { $hasData = $true }
                if (-not $hasData) { continue }

                $cols.Add([PSCustomObject]@{
                    LogicalName = $colName
                    DisplayName = $displayName
                    SortKey     = (Get-ColumnSortKey -ColName $colName -PrimaryKey $pk)
                })
            }

            if ($cols.Count -eq 0) {
                $Logger.Warn("No columns with data for [$sqlTableName]; skipping view.")
                continue
            }

            # Order: PK -> name -> regular (alphabetical groups address1_* together) -> lookups -> owner -> audit
            $sortedCols = $cols | Sort-Object SortKey

            # Build SELECT list, deduping any colliding display labels
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $viewLines = [System.Collections.Generic.List[string]]::new()

            foreach ($c in $sortedCols) {
                $alias = $c.DisplayName
                if (-not $seen.Add($alias)) {
                    # Two columns share a display name -- disambiguate with the logical name
                    $alias = "$($c.DisplayName) ($($c.LogicalName))"
                    if (-not $seen.Add($alias)) {
                        $alias = $c.LogicalName
                        $seen.Add($alias) | Out-Null
                    }
                }
                # Escape ] inside aliases (SQL bracket-quoting)
                $aliasEsc = $alias -replace '\]', ']]'
                $viewLines.Add("    [$($c.LogicalName)] AS [$aliasEsc]")
            }

            $viewName = "vw_${sqlTableName}"
            $viewBody = $viewLines -join ",`n"
            $whereClause = if ($hasIsActive) { "`nWHERE [is_active] = 1" } else { "" }

            # CREATE OR ALTER is atomic and preserves dependencies -- saved
            # queries, BI reports, and downstream views keep their references
            # to vw_*. DROP + CREATE would silently invalidate all of them.
            $createViewSql = @"
CREATE OR ALTER VIEW [$viewName] AS
SELECT
$viewBody
FROM [$sqlTableName]$whereClause;
"@
            $SQL.ExecuteNonQuery($createViewSql)
            $filterNote = if ($hasIsActive) { " (filters is_active=1)" } else { "" }
            $Logger.Success("View [$viewName] created: $($viewLines.Count) columns, display names, grouped$filterNote.")
        }
        catch {
            $Logger.Error("Failed to build view for [$entityName]: $($_.Exception.Message)")
        }
    }
}

# ==============================================================================
# REGION: FEATURE 3 - DATA DICTIONARY TABLES
# ==============================================================================

function Build-DataDictionary {
    <#
    .SYNOPSIS
        Builds/maintains two data dictionary tables in SQL:
          - ods_datadictionary_tables:   row counts, column counts, density, sync metadata
          - ods_datadictionary_columns:  per-column stats (density, distinct count, has_data)
        
        Combines Dataverse API metadata with actual SQL table statistics.
    #>
    param(
        # $SQL: [SQLConnector]; $Dataverse: [DataverseConnector]; $Logger: [SyncLogger].
        # Types intentionally omitted -- see top-of-file note re class identity drift.
        $SQL,
        $Dataverse,
        [string]$SqlPrefix,
        [System.Collections.Generic.List[hashtable]]$TableList,
        $Logger
    )

    $Logger.Info("=== Building Data Dictionary ===")

    # -------------------------------------------------------
    # Ensure dictionary tables exist
    # -------------------------------------------------------
    $createTablesDDL = @"
IF OBJECT_ID('ods_datadictionary_tables', 'U') IS NULL
CREATE TABLE [ods_datadictionary_tables] (
    [dictionary_table_id]   NVARCHAR(450) NOT NULL PRIMARY KEY CLUSTERED,
    [logicalname]           NVARCHAR(450) NULL,
    [displayname]           NVARCHAR(MAX) NULL,
    [schemaname]            NVARCHAR(MAX) NULL,
    [sql_table_name]        NVARCHAR(450) NULL,
    [row_count]             BIGINT NULL,
    [column_count]          INT NULL,
    [columns_with_data]     INT NULL,
    [data_density_pct]      DECIMAL(5,2) NULL,
    [sync_source]           NVARCHAR(100) NULL,
    [last_sync_utc]         DATETIME2 NULL,
    [modifiedon]            DATETIME2 NULL
);

IF OBJECT_ID('ods_datadictionary_columns', 'U') IS NULL
CREATE TABLE [ods_datadictionary_columns] (
    [dictionary_column_id]  NVARCHAR(450) NOT NULL PRIMARY KEY CLUSTERED,
    [entitylogicalname]     NVARCHAR(450) NULL,
    [logicalname]           NVARCHAR(450) NULL,
    [displayname]           NVARCHAR(MAX) NULL,
    [schemaname]            NVARCHAR(MAX) NULL,
    [attributetype]         NVARCHAR(200) NULL,
    [requiredlevel]         NVARCHAR(100) NULL,
    [maxlength]             INT NULL,
    [description]           NVARCHAR(MAX) NULL,
    [sql_column_name]       NVARCHAR(450) NULL,
    [sql_data_type]         NVARCHAR(200) NULL,
    [row_count]             BIGINT NULL,
    [non_null_count]        BIGINT NULL,
    [distinct_count]        BIGINT NULL,
    [density_pct]           DECIMAL(5,2) NULL,
    [has_data]              BIT NULL,
    [modifiedon]            DATETIME2 NULL
);
"@
    $SQL.ExecuteNonQuery($createTablesDDL)

    # -------------------------------------------------------
    # Collect Dataverse metadata for all synced tables
    # -------------------------------------------------------
    $entityMeta = @{}   # logicalname -> { displayname, schemaname, metadataid }
    $columnMeta = @{}   # "entity|column" -> { displayname, schemaname, type, ... }

    # Fetch all entity definitions once
    try {
        $url = "$($Dataverse.EnvironmentUrl)api/data/v9.2/EntityDefinitions?`$select=LogicalName,SchemaName,DisplayName,MetadataId"
        $allEntities = @{}
        do {
            $response = $Dataverse.InvokeApiCall($url)
            foreach ($e in $response.value) {
                $dName = $e.SchemaName
                if ($e.DisplayName -and $e.DisplayName.UserLocalizedLabel) {
                    $dName = $e.DisplayName.UserLocalizedLabel.Label
                }
                $allEntities[$e.LogicalName] = @{
                    displayname = $dName
                    schemaname  = $e.SchemaName
                    metadataid  = $e.MetadataId
                }
            }
            $url = $null
            if ($response.PSObject.Properties['@odata.nextLink']) {
                $url = $response.'@odata.nextLink'
            }
        } while ($url)

        foreach ($tblInfo in $TableList) {
            $eName = $tblInfo.LogicalName
            if ($eName -eq "GlobalChoices" -or $eName -like "ods_*") { continue }
            if ($allEntities.ContainsKey($eName)) {
                $entityMeta[$eName] = $allEntities[$eName]
            }
        }
    }
    catch {
        $Logger.Warn("Could not fetch entity definitions: $($_.Exception.Message)")
    }

    # Fetch attribute definitions per table
    foreach ($tblInfo in $TableList) {
        $eName = $tblInfo.LogicalName
        if ($eName -eq "GlobalChoices" -or $eName -like "ods_*") { continue }

        try {
            # MaxLength and Description removed from $select -- both 400 against
            # the heterogeneous `Attributes` collection because they aren't on
            # the base AttributeMetadata type (MaxLength is only on
            # StringAttributeMetadata; Description got tightened by Microsoft
            # mid-2026). The fields we keep are all base-class properties.
            # To get back per-subtype detail (max length, description), do a
            # second pass with a cast: .../Attributes/Microsoft.Dynamics.CRM.<Subtype>?...
            $url = "$($Dataverse.EnvironmentUrl)api/data/v9.2/EntityDefinitions(LogicalName='$eName')/Attributes?`$select=LogicalName,SchemaName,DisplayName,MetadataId,AttributeType,RequiredLevel"
            $response = $Dataverse.InvokeApiCall($url)
            foreach ($a in $response.value) {
                $dName = $a.SchemaName
                if ($a.DisplayName -and $a.DisplayName.UserLocalizedLabel) {
                    $dName = $a.DisplayName.UserLocalizedLabel.Label
                }
                $desc = ""
                if ($a.PSObject.Properties['Description'] -and $a.Description -and $a.Description.UserLocalizedLabel) {
                    $desc = $a.Description.UserLocalizedLabel.Label
                }
                $maxLen = 0
                if ($a.PSObject.Properties['MaxLength'] -and $null -ne $a.MaxLength) {
                    $maxLen = [int]$a.MaxLength
                }
                $reqLevel = ""
                if ($a.PSObject.Properties['RequiredLevel'] -and $null -ne $a.RequiredLevel) {
                    $reqLevel = $a.RequiredLevel.Value
                }

                $key = "$eName|$($a.LogicalName)"
                $columnMeta[$key] = @{
                    displayname   = $dName
                    schemaname    = $a.SchemaName
                    attributetype = $a.AttributeType
                    requiredlevel = $reqLevel
                    maxlength     = $maxLen
                    description   = $desc
                    metadataid    = $a.MetadataId
                }
            }
        }
        catch {
            # Surface the response body if Dataverse returned one -- the
            # default Exception.Message just says "Bad Request" and hides
            # the real error code.
            $detail = ""
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $detail = $_.ErrorDetails.Message
                if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) + "..." }
                $detail = " | body: $detail"
            }
            $Logger.Warn("Could not fetch attributes for $eName : $($_.Exception.Message)$detail")
        }
    }

    # -------------------------------------------------------
    # Lookup pass: fetch each entity's lookup attributes + their
    # target entities. Populates lookupMap keyed by "<entity>|<attribute>"
    # -> list of target entity logical names. Used below to set
    # is_lookup / lookup_targets on column records AND to build the
    # ods_datadictionary_relationships rows.
    # -------------------------------------------------------
    $lookupMap = @{}   # "<entity>|<attribute>" -> [string[]]targets
    foreach ($tblInfo in $TableList) {
        $eName = $tblInfo.LogicalName
        if ($eName -eq "GlobalChoices" -or $eName -like "ods_*") { continue }

        try {
            $lookupRows = $Dataverse.FetchLookupAttributes($eName)
            foreach ($lk in $lookupRows) {
                $targets = @()
                if ($lk.Targets) { $targets = @($lk.Targets) }
                $lookupMap["$eName|$($lk.LogicalName)"] = $targets
            }
        }
        catch {
            $Logger.Warn("Could not fetch lookups for $eName : $($_.Exception.Message)")
        }
    }
    $Logger.Info("Lookup pass: indexed $($lookupMap.Count) lookup attributes across $($TableList.Count) tables.")

    # -------------------------------------------------------
    # Build table-level & column-level dictionary records
    # -------------------------------------------------------
    $tableRecords         = [System.Collections.Generic.List[PSObject]]::new()
    $columnRecords        = [System.Collections.Generic.List[PSObject]]::new()
    $relationshipRecords  = [System.Collections.Generic.List[PSObject]]::new()
    $now = [datetime]::UtcNow

    foreach ($tblInfo in $TableList) {
        $eName = $tblInfo.LogicalName
        if ($eName -eq "GlobalChoices" -or $eName -like "ods_*") { continue }

        $sqlTableName = if ($tblInfo.SqlTableName) { $SqlPrefix + $tblInfo.SqlTableName } else { $SqlPrefix + $eName }
        $displayName = $eName
        $schemaName = $eName
        if ($entityMeta.ContainsKey($eName)) {
            $displayName = $entityMeta[$eName].displayname
            $schemaName  = $entityMeta[$eName].schemaname
        }

        $rowCount = 0
        $totalCols = 0
        $colsWithData = 0

        try {
            $tableExistsResult = $SQL.ExecuteQuery("SELECT COUNT(*) AS cnt FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$sqlTableName'")
            if ($tableExistsResult -and $tableExistsResult[0].cnt -gt 0) {
                $countResult = $SQL.ExecuteQuery("SELECT COUNT(*) AS cnt FROM [$sqlTableName]")
                $rowCount = [long]$countResult[0].cnt

                $sqlColumns = $SQL.ExecuteQuery("SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$sqlTableName' ORDER BY ORDINAL_POSITION")
                $totalCols = $sqlColumns.Count

                foreach ($colRow in $sqlColumns) {
                    $colName = $colRow.COLUMN_NAME
                    $sqlDataType = $colRow.DATA_TYPE
                    if ($colName -match '^@' -or $colName -match '^_.*_value@') { continue }

                    $nonNull = 0
                    $distinctVals = 0
                    $hasData = $false

                    if ($rowCount -gt 0) {
                        try {
                            $stats = $SQL.ExecuteQuery(@"
                                SELECT 
                                    COUNT([$colName]) AS non_null_count,
                                    COUNT(DISTINCT [$colName]) AS distinct_count
                                FROM [$sqlTableName]
"@)
                            $nonNull = [long]$stats[0].non_null_count
                            $distinctVals = [long]$stats[0].distinct_count
                            $hasData = $nonNull -gt 0
                        }
                        catch {
                            try {
                                $nnCheck = $SQL.ExecuteQuery("SELECT COUNT([$colName]) AS nn FROM [$sqlTableName]")
                                $nonNull = [long]$nnCheck[0].nn
                                $hasData = $nonNull -gt 0
                                $distinctVals = -1
                            } catch {}
                        }
                    }

                    if ($hasData) { $colsWithData++ }

                    $density = if ($rowCount -gt 0) { [math]::Round(($nonNull / $rowCount) * 100, 2) } else { 0 }

                    $metaKey = "$eName|$colName"
                    $colDisplay = $colName
                    $colSchema = $colName
                    $colType = ""
                    $colReq = ""
                    $colMaxLen = 0
                    $colDesc = ""
                    $colMetaId = ""
                    if ($columnMeta.ContainsKey($metaKey)) {
                        $cm = $columnMeta[$metaKey]
                        $colDisplay = $cm.displayname
                        $colSchema  = $cm.schemaname
                        $colType    = $cm.attributetype
                        $colReq     = $cm.requiredlevel
                        $colMaxLen  = $cm.maxlength
                        $colDesc    = $cm.description
                        $colMetaId  = $cm.metadataid
                    }

                    # Lookup classification. Dataverse exposes lookup values in
                    # the SQL replica as `_<attribute>_value` columns. Strip
                    # that pattern to recover the CRM attribute logical name
                    # and check the lookup map for targets.
                    $isLookup = $false
                    $lookupTargetsJson = $null
                    $lookupAttrName = $null
                    if ($colName -match '^_(.+)_value$') {
                        $lookupAttrName = $Matches[1]
                    }
                    if ($lookupAttrName -and $lookupMap.ContainsKey("$eName|$lookupAttrName")) {
                        $targetList = $lookupMap["$eName|$lookupAttrName"]
                        if ($targetList -and $targetList.Count -gt 0) {
                            $isLookup = $true
                            $lookupTargetsJson = (ConvertTo-Json -InputObject @($targetList) -Compress)
                            foreach ($target in $targetList) {
                                if (-not $target) { continue }
                                $relationshipRecords.Add([PSCustomObject]@{
                                    relationship_id = "$eName|$lookupAttrName|$target"
                                    from_entity     = $eName
                                    from_attribute  = $lookupAttrName
                                    from_sql_column = $colName
                                    to_entity       = $target
                                    modifiedon      = $now
                                })
                            }
                        }
                    }

                    $colId = if ($colMetaId) { $colMetaId } else { "$eName|$colName" }

                    $columnRecords.Add([PSCustomObject]@{
                        dictionary_column_id = $colId
                        entitylogicalname    = $eName
                        logicalname          = $colName
                        displayname          = $colDisplay
                        schemaname           = $colSchema
                        attributetype        = $colType
                        requiredlevel        = $colReq
                        maxlength            = $colMaxLen
                        description          = $colDesc
                        sql_column_name      = $colName
                        sql_data_type        = $sqlDataType
                        row_count            = $rowCount
                        non_null_count       = $nonNull
                        distinct_count       = $distinctVals
                        density_pct          = $density
                        has_data             = $hasData
                        is_lookup            = $isLookup
                        lookup_targets       = $lookupTargetsJson
                        modifiedon           = $now
                    })
                }
            }
        }
        catch {
            $Logger.Warn("Stats collection failed for [$sqlTableName]: $($_.Exception.Message)")
        }

        $dataDensity = if ($totalCols -gt 0) { [math]::Round(($colsWithData / $totalCols) * 100, 2) } else { 0 }

        $tblId = $eName
        if ($entityMeta.ContainsKey($eName) -and $entityMeta[$eName].metadataid) {
            $tblId = $entityMeta[$eName].metadataid
        }

        $tableRecords.Add([PSCustomObject]@{
            dictionary_table_id = $tblId
            logicalname         = $eName
            displayname         = $displayName
            schemaname          = $schemaName
            sql_table_name      = $sqlTableName
            row_count           = $rowCount
            column_count        = $totalCols
            columns_with_data   = $colsWithData
            data_density_pct    = $dataDensity
            sync_source         = $tblInfo.Source
            last_sync_utc       = $now
            modifiedon          = $now
        })
    }

    # Upsert the dictionary tables
    if ($tableRecords.Count -gt 0) {
        $Logger.Info("Upserting $($tableRecords.Count) records into [ods_datadictionary_tables]")
        $SQL.BulkUpsert("ods_datadictionary_tables", "dictionary_table_id", $tableRecords, $Logger)
    }
    if ($columnRecords.Count -gt 0) {
        $Logger.Info("Upserting $($columnRecords.Count) records into [ods_datadictionary_columns]")
        $SQL.BulkUpsert("ods_datadictionary_columns", "dictionary_column_id", $columnRecords, $Logger)
    }
    if ($relationshipRecords.Count -gt 0) {
        $Logger.Info("Upserting $($relationshipRecords.Count) records into [ods_datadictionary_relationships]")
        $SQL.BulkUpsert("ods_datadictionary_relationships", "relationship_id", $relationshipRecords, $Logger)
    }

    $Logger.Success("Data dictionary updated: $($tableRecords.Count) tables, $($columnRecords.Count) columns, $($relationshipRecords.Count) relationships.")
}

# ==============================================================================
# REGION: RECONCILE-DELETES PASS
# ==============================================================================

function Invoke-ReconcileDeletes {
    <#
    .SYNOPSIS
        Soft-deletes rows that have vanished from Dataverse since the last
        replica sync. For every replica table:
          1. Pulls all live PKs from Dataverse ($select=<pk>).
          2. Pulls all SQL PKs grouped by is_active.
          3. Computes newly_missing  = active in SQL but not in Dataverse.
          4. Computes reappeared     = inactive in SQL but back in Dataverse.
          5. Updates is_active / detected_missing_utc accordingly via a
             bulk-loaded #temp table and a single UPDATE...JOIN per direction.

        Safety guard: if more than $MaxMissingPct of the active rows in a table
        would be flagged as missing in one pass, skips that table and writes
        a row to ops.review_queue. Protects against transient Dataverse
        failures that return partial results.

        Does NOT physically delete anything. Reporting views are expected to
        filter `WHERE is_active = 1` to hide soft-deleted rows.
    #>
    param(
        # $Dataverse: [DataverseConnector]; $SQL: [SQLConnector];
        # $Logger: [SyncLogger]; $RunLog: [OpsRunLog].
        # Types intentionally omitted -- see top-of-file note re class identity.
        $Dataverse,
        $SQL,
        [string]$SqlConnectionString,
        [string]$SqlPrefix,
        [System.Collections.Generic.List[hashtable]]$TableList,
        $Logger,
        $RunLog,
        [double]$MaxMissingPct = 0.75,
        # Percentage threshold only applies when active row count >= this.
        # Tiny tables (e.g. 3 rows) produce meaningless percentages, so we
        # skip the check below this floor -- the Dataverse-returned-zero
        # guard still catches the catastrophic case.
        [int]$MinRowCountForThreshold = 10,
        [bool]$DryRun = $false
    )

    $Logger.Info("=== Reconcile-Deletes Pass Started (DryRun=$DryRun, threshold=$([math]::Round($MaxMissingPct*100,1))% above $MinRowCountForThreshold rows) ===")

    $totalFlagged = 0L
    $totalReappeared = 0L
    $totalErrors = 0L
    $totalSkipped = 0L

    foreach ($tblInfo in $TableList) {
        $entityName = $tblInfo.LogicalName

        # Skip metadata / option-set replicas -- they don't have a stable
        # row-as-entity model and aren't subject to user deletes.
        if ($entityName -eq "GlobalChoices" -or $entityName -like "ods_*") { continue }

        $sqlTableName = if ($tblInfo.SqlTableName) { $SqlPrefix + $tblInfo.SqlTableName } else { $SqlPrefix + $entityName }
        $pk = if ($tblInfo.PrimaryKey) { $tblInfo.PrimaryKey } else { $entityName + "id" }

        $tableLogger = $Logger.ForTable($entityName)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $flagged = 0
        $reappeared = 0
        $tableStatus = "success"
        $tableErr = ""

        try {
            # 1. SQL table must exist
            $existsResult = $SQL.ExecuteQuery("SELECT COUNT(*) AS cnt FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$sqlTableName'")
            if (-not $existsResult -or $existsResult[0].cnt -eq 0) {
                $tableLogger.Info("Reconcile: SQL table doesn't exist yet; skipping.")
                $totalSkipped++
                continue
            }

            # 2. Soft-delete columns must exist (sql\0002_softdelete_columns.sql run)
            $colsResult = $SQL.ExecuteQuery("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$sqlTableName' AND COLUMN_NAME IN ('is_active', 'detected_missing_utc')")
            if ($colsResult.Count -lt 2) {
                $tableLogger.Warn("Reconcile: missing is_active/detected_missing_utc on [$sqlTableName] (run sql\0002_softdelete_columns.sql); skipping.")
                $totalSkipped++
                continue
            }

            # 3. Live PKs from Dataverse
            $tableLogger.Info("Reconcile: fetching live PKs from Dataverse...")
            $livePks = $Dataverse.FetchAllPrimaryKeys($entityName, $pk)
            $tableLogger.Info("Reconcile: $($livePks.Count) live rows in Dataverse.")

            # Safety: if the Dataverse fetch returned 0 rows but SQL has many,
            # something is wrong (auth, throttling, transient error). Refuse
            # to flag everything as missing.
            $sqlCount = [long]($SQL.ExecuteQuery("SELECT COUNT(*) AS cnt FROM [$sqlTableName] WHERE is_active = 1"))[0].cnt
            if ($livePks.Count -eq 0 -and $sqlCount -gt 0) {
                $msg = "Dataverse returned 0 rows for $entityName but SQL has $sqlCount active rows. Refusing to flag. Investigate before re-running."
                $tableLogger.Warn($msg)
                if (-not $DryRun) {
                    $SQL.ExecuteNonQuery("INSERT INTO ops.review_queue (source, source_table, reason, status) VALUES ('CRMReconcileDeletes', '$sqlTableName', '$($msg -replace "'", "''")', 'open')")
                }
                $totalSkipped++
                continue
            }

            # 4. SQL PKs grouped by is_active
            $sqlActive = [System.Collections.Generic.HashSet[guid]]::new()
            $sqlInactive = [System.Collections.Generic.HashSet[guid]]::new()
            $sqlRows = $SQL.ExecuteQuery("SELECT [$pk] AS pk, is_active FROM [$sqlTableName] WHERE [$pk] IS NOT NULL")
            foreach ($r in $sqlRows) {
                try {
                    $g = [guid]$r.pk
                    if ([bool]$r.is_active) {
                        $sqlActive.Add($g) | Out-Null
                    } else {
                        $sqlInactive.Add($g) | Out-Null
                    }
                } catch {}
            }

            # 5. Set differences
            $newlyMissing = [System.Collections.Generic.HashSet[guid]]::new($sqlActive)
            $newlyMissing.ExceptWith($livePks)

            $reappearedSet = [System.Collections.Generic.HashSet[guid]]::new($sqlInactive)
            $reappearedSet.IntersectWith($livePks)

            # 6. Threshold guard -- only meaningful above the floor
            $totalActive = $sqlActive.Count
            if ($totalActive -ge $MinRowCountForThreshold -and $newlyMissing.Count -gt 0) {
                $pct = $newlyMissing.Count / $totalActive
                if ($pct -gt $MaxMissingPct) {
                    $msg = "Reconcile threshold exceeded -- would flag $($newlyMissing.Count) / $totalActive ($([math]::Round($pct*100,1))%) as missing (threshold $([math]::Round($MaxMissingPct*100,1))%). Skipping."
                    $tableLogger.Warn($msg)
                    if (-not $DryRun) {
                        $payload = "{`"newMissing`": $($newlyMissing.Count), `"totalActive`": $totalActive, `"pct`": $([math]::Round($pct*100,1))}"
                        $SQL.ExecuteNonQuery(@"
INSERT INTO ops.review_queue (source, source_table, reason, payload_json, status)
VALUES ('CRMReconcileDeletes', '$sqlTableName', '$($msg -replace "'", "''")', '$payload', 'open')
"@)
                    }
                    $totalSkipped++
                    continue
                }
            }

            if ($DryRun) {
                $tableLogger.Info("Reconcile [DRY]: would flag $($newlyMissing.Count) missing, $($reappearedSet.Count) reappeared.")
                $flagged = $newlyMissing.Count
                $reappeared = $reappearedSet.Count
            }
            else {
                # 7. Apply changes via bulk-loaded #temp tables (handles large sets)
                if ($newlyMissing.Count -gt 0) {
                    $flagged = Update-SqlReconcileFlag -ConnString $SqlConnectionString -TableName $sqlTableName -PrimaryKey $pk -Pks $newlyMissing -IsActive $false
                    $tableLogger.Success("Reconcile: flagged $flagged rows missing in [$sqlTableName].")
                }
                if ($reappearedSet.Count -gt 0) {
                    $reappeared = Update-SqlReconcileFlag -ConnString $SqlConnectionString -TableName $sqlTableName -PrimaryKey $pk -Pks $reappearedSet -IsActive $true
                    $tableLogger.Success("Reconcile: cleared missing flag on $reappeared reappeared rows.")
                }
                if ($newlyMissing.Count -eq 0 -and $reappearedSet.Count -eq 0) {
                    $tableLogger.Info("Reconcile: no changes.")
                }
            }

            $totalFlagged += $flagged
            $totalReappeared += $reappeared
        }
        catch {
            $tableStatus = "error"
            $tableErr = $_.Exception.Message
            $tableLogger.Error("Reconcile failed for $entityName : $tableErr")
            $Logger.Error("Reconcile failed for $entityName : $tableErr")
            $totalErrors++
        }

        $sw.Stop()
        $RunLog.LogTable(
            $entityName,
            "reconcile_deletes",
            [long]($flagged + $reappeared),
            [int]$sw.ElapsedMilliseconds,
            $tableStatus,
            $tableErr
        )
    }

    $Logger.Info("Reconcile-Deletes complete: flagged=$totalFlagged, reappeared=$totalReappeared, skipped=$totalSkipped, errors=$totalErrors")
    return @{
        Flagged    = $totalFlagged
        Reappeared = $totalReappeared
        Skipped    = $totalSkipped
        Errors     = $totalErrors
    }
}

function Update-SqlReconcileFlag {
    <#
    .SYNOPSIS
        Bulk-load a set of GUIDs into a #temp table and UPDATE...JOIN
        to flip is_active / detected_missing_utc on matching rows.
        Returns the number of rows actually updated.
    #>
    param(
        [string]$ConnString,
        [string]$TableName,
        [string]$PrimaryKey,
        [System.Collections.Generic.HashSet[guid]]$Pks,
        [bool]$IsActive
    )

    if ($Pks.Count -eq 0) { return 0 }

    $conn = [System.Data.SqlClient.SqlConnection]::new($ConnString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $stage = "#recon_" + [Guid]::NewGuid().ToString("N")
        $cmd.CommandText = "CREATE TABLE $stage (pk UNIQUEIDENTIFIER PRIMARY KEY)"
        $cmd.ExecuteNonQuery() | Out-Null

        $dt = [System.Data.DataTable]::new()
        $dt.Columns.Add("pk", [guid]) | Out-Null
        foreach ($g in $Pks) { $dt.Rows.Add($g) | Out-Null }

        $bulk = [System.Data.SqlClient.SqlBulkCopy]::new($conn)
        $bulk.DestinationTableName = $stage
        $bulk.BulkCopyTimeout = 300
        $bulk.WriteToServer($dt)

        if ($IsActive) {
            $cmd.CommandText = @"
UPDATE t SET t.is_active = 1, t.detected_missing_utc = NULL
FROM [$TableName] t
INNER JOIN $stage s ON s.pk = t.[$PrimaryKey];
"@
        } else {
            $cmd.CommandText = @"
UPDATE t SET t.is_active = 0, t.detected_missing_utc = SYSUTCDATETIME()
FROM [$TableName] t
INNER JOIN $stage s ON s.pk = t.[$PrimaryKey]
WHERE t.is_active = 1;  -- belt-and-suspenders: don't restamp already-flagged rows
"@
        }
        $cmd.CommandTimeout = 300
        $affected = $cmd.ExecuteNonQuery()

        $cmd.CommandText = "DROP TABLE $stage"
        $cmd.ExecuteNonQuery() | Out-Null

        return $affected
    }
    finally { $conn.Dispose() }
}

# ==============================================================================
# REGION: MAIN EXECUTION
# ==============================================================================

if (-not (Test-Path $ConfigPath)) { Write-Error "Config file not found: $ConfigPath"; exit 1 }

try { [xml]$xml = Get-Content $ConfigPath -Raw; $cfg = $xml.Config }
catch { Write-Error "Invalid XML Config"; exit 1 }

# Config Parsing
$OrgUrl = Get-XmlProp $cfg.Dataverse "OrgUrl"
$ClientId = Get-XmlProp $cfg.Dataverse "ClientId"
$TenantId = Get-XmlProp $cfg.Dataverse "TenantId"
$ClientSecret = Get-XmlProp $cfg.Dataverse "ClientSecret"

$SqlUser = Get-XmlProp $cfg.Sql "Username"
$SqlPass = Get-XmlProp $cfg.Sql "Password"
$SqlServer = Get-XmlProp $cfg.Sql "Server"
$SqlDb = Get-XmlProp $cfg.Sql "Database"
$SqlPrefix = Get-XmlProp $cfg.Sql "TablePrefix" ""

$SqlStr = if ($SqlUser) { 
    "Server=$SqlServer;Database=$SqlDb;User Id=$SqlUser;Password=$SqlPass;TrustServerCertificate=True;" 
} else { 
    "Server=$SqlServer;Database=$SqlDb;Integrated Security=True;TrustServerCertificate=True;" 
}

$LogPath = Get-XmlProp $cfg.Paths "LogPath" (Join-Path $PSScriptRoot "sync.log")
$StatePath = Get-XmlProp $cfg.Paths "StatePath" (Join-Path $PSScriptRoot "state.json")
$BatchSize = [int](Get-XmlProp $cfg.Performance "BatchSize" 5000)
$PageSize = [int](Get-XmlProp $cfg.Performance "PageSize" 5000)
$MaxParallel = [int](Get-XmlProp $cfg.Performance "MaxParallel" 5)

$Logger = [SyncLogger]::new($LogPath)
$Logger.Info("=== Job Started (v3.0 - Prefix/Dictionary/Views) ===")

# Apply ops.pipeline_config overrides if present. Fails open (XML values stand
# when the ops schema isn't created or the table is empty).
$BatchSize   = [int](Get-PipelineConfigOverride -ConnString $SqlStr -Pipeline "CRMToSQL" -ConfigKey "BatchSize"   -DefaultValue $BatchSize   -Logger $Logger)
$PageSize    = [int](Get-PipelineConfigOverride -ConnString $SqlStr -Pipeline "CRMToSQL" -ConfigKey "PageSize"    -DefaultValue $PageSize    -Logger $Logger)
$MaxParallel = [int](Get-PipelineConfigOverride -ConnString $SqlStr -Pipeline "CRMToSQL" -ConfigKey "MaxParallel" -DefaultValue $MaxParallel -Logger $Logger)

# Hoisted so the catch block can safely reference them under StrictMode.
$RunLog = $null
$totalRows = 0L
$totalErrors = 0L

try {
    # Initialize Connectors
    $Dataverse = [DataverseConnector]::new($OrgUrl, $PageSize, $ClientId, $TenantId, $ClientSecret)
    $SQL = [SQLConnector]::new($SqlStr, $BatchSize)

    # Test Mode
    if ($TestConnection) {
        Write-Host "`nTesting Connections..." -ForegroundColor Cyan
        try {
            $null = $Dataverse.InvokeApiCall("$($Dataverse.EnvironmentUrl)api/data/v9.2/WhoAmI")
            Write-Host "Dataverse: OK" -ForegroundColor Green
            $SQL.TestConnection()
            Write-Host "SQL: OK" -ForegroundColor Green
        } catch {
            Write-Error "Connection Test Failed: $_"
        }
        exit 0
    }

    # === Reconcile-Deletes Mode ===========================================
    # Runs the soft-delete reconcile pass instead of the sync. Uses the same
    # config + table resolution as the sync. Daily schedule recommended,
    # outside the hourly sync window.
    if ($ReconcileDeletes) {
        $RunLog = [OpsRunLog]::new($SqlStr, "CRMReconcileDeletes")
        $RunLog.Start("DryRun=$DryRun, threshold=$([math]::Round($MaxMissingPct*100,1))%")

        $resolvedTables = Resolve-TableList -ConfigXml $xml -Dataverse $Dataverse -Logger $Logger
        $resolvedTables = Select-RequestedTables -Resolved $resolvedTables -Requested $Table -Logger $Logger
        if ($resolvedTables.Count -eq 0) { throw "Reconcile: no tables to scan (or -Table override matched nothing)." }

        $reconcileResult = Invoke-ReconcileDeletes `
            -Dataverse $Dataverse `
            -SQL $SQL `
            -SqlConnectionString $SqlStr `
            -SqlPrefix $SqlPrefix `
            -TableList $resolvedTables `
            -Logger $Logger `
            -RunLog $RunLog `
            -MaxMissingPct $MaxMissingPct `
            -MinRowCountForThreshold $MinRowCountForThreshold `
            -DryRun:$DryRun

        $finalStatus = if ($reconcileResult.Errors -gt 0) { "partial" } else { "success" }
        $RunLog.Complete(
            $finalStatus,
            0L,
            [long]($reconcileResult.Flagged + $reconcileResult.Reappeared),
            [long]$reconcileResult.Errors
        )
        $Logger.Success("=== Reconcile-Deletes Completed (flagged=$($reconcileResult.Flagged), reappeared=$($reconcileResult.Reappeared), skipped=$($reconcileResult.Skipped), errors=$($reconcileResult.Errors)) ===")
        exit 0
    }

    # Open a row in ops.runlog (fails open if ops.* not yet created).
    # Pipeline name reflects the mode so the dashboard separates the
    # hourly sync from the daily refresh in historical reporting.
    $pipelineName = if ($Mode -eq 'Sync') { "CRMToSQL" } else { "CRMRefresh" }
    $RunLog = [OpsRunLog]::new($SqlStr, $pipelineName)
    $RunLog.Start("Mode=$Mode")
    $Logger.Info("Mode: $Mode  (pipeline: $pipelineName)")

    # Watermark store only matters when we're actually syncing data.
    # DictionaryOnly skips bootstrap and the sync entirely.
    $Watermarks = $null
    if ($Mode -ne 'DictionaryOnly') {
        $Watermarks = [WatermarkStore]::new($SqlStr, $StatePath)
        if ($Watermarks.SqlAvailable) {
            $migrated = $Watermarks.BootstrapFromJson()
            if ($migrated -gt 0) {
                $Logger.Info("WatermarkStore: bootstrapped $migrated entity watermarks from $StatePath into ops.crm_sync_watermark.")
            }
        }
    }

    # =========================================================================
    # FEATURE 1: Resolve full table list (explicit + prefix + syncAll)
    # =========================================================================
    $resolvedTables = Resolve-TableList -ConfigXml $xml -Dataverse $Dataverse -Logger $Logger
    $resolvedTables = Select-RequestedTables -Resolved $resolvedTables -Requested $Table -Logger $Logger

    if ($resolvedTables.Count -eq 0) { throw "No tables to sync (check config <Tables> section, or -Table override matched nothing)." }

    # Build a compat array for methods expecting objects with .LogicalName
    $configuredTablesCompat = $resolvedTables | ForEach-Object {
        [PSCustomObject]@{ LogicalName = $_.LogicalName }
    }

    # =========================================================================
    # SYNC LOOP (Parallel via Runspaces - MaxParallel tables at a time)
    # Skipped entirely in DictionaryOnly mode.
    # =========================================================================
    if ($Mode -eq 'DictionaryOnly') {
        $Logger.Info("Mode=DictionaryOnly: skipping data sync.")
    }
    else {

    # Separate special tables (must run sequentially first) from standard data tables
    $specialTables = [System.Collections.Generic.List[hashtable]]::new()
    $standardTables = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($tblInfo in $resolvedTables) {
        $eName = $tblInfo.LogicalName
        if ($eName -eq "GlobalChoices" -or $eName -eq "ods_metadata" -or $eName -eq "ods_metadata_columns") {
            $specialTables.Add($tblInfo)
        } else {
            $standardTables.Add($tblInfo)
        }
    }

    # --- Sync special tables sequentially (they depend on shared state/metadata) ---
    foreach ($tblInfo in $specialTables) {
        $entityName = $tblInfo.LogicalName
        $rawSqlName = $tblInfo.SqlTableName
        $sqlTableName = if ($rawSqlName) { $SqlPrefix + $rawSqlName } else { $SqlPrefix + $entityName }
        $pk = if ($tblInfo.PrimaryKey) { $tblInfo.PrimaryKey } else { $entityName + "id" }

        $tableLogger = $Logger.ForTable($entityName)
        $Logger.Info("Syncing [$entityName] -> [$sqlTableName] (source: $($tblInfo.Source))")
        $tableLogger.Info("=== Sync Started ===")

        $swSpecial = [System.Diagnostics.Stopwatch]::StartNew()
        $specialRows = 0L
        $specialStatus = "success"
        $specialErr = ""

        try {
            $records = $null

            if ($entityName -eq "GlobalChoices") {
                $pk = "globalchoiceid"
                $records = $Dataverse.FetchAllOptionSets($configuredTablesCompat)
            }
            elseif ($entityName -eq "ods_metadata") {
                $pk = "entityid"
                $records = $Dataverse.FetchEntityDefinitions()
            }
            elseif ($entityName -eq "ods_metadata_columns") {
                $pk = "columnid"
                $records = $Dataverse.FetchAttributeDefinitions($configuredTablesCompat)
            }

            if ($records.Count -gt 0) {
                $SQL.BulkUpsert($sqlTableName, $pk, $records, $tableLogger)
                $tableLogger.Success("Synced $($records.Count) records.")
                $specialRows = [long]$records.Count
            } else {
                $tableLogger.Info("No new records found.")
            }
        }
        catch {
            $specialStatus = "error"
            $specialErr = $_.Exception.Message
            $tableLogger.Error("Failed to sync: $($_.Exception.Message)")
            $Logger.Error("Failed to sync table $entityName : $($_.Exception.Message)")
            $totalErrors++
        }

        $swSpecial.Stop()
        $RunLog.LogTable($entityName, "upsert", $specialRows, [int]$swSpecial.ElapsedMilliseconds, $specialStatus, $specialErr)
        $totalRows += $specialRows
    }

    # --- Sync standard data tables in parallel ---
    if ($standardTables.Count -gt 0) {
        $Logger.Info("Starting parallel sync of $($standardTables.Count) standard tables (MaxParallel=$MaxParallel)")

        # Per-table error tracking happens through $r.Success in the reap loop;
        # state advances happen via $Watermarks.Set after each successful job.

        # Build the scriptblock that each runspace will execute
        $syncScriptBlock = {
            param(
                [hashtable]$TblInfo,
                [string]$SqlConnectionString,
                [int]$BatchSize,
                [string]$OrgUrl,
                [int]$PageSize,
                [string]$ClientId,
                [string]$TenantId,
                [string]$ClientSecret,
                [string]$SqlPrefix,
                [string]$StateFilePath,
                [string]$LogBaseDir,
                [string]$ModulePath,
                [bool]$FullLoad
            )

            # Each runspace needs its own strict mode + error pref
            Set-StrictMode -Version 2.0
            $ErrorActionPreference = "Stop"

            $entityName = $TblInfo.LogicalName
            $rawSqlName = $TblInfo.SqlTableName
            $sqlTableName = if ($rawSqlName) { $SqlPrefix + $rawSqlName } else { $SqlPrefix + $entityName }
            $pk = if ($TblInfo.PrimaryKey) { $TblInfo.PrimaryKey } else { $entityName + "id" }

            # Per-table log file (flat: logs/tables/<entityName>.log)
            $tableLogDir = Join-Path $LogBaseDir "tables"
            if (-not (Test-Path $tableLogDir)) { New-Item -ItemType Directory -Path $tableLogDir -Force | Out-Null }
            $tableLogPath = Join-Path $tableLogDir "$entityName.log"

            function Write-TableLog([string]$msg, [string]$level) {
                $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                $entry = "$ts | $($level.PadRight(7)) | [$entityName] $msg"
                $color = switch ($level) { "ERROR" { "Red" } "WARN" { "Yellow" } "SUCCESS" { "Green" } default { "Cyan" } }
                Write-Host "[$level] [$entityName] $msg" -ForegroundColor $color
                try { $entry | Out-File -FilePath $tableLogPath -Append -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
            }

            Write-TableLog "=== Sync Started ===" "INFO"

            $result = @{ Success = $false; EntityName = $entityName; Error = ""; MaxModifiedOn = $null; RecordCount = 0; DurationMs = 0 }
            $swT = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                # --- Authenticate to Dataverse (each runspace gets its own token) ---
                $baseUrl = $OrgUrl.TrimEnd('/') + "/"
                $token = $null

                $useInteractive = [string]::IsNullOrWhiteSpace($ClientSecret) -or $ClientSecret -eq "INTERACTIVE"
                if (-not $useInteractive) {
                    $authUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
                    $scope = $baseUrl + ".default"
                    $body = @{ client_id = $ClientId; client_secret = $ClientSecret; scope = $scope; grant_type = "client_credentials" }
                    $response = Invoke-RestMethod -Uri $authUrl -Method Post -Body $body -ErrorAction Stop
                    $token = $response.access_token
                } else {
                    if (-not (Get-Module -Name Az.Accounts)) { Import-Module Az.Accounts -ErrorAction Stop }
                    $context = Get-AzContext
                    if (-not $context) { $context = Connect-AzAccount }
                    $tokenObj = Get-AzAccessToken -ResourceUrl $baseUrl
                    $token = $tokenObj.Token
                }

                $headers = @{
                    Authorization      = "Bearer $token"
                    Accept             = "application/json"
                    "OData-MaxVersion" = "4.0"
                    "OData-Version"    = "4.0"
                    Prefer             = "odata.maxpagesize=$PageSize"
                    "User-Agent"       = "DataverseSqlSync/3.0"
                }

                # --- Read last sync state ---
                # SQL ops.crm_sync_watermark is the source of truth. Fall back
                # to JSON only if SQL has no row yet (bootstrap edge case).
                $lastSync = [datetime]::MinValue
                $wmFromSql = $false
                try {
                    $wmConn = [System.Data.SqlClient.SqlConnection]::new($SqlConnectionString)
                    $wmConn.Open()
                    try {
                        $wmCmd = $wmConn.CreateCommand()
                        $wmCmd.CommandText = "SELECT last_modified_utc FROM ops.crm_sync_watermark WHERE logical_name = @e"
                        $wmCmd.Parameters.AddWithValue("@e", $entityName) | Out-Null
                        $wmResult = $wmCmd.ExecuteScalar()
                        if (($null -ne $wmResult) -and ($wmResult -isnot [System.DBNull])) {
                            $lastSync = [datetime]$wmResult
                            $wmFromSql = $true
                        }
                    } finally { $wmConn.Dispose() }
                } catch {}
                if (-not $wmFromSql -and (Test-Path $StateFilePath)) {
                    try {
                        $stateData = Get-Content $StateFilePath -Raw | ConvertFrom-Json -AsHashtable
                        if ($stateData.ContainsKey($entityName)) {
                            $lastSync = [datetime]$stateData[$entityName]
                        }
                    } catch {}
                }

                # Manual override: -FullLoad discards the watermark so this run
                # re-fetches the whole table. The MaxModifiedOn watermark still
                # advances after the upsert, so the next scheduled run resumes
                # incremental from here.
                if ($FullLoad) {
                    $lastSync = [datetime]::MinValue
                    Write-TableLog "Full load forced (-FullLoad): ignoring watermark." "INFO"
                }

                # --- Build filter ---
                $filter = ""
                if ($lastSync.Year -gt 1900) {
                    Write-TableLog "Incremental: fetching changes since $($lastSync.ToString('u'))" "INFO"
                    $filter = "modifiedon gt $($lastSync.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
                } else {
                    Write-TableLog "Initial Load: fetching all records" "INFO"
                }

                # --- Resolve OData entity-set name (metadata first, then guess) ---
                # EntitySetName comes from the discovery-time metadata enrichment.
                # The plural rules are only a fallback for tables the metadata map
                # didn't cover.
                $entitySet = $null
                if ($TblInfo.ContainsKey('EntitySetName')) { $entitySet = $TblInfo.EntitySetName }
                if ([string]::IsNullOrWhiteSpace($entitySet)) {
                    $entitySet = if ($entityName.EndsWith("y")) { $entityName.TrimEnd("y") + "ies" }
                                 elseif ($entityName.EndsWith("s")) { $entityName + "es" }
                                 else { $entityName + "s" }
                }

                # --- Fetch records from Dataverse with retry ---
                $baseQueryUrl = "${baseUrl}api/data/v9.2/$entitySet"
                $url = $baseQueryUrl
                if (-not [string]::IsNullOrWhiteSpace($filter)) { $url += "?`$filter=$filter" }

                $records = [System.Collections.Generic.List[PSObject]]::new()
                $filterFallbackUsed = $false
                do {
                    $resp = $null
                    $maxRetries = 5; $retryCount = 0; $baseWait = 2
                    do {
                        try {
                            $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
                        } catch {
                            $sc = 0
                            if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode }
                            if ($sc -eq 429 -or ($sc -ge 500 -and $sc -lt 600)) {
                                $retryCount++
                                if ($retryCount -gt $maxRetries) { throw $_ }
                                $wait = ($baseWait * [Math]::Pow(2, $retryCount)) + (Get-Random -Minimum 0 -Maximum 1000) / 1000
                                Write-TableLog "API Throttled ($sc). Retry $retryCount in $($wait.ToString('N1'))s..." "WARN"
                                Start-Sleep -Seconds $wait
                            }
                            elseif ($sc -eq 400 -and -not [string]::IsNullOrWhiteSpace($filter) -and -not $filterFallbackUsed) {
                                # The incremental filter was rejected -- typically an
                                # entity with no 'modifiedon' attribute. Retry once as
                                # a full, unfiltered load so we still capture the data.
                                $filterFallbackUsed = $true
                                $filter = ""
                                $records.Clear()
                                $url = $baseQueryUrl
                                Write-TableLog "Incremental filter rejected (400); retrying as full load." "WARN"
                                break
                            }
                            else { throw $_ }
                        }
                    } while (-not $resp -and $retryCount -le $maxRetries)

                    # Filter-fallback path: $resp is null because we reset $url to
                    # re-request unfiltered. Loop again rather than dereferencing null.
                    if ($null -eq $resp) { continue }

                    if ($resp.value) {
                        $castedItems = [PSObject[]]$resp.value
                        $records.AddRange($castedItems)
                    }
                    $url = $null
                    if ($resp.PSObject.Properties['@odata.nextLink']) { $url = $resp.'@odata.nextLink' }
                } while ($url)

                # --- Upsert into SQL via shared module ---
                if ($records.Count -gt 0) {
                    Import-Module $ModulePath -Force

                    # Wrap Write-TableLog as 1-arg scriptblocks so the module
                    # can route through this runspace's per-table file logger.
                    $tlInfo    = { param($m) Write-TableLog $m "INFO" }
                    $tlWarn    = { param($m) Write-TableLog $m "WARN" }
                    $tlSuccess = { param($m) Write-TableLog $m "SUCCESS" }
                    $tlError   = { param($m) Write-TableLog $m "ERROR" }

                    Invoke-OdsSqlBulkUpsert `
                        -ConnString  $SqlConnectionString `
                        -TableName   $sqlTableName `
                        -PrimaryKey  $pk `
                        -Records     $records `
                        -BatchSize   $BatchSize `
                        -LogInfo     $tlInfo `
                        -LogWarn     $tlWarn `
                        -LogSuccess  $tlSuccess `
                        -LogError    $tlError | Out-Null

                    # Track max modifiedon for the watermark. Entities with no
                    # 'modifiedon' attribute (e.g. activityparty) make Measure-Object
                    # throw -- the rows are already upserted above, so guard this so
                    # the table reports success instead of a false failure. No
                    # modifiedon means no incremental watermark: the table re-loads
                    # in full each run (correct for these), via the 400 fallback.
                    $maxDate = $null
                    try {
                        $maxDate = ($records | Measure-Object -Property modifiedon -Maximum).Maximum
                    } catch { $maxDate = $null }
                    if ($maxDate) {
                        $result.MaxModifiedOn = [datetime]$maxDate
                    }
                    $result.RecordCount = $records.Count
                    Write-TableLog "Synced $($records.Count) records." "SUCCESS"
                } else {
                    Write-TableLog "No new records found." "INFO"
                }

                $result.Success = $true
            }
            catch {
                $result.Error = $_.Exception.Message
                Write-TableLog "Failed to sync: $($_.Exception.Message)" "ERROR"
            }

            $swT.Stop()
            $result.DurationMs = [int]$swT.ElapsedMilliseconds
            return $result
        }

        # --- Create runspace pool ---
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
        $runspacePool.Open()

        $jobs = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($tblInfo in $standardTables) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $runspacePool
            $ps.AddScript($syncScriptBlock) | Out-Null
            $ps.AddParameter("TblInfo", $tblInfo) | Out-Null
            $ps.AddParameter("SqlConnectionString", $SqlStr) | Out-Null
            $ps.AddParameter("BatchSize", $BatchSize) | Out-Null
            $ps.AddParameter("OrgUrl", $OrgUrl) | Out-Null
            $ps.AddParameter("PageSize", $PageSize) | Out-Null
            $ps.AddParameter("ClientId", $ClientId) | Out-Null
            $ps.AddParameter("TenantId", $TenantId) | Out-Null
            $ps.AddParameter("ClientSecret", $ClientSecret) | Out-Null
            $ps.AddParameter("SqlPrefix", $SqlPrefix) | Out-Null
            $ps.AddParameter("StateFilePath", $StatePath) | Out-Null
            $ps.AddParameter("LogBaseDir", (Split-Path -Parent $LogPath)) | Out-Null
            $ps.AddParameter("ModulePath", $script:OdsModulePath) | Out-Null
            $ps.AddParameter("FullLoad", $FullLoad.IsPresent) | Out-Null

            $handle = $ps.BeginInvoke()

            $Logger.Info("Queued [$($tblInfo.LogicalName)] -> [$SqlPrefix$(if ($tblInfo.SqlTableName) { $tblInfo.SqlTableName } else { $tblInfo.LogicalName })] (source: $($tblInfo.Source))")
            $jobs.Add(@{ PowerShell = $ps; Handle = $handle; EntityName = $tblInfo.LogicalName })
        }

        # --- Wait for all runspaces and collect results ---
        foreach ($job in $jobs) {
            try {
                $jobResult = $job.PowerShell.EndInvoke($job.Handle)

                # Check for stream errors (non-terminating)
                if ($job.PowerShell.Streams.Error.Count -gt 0) {
                    foreach ($err in $job.PowerShell.Streams.Error) {
                        $Logger.Error("[$($job.EntityName)] Stream error: $($err.Exception.Message)")
                    }
                }

                # Process result
                if ($jobResult -and $jobResult.Count -gt 0) {
                    $r = $jobResult[-1]  # last output is our result hashtable
                    if ($r -is [hashtable] -or $r.PSObject.Properties['Success']) {
                        if ($r.Success -and $r.MaxModifiedOn) {
                            $runIdForWm = if ($null -ne $RunLog) { $RunLog.RunId } else { 0L }
                            $Watermarks.Set($r.EntityName, $r.MaxModifiedOn, $runIdForWm)
                        }
                        if (-not $r.Success) {
                            $Logger.Error("Failed to sync table $($r.EntityName) : $($r.Error)")
                            $totalErrors++
                        }
                        $rowCount = [long]$(if ($null -ne $r.RecordCount) { $r.RecordCount } else { 0 })
                        $totalRows += $rowCount
                        $RunLog.LogTable(
                            $r.EntityName,
                            "upsert",
                            $rowCount,
                            [int]$(if ($null -ne $r.DurationMs) { $r.DurationMs } else { 0 }),
                            $(if ($r.Success) { "success" } else { "error" }),
                            $r.Error
                        )
                    }
                }
            }
            catch {
                $Logger.Error("Failed to sync table $($job.EntityName) : $($_.Exception.Message)")
                $totalErrors++
                $RunLog.LogTable($job.EntityName, "upsert", 0L, 0, "error", $_.Exception.Message)
            }
            finally {
                $job.PowerShell.Dispose()
            }
        }

        $runspacePool.Close()
        $runspacePool.Dispose()
        $Logger.Info("Parallel sync complete.")
    }

    # Targeted-run verification: when -Table was used (a small, deliberate set),
    # compare source vs target row counts and report anything missing from SQL.
    # Not run on full/syncAll discovery -- it would issue a PK fetch per table
    # across the whole catalog.
    if ($Table -and $Table.Count -gt 0) {
        $runStamp = (Get-Date -Format 'yyyyMMdd_HHmmss')
        Invoke-RowCountCompare `
            -Dataverse  $Dataverse `
            -SQL        $SQL `
            -TableList  $resolvedTables `
            -SqlPrefix  $SqlPrefix `
            -Logger     $Logger `
            -LogBaseDir (Split-Path -Parent $LogPath) `
            -RunStamp   $runStamp
    }

    }   # end: if ($Mode -ne 'DictionaryOnly') -- close the sync gate

    # =========================================================================
    # FEATURE 3: Build Data Dictionary (after all tables are synced)
    # Skipped in Sync mode -- only runs on Refresh and DictionaryOnly.
    # =========================================================================
    if ($Mode -eq 'Sync') {
        $Logger.Info("Mode=Sync: skipping dictionary + views rebuild.")
    }
    else {

    # Re-authenticate in case the token expired during parallel sync
    $Logger.Info("Refreshing Dataverse token before dictionary build...")
    try { $Dataverse.Authenticate() }
    catch { $Logger.Warn("Token refresh failed, continuing with existing token: $($_.Exception.Message)") }

    $swDict = [System.Diagnostics.Stopwatch]::StartNew()
    $dictStatus = "success"; $dictErr = ""
    try {
        Build-DataDictionary -SQL $SQL -Dataverse $Dataverse -SqlPrefix $SqlPrefix -TableList $resolvedTables -Logger $Logger
    } catch {
        $dictStatus = "error"; $dictErr = $_.Exception.Message; $totalErrors++; throw
    } finally {
        $swDict.Stop()
        $RunLog.LogTable("__data_dictionary__", "build", 0L, [int]$swDict.ElapsedMilliseconds, $dictStatus, $dictErr)
    }

    # =========================================================================
    # FEATURE 2: Build Friendly Views (after dictionary is populated)
    # =========================================================================
    $swViews = [System.Diagnostics.Stopwatch]::StartNew()
    $viewsStatus = "success"; $viewsErr = ""
    try {
        Build-FriendlyViews -SQL $SQL -SqlPrefix $SqlPrefix -TableList $resolvedTables -Logger $Logger
    } catch {
        $viewsStatus = "error"; $viewsErr = $_.Exception.Message; $totalErrors++; throw
    } finally {
        $swViews.Stop()
        $RunLog.LogTable("__friendly_views__", "build", 0L, [int]$swViews.ElapsedMilliseconds, $viewsStatus, $viewsErr)
    }

    }   # end: if ($Mode -eq 'Sync') ... else { dictionary + views }

    $finalStatus = if ($totalErrors -gt 0) { "partial" } else { "success" }
    $RunLog.Complete($finalStatus, $totalRows, $totalRows, $totalErrors)
    $Logger.Success("=== $($pipelineName) portion completed ===")

    # === Optional bundled reconcile pass ==================================
    # Lets a single scheduled task do both daily refresh and reconcile.
    # Runs as its own ops.runlog row (pipeline = CRMReconcileDeletes) so
    # failures don't affect the Refresh status that was just recorded.
    if ($IncludeReconcile) {
        $Logger.Info("=== -IncludeReconcile: starting bundled reconcile-deletes pass ===")

        # Token may have expired during a long Refresh -- re-auth before the
        # reconcile pass makes ~200 metadata calls.
        try { $Dataverse.Authenticate() }
        catch { $Logger.Warn("Token refresh failed before bundled reconcile: $($_.Exception.Message)") }

        $reconRunLog = [OpsRunLog]::new($SqlStr, "CRMReconcileDeletes")
        $reconRunLog.Start("DryRun=$DryRun, threshold=$([math]::Round($MaxMissingPct*100,1))% (bundled via -IncludeReconcile)")

        # $resolvedTables already populated earlier -- reuse it.
        $reconcileResult = Invoke-ReconcileDeletes `
            -Dataverse $Dataverse `
            -SQL $SQL `
            -SqlConnectionString $SqlStr `
            -SqlPrefix $SqlPrefix `
            -TableList $resolvedTables `
            -Logger $Logger `
            -RunLog $reconRunLog `
            -MaxMissingPct $MaxMissingPct `
            -MinRowCountForThreshold $MinRowCountForThreshold `
            -DryRun:$DryRun

        $reconStatus = if ($reconcileResult.Errors -gt 0) { "partial" } else { "success" }
        $reconRunLog.Complete(
            $reconStatus,
            0L,
            [long]($reconcileResult.Flagged + $reconcileResult.Reappeared),
            [long]$reconcileResult.Errors
        )
        $Logger.Success("=== Bundled reconcile-deletes completed (flagged=$($reconcileResult.Flagged), reappeared=$($reconcileResult.Reappeared), skipped=$($reconcileResult.Skipped), errors=$($reconcileResult.Errors)) ===")
    }

    $Logger.Success("=== Job Completed ===")
}
catch {
    if ($null -ne $RunLog) { $RunLog.Complete("failed", $totalRows, $totalRows, ($totalErrors + 1)) }
    $Logger.Error("Fatal Job Error: $_")
    exit 1
}
