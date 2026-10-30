<#
.SYNOPSIS
    Bulk upsert and schema-evolve helpers for Sync-DataverseToSqlServer.ps1
    (Dataverse to SQL Server Sync, version 0.6.0 beta). Kept in a module so
    the main thread (SQLConnector class) and the parallel runspaces, which
    cannot share class instances, call the same code.

    Exported functions
    ------------------
      ConvertTo-OdsRecordDataTable
          Build a System.Data.DataTable from a list of PSObject records,
          inferring column types and skipping OData metadata fields.

      Set-OdsSqlTableSchema
          Create the target table if missing, otherwise ALTER it to add
          any new columns. Returns: $true if created, array of added
          column names if altered, empty array if nothing changed.

      Invoke-OdsSqlBulkUpsert
          Full pipeline: ConvertTo -> schema-evolve -> SqlBulkCopy into
          staging #table -> MERGE -> drop staging. Returns rows written.

    Logging
    -------
    The functions take optional 1-arg scriptblocks for Info / Warn /
    Success / Error so callers can route messages to their own loggers
    (SyncLogger in the main thread, Write-TableLog in runspaces).

    Author: John Stover, Org Data Solutions.
    Copyright (c) 2026 John Stover. MIT License (see LICENSE).
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# Azure SQL transient error numbers (SqlException.Number). These mean the
# service briefly failed over / was throttled / the connection dropped -- a
# retry on a fresh connection succeeds. They are NOT data errors. Microsoft's
# documented transient list plus the network-drop numbers that surface as
# SQLSTATE 08S01 in ODBC drivers.
$script:OdsTransientSqlErrorNumbers = @(
    -2,     # timeout expired
    20, 64, # connection-level network errors
    233,    # no process on the other end of the pipe
    10053, 10054, 10060,  # transport-level: connection aborted/reset/forcibly closed
    10928, 10929,         # resource governance limits
    40197, 40501, 40613,  # service error / busy / database unavailable (failover)
    49918, 49919, 49920,  # cannot process request, too busy
    4060, 4221,           # cannot open database (transient during failover)
    1205                  # deadlock victim
)

function Test-OdsTransientSqlError {
    <#
    .SYNOPSIS
        True if an error record is an Azure SQL transient/connection fault that
        is worth retrying on a fresh connection (vs. a data/logic error, which
        should fail fast).
    #>
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $ex = $ErrorRecord.Exception
    while ($ex) {
        if ($ex -is [System.Data.SqlClient.SqlException]) {
            foreach ($e in $ex.Errors) {
                if ($script:OdsTransientSqlErrorNumbers -contains $e.Number) { return $true }
            }
        }
        # Network drops sometimes arrive as a plain Win32/IO exception.
        $msg = $ex.Message
        if ($msg -match 'transport-level|forcibly closed|semaphore timeout|existing connection|Communication link failure|connection was successfully established.*then an error') {
            return $true
        }
        $ex = $ex.InnerException
    }
    return $false
}

function ConvertTo-OdsRecordDataTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[PSObject]]$Records
    )

    # DataTable implements IListSource -- PowerShell will unwrap it to its
    # rows when it flows through a pipeline / function return. Every return
    # here uses Write-Output -NoEnumerate to keep the table as a single object.
    $dt = [System.Data.DataTable]::new()
    if ($Records.Count -eq 0) { Write-Output -NoEnumerate $dt; return }

    $schemaRef = $Records | Where-Object { $_ -ne $null } | Select-Object -First 1
    if (-not $schemaRef) { Write-Output -NoEnumerate $dt; return }

    $props = $schemaRef.PSObject.Properties | Where-Object {
        $_.Name -notmatch '^@' -and
        $_.Name -notmatch '^_.*_value@' -and
        $_.Value -isnot [PSCustomObject] -and
        $_.Value -isnot [array]
    }

    foreach ($p in $props) {
        $type = [string]
        if ($null -ne $p.Value) {
            switch ($p.Value.GetType().Name) {
                "Boolean"  { $type = [bool] }
                "DateTime" { $type = [datetime] }
                "Int32"    { $type = [decimal] }
                "Int64"    { $type = [decimal] }
                "Decimal"  { $type = [decimal] }
                "Double"   { $type = [decimal] }
                "Guid"     { $type = [guid] }
            }
        }
        $dt.Columns.Add($p.Name, $type) | Out-Null
    }

    foreach ($rec in $Records) {
        $row = $dt.NewRow()
        foreach ($col in $dt.Columns) {
            $val = $rec.($col.ColumnName)
            if ($null -eq $val -or $val -eq '') {
                $row[$col] = [DBNull]::Value
            }
            elseif ($col.DataType -eq [datetime]) {
                if ($val -is [string]) { $row[$col] = [datetime]::Parse($val).ToUniversalTime() }
                else { $row[$col] = $val.ToUniversalTime() }
            }
            else {
                $row[$col] = $val
            }
        }
        # Cast to [void] -- DataRowCollection.Add() returns the row index which
        # otherwise leaks into the function's output pipeline.
        [void]$dt.Rows.Add($row)
    }
    # See note above re: IListSource unwrapping.
    Write-Output -NoEnumerate $dt
}

function _Resolve-OdsSqlType {
    # Internal -- maps a .NET type name to its T-SQL equivalent.
    param([string]$DataTypeName, [bool]$IsPrimaryKey = $false)

    $t = switch ($DataTypeName) {
        "Boolean"  { "BIT" }
        "DateTime" { "DATETIME2" }
        "Decimal"  { "DECIMAL(28,6)" }
        "Guid"     { "UNIQUEIDENTIFIER" }
        default    { "NVARCHAR(MAX)" }
    }
    if ($IsPrimaryKey -and $t -eq "NVARCHAR(MAX)") { $t = "NVARCHAR(450)" }
    return $t
}

function Set-OdsSqlTableSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.Data.SqlClient.SqlConnection]$Conn,
        [Parameter(Mandatory = $true)] [string]$TableName,
        [Parameter(Mandatory = $true)] [string]$PrimaryKey,
        [Parameter(Mandatory = $true)] [System.Data.DataTable]$DataTable
    )

    $cmd = $Conn.CreateCommand()
    $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @t"
    $cmd.Parameters.AddWithValue("@t", $TableName) | Out-Null
    $exists = [int]$cmd.ExecuteScalar() -gt 0

    if (-not $exists) {
        $cols = @()
        foreach ($c in $DataTable.Columns) {
            $sqlType = _Resolve-OdsSqlType -DataTypeName $c.DataType.Name -IsPrimaryKey ($c.ColumnName -eq $PrimaryKey)
            if ($c.ColumnName -eq $PrimaryKey) {
                $cols += "[$($c.ColumnName)] $sqlType NOT NULL PRIMARY KEY CLUSTERED"
            } else {
                $cols += "[$($c.ColumnName)] $sqlType NULL"
            }
        }
        $cmd.CommandText = "CREATE TABLE [$TableName] ($($cols -join ', '))"
        $cmd.Parameters.Clear()
        $cmd.ExecuteNonQuery() | Out-Null
        return $true
    }

    # Add Missing Columns
    $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @t"
    $cmd.Parameters.Clear()
    $cmd.Parameters.AddWithValue("@t", $TableName) | Out-Null
    $reader = $cmd.ExecuteReader()
    $existingCols = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    while ($reader.Read()) { $existingCols.Add($reader["COLUMN_NAME"]) | Out-Null }
    $reader.Close()

    $added = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $DataTable.Columns) {
        if (-not $existingCols.Contains($c.ColumnName)) {
            $sqlType = _Resolve-OdsSqlType -DataTypeName $c.DataType.Name -IsPrimaryKey $false
            $cmd.CommandText = "ALTER TABLE [$TableName] ADD [$($c.ColumnName)] $sqlType NULL"
            $cmd.ExecuteNonQuery() | Out-Null
            $added.Add($c.ColumnName) | Out-Null
        }
    }
    return $added.ToArray()
}

function Invoke-OdsSqlBulkUpsert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ConnString,
        [Parameter(Mandatory = $true)] [string]$TableName,
        [Parameter(Mandatory = $true)] [string]$PrimaryKey,
        [Parameter(Mandatory = $true)] [System.Collections.Generic.List[PSObject]]$Records,
        [int]$BatchSize = 5000,
        [scriptblock]$LogInfo,
        [scriptblock]$LogWarn,
        [scriptblock]$LogSuccess,
        [scriptblock]$LogError
    )

    if ($Records.Count -eq 0) { return 0 }

    $dt = ConvertTo-OdsRecordDataTable -Records $Records
    if ($dt.Rows.Count -eq 0) { return 0 }

    # Retry the whole open -> bulk -> MERGE on Azure transient faults. The
    # operation is idempotent (MERGE by PK into a fresh per-call #staging table),
    # so a clean reconnect-and-redo is safe. Bounded (waits 2s,4s,8s) so a dead
    # server fails fast instead of hanging the table.
    $maxAttempts = 4
    $attempt     = 0
    while ($true) {
    $attempt++
    $conn = [System.Data.SqlClient.SqlConnection]::new($ConnString)
    try {
        $conn.Open()

        # Schema evolution
        $schemaResult = Set-OdsSqlTableSchema -Conn $conn -TableName $TableName -PrimaryKey $PrimaryKey -DataTable $dt
        if ($schemaResult -is [bool] -and $schemaResult) {
            if ($LogWarn) { & $LogWarn "Creating table [$TableName]" }
        }
        elseif ($schemaResult -is [array] -or $schemaResult -is [string[]]) {
            foreach ($col in $schemaResult) {
                if ($LogInfo) { & $LogInfo "Adding new column [$col] to [$TableName]" }
            }
        }

        # Staging + bulk copy + MERGE
        $stageName = "#Staging_" + [Guid]::NewGuid().ToString("N")
        $colDefs = $dt.Columns | ForEach-Object {
            "[$($_.ColumnName)] $(_Resolve-OdsSqlType -DataTypeName $_.DataType.Name)"
        }
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "CREATE TABLE $stageName ($($colDefs -join ', '))"
        $cmd.ExecuteNonQuery() | Out-Null

        $bulk = [System.Data.SqlClient.SqlBulkCopy]::new($conn)
        $bulk.DestinationTableName = $stageName
        $bulk.BatchSize = $BatchSize
        $bulk.BulkCopyTimeout = 600
        foreach ($c in $dt.Columns) { $bulk.ColumnMappings.Add($c.ColumnName, $c.ColumnName) | Out-Null }
        $bulk.WriteToServer($dt)

        $colNames = $dt.Columns.ColumnName
        $updateSet = ($colNames | Where-Object { $_ -ne $PrimaryKey } | ForEach-Object { "target.[$_] = source.[$_]" }) -join ', '
        if (-not $updateSet) { $updateSet = "target.[$PrimaryKey] = source.[$PrimaryKey]" }
        $insertCols = ($colNames | ForEach-Object { "[$_]" }) -join ', '
        $insertVals = ($colNames | ForEach-Object { "source.[$_]" }) -join ', '

        $cmd.CommandText = @"
MERGE [$TableName] AS target
USING $stageName AS source
ON target.[$PrimaryKey] = source.[$PrimaryKey]
WHEN MATCHED THEN UPDATE SET $updateSet
WHEN NOT MATCHED THEN INSERT ($insertCols) VALUES ($insertVals);
DROP TABLE $stageName;
"@
        $cmd.CommandTimeout = 600
        $cmd.ExecuteNonQuery() | Out-Null

        if ($LogSuccess) { & $LogSuccess "Upserted $($dt.Rows.Count) rows into [$TableName]" }
        return $dt.Rows.Count
    }
    catch {
        if ((Test-OdsTransientSqlError $_) -and $attempt -lt $maxAttempts) {
            $wait = [int][Math]::Pow(2, $attempt)   # 2s, 4s, 8s
            if ($LogWarn) {
                & $LogWarn ("Transient SQL fault on [$TableName] (attempt $attempt/$maxAttempts): " +
                            "$($_.Exception.Message). Retrying in ${wait}s...")
            }
            Start-Sleep -Seconds $wait
            continue   # finally disposes this $conn; loop opens a fresh one
        }
        if ($LogError) { & $LogError "SQL Bulk Error: $_" }
        throw
    }
    finally {
        $conn.Dispose()
    }
    }
}

Export-ModuleMember -Function ConvertTo-OdsRecordDataTable, Set-OdsSqlTableSchema, Invoke-OdsSqlBulkUpsert
