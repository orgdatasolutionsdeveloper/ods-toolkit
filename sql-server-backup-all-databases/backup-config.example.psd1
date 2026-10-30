# =============================================================================
#  backup-config.example.psd1 - every setting of SQL Server Backup All
#  Databases, by John Stover, Org Data Solutions.
#
#  You do not have to create backup-config.psd1 by hand: run the script
#  once and it asks for the settings and writes the file. To fill it in
#  yourself, copy this file to backup-config.psd1 next to the script and edit it.
#
#  Read by Backup-AllSqlServerDatabases.ps1 (next to it) via
#  Import-PowerShellDataFile. PSD1 is PowerShell-native data: hashtables,
#  arrays, strings, numbers and booleans only. No code runs from this file.
#
#  SECRETS WARNING
#  ---------------
#  Any credentials below are PLAINTEXT. The file's ACL is the only thing
#  protecting them. Keep backup-config.psd1 in a folder only the operator
#  account can read, keep it out of source control and out of synced folders
#  (OneDrive, Dropbox), or leave DefaultCredential out and use Windows
#  (integrated) authentication instead.
# =============================================================================
@{

    # REQUIRED. Backup root + log location. Also the Destination for any
    # target that doesn't set its own. A local folder (e.g. 'X:\SqlBackups')
    # or a UNC share (e.g. '\\fileserver\SqlBackups'). There is no default.
    BackupRoot = '<set-your-backup-folder>'

    # Delete .bak files older than this many days from every destination after
    # the run. 0 keeps everything. Retention removes EVERY .bak under each
    # destination, not only ones this script made, so use dedicated folders.
    RetentionDays = 0

    # Force backup compression off even on editions that support it. Defaults
    # to $false (compression auto-enabled where supported).
    NoCompression = $false

    # Default SQL credentials, used for every target that doesn't override.
    # Leave this whole block out (or commented) to use Windows authentication.
    # The login needs BACKUP DATABASE permission: db_backupoperator or db_owner
    # in each database, or the sysadmin server role.
    # DefaultCredential = @{
    #     User     = 'backup_login'
    #     Password = '<set-me>'
    # }

    # ------------------------------------------------------------------
    #  Target list. One hashtable per SQL Server instance.
    #
    #  Fields:
    #    Name              friendly label for logging
    #    Instance          server[\instance]   (ignored if ConnectionString is set)
    #    Destination       where THAT server writes the .bak (UNC for remote-
    #                      to-local; defaults to BackupRoot above)
    #    Credential        optional @{ User = ...; Password = ... } per-target
    #                      override of DefaultCredential
    #    ConnectionString  optional full connection string -- overrides
    #                      Instance + credentials
    # ------------------------------------------------------------------
    Targets = @(

        # The default instance on this machine, Windows authentication,
        # backups into BackupRoot.
        @{
            Name     = 'local'
            Instance = 'localhost'
        }

        # ------- Named instance into its own subfolder -------
        # @{
        #     Name        = 'reporting'
        #     Instance    = 'localhost\REPORTING'
        #     Destination = 'X:\SqlBackups\reporting'
        # }

        # ------- Remote SQL Server writing into a share on this machine -------
        # Share the backup folder as \\THISBOX\SqlBackups, grant write to the
        # remote SQL Server service account, then:
        # @{
        #     Name        = 'sql02'
        #     Instance    = 'SQL02'
        #     Destination = '\\THISBOX\SqlBackups\sql02'
        # }

        # ------- Per-target credential override -------
        # @{
        #     Name        = 'sql03'
        #     Instance    = 'SQL03'
        #     Destination = '\\THISBOX\SqlBackups\sql03'
        #     Credential  = @{ User = 'backup_login'; Password = '<set-me>' }
        # }

        # ------- Full connection string (overrides Instance + credentials) -------
        # @{
        #     Name             = 'sql04'
        #     ConnectionString = 'Server=SQL04;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;'
        #     Destination      = '\\THISBOX\SqlBackups\sql04'
        # }
    )
}
