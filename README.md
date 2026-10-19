# ODS Offline Toolkit

**Free tools from Org Data Solutions** for nonprofits, associations and any
organization that runs on SQL Server or Microsoft Dataverse. Run them on your
own machine, against your own systems, and see what you have before you
trust anyone with a password.

> **Nothing leaves your machine.** No tool in this toolkit has telemetry,
> analytics or an upload step. Each one talks only to the systems you point
> it at (your SQL Server, your Dataverse environment and Microsoft's sign-in
> service) and writes its results to files on your computer. Nothing is
> sent to Org Data Solutions. Each report ends with a plain link to our
> sign-up page; it carries only the tool's name, never your data, and only
> if you click it.

---

## The tools

| Tool | What it does | Language | Changes anything? |
|---|---|---|---|
| [**Governance Scan**](ods-governance-scan/README.md) | Finds sensitive data in a SQL Server / Azure SQL database (by column name and, with `--sample`, by the values themselves), shows who can read it, and scores governance readiness 0–100. HTML report + three CSVs. | Python | No. Read-only. |
| [**Dataverse Audit Export**](ods-audit-export/README.md) | Checks whether Dataverse auditing is on for each table and column, and exports the audit history to one CSV per table, with an HTML summary. | Python | No. Read-only. |
| [**Dataverse to SQL Sync**](ods-dataverse-sql-sync/README.md) | Copies Dataverse tables into your own SQL database and keeps them current incrementally; builds a data dictionary and friendly-name views. | PowerShell | Writes to the SQL database you choose. Read-only against Dataverse. |
| [**SQL Backup**](ods-sql-backup/README.md) | Backs up every online database on one or more SQL Server instances into folders you choose, with logs and optional retention. | PowerShell | Writes `.bak` files; retention deletes old ones. |

### Requirements at a glance

| Tool | Runtime | Needs | Credentials |
|---|---|---|---|
| Governance Scan | Python 3.9+ | `pip install pyodbc` and a SQL Server ODBC driver (17 or 18) | A read-only SQL login (`db_datareader`) or Windows authentication |
| Dataverse Audit Export | Python 3.9+ | Nothing else: standard library only | An Entra ID app registration (client secret) that is an Application User with a role that can read audit data |
| Dataverse to SQL Sync | PowerShell 7.2+ | — | The same kind of app registration, plus a SQL login that can create tables and views in the target database |
| SQL Backup | Windows PowerShell 5.1 or PowerShell 7 | The `SqlServer` PowerShell module | A login with `BACKUP DATABASE` permission, or Windows authentication |

Each tool reads its settings from a config file you create from the included
example (`config.sample.xml`, `config.example.xml` or
`backup-config.example.psd1`). Those files hold passwords or client secrets:
keep them private and out of source control. The `.gitignore` here already
excludes them.

## Getting started

1. Download the toolkit and check the files against `SHA256SUMS.txt`
   (see below).
2. Open the folder of the tool you want and follow its README. Each one
   takes 2 to 15 minutes to set up.
3. Run it against one system you own. Read the report.

## Checking the download

Every file is listed in `SHA256SUMS.txt` with its SHA-256 hash. In
PowerShell, from the toolkit folder:

```powershell
.\Write-Checksums.ps1 -Verify
```

or, on macOS / Linux / Git Bash:

```bash
sha256sum -c SHA256SUMS.txt
```

Any `FAILED` line means that file differs from the release. Do not run it.

## Running the PowerShell tools

Files downloaded from the internet are marked as such by Windows, and the
default execution policy (`RemoteSigned`) refuses to run unsigned scripts
that carry that mark. The scripts in this release are **not yet signed**
(see [docs/CODE-SIGNING.md](docs/CODE-SIGNING.md)). After verifying the
checksums, clear the mark on the toolkit's files:

```powershell
Get-ChildItem -Recurse -File | Unblock-File
```

Once signed releases are available, this step goes away, and you can check a
script's signature with `Get-AuthenticodeSignature <file>`.

## Folder layout

```
ods-toolkit/
  README.md                  this file
  LICENSE                    MIT License
  SHA256SUMS.txt             SHA-256 of every file
  Write-Checksums.ps1        writes / verifies SHA256SUMS.txt
  docs/CODE-SIGNING.md       how releases will be signed
  ods-governance-scan/       Python: sensitive-data scan of a SQL database
  ods-audit-export/          Python: Dataverse audit readiness + export
  ods-dataverse-sql-sync/    PowerShell: Dataverse -> SQL replica
  ods-sql-backup/            PowerShell: back up every database on an instance
```

## Free workspace

The governance tools of the hosted **ODS Data Management Platform** are free
for approved nonprofits and .org organizations: data catalog and profiling,
sensitivity tags with role-based masking, access audit, evidence pack and
weekly digest. Each tool's report links to the sign-up page.

## License, customized versions and support

The toolkit is open source under the [MIT License](LICENSE): use it, change
it and share it, including in commercial work, as long as the copyright
notice stays with the code.

These tools grew out of work Org Data Solutions built for specific clients.
Organizations that run a customized version are welcome to keep it, and to
maintain their own fork if they prefer; the MIT License allows that without
asking.

The tools are provided as-is, without warranty. Test them on a non-production
system first. Questions and bug reports: **support@orgdatasolutions.com**
