/* =============================================================================
   0002_softdelete_columns.sql
   ODS Dataverse to SQL Sync - soft-delete columns for -ReconcileDeletes
   -----------------------------------------------------------------------------
   Adds two columns to each replica table in the dbo schema:
       is_active             BIT        NOT NULL  DEFAULT 1
       detected_missing_utc  DATETIME2  NULL

   Why
   ---
   Incremental sync only sees rows that still exist in Dataverse, so a row
   deleted there stays in SQL. The reconcile pass
   (Sync-DataverseToSql.ps1 -ReconcileDeletes) compares primary keys and sets
   is_active = 0 plus detected_missing_utc on rows that are gone. Nothing is
   physically deleted. The vw_<table> views the sync builds filter on
   is_active = 1 automatically once the column exists.

   Which tables
   ------------
   1. Every table the sync has recorded in dbo.ods_datadictionary_tables
      (filled by a -Mode Refresh run), and
   2. every dbo table whose name matches a pattern in @Include below.
      EDIT @Include to match your config.xml: your <Table> names and
      <Prefixes>, each with the <TablePrefix> in front if you set one.
      In LIKE patterns write the underscore as [_].
   Always skipped: the ods_* dictionary/metadata tables, GlobalChoices,
   anything outside dbo, and all views.

   Safety
   ------
   @DryRun = 1 (the default) prints every ALTER without running it.
   Review the list, then set @DryRun = 0 and run again.
   Idempotent: tables that already have the columns are skipped.
   ========================================================================= */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @DryRun BIT = 1;       /* 1 = print only, no changes; 0 = apply */

DECLARE @Include TABLE (pattern SYSNAME COLLATE DATABASE_DEFAULT NOT NULL);
INSERT INTO @Include (pattern) VALUES
    (N'account'),
    (N'contact'),
    (N'new[_]%');              /* your publisher prefix, e.g. N'cr123[_]%' */

DECLARE @cmd     NVARCHAR(MAX);
DECLARE @tbl     SYSNAME;
DECLARE @added   INT = 0;
DECLARE @skipped INT = 0;

CREATE TABLE #targets (name SYSNAME COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);

INSERT INTO #targets (name)
SELECT DISTINCT t.name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN @Include i   ON t.name LIKE i.pattern
WHERE s.name = 'dbo';

IF OBJECT_ID('dbo.ods_datadictionary_tables', 'U') IS NOT NULL
    EXEC sp_executesql N'
        INSERT INTO #targets (name)
        SELECT DISTINCT d.sql_table_name
        FROM dbo.ods_datadictionary_tables d
        JOIN sys.tables t  ON t.name = d.sql_table_name
        JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = ''dbo''
        WHERE d.sql_table_name IS NOT NULL
          AND d.sql_table_name NOT IN (SELECT name FROM #targets);';

DELETE FROM #targets
WHERE name LIKE N'ods[_]%'
   OR name LIKE N'%ods[_]metadata%'
   OR name LIKE N'%GlobalChoices';

PRINT '-----------------------------------------------------------------------';
PRINT '0002_softdelete_columns.sql  (DryRun = ' + CAST(@DryRun AS NVARCHAR) + ')';
PRINT '-----------------------------------------------------------------------';

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM #targets ORDER BY name;

OPEN c;
FETCH NEXT FROM c INTO @tbl;

WHILE @@FETCH_STATUS = 0
BEGIN
    /* --- is_active --- */
    IF NOT EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID(N'[dbo].' + QUOTENAME(@tbl)) AND name = 'is_active'
    )
    BEGIN
        SET @cmd =
            N'ALTER TABLE [dbo].' + QUOTENAME(@tbl)
          + N' ADD [is_active] BIT NOT NULL'
          + N' CONSTRAINT ' + QUOTENAME(N'DF_' + @tbl + N'_is_active') + N' DEFAULT (1);';

        PRINT '  + ' + @cmd;
        IF @DryRun = 0
            EXEC sp_executesql @cmd;

        SET @added = @added + 1;
    END
    ELSE
        SET @skipped = @skipped + 1;

    /* --- detected_missing_utc --- */
    IF NOT EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID(N'[dbo].' + QUOTENAME(@tbl)) AND name = 'detected_missing_utc'
    )
    BEGIN
        SET @cmd =
            N'ALTER TABLE [dbo].' + QUOTENAME(@tbl)
          + N' ADD [detected_missing_utc] DATETIME2 NULL;';

        PRINT '  + ' + @cmd;
        IF @DryRun = 0
            EXEC sp_executesql @cmd;

        SET @added = @added + 1;
    END
    ELSE
        SET @skipped = @skipped + 1;

    FETCH NEXT FROM c INTO @tbl;
END

CLOSE c;
DEALLOCATE c;
DROP TABLE #targets;

PRINT '-----------------------------------------------------------------------';
PRINT 'Columns to add / added: ' + CAST(@added   AS NVARCHAR);
PRINT 'Columns already present (skipped): ' + CAST(@skipped AS NVARCHAR);
IF @DryRun = 1
    PRINT 'DryRun = 1: no changes were made. Set @DryRun = 0 to apply.';
ELSE
    PRINT 'Done.';
GO
