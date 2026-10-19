# Code signing for the PowerShell tools

**Status: not signed yet.** A code-signing certificate still has to be
bought. Until then, users must run `Unblock-File` after checking the
SHA-256 checksums (see the top-level README), and the release notes should
say so plainly.

## Why it matters

Windows marks files downloaded from the internet. Under the default
execution policy (`RemoteSigned`), PowerShell refuses to run a marked script
unless it carries a valid Authenticode signature. Unsigned scripts also draw
warnings from SmartScreen and endpoint security tools, which is a poor first
impression for a governance product. Signing proves the script came from
Org Data Solutions and was not changed after release.

Files to sign (Authenticode applies to PowerShell files only):

| File | Signed? |
|---|---|
| `ods-dataverse-sql-sync/Sync-DataverseToSql.ps1` | Yes |
| `ods-dataverse-sql-sync/Modules/Ods.SqlUpsert.psm1` | Yes (the script imports it, so `AllSigned` needs it signed too) |
| `ods-sql-backup/Backup-AllSqlDatabases.ps1` | Yes |
| `ods-sql-backup/backup-config.example.psd1` | Optional (data file, not executed) |
| `Write-Checksums.ps1` | Yes |
| Python, SQL, XML, Markdown | No Authenticode. Covered by `SHA256SUMS.txt`. |

## Buying the certificate

Still to decide. Options, all issued to the organization "Org Data
Solutions" (the name users will see in the signature):

1. **Organization Validation (OV) code-signing certificate** from a public
   CA (DigiCert, Sectigo, GlobalSign, SSL.com and others). Since June 2023
   the private key must live on a hardware token or a cloud HSM, so the
   certificate arrives on a USB token or as a cloud-signing account, not as
   a `.pfx` file. Validation checks the business registration and takes days
   to a couple of weeks.
2. **Extended Validation (EV)** certificate: stricter validation, higher
   price. Mostly matters for signed `.exe` / `.msi` installers and kernel
   drivers; not needed for PowerShell scripts.
3. **Microsoft's cloud signing service** in Azure (called Trusted Signing
   when this was written): a monthly subscription, keys held by Microsoft,
   signing from the command line or a build pipeline. Its name, eligibility
   rules and pricing have changed over time; check the current terms before
   choosing it.

Recommendation: an OV certificate (option 1) or the Azure service
(option 3), whichever is cheaper over three years once eligibility is
confirmed. Record where the token or account lives and who can use it; never
commit a key, `.pfx` or password to this repository.

## Signing a release

On the release machine, with the certificate available:

```powershell
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
        Where-Object Subject -like '*Org Data Solutions*' |
        Select-Object -First 1

$files = @(
  'ods-dataverse-sql-sync\Sync-DataverseToSql.ps1',
  'ods-dataverse-sql-sync\Modules\Ods.SqlUpsert.psm1',
  'ods-sql-backup\Backup-AllSqlDatabases.ps1',
  'Write-Checksums.ps1'
)
foreach ($f in $files) {
  Set-AuthenticodeSignature -FilePath $f -Certificate $cert `
      -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
}
Get-ChildItem -Recurse -Include *.ps1, *.psm1 | Get-AuthenticodeSignature |
  Format-Table Status, Path -AutoSize          # every row must say Valid
```

Use the timestamp server your CA documents (the DigiCert one is shown as an
example). A timestamp keeps the signature valid after the certificate
expires. Cloud-signing services ship their own command-line tool instead of
`Set-AuthenticodeSignature`; the steps around it are the same.

## Release order

Signing changes a file's bytes, so the order matters:

1. Final edits, then the checks: `python -I -m py_compile` on both Python
   tools, and a clean `[System.Management.Automation.Language.Parser]::ParseFile`
   on every `.ps1` / `.psm1`.
2. Sign the PowerShell files (above) and verify every signature is `Valid`.
3. `.\Write-Checksums.ps1` to regenerate `SHA256SUMS.txt`.
4. `.\Write-Checksums.ps1 -Verify` on a fresh copy (for example a clean
   checkout or the extracted release zip).
5. Tag the release and publish the zip with `SHA256SUMS.txt` next to it.

Any edit to a signed file invalidates its signature: re-sign, then
regenerate the checksums.

## Notes

- Signature blocks are appended as comment lines at the end of each file.
  Keep the files' line endings unchanged after signing (the repository's
  `.gitattributes` turns off line-ending conversion for this reason).
- Users who want the strictest setting can run with
  `Set-ExecutionPolicy AllSigned -Scope CurrentUser` once releases are signed.
