# ODS SQL Backup

**A free tool from Org Data Solutions.** One PowerShell script that backs up
every online database on one or more SQL Server instances into folders you
choose, with dated logs and optional retention. Schedule it nightly and
stop wondering whether last night's backup ran.

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
  somewhere you didn't choose.
- **Retention deletes files.** With `RetentionDays > 0` it removes *every*
  `.bak` older than that under each destination, including files this script
  did not create. Use folders dedicated to these backups.
- **Credentials.** `backup-config.psd1` can hold a SQL password in plaintext.
  Prefer Windows authentication (leave `DefaultCredential` out); otherwise
  restrict the file's permissions and keep it out of source control and
  synced folders.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- The `SqlServer` PowerShell module (or the older `SQLPS`) for `Invoke-Sqlcmd`:
  `Install-Module SqlServer -Scope CurrentUser`
- A login with `BACKUP DATABASE` permission (`db_backupoperator` or
  `db_owner` in each database, or `sysadmin`).
- The **SQL Server service account** (not your account) needs write access to
  each destination folder, because SQL Server writes the `.bak` itself.

## Setup (~5 minutes)

```powershell
Copy-Item backup-config.example.psd1 backup-config.psd1
notepad backup-config.psd1      # set BackupRoot and your Targets
.\Backup-AllSqlDatabases.ps1    # run once by hand and read the log
```

One-off run with no config file:

```powershell
.\Backup-AllSqlDatabases.ps1 -BackupRoot 'X:\SqlBackups' -Targets @{ Name = 'local'; Instance = 'localhost' }
```

## Schedule it

Task Scheduler, once a run by hand looks right:

- Program: `powershell.exe` (or `pwsh.exe`)
- Arguments: `-NoProfile -File "<full-path>\Backup-AllSqlDatabases.ps1"`
- Run with highest privileges, whether the user is logged on or not.

If your execution policy blocks the script, see *Running the PowerShell
tools* in the toolkit's top-level README.

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
backup folder (e.g. `\\THISBOX\SqlBackups`), give the remote SQL Server
service account write access, and set that target's `Destination` to the UNC
path. Examples are in `backup-config.example.psd1`.

## Parameters

| Parameter | Meaning |
|---|---|
| `-ConfigPath` | Config file. Default: `backup-config.psd1` next to the script. |
| `-BackupRoot` | Backup + log folder. **Required** unless the config sets `BackupRoot`. |
| `-RetentionDays` | Override the config's retention (0 keeps everything). |
| `-NoCompression` | Turn compression off. |
| `-Targets` | Replace the config's target list for this run. |

## Then what?

A backup protects the database. It doesn't tell you what's in it, who can
read it, or whether the data is any good. The toolkit's **Governance Scan**
answers that offline, and the hosted **ODS Data Management Platform** keeps
answering it: a data catalog, sensitivity tags with role-based masking, a
governance scorecard and an access audit.

The governance tools are free for approved nonprofits and .org
organizations. The SQL Server connector is a premium add-on for a free
workspace.

**[Load these results into your free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-sql-backup)**

Questions: **support@orgdatasolutions.com**
