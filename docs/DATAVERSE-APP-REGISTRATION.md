# Creating the app registration for the Dataverse tools

The two Dataverse tools (Dataverse Audit History Export and Dataverse to SQL
Server Sync) sign in to your environment as an application, not as a person.
That takes three things, which you create once and reuse for both tools:

1. An **app registration** in Microsoft Entra ID.
2. A **client secret** on that registration.
3. An **application user** in your Dataverse environment that is linked to
   the registration and holds a security role.

When you are done you will have four values for `config.xml`:

| Value | Where it comes from | Looks like |
|---|---|---|
| OrgUrl | Your environment's address | `https://yourorg.crm.dynamics.com` |
| TenantId | Entra ID, "Directory (tenant) ID" | a GUID |
| ClientId | Entra ID, "Application (client) ID" | a GUID |
| ClientSecret | Entra ID, the secret's **Value** | a long random string |

You need to be a Global Administrator or Application Administrator in Entra
ID for steps 1 and 2, and a System Administrator in the Dataverse environment
for step 3. If that is two different people, the first person sends the
second the Application (client) ID; the secret stays with whoever runs the
tool.

## Step 1: create the app registration

1. Open <https://entra.microsoft.com> and sign in.
2. In the left menu choose **Identity > Applications > App registrations**.
3. Click **New registration**.
4. Name it something you will recognize later, for example
   `Dataverse Export Tools`.
5. Under **Supported account types** leave the default,
   *Accounts in this organizational directory only*.
6. Leave **Redirect URI** empty.
7. Click **Register**.

The registration's **Overview** page now shows two GUIDs. Copy both into a
text file for the moment:

- **Application (client) ID** goes in `config.xml` as `ClientId`.
- **Directory (tenant) ID** goes in `config.xml` as `TenantId`.

## Step 2: create the client secret

1. On the same registration choose **Certificates & secrets** in the left
   menu.
2. Click **New client secret**.
3. Give it a description and pick an expiry. Twelve or twenty-four months is
   usual. Write the expiry date in your calendar: when the secret expires the
   tools stop signing in until you create a new one and put it in
   `config.xml`.
4. Click **Add**.
5. Copy the **Value** column right away. It is shown only once. If you leave
   the page without copying it, delete the secret and create another.

The value goes in `config.xml` as `ClientSecret`. It is a password: keep it
out of email, chat and source control.

No API permissions need to be added on the registration. Access to Dataverse
is granted by the security role in step 3.

## Step 3: add the application user to your environment

1. Open <https://admin.powerplatform.microsoft.com> and sign in.
2. Choose **Environments**, then click the environment you want the tools to
   read.
3. Click **Settings** at the top, open **Users + permissions**, then click
   **Application users**.
4. Click **New app user**.
5. Click **Add an app**, find the registration from step 1 by name, select
   it and click **Add**.
6. Choose the **Business unit**. The root business unit is the usual choice.
7. Next to **Security roles** click the pencil, tick a role, and click
   **Save**. See the next section for which role.
8. Click **Create**.

The environment's address, shown on the same environment page as
**Environment URL**, goes in `config.xml` as `OrgUrl`. Use the form
`https://yourorg.crm.dynamics.com` with no path after the host name.

## Which security role

**System Administrator** works for both tools and is the quickest way to get
a first run working. For a least-privilege setup, create a custom role
instead:

- **Dataverse Audit History Export** needs the environment-level privileges
  *View Audit History*, *View Audit Summary* and *View Audit Partitions*
  (under Core Records > Audit in the role editor), plus organization-wide
  **Read** on every table whose audit history you want to export.
- **Dataverse to SQL Server Sync** needs organization-wide **Read** on every
  table you sync. Table and column metadata is readable by any user, so
  nothing extra is needed for the data dictionary.

Neither tool writes to Dataverse, so no Create, Write, Delete or Append
privilege is needed.

## Checking that it works

Both tools print a clear message when sign-in fails. The usual causes:

| Message | Fix |
|---|---|
| `AADSTS7000215` invalid client secret | The secret was pasted wrong or has expired. Create a new one (step 2). |
| `AADSTS700016` application not found | `ClientId` or `TenantId` is wrong, or the registration is in a different tenant. |
| HTTP 401 after a successful sign-in | The application user was not created in this environment (step 3), or `OrgUrl` points at a different environment. |
| HTTP 403 | The application user's security role lacks Read on that table or the audit privileges. |

For the sync tool, `.\Sync-DataverseToSqlServer.ps1 -TestConnection` checks
the Dataverse and SQL connections and changes nothing.
