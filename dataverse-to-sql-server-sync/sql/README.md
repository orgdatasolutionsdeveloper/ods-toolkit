# SQL scripts (optional)

Idempotent, numbered scripts for the database the sync writes to. Each one
is safe to re-run. The sync runs without any of them. They add run history,
SQL-backed watermarks and soft-delete support.

| File | What it does | Changes existing tables? |
|---|---|---|
| `0001_ops_schema.sql` | Creates the `ops` schema: `runlog`, `run_table_log`, `error_log`, `crm_sync_watermark`, `pipeline_config`, `review_queue`, and the `vw_pipeline_health` view. | No |
| `0002_softdelete_columns.sql` | Adds `is_active` (default 1) and `detected_missing_utc` to your replica tables, for `-ReconcileDeletes`. **Dry run by default.** | Yes: two additive columns |
| `0003_datadictionary_relationships.sql` | Creates the indexed `ods_datadictionary_relationships` table. Run it before the first `-Mode Refresh`. | Adds two nullable columns to `ods_datadictionary_columns` if that table exists |

## How to run

1. Connect to the **target** database (the one `config.xml` names in
   `<Sql><Database>`) as a user with `CREATE SCHEMA`, `CREATE TABLE`,
   `CREATE VIEW` and `ALTER` on `dbo`.
2. Use a client that understands `GO` batch separators: SSMS, Azure Data
   Studio, or `sqlcmd`.
3. Run `0001_ops_schema.sql`, then `0003_datadictionary_relationships.sql`.
4. When you want `-ReconcileDeletes`: run one sync first (so the tables
   exist), edit the `@Include` patterns in `0002_softdelete_columns.sql` to
   match your config, run it with `@DryRun = 1`, read the list, then set
   `@DryRun = 0` and run it again.

## Checking on the sync

```sql
SELECT * FROM ops.vw_pipeline_health;            -- one row per pipeline
SELECT TOP (50) * FROM ops.run_table_log ORDER BY logged_utc DESC;
SELECT * FROM ops.review_queue WHERE status = 'open';
```

Pipelines: `CRMToSQL` (hourly `-Mode Sync`), `CRMRefresh` (`-Mode Refresh` or
`DictionaryOnly`), `CRMReconcileDeletes` (`-ReconcileDeletes`).

## Overriding settings without editing config.xml

```sql
MERGE ops.pipeline_config AS t
USING (SELECT 'CRMToSQL' p, 'BatchSize' k, '10000' v) AS s
  ON t.pipeline = s.p AND t.config_key = s.k
WHEN MATCHED THEN UPDATE SET config_value = s.v, updated_utc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (pipeline, config_key, config_value) VALUES (s.p, s.k, s.v);
```

`BatchSize`, `PageSize` and `MaxParallel` are read this way.

## Rollback

`0001`:

```sql
DROP VIEW  IF EXISTS ops.vw_pipeline_health;
DROP TABLE IF EXISTS ops.run_table_log;     -- before runlog (foreign key)
DROP TABLE IF EXISTS ops.runlog;
DROP TABLE IF EXISTS ops.error_log;
DROP TABLE IF EXISTS ops.crm_sync_watermark;
DROP TABLE IF EXISTS ops.pipeline_config;
DROP TABLE IF EXISTS ops.review_queue;
DROP SCHEMA IF EXISTS ops;
```

Dropping `ops.crm_sync_watermark` makes the next sync fall back to the JSON
state file, or do a full reload if that file is gone.

`0002`, per table (soft-delete history in these columns is lost):

```sql
ALTER TABLE [dbo].[<table>] DROP CONSTRAINT [DF_<table>_is_active];
ALTER TABLE [dbo].[<table>] DROP COLUMN [is_active];
ALTER TABLE [dbo].[<table>] DROP COLUMN [detected_missing_utc];
```
