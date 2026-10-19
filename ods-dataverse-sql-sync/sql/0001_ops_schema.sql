/* =============================================================================
   0001_ops_schema.sql
   ODS Dataverse to SQL Sync - optional `ops` schema
   -----------------------------------------------------------------------------
   Adds:
       ops.runlog              one row per sync run
       ops.run_table_log       per-table outcome inside a run
       ops.error_log           per-row error events
       ops.crm_sync_watermark  per-table incremental watermark (replaces the
                               JSON state file named in config.xml Paths/StatePath)
       ops.pipeline_config     optional runtime overrides (BatchSize, PageSize,
                               MaxParallel for pipeline 'CRMToSQL')
       ops.review_queue        tables a reconcile pass refused to change
       ops.vw_pipeline_health  at-a-glance status view

   The sync works without this schema (it falls back to the JSON state file
   and skips run logging), but with it you get SQL-backed watermarks and a
   run history you can report on.

   Properties
   ----------
   - Idempotent. Safe to run repeatedly.
   - Additive only. No existing object is dropped or altered, except the
     ops.vw_pipeline_health view, which is (re)created with CREATE OR ALTER.
   - No cascading foreign keys.
   - SQL Server 2016 SP1 or later, and Azure SQL.

   How to apply
   ------------
   Connect to the TARGET database (the one config.xml <Sql><Database> names)
   as a user with CREATE SCHEMA, CREATE TABLE and CREATE VIEW, in a tool that
   understands GO batch separators (SSMS, Azure Data Studio, sqlcmd).
   ========================================================================= */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------- schema ------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ops')
    EXEC('CREATE SCHEMA [ops] AUTHORIZATION [dbo];');
GO

/* ---------- ops.runlog --------------------------------------------------- */
IF OBJECT_ID('ops.runlog', 'U') IS NULL
BEGIN
    CREATE TABLE ops.runlog (
        run_id        BIGINT IDENTITY(1,1) NOT NULL,
        pipeline      NVARCHAR(100)        NOT NULL,
        host_name     NVARCHAR(200)        NULL,
        started_utc   DATETIME2            NOT NULL CONSTRAINT DF_ops_runlog_started   DEFAULT SYSUTCDATETIME(),
        ended_utc     DATETIME2            NULL,
        status        NVARCHAR(20)         NULL,   /* 'running' | 'success' | 'failed' | 'partial' */
        rows_in       BIGINT               NULL,
        rows_out      BIGINT               NULL,
        rows_error    BIGINT               NULL,
        notes         NVARCHAR(MAX)        NULL,
        CONSTRAINT PK_ops_runlog PRIMARY KEY CLUSTERED (run_id)
    );

    CREATE INDEX IX_ops_runlog_pipeline_started
        ON ops.runlog (pipeline, started_utc DESC);
END
GO

/* ---------- ops.run_table_log ------------------------------------------- */
IF OBJECT_ID('ops.run_table_log', 'U') IS NULL
BEGIN
    CREATE TABLE ops.run_table_log (
        run_table_log_id  BIGINT IDENTITY(1,1) NOT NULL,
        run_id            BIGINT               NOT NULL,
        table_name        NVARCHAR(256)        NOT NULL,
        action            NVARCHAR(50)         NULL,   /* 'upsert' | 'build' | 'reconcile_deletes' */
        rows              BIGINT               NULL,
        duration_ms       INT                  NULL,
        status            NVARCHAR(20)         NULL,   /* 'success' | 'warn' | 'error' */
        error_msg         NVARCHAR(MAX)        NULL,
        logged_utc        DATETIME2            NOT NULL CONSTRAINT DF_ops_rtl_logged DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ops_run_table_log PRIMARY KEY CLUSTERED (run_table_log_id),
        CONSTRAINT FK_ops_run_table_log_runlog
            FOREIGN KEY (run_id) REFERENCES ops.runlog (run_id)
    );

    CREATE INDEX IX_ops_run_table_log_run_id ON ops.run_table_log (run_id);
    CREATE INDEX IX_ops_run_table_log_table  ON ops.run_table_log (table_name, logged_utc DESC);
END
GO

/* ---------- ops.error_log ----------------------------------------------- */
/* run_id is nullable on purpose: errors can be captured before or after a run is opened. */
IF OBJECT_ID('ops.error_log', 'U') IS NULL
BEGIN
    CREATE TABLE ops.error_log (
        error_id      BIGINT IDENTITY(1,1) NOT NULL,
        run_id        BIGINT               NULL,
        pipeline      NVARCHAR(100)        NULL,
        table_name    NVARCHAR(256)        NULL,
        row_pk        NVARCHAR(256)        NULL,
        error_msg     NVARCHAR(MAX)        NOT NULL,
        payload_json  NVARCHAR(MAX)        NULL,
        occurred_utc  DATETIME2            NOT NULL CONSTRAINT DF_ops_errorlog_occurred DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ops_error_log PRIMARY KEY CLUSTERED (error_id)
    );

    CREATE INDEX IX_ops_error_log_pipeline_occurred
        ON ops.error_log (pipeline, occurred_utc DESC);
    CREATE INDEX IX_ops_error_log_run_id
        ON ops.error_log (run_id);
END
GO

/* ---------- ops.crm_sync_watermark -------------------------------------- */
/* On its first run after this script, the sync copies any watermarks from the
   JSON state file into this table, then uses this table only. */
IF OBJECT_ID('ops.crm_sync_watermark', 'U') IS NULL
BEGIN
    CREATE TABLE ops.crm_sync_watermark (
        logical_name       NVARCHAR(256) NOT NULL,
        last_modified_utc  DATETIME2     NOT NULL,
        run_id             BIGINT        NULL,
        updated_utc        DATETIME2     NOT NULL CONSTRAINT DF_ops_watermark_updated DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ops_crm_sync_watermark PRIMARY KEY CLUSTERED (logical_name)
    );
END
GO

/* ---------- ops.pipeline_config ----------------------------------------- */
/* (pipeline, key) -> value. The sync reads BatchSize, PageSize and
   MaxParallel for pipeline 'CRMToSQL'; a row here overrides config.xml. */
IF OBJECT_ID('ops.pipeline_config', 'U') IS NULL
BEGIN
    CREATE TABLE ops.pipeline_config (
        pipeline      NVARCHAR(100)  NOT NULL,
        config_key    NVARCHAR(200)  NOT NULL,
        config_value  NVARCHAR(MAX)  NULL,
        notes         NVARCHAR(500)  NULL,
        updated_utc   DATETIME2      NOT NULL CONSTRAINT DF_ops_pipelineconfig_updated DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ops_pipeline_config PRIMARY KEY CLUSTERED (pipeline, config_key)
    );
END
GO

/* ---------- ops.review_queue -------------------------------------------- */
/* Items that need a person to decide, e.g. a reconcile-deletes pass that
   would have flagged more rows than its safety threshold allows. */
IF OBJECT_ID('ops.review_queue', 'U') IS NULL
BEGIN
    CREATE TABLE ops.review_queue (
        queue_id      BIGINT IDENTITY(1,1) NOT NULL,
        source        NVARCHAR(100)        NOT NULL,
        source_table  NVARCHAR(256)        NULL,
        source_pk     NVARCHAR(256)        NULL,
        reason        NVARCHAR(500)        NOT NULL,
        payload_json  NVARCHAR(MAX)        NULL,
        status        NVARCHAR(20)         NOT NULL CONSTRAINT DF_ops_review_queue_status  DEFAULT 'open',
        assigned_to   NVARCHAR(200)        NULL,
        created_utc   DATETIME2            NOT NULL CONSTRAINT DF_ops_review_queue_created DEFAULT SYSUTCDATETIME(),
        resolved_utc  DATETIME2            NULL,
        resolved_by   NVARCHAR(200)        NULL,
        resolution    NVARCHAR(MAX)        NULL,
        CONSTRAINT PK_ops_review_queue PRIMARY KEY CLUSTERED (queue_id)
    );

    CREATE INDEX IX_ops_review_queue_status
        ON ops.review_queue (status, created_utc DESC);
END
GO

/* ---------- ops.vw_pipeline_health -------------------------------------- */
/* One row per pipeline (CRMToSQL = hourly sync, CRMRefresh = daily refresh,
   CRMReconcileDeletes = reconcile pass).
   last_success_utc counts any completed run ('success' or 'partial': a partial
   run still delivered data). errors_24h counts table-level errors from
   run_table_log plus row-level errors from error_log. */
CREATE OR ALTER VIEW ops.vw_pipeline_health AS
WITH latest AS (
    SELECT pipeline,
           MAX(CASE WHEN status IN ('success','partial') THEN started_utc END)
               AS last_success_utc,
           MAX(started_utc) AS last_run_utc
    FROM ops.runlog
    GROUP BY pipeline
),
last_status AS (
    SELECT r.pipeline, r.status
    FROM ops.runlog r
    INNER JOIN (
        SELECT pipeline, MAX(started_utc) AS m FROM ops.runlog GROUP BY pipeline
    ) m ON m.pipeline = r.pipeline AND m.m = r.started_utc
)
SELECT
    l.pipeline,
    l.last_run_utc,
    l.last_success_utc,
    s.status AS last_status,
    DATEDIFF(MINUTE, l.last_success_utc, SYSUTCDATETIME()) AS minutes_since_success,
    (
        (SELECT COUNT(*)
           FROM ops.run_table_log t
           JOIN ops.runlog r ON r.run_id = t.run_id
          WHERE r.pipeline = l.pipeline
            AND t.status = 'error'
            AND t.logged_utc > DATEADD(HOUR, -24, SYSUTCDATETIME()))
      +
        (SELECT COUNT(*)
           FROM ops.error_log e
          WHERE e.pipeline = l.pipeline
            AND e.occurred_utc > DATEADD(HOUR, -24, SYSUTCDATETIME()))
    ) AS errors_24h,
    (SELECT COUNT(*)
       FROM ops.review_queue q
      WHERE q.source = l.pipeline AND q.status = 'open') AS review_queue_open
FROM latest l
LEFT JOIN last_status s ON s.pipeline = l.pipeline;
GO

PRINT '0001_ops_schema.sql - done.';
GO
