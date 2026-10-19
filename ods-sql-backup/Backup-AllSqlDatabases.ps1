<#
.SYNOPSIS
    ODS SQL Backup - a free tool from Org Data Solutions.
    Backs up every online database on one or more SQL Server instances to a
    backup folder you choose, driven by a sidecar PSD1 config file.

.DESCRIPTION
    Configuration -- including SQL credentials, the target list, backup root,
    retention, and per-target overrides -- lives in `backup-config.psd1` next
    to this script. The script imports it via Import-PowerShellDataFile,
    merges in any command-line overrides, then iterates each target:

      1. Enumerates user databases via sys.databases (skips tempdb, snapshots,
         and anything not ONLINE).
      2. Runs BACKUP DATABASE for each, into <Destination>/<DbName>/<DbName>_<ts>.bak
      3. Logs everything to a dated file in <BackupRoot>.
      4. Applies retention if configured.

    There is no default backup folder: set BackupRoot in the config or pass
    -BackupRoot. Backups go only to the folders you name. Nothing is sent to
    Org Data Solutions.

    Compression is auto-enabled where the edition supports it. Express drops
    to no compression.

    REMOTE BACKUPS -> THIS MACHINE (important):
    A target's `Destination` is the path the *SQL Server service account*
    writes to, evaluated on that server. For the local instance, a local
    folder works. For a REMOTE instance to land files on this machine, share
    the backup folder (e.g. \\THISBOX\SqlBackups) and set the remote target's
    Destination to that UNC path. The remote SQL service account needs write
    access to the share.

    SECRETS NOTE:
    `backup-config.psd1` can hold SQL credentials in plaintext. Put the file
    alongside this script in a folder whose ACL only the operator account can
    read, or omit DefaultCredential to use Windows (integrated) authentication.

    Requirements: Windows PowerShell 5.1 or PowerShell 7, and the SqlServer
    (or older SQLPS) module for Invoke-Sqlcmd.

.PARAMETER ConfigPath
    Config file to use. Default: backup-config.psd1 next to this script.

.PARAMETER BackupRoot
    Required unless the config sets BackupRoot (this parameter wins when both
    are set). The local or UNC folder for backups and the daily log, and the
    Destination for any target that does not name its own. No default.

.PARAMETER RetentionDays
    Override config.RetentionDays. Deletes .bak files older than this many
    days under every destination, including ones this script did not create.

.PARAMETER NoCompression
    Force compression off regardless of config.

.PARAMETER Targets
    Override the entire target list at the command line. Same hashtable
    shape as the config's Targets array. With -BackupRoot and -Targets, the
    script runs without a config file (when -ConfigPath is not given).

.EXAMPLE
    .\Backup-AllSqlDatabases.ps1
        Use ./backup-config.psd1 for everything.

.EXAMPLE
    .\Backup-AllSqlDatabases.ps1 -RetentionDays 30
        Use config but override retention.

.EXAMPLE
    .\Backup-AllSqlDatabases.ps1 -BackupRoot 'X:\SqlBackups' -Targets @{ Name = 'local'; Instance = 'localhost' }
        One-off backup of the local default instance with Windows
        authentication, no config file.

.EXAMPLE
    .\Backup-AllSqlDatabases.ps1 -ConfigPath .\nightly-config.psd1

.NOTES
    Copyright (c) 2026 Org Data Solutions. MIT License (see LICENSE).
#>
[CmdletBinding()]
param(
    [string]   $ConfigPath,
    [string]   $BackupRoot,
    [int]      $RetentionDays = -1,
    [switch]   $NoCompression,
    [object[]] $Targets
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load config (PSD1 sidecar). Cmdline params override config values.
# ---------------------------------------------------------------------------
$configGiven = $PSBoundParameters.ContainsKey('ConfigPath')
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'backup-config.psd1'
}
if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = Import-PowerShellDataFile -Path $ConfigPath
}
elseif (-not $configGiven -and $Targets) {
    # Ad-hoc run: everything comes from the command line.
    $cfg = @{}
    $ConfigPath = '(none: command line only)'
}
else {
    throw "Config file not found: $ConfigPath  --  copy backup-config.example.psd1 to backup-config.psd1 next to this script and fill in your settings, or pass -BackupRoot and -Targets."
}

if (-not $BackupRoot)              { $BackupRoot    = $cfg.BackupRoot }
if (-not $BackupRoot -or $BackupRoot -match '^\s*<') {
    $hint = if ($cfg.Count -gt 0) { "Set BackupRoot in $ConfigPath or pass -BackupRoot" } else { "Pass -BackupRoot" }
    throw "No backup folder set. $hint (a local folder or a \\server\share path)."
}
if ($RetentionDays -lt 0)          { $RetentionDays = if ($null -ne $cfg.RetentionDays) { [int]$cfg.RetentionDays } else { 0 } }
if (-not $NoCompression)           { $NoCompression = [bool]$cfg.NoCompression }
if (-not $Targets -and $cfg.Targets) { $Targets    = $cfg.Targets }
if (-not $Targets) {
    throw "No targets configured. Set Targets in $ConfigPath or pass -Targets."
}

# Build the default PSCredential from the config (if it specifies one).
$defaultCred = $null
if ($cfg.DefaultCredential) {
    $dc = $cfg.DefaultCredential
    if (-not $dc.User) { throw "DefaultCredential in config has no User." }
    if (-not $dc.Password) { throw "DefaultCredential in config has no Password. (Integrated auth: omit DefaultCredential entirely.)" }
    $sec = ConvertTo-SecureString $dc.Password -AsPlainText -Force
    $defaultCred = New-Object System.Management.Automation.PSCredential($dc.User, $sec)
}

# ---------------------------------------------------------------------------
# Load a SQL module that provides Invoke-Sqlcmd
# ---------------------------------------------------------------------------
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    if (Get-Module -ListAvailable -Name SqlServer) {
        Import-Module SqlServer -ErrorAction Stop
    } elseif (Get-Module -ListAvailable -Name SQLPS) {
        Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
    } else {
        throw "Neither the 'SqlServer' nor 'SQLPS' module is available. Install with: Install-Module SqlServer -Scope AllUsers"
    }
}
$invokeCmd = Get-Command Invoke-Sqlcmd

# ---------------------------------------------------------------------------
# Backup root + log file
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
}
$logFile = Join-Path $BackupRoot ("BackupLog_{0:yyyyMMdd}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0:yyyy-MM-dd HH:mm:ss}  [{1}]  {2}" -f (Get-Date), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    Add-Content -LiteralPath $logFile -Value $line
}

# ---------------------------------------------------------------------------
# Build Invoke-Sqlcmd args for a given target hashtable
# ---------------------------------------------------------------------------
function Get-SqlConnArgs {
    param($Target)
    $a = @{ QueryTimeout = 0; ErrorAction = 'Stop' }
    if ($invokeCmd.Parameters.ContainsKey('TrustServerCertificate')) {
        $a['TrustServerCertificate'] = $true
    }

    if ($Target.ConnectionString) {
        $a['ConnectionString'] = $Target.ConnectionString
        return $a
    }

    $a['ServerInstance'] = $Target.Instance
    $cred = if ($Target.Credential) {
        # Per-target inline credential (config hashtable form): build PSCredential.
        $tc = $Target.Credential
        if ($tc -is [System.Management.Automation.PSCredential]) { $tc }
        elseif ($tc.User -and $tc.Password) {
            $sec = ConvertTo-SecureString $tc.Password -AsPlainText -Force
            New-Object System.Management.Automation.PSCredential($tc.User, $sec)
        } else {
            throw "Target '$($Target.Name)' has a Credential entry but it lacks User and/or Password."
        }
    } else { $defaultCred }

    if ($cred) {
        if ($invokeCmd.Parameters.ContainsKey('Credential')) {
            $a['Credential'] = $cred
        } else {
            # Older module: only plaintext username/password are supported
            $a['Username'] = $cred.UserName
            $a['Password'] = $cred.GetNetworkCredential().Password
        }
    }
    # No creds -> integrated/Windows auth
    return $a
}

Write-Log "===== Backup run started: config=$ConfigPath ($($Targets.Count) target(s)) ====="

$grandSuccess = 0
$grandFailed  = @()
$destinations = New-Object System.Collections.Generic.HashSet[string]

foreach ($t in $Targets) {
    $label = if ($t.Name) { $t.Name } elseif ($t.Instance) { $t.Instance } else { 'target' }
    $dest  = if ($t.Destination) { $t.Destination } else { $BackupRoot }
    [void]$destinations.Add($dest)

    Write-Log "----- Target '$label' -> $dest -----"
    $conn = Get-SqlConnArgs -Target $t

    # Compression support (engine edition 4 = Express, no compression)
    $useCompression = -not $NoCompression
    if ($useCompression) {
        try {
            $edition = (Invoke-Sqlcmd @conn -Query "SELECT CAST(SERVERPROPERTY('EngineEdition') AS int) AS Edition").Edition
            if ($edition -eq 4) {
                $useCompression = $false
                Write-Log "[$label] Edition does not support compression; disabling it." 'WARN'
            }
        } catch {
            $useCompression = $false
            Write-Log "[$label] Could not determine edition; disabling compression. $($_.Exception.Message)" 'WARN'
        }
    }

    $dbQuery = @"
SELECT name FROM sys.databases
WHERE database_id <> 2 AND state = 0 AND source_database_id IS NULL
ORDER BY name;
"@
    try {
        $databases = Invoke-Sqlcmd @conn -Query $dbQuery | Select-Object -ExpandProperty name
    } catch {
        Write-Log "[$label] Failed to connect / enumerate databases: $($_.Exception.Message)" 'ERROR'
        $grandFailed += "$label (connection)"
        continue
    }

    if (-not $databases) { Write-Log "[$label] No databases found." 'WARN'; continue }
    Write-Log ("[$label] Found {0} database(s): {1}" -f $databases.Count, ($databases -join ', '))

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    foreach ($db in $databases) {
        $dbFolder = Join-Path $dest $db
        try {
            if (-not (Test-Path -LiteralPath $dbFolder)) {
                New-Item -ItemType Directory -Path $dbFolder -Force | Out-Null
            }
        } catch {
            Write-Log "[$label] Cannot create destination folder '$dbFolder': $($_.Exception.Message)" 'ERROR'
            $grandFailed += "$label/$db (folder)"
            continue
        }

        $backupFile = Join-Path $dbFolder ("{0}_{1}.bak" -f $db, $timestamp)
        $compressionClause = if ($useCompression) { ', COMPRESSION' } else { '' }
        $dbSafe   = $db -replace '\]', ']]'
        $fileSafe = $backupFile -replace "'", "''"

        $backupSql = @"
BACKUP DATABASE [$dbSafe]
TO DISK = N'$fileSafe'
WITH INIT, CHECKSUM, STATS = 10$compressionClause,
NAME = N'$db full backup';
"@
        try {
            Write-Log "[$label] Backing up [$db] -> $backupFile"
            Invoke-Sqlcmd @conn -Query $backupSql
            try {
                $sizeMB = [math]::Round((Get-Item -LiteralPath $backupFile).Length / 1MB, 2)
                Write-Log "[$label] Completed [$db] ($sizeMB MB)"
            } catch {
                Write-Log "[$label] Completed [$db] (size not readable from this host)"
            }
            $grandSuccess++
        } catch {
            Write-Log "[$label] FAILED [$db]: $($_.Exception.Message)" 'ERROR'
            $grandFailed += "$label/$db"
        }
    }
}

# ---------------------------------------------------------------------------
# Retention cleanup across every destination
# ---------------------------------------------------------------------------
if ($RetentionDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Write-Log "Applying retention: removing .bak older than $RetentionDays day(s) (before $cutoff)."
    foreach ($d in $destinations) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        try {
            $old = Get-ChildItem -Path $d -Recurse -Filter '*.bak' -File -ErrorAction Stop |
                   Where-Object { $_.LastWriteTime -lt $cutoff }
            foreach ($f in $old) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force
                    Write-Log "Removed old backup: $($f.FullName)"
                } catch { Write-Log "Could not remove $($f.FullName): $($_.Exception.Message)" 'WARN' }
            }
        } catch { Write-Log "Retention scan failed for '$d': $($_.Exception.Message)" 'WARN' }
    }
}

Write-Log ("===== Run finished: {0} succeeded, {1} failed =====" -f $grandSuccess, $grandFailed.Count)
if ($grandFailed.Count -gt 0) {
    Write-Log ("Failures: {0}" -f ($grandFailed -join ', ')) 'ERROR'
    exit 1
}
exit 0
