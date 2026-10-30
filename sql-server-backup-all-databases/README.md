# SQL Server Backup All Databases

**Version 0.5.0 (beta). By John Stover, Org Data Solutions.**

One PowerShell script that backs up every online database on one or more
SQL Server instances into folders you choose, with dated logs and optional
retention. Schedule it nightly and stop wondering whether last night's
backup ran.

---

## What it does

| | |
|---|---|
| **Finds the databases** | Every user database that is ONLINE, on every instance you list. Skips `tempdb` and snapshots. New databases are picked up automatically. |
| **Backs them up** | `BACKUP DATABASE ... WITH CHECKSUM`, compressed where the edition supports it (Express does not). |
| **Logs it** | One log file per day in your backup folder, with sizes and every failure. |
| **Cleans up** | Optional retention: removes `.bak` files older than N days. |

The script exits with code 1 when any database fails, so Task Scheduler and
monitoring tools can tell.

## Safety

- **Nothing leaves your machine** (or your network). No telemetry, no upload.
  Backups go only to the folders you name.
- **No default folder.** You must set `BackupRoot`, so a backup never lands
  somewhere you did not choose.
- **Retention deletes files.** With `RetentionDays` above 0 it removes
  *every* `.bak` older than that under each destination, including files
  this script did not create. Use folders dedicated to these backups.
- **Credentials.** `backup-config.psd1` can hold a SQL password in plain
  text. Prefer Windows authentication (leave `DefaultCredential` out);
  otherwise restrict the file's permissions and keep it out of source
  control and synced folders.

## What you need

- **Windows** with Windows PowerShell 5.1 (included) or PowerShell 7.
- The `SqlServer` PowerShell module. The script installs it for the current
  user from the PowerShell Gallery when it is missing (one time, a minute or
  two). The older `SQLPS` module also works.
- A login with `BACKUP DATABASE` permission (`db_backupoperator` or
  `db_owner` in each database, or `sysadmin`), or your Windows account.
- The **SQL Server service account** (not your account) needs write access
  to each destination folder, because SQL Server writes the `.bak` itself.

## Quick start

1. Double-click **`run.cmd`** in this folder, or open a command prompt here
   and type `run`.
2. The first time, it asks four or five questions (backup folder, instance,
   Windows account or SQL login, retention) and writes `backup-config.psd1`
   next to the script.
3. It backs up every database on that instance and prints the log. Read
   the log once before you schedule it.

To change the settings later, edit `backup-config.psd1` with any text
editor. `backup-config.example.psd1` explains every setting, including
several instances, per-instance folders and credentials, and full
connection strings.

One-off run with no config file:

```powershell
.\Backup-AllSqlServerDatabases.ps1 -BackupRoot 'X:\SqlBackups' -Targets @{ Name = 'local'; Instance = 'localhost' }
```

## Running it

```
run                                 use backup-config.psd1 for everything
run -RetentionDays 30               override retention for this run
run -NoCompression                  turn compression off
run -ConfigPath .\nightly.psd1      use another config file
```

`run.cmd` uses PowerShell 7 when it is installed and Windows PowerShell
otherwise, and starts the script with `-ExecutionPolicy Bypass`, so no
policy change is needed.

## Schedule it

Task Scheduler, once a run by hand looks right:

- Program: `powershell.exe` (or `pwsh.exe`)
- Arguments: `-NoProfile -ExecutionPolicy Bypass -File "<full-path>\Backup-AllSqlServerDatabases.ps1"`
- Run with highest privileges, whether the user is logged on or not.

## Layout on disk

```
<Destination>\
  <DbName>\
    <DbName>_yyyyMMdd_HHmmss.bak
<BackupRoot>\BackupLog_yyyyMMdd.log
```

## Remote instances

A target's `Destination` is evaluated **on the SQL Server that runs the
backup**. To bring a remote server's backups to this machine, share the
backup folder (for example `\\THISBOX\SqlBackups`), give the remote SQL
Server service account write access, and set that target's `Destination`
to the UNC path. Examples are in `backup-config.example.psd1`.

## Parameters

| Parameter | Meaning |
|---|---|
| `-ConfigPath` | Config file. Default: `backup-config.psd1` next to the script. |
| `-BackupRoot` | Backup and log folder. **Required** unless the config sets `BackupRoot`. |
| `-RetentionDays` | Override the config's retention (0 keeps everything). |
| `-NoCompression` | Turn compression off. |
| `-Targets` | Replace the config's target list for this run. |

## Known limits (beta)

- Full backups only. No differential or log backups, so point-in-time
  restore is not covered. For databases in the FULL recovery model, add
  your own log backups or the log file keeps growing.
- One backup file per database per run; no striping, no Azure Blob
  destinations.
- Retention is by file age under each destination, not by backup count.

## Troubleshooting

| Message | What to do |
|---|---|
| `Failed to connect / enumerate databases` | Check the instance name, that SQL Server is running and reachable, and the login. |
| `Cannot open backup device ... Operating system error 5 (Access is denied)` | The SQL Server service account cannot write to the destination folder. Give it write access, or for a remote instance use a share. |
| `BACKUP DATABASE permission denied` | The login needs `db_backupoperator` or `db_owner` in that database, or `sysadmin`. |
| `Could not install the SqlServer module automatically` | Run `Install-Module SqlServer -Scope CurrentUser` in PowerShell by hand, then run again. |
| `Edition does not support compression; disabling it` | Normal on Express. The backup runs uncompressed. |

## Then what?

A backup protects the database. It does not tell you what is in it, who can
read it, or whether the data is any good. The **SQL Server Sensitive Data
Scanner** in this repository answers that offline, and the hosted **ODS Data
Management Platform** keeps answering it: a data catalog, sensitivity tags
with role-based masking, a scorecard and an access audit.

The governance tools are free for approved nonprofits and .org
organizations. The SQL Server connector is a premium add-on for a free
workspace.

**[Load these results into your free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-sql-backup)**

Questions: **support@orgdatasolutions.com**

## License

MIT License. Copyright (c) 2026 John Stover, Org Data Solutions. Provided
as-is, without warranty.
