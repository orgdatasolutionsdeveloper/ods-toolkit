<#
.SYNOPSIS
    SQL Server Backup All Databases, version 0.5.0 (beta).
    By John Stover, Org Data Solutions.

    Backs up every online database on one or more SQL Server instances into
    a folder you choose, with a dated log and optional retention.

.DESCRIPTION
    Settings (the target list, the backup folder, retention, credentials and
    per-target overrides) live in backup-config.psd1 next to this script.
    On the first run with no config file the script asks for the settings on
    the console and writes the file for you. Command-line parameters override
    the file. For each target the script:

      1. Lists the user databases from sys.databases (skips tempdb, snapshots
         and anything not ONLINE).
      2. Runs BACKUP DATABASE for each one into <Destination>\<DbName>\<DbName>_<timestamp>.bak
      3. Logs everything to a dated file in <BackupRoot>.
      4. Applies retention when it is configured.

    There is no default backup folder: set BackupRoot in the config or pass
    -BackupRoot. Backups go only to the folders you name. Nothing is sent to
    Org Data Solutions.

    Compression is used where the edition supports it. Express editions get
    an uncompressed backup.

    Remote instances: a target's Destination is the path the SQL Server
    service account writes to, evaluated on that server. For the local
    instance a local folder works. For a remote instance to land its files
    on this machine, share the backup folder (for example \\THISBOX\SqlBackups)
    and set that target's Destination to the UNC path. The remote SQL Server
    service account needs write access to the share.

    Credentials: backup-config.psd1 can hold a SQL password in plain text.
    Keep the file in a folder only the operator account can read, or leave
    DefaultCredential out and use Windows authentication.

    Requirements: Windows PowerShell 5.1 or PowerShell 7, and the SqlServer
    module (for Invoke-Sqlcmd). When the module is missing the script
    installs it for the current user from the PowerShell Gallery.
    run.cmd in this folder starts the script with no execution-policy change.

.PARAMETER ConfigPath
    Config file to use. Default: backup-config.psd1 next to this script.

.PARAMETER BackupRoot
    Required unless the config sets BackupRoot (this parameter wins when both
    are set). The local or UNC folder for backups and the daily log, and the
    Destination for any target that does not name its own. No default.

.PARAMETER RetentionDays
    Override the config's RetentionDays. Deletes .bak files older than this
    many days under every destination, including files this script did not
    create.

.PARAMETER NoCompression
    Turn compression off regardless of the config.

.PARAMETER Targets
    Replace the target list for this run. Same hashtable shape as the
    config's Targets array. With -BackupRoot and -Targets the script runs
    without a config file (when -ConfigPath is not given).

.EXAMPLE
    .\Backup-AllSqlServerDatabases.ps1
        Use backup-config.psd1 next to the script for everything.

.EXAMPLE
    .\Backup-AllSqlServerDatabases.ps1 -RetentionDays 30
        Use the config but override retention.

.EXAMPLE
    .\Backup-AllSqlServerDatabases.ps1 -BackupRoot 'X:\SqlBackups' -Targets @{ Name = 'local'; Instance = 'localhost' }
        One-off backup of the local default instance with Windows
        authentication, no config file.

.EXAMPLE
    .\Backup-AllSqlServerDatabases.ps1 -ConfigPath .\nightly-config.psd1

.NOTES
    Author: John Stover, Org Data Solutions.
    Copyright (c) 2026 John Stover. MIT License (see LICENSE).
    Provided as-is, without warranty. Questions: support@orgdatasolutions.com
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
$ToolName    = 'SQL Server Backup All Databases'
$ToolVersion = '0.5.0'

# ---------------------------------------------------------------------------
# First run with no config file: ask for the settings and write the file.
# ---------------------------------------------------------------------------
function Format-Psd1String([string]$Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function New-ConfigInteractively([string]$Path) {
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
        throw "Config file not found: $Path. Copy backup-config.example.psd1 to backup-config.psd1 next to this script and fill it in, or run the script from a console and it will ask for the settings."
    }
    Write-Host ""
    Write-Host "No backup-config.psd1 found. Answer these questions and the file will be written to:"
    Write-Host "  $Path"
    Write-Host ""
    $root = (Read-Host "  Backup folder (a local folder like D:\SqlBackups, or \\server\share)").Trim()
    if (-not $root) { throw "A backup folder is required." }
    $instance = (Read-Host "  SQL Server instance (localhost, SQL01, or SQL01\SQLEXPRESS) [localhost]").Trim()
    if (-not $instance) { $instance = 'localhost' }
    $useSqlLogin = (Read-Host "  Sign in with a SQL login instead of your Windows account? [y/N]").Trim().ToLower()
    $credBlock = "    # Windows authentication. To use a SQL login instead, add:`r`n    # DefaultCredential = @{ User = 'backup_login'; Password = 'the-password' }`r`n"
    if ($useSqlLogin -eq 'y' -or $useSqlLogin -eq 'yes') {
        $user = (Read-Host "  SQL login name").Trim()
        $secure = Read-Host "  Password (not shown while typing)" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secure))
        $credBlock = "    DefaultCredential = @{`r`n        User     = $(Format-Psd1String $user)`r`n        Password = $(Format-Psd1String $plain)`r`n    }`r`n"
    }
    $days = (Read-Host "  Delete .bak files older than this many days (0 keeps everything) [0]").Trim()
    if (-not ($days -match '^\d+$')) { $days = '0' }
    $text = @"
# SQL Server Backup All Databases - settings.
# Written by the script on first run. Edit with any text editor.
# Every setting is explained in backup-config.example.psd1.
# KEEP THIS FILE PRIVATE if it holds a password.
@{
    BackupRoot    = $(Format-Psd1String $root)
    RetentionDays = $days
    NoCompression = `$false
$credBlock
    Targets = @(
        @{
            Name     = 'default'
            Instance = $(Format-Psd1String $instance)
        }
    )
}
"@
    [IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ""
    Write-Host "Written: $Path"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Load config (PSD1 file). Command-line parameters override config values.
# ---------------------------------------------------------------------------
$configGiven = $PSBoundParameters.ContainsKey('ConfigPath')
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'backup-config.psd1'
}
if (-not (Test-Path -LiteralPath $ConfigPath) -and -not $configGiven -and -not $Targets) {
    New-ConfigInteractively -Path $ConfigPath
}
if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = Import-PowerShellDataFile -Path $ConfigPath
}
elseif (-not $configGiven -and $Targets) {
    # One-off run: everything comes from the command line.
    $cfg = @{}
    $ConfigPath = '(none: command line only)'
}
else {
    throw "Config file not found: $ConfigPath. Copy backup-config.example.psd1 to backup-config.psd1 next to this script and fill in your settings, or pass -BackupRoot and -Targets."
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
# Load a module that provides Invoke-Sqlcmd; install SqlServer if none exists
# ---------------------------------------------------------------------------
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
    if (Get-Module -ListAvailable -Name SqlServer) {
        Import-Module SqlServer -ErrorAction Stop
    } elseif (Get-Module -ListAvailable -Name SQLPS) {
        Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
    } else {
        Write-Host "The SqlServer PowerShell module is not installed. Installing it for the current user from the PowerShell Gallery (one time, a minute or two) ..."
        try {
            # Older Windows PowerShell builds default to TLS 1.0, which the gallery refuses.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
            }
            Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Import-Module SqlServer -ErrorAction Stop
        } catch {
            throw "Could not install the SqlServer module automatically: $($_.Exception.Message). Install it by hand in PowerShell with: Install-Module SqlServer -Scope CurrentUser"
        }
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

Write-Log "===== $ToolName $ToolVersion (beta): run started, config=$ConfigPath ($($Targets.Count) target(s)) ====="

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
