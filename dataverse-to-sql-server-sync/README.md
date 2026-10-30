# Dataverse to SQL Server Sync

**Version 0.6.0 (beta). By John Stover, Org Data Solutions.**

Copies the tables you choose from a Dataverse or Dynamics 365 environment
into a SQL Server or Azure SQL database you own, then keeps them current
with fast incremental runs. Your reports, Power BI models and SQL queries
run against your own copy, at full speed, with no API limits. The script
only reads from Dataverse, and the data flows from Microsoft's servers to
your SQL database and nowhere else.

---

## What it does

| | |
|---|---|
| **Copies your tables** | The tables you list, every table matching a prefix (`new_`, your publisher prefix, ...), or everything. New columns are added to SQL automatically. |
| **Keeps them current** | Each run fetches only rows changed since the last run (a `modifiedon` watermark per table), several tables at a time. Entity-set names and primary keys come from Dataverse metadata, so irregular table names sync too. |
| **Explains them** | `-Mode Refresh` builds a data dictionary (`ods_datadictionary_tables`, `_columns`, `_relationships`: row counts, fill rates, lookups) and a `vw_<table>` view per table with Dataverse display names as column names. |
| **Finds deletions** | `-ReconcileDeletes` marks rows that no longer exist in Dataverse (`is_active = 0`). It never deletes a row, and it refuses to act when a result looks wrong. |

## Safety

- **Nothing leaves your machine.** No telemetry, no upload. Data flows from
  your Dataverse environment to your SQL database, through the machine that
  runs the script, and nowhere else.
- **Read-only against Dataverse.** The script only reads from Dataverse.
- **It writes to SQL.** It creates and alters tables and views in the target
  database (`CREATE TABLE`, `ALTER TABLE ... ADD`, `CREATE OR ALTER VIEW`,
  `MERGE`). Point it at a database made for the copy, not at one another
  application owns.
- **Deletes are soft.** The reconcile pass only flips `is_active`, skips any
  table where it would flag more than 75% of rows (`-MaxMissingPct`), and
  refuses outright when Dataverse returns no rows. `-DryRun` shows what it
  would change.
- `config.xml` holds a client secret and may hold a SQL password. Keep it
  out of source control and restrict who can read it.

## What you need

- **PowerShell 7.2 or later** (`pwsh`). Windows PowerShell 5.1 is not
  enough. On Windows, `run.cmd` installs PowerShell 7 for you if it is
  missing. PowerShell 7 on macOS or Linux also works.
- **An app registration** that is an application user in the environment,
  with a security role that can read the tables you copy. Creating one
  takes about ten minutes: follow
  [docs/DATAVERSE-APP-REGISTRATION.md](../docs/DATAVERSE-APP-REGISTRATION.md).
  Or leave the client secret empty to sign in as yourself in a browser; the
  script installs the `Az.Accounts` module it needs for that.
- **A SQL Server 2016 SP1 or later, or Azure SQL, database** made for the
  copy, and a login that can `CREATE TABLE`, `ALTER TABLE` and
  `CREATE VIEW` in it (`db_owner` on that one database is the simple
  choice). Or your Windows account, when SQL Server trusts it.

## Quick start (Windows)

1. Double-click **`run.cmd`** in this folder, or open a command prompt here
   and type `run`.
2. The first time, it asks for the settings on the console (the four app
   registration values, the SQL Server and database, how to sign in to SQL,
   and which tables to copy) and writes `config.xml` next to the script.
   Keep that file private.
3. Check both connections without changing anything:
   `run -TestConnection`
4. Copy the data: `run`. The first run loads every listed table in full;
   later runs are incremental.
5. Add the data dictionary and the friendly views: `run -Mode Refresh`.

To change the settings later, edit `config.xml` with any text editor.
`config.example.xml` explains every setting, including prefixes, excluded
tables and the three special tables (`GlobalChoices`, `ods_metadata`,
`ods_metadata_columns`).

Optional but recommended: run the scripts in [`sql\`](sql/README.md)
against the target database for run history, SQL-backed watermarks and
soft-delete support.

The `Modules\` folder must stay next to the script.

## Quick start (macOS, Linux, or Windows without run.cmd)

```powershell
pwsh ./Sync-DataverseToSqlServer.ps1 -TestConnection
pwsh ./Sync-DataverseToSqlServer.ps1
pwsh ./Sync-DataverseToSqlServer.ps1 -Mode Refresh
```

Same first-run questions, same result.

## Running it

| Command | What it does | Suggested schedule |
|---|---|---|
| `run` | Incremental data sync (`-Mode Sync`) | Hourly |
| `run -Mode Refresh` | Sync, then rebuild the data dictionary and views | Daily |
| `run -Mode DictionaryOnly` | Dictionary and views only, for example after a schema change in Dataverse | As needed |
| `run -ReconcileDeletes -DryRun` | Report rows deleted in Dataverse, change nothing | Before the first real run |
| `run -ReconcileDeletes` | Mark deleted rows `is_active = 0` | Daily, outside the sync window |
| `run -Mode Refresh -IncludeReconcile` | The daily refresh, then the reconcile pass, in one task (logged as two runs) | Daily, instead of two tasks |
| `run -TestConnection` | Check both connections and exit | |

On macOS or Linux replace `run` with `pwsh ./Sync-DataverseToSqlServer.ps1`.

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
changes, so overlapping hourly and daily schedules are safe. The guard is
per machine: do not schedule the sync against the same database from two
machines.

### Scheduling (Task Scheduler)

- Program: `pwsh.exe`
- Arguments: `-NoProfile -ExecutionPolicy Bypass -File "<full-path>\Sync-DataverseToSqlServer.ps1" -Mode Refresh`
- Start in: the script's folder (relative paths in `config.xml` resolve
  from there)

How long it takes: the first full load depends on the size of the tables
(a few hundred thousand rows take minutes). Incremental runs on a quiet
environment finish in under a minute.

## What lands in SQL

| Object | Written by |
|---|---|
| One table per Dataverse table (`<TablePrefix><logicalname>`), primary key from Dataverse metadata (usually `<logicalname>id`) | Every sync |
| `GlobalChoices` (option-set labels), if listed in config | Every sync |
| `ods_datadictionary_tables`, `ods_datadictionary_columns`, `ods_datadictionary_relationships` | `Refresh`, `DictionaryOnly` |
| `vw_<table>` views with display-name columns (only columns that hold data) | `Refresh`, `DictionaryOnly` |
| `ops.*` run log, watermarks, review queue | Every run, once `sql\0001_ops_schema.sql` exists |

Logs go to the `LogPath` in `config.xml` (default `logs\sync_log.txt`),
plus one file per table under `logs\tables\` and the `-Table` comparison
reports under `logs\compare\`. Watermarks live in `ops.crm_sync_watermark`
once the `ops` schema exists, otherwise in the JSON file named by
`StatePath`. To reload one table in full:
`run -Table <name> -FullLoad`.

## Known limits (beta)

- Tables without a `modifiedon` column cannot be synced incrementally: the
  filtered request is rejected, the sync retries it as a full load, and
  those tables reload in full on every run.
- The reconcile pass (`-ReconcileDeletes`) derives the Web API entity-set
  name from the logical name with simple plural rules (`-y` to `-ies`, `-s`
  to `-es`, otherwise `-s`). For a table whose entity-set name differs, the
  reconcile logs an error for that table and continues; the sync itself is
  not affected.
- If the metadata lookup fails, the sync falls back to the same plural rules
  and to `<logicalname>id` as the primary key, and logs a warning. A
  `<PrimaryKey>` on a `<Table>` entry in `config.xml` always wins.
- A SQL column's type is set when the column is created, from the first
  record fetched in that run (text, number, date, true/false, GUID). A column
  that is empty in that record is created as text (`NVARCHAR(MAX)`).
- Interactive sign-in (empty client secret) is meant for a first look. For a
  scheduled task use an app registration.

## Troubleshooting

| Message | What to do |
|---|---|
| `AADSTS7000215` or `AADSTS700016` during sign-in | Wrong or expired client secret, or wrong client id / tenant id. See [docs/DATAVERSE-APP-REGISTRATION.md](../docs/DATAVERSE-APP-REGISTRATION.md). |
| `401` or `403` from Dataverse | The app registration is not an application user in this environment, or its role cannot read that table. |
| `Login failed for user` from SQL | Wrong SQL login or password in `config.xml`, or the login has no access to that database. |
| `CREATE TABLE permission denied` | The SQL login needs `db_owner` (or `CREATE TABLE`, `ALTER` and `CREATE VIEW`) on the target database. |
| `Another copy of Sync-DataverseToSqlServer.ps1 is already running` | A scheduled run is in progress. Wait for it, or use `-Force` for a targeted `-Table` run that does not touch the same tables. |
| `Cannot convert SQLConnector to SQLConnector` | The script was run twice in one PowerShell window after an edit. Open a new window. |
| `Incremental filter rejected (400); retrying as full load` | Normal for tables without `modifiedon`. The table reloads in full. |
| `#Requires -Version 7.2` error | You started the script in Windows PowerShell 5.1. Use `run.cmd` or `pwsh`. |

## Then what?

A SQL copy of your CRM is where governance starts, not where it ends. The
hosted **ODS Data Management Platform** catalogs and profiles every table,
tags sensitive columns and masks them by role in every grid, chart, export
and share link, and keeps an access audit you can hand to your board.

The governance tools are free for approved nonprofits and .org
organizations. The Dataverse and SQL Server connectors are premium add-ons
for a free workspace.

Questions: **support@orgdatasolutions.com**

**[Load these results into your free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-dataverse-sql-sync)**

## License

MIT License. Copyright (c) 2026 John Stover, Org Data Solutions. Provided
as-is, without warranty.
