/* =============================================================================
   0003_datadictionary_relationships.sql
   ODS Dataverse to SQL Sync - indexed relationships table for the dictionary
   -----------------------------------------------------------------------------
   Adds:
     - dbo.ods_datadictionary_relationships          (table + two indexes)
     - dbo.ods_datadictionary_columns.is_lookup      (BIT)
     - dbo.ods_datadictionary_columns.lookup_targets (NVARCHAR(MAX), JSON array)

   Why
   ---
   The data dictionary records every Dataverse lookup column, and a
   -Mode Refresh run fills this table with what each lookup points to
   (contact._parentcustomerid_value -> account, and so on), so you can
   generate JOINs or answer "what references this table?" in SQL.

   The sync creates the table and columns by itself if they are missing,
   but without indexes. Run this script BEFORE the first -Mode Refresh to get
   the indexed version. If the table already exists, the script leaves it
   alone.

   Idempotent. Safe to re-run. Does not depend on 0001_ops_schema.sql.
   ========================================================================= */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------- ods_datadictionary_relationships ----------------------------- */
IF OBJECT_ID('dbo.ods_datadictionary_relationships', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ods_datadictionary_relationships (
        relationship_id   NVARCHAR(450) NOT NULL,   /* "<from_entity>|<from_attribute>|<to_entity>" */
        from_entity       NVARCHAR(450) NOT NULL,   /* logical name of the source table (e.g. contact) */
        from_attribute    NVARCHAR(450) NOT NULL,   /* lookup attribute name (e.g. parentcustomerid) */
        from_sql_column   NVARCHAR(450) NOT NULL,   /* SQL column on the replica (e.g. _parentcustomerid_value) */
        to_entity         NVARCHAR(450) NOT NULL,   /* logical name of the target table (e.g. account) */
        modifiedon        DATETIME2     NOT NULL CONSTRAINT DF_ods_relationships_modifiedon DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ods_datadictionary_relationships PRIMARY KEY CLUSTERED (relationship_id)
    );

    CREATE INDEX IX_ods_relationships_from
        ON dbo.ods_datadictionary_relationships (from_entity, from_sql_column);

    CREATE INDEX IX_ods_relationships_to
        ON dbo.ods_datadictionary_relationships (to_entity);
END
GO

/* ---------- new columns on ods_datadictionary_columns -------------------- */
/* Only when the dictionary table exists (it is created by the first Refresh). */
IF OBJECT_ID('dbo.ods_datadictionary_columns', 'U') IS NOT NULL
   AND NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ods_datadictionary_columns') AND name = 'is_lookup'
)
BEGIN
    ALTER TABLE dbo.ods_datadictionary_columns ADD [is_lookup] BIT NULL;
END
GO

IF OBJECT_ID('dbo.ods_datadictionary_columns', 'U') IS NOT NULL
   AND NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ods_datadictionary_columns') AND name = 'lookup_targets'
)
BEGIN
    ALTER TABLE dbo.ods_datadictionary_columns ADD [lookup_targets] NVARCHAR(MAX) NULL;
END
GO

PRINT '0003_datadictionary_relationships.sql - done.';
GO
