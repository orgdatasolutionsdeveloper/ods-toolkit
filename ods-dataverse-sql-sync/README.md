# ODS Dataverse to SQL Sync

**A free tool from Org Data Solutions.** Copies the tables you choose from a
Dataverse / Dynamics 365 environment into a SQL Server or Azure SQL database
you own, then keeps them current with fast incremental syncs. Your reports,
Power BI models and SQL queries run against your own copy, at full speed,
with no API limits.

---

## What it does

| | |
|---|---|
| **Copies your tables** | The tables you list, every table matching a prefix (`new_`, your publisher prefix, ...), or everything. New columns are added to SQL automatically. |
| **Keeps them current** | Each run fetches only rows changed since the last run (`modifiedon` watermark per table), several tables at a time. Entity-set names and primary keys come from Dataverse metadata, so irregular table names sync too. |
| **Explains them** | `-Mode Refresh` builds a data dictionary (`ods_datadictionary_tables`, `_columns`, `_relationships`: row counts, fill rates, lookups) and a `vw_<table>` view per table with Dataverse display names as column names. |
| **Finds deletions** | `-ReconcileDeletes` marks rows that no longer exist in Dataverse (`is_active = 0`). It never deletes a row, and it refuses to act when a result looks wrong. |

## Safety

- **Nothing leaves your machine.** No telemetry, no upload. Data flows from
  your Dataverse environment to your SQL database, through the machine that
  runs the script, and nowhere else.
- **Read-only against Dataverse.** The script only reads from Dataverse.
- **It writes to SQL.** It creates and alters tables and views in the
  target database (`CREATE TABLE`, `ALTER TABLE ... ADD`, `CREATE OR ALTER
  VIEW`, `MERGE`). Point it at a database meant for the replica, not at one
  another application owns.
- **Deletes are soft.** The reconcile pass only flips `is_active`, skips any
  table where it would flag more than 75% of rows (`-MaxMissingPct`), and
  refuses outright when Dataverse returns no rows. `-DryRun` shows what it
  would change.
- `config.xml` holds a client secret and a SQL password. Keep it out of
  source control and restrict who can read it.

## Requirements

- **PowerShell 7.2 or later** (`pwsh`). Windows PowerShell 5.1 is not enough.
- An app registration in Microsoft Entra ID with a client secret, added to
  the environment as an **Application User** with a role that can read the
  tables you sync. (Or leave the secret empty to sign in as yourself with the
  `Az.Accounts` module.)
- A SQL Server 2016 SP1+ or Azure SQL database, and a login that can
  `CREATE TABLE`, `ALTER TABLE` and `CREATE VIEW` in it.

## Setup (~15 minutes)

```powershell
Copy-Item config.example.xml config.xml
notepad config.xml                          # Dataverse, SQL and your table list
.\Sync-DataverseToSql.ps1 -TestConnection   # checks both connections, changes nothing
.\Sync-DataverseToSql.ps1                   # first run = full load of each table
.\Sync-DataverseToSql.ps1 -Mode Refresh     # adds the dictionary and vw_* views
```

Optional but recommended: run the scripts in [`sql\`](sql/README.md) for run
history, SQL-backed watermarks and soft-delete support.

The `Modules\` folder must stay next to the script.

## Run it

| Command | What it does | Suggested schedule |
|---|---|---|
| `.\Sync-DataverseToSql.ps1` | Incremental data sync (`-Mode Sync`) | Hourly |
| `.\Sync-DataverseToSql.ps1 -Mode Refresh` | Sync, then rebuild the data dictionary and views | Daily |
| `.\Sync-DataverseToSql.ps1 -Mode DictionaryOnly` | Dictionary and views only, e.g. after a schema change in Dataverse | As needed |
| `.\Sync-DataverseToSql.ps1 -ReconcileDeletes -DryRun` | Report rows deleted in Dataverse, change nothing | Before the first real run |
| `.\Sync-DataverseToSql.ps1 -ReconcileDeletes` | Mark deleted rows `is_active = 0` | Daily, outside the sync window |
| `.\Sync-DataverseToSql.ps1 -Mode Refresh -IncludeReconcile` | The daily refresh, then the reconcile pass, in one task (logged as two runs) | Daily, instead of two tasks |
| `.\Sync-DataverseToSql.ps1 -TestConnection` | Check both connections and exit | — |

Manual overrides, for one-off runs:

| Option | What it does |
|---|---|
| `-Table contact,account` | Only these tables (logical names, singular). Afterward, compares row counts in Dataverse and SQL for each and, when rows are missing, writes the missing keys to `logs\compare\`. |
| `-FullLoad` | Ignore the watermark and re-fetch every row. The watermark still advances, so the next scheduled run is incremental again. Pair it with `-Table`. |
| `-Force` | Skip the single-instance guard (below). Only when the run holding the lock is not touching the same tables. |

Reconcile options: `-MaxMissingPct 0.75` (skip a table above this share of
missing rows), `-MinRowCountForThreshold 10` (ignore the percentage on
smaller tables) and `-DryRun`.

**Single-instance guard.** Only one copy of the script runs at a time on a
machine. A run that finds another in progress prints a message and exits
(`-TestConnection` is exempt), and the next scheduled run picks up the
changes, so overlapping hourly and daily schedules are safe. The guard is per machine: do not schedule the sync
against the same database from two machines.

### Scheduling (Task Scheduler)

- Program: `pwsh.exe`
- Arguments: `-NoProfile -File "<full-path>\Sync-DataverseToSql.ps1" -Mode Refresh`
- Start in: the script's folder (relative paths in `config.xml` resolve from there)

If your execution policy blocks the script, see *Running the PowerShell
tools* in the toolkit's top-level README.

## What lands in SQL

| Object | Written by |
|---|---|
| One table per Dataverse table (`<TablePrefix><logicalname>`), primary key from Dataverse metadata (usually `<logicalname>id`) | Every sync |
| `GlobalChoices` (option-set labels), if listed in config | Every sync |
| `ods_datadictionary_tables`, `ods_datadictionary_columns`, `ods_datadictionary_relationships` | `Refresh`, `DictionaryOnly` |
| `vw_<table>` views with display-name columns (only columns that hold data) | `Refresh`, `DictionaryOnly` |
| `ops.*` run log, watermarks, review queue | Every run, once `sql\0001_ops_schema.sql` exists |

Logs go to the `LogPath` in `config.xml`, plus one file per table under
`logs\tables\` and the `-Table` comparison reports under `logs\compare\`,
next to it. Watermarks live in `ops.crm_sync_watermark` once the `ops` schema
exists, otherwise in the JSON file named by `StatePath`. To reload one table
in full: `.\Sync-DataverseToSql.ps1 -Table <name> -FullLoad`.

## Known limitations

- Tables without a `modifiedon` column can't be synced incrementally: the
  filtered request is rejected, the sync retries it as a full load, and
  those tables reload in full on every run.
- The reconcile pass (`-ReconcileDeletes`) still derives the Web API
  entity-set name from the logical name with simple plural rules (`-y` →
  `-ies`, `-s` → `-es`, otherwise `-s`). For a table whose entity-set name
  differs, the reconcile logs an error for that table and continues; the
  sync itself is not affected.
- If the metadata lookup fails, the sync falls back to the same plural rules
  and to `<logicalname>id` as the primary key, and logs a warning. A
  `<PrimaryKey>` on a `<Table>` entry in `config.xml` always wins.
- A SQL column's type is set when the column is created, from the first
  record fetched in that run (text, number, date, true/false, GUID). A column
  that is empty in that record is created as text (`NVARCHAR(MAX)`).

## Then what?

A SQL copy of your CRM is where governance starts, not where it ends. The
hosted **ODS Data Management Platform** catalogs and profiles every table,
tags sensitive columns and masks them by role in every grid, chart, export
and AI answer, and keeps an access audit you can hand to your board.

The governance tools are free for approved nonprofits and .org
organizations. The Dataverse and SQL Server connectors are premium add-ons
for a free workspace.

Questions: **support@orgdatasolutions.com**

**[Load these results into your free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-dataverse-sql-sync)**
