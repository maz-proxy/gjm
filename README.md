# Stock Opname

Static web application for stock-opname reconciliation. GitHub Actions publishes it to GitHub Pages whenever a commit is pushed to `main`. Supabase provides staff authentication and shared team data.

## Language preference

Use the Indonesian and UK flag buttons on the login screen or in the workspace toolbar to switch between Indonesian and English. The selection applies to the app interface and print/PDF pages, defaults to Indonesian, and is saved in the current browser on the current device; it is not shared with other accounts or devices. User-entered and inventory data are not translated.

## Publish with GitHub Pages

1. Create a GitHub repository and add this project to it.
2. Make sure the deployment workflow and `index.html` are committed on the `main` branch.
3. In the repository, open **Settings → Pages** and set **Build and deployment → Source** to **GitHub Actions**. This one-time setting must be enabled by a repository administrator.
4. Push a commit to `main`, or run **Deploy to GitHub Pages** from the repository's **Actions** tab.
5. Once the workflow succeeds, open the Pages URL shown in the deployment job (normally `https://<account>.github.io/<repository>/`).

The workflow packages `index.html` and the login background image from `assets/` for publishing. The spreadsheet parser is loaded from jsDelivr, so users need an internet connection to use workbook import/export features.

## Build the Android APK

The Android app uses Capacitor to package the existing web workspace in a native Android shell. It keeps using the same Supabase project and requires an internet connection for login, shared data, and spreadsheet parsing. **Build Android APK** runs on each relevant push to `main` and can also be started manually from the GitHub Actions tab; download the `stock-opname-debug-apk` artifact from the completed run.

1. To build locally, install Node.js 22 or newer, Java 21, Android Studio, and the Android SDK components requested by the Gradle project.
2. In PowerShell, run `npm.cmd ci`, then `npm.cmd run android:apk`. The debug APK is created at `android\app\build\outputs\apk\debug\app-debug.apk`; install it on a test device before distributing it.
3. Deploy the updated `login-with-username` and `admin-users` Supabase Edge Functions so their CORS allowlist accepts the Android WebView origin `https://localhost`.

The debug APK is for testing. A release APK intended for distribution must be signed with a private release key; do not commit the key or its passwords.

## Supabase authentication and shared data

The browser app uses the Supabase project URL and publishable key in `index.html`. A publishable key is intended for browser use; never put a Supabase secret or `service_role` key in this repository.

1. In Supabase **Authentication → Settings**, disable public sign-ups.
2. In **Authentication → URL Configuration**, set **Site URL** to `https://m-maz.vercel.app/` and add it under **Redirect URLs**. Keep `https://projectme-maz.github.io/gjm/` there too if that address is still used.
3. In **SQL Editor → New query**, paste the contents of [`supabase-setup.sql`](./supabase-setup.sql), and click **Run**. This creates the shared-state table and a private username-to-auth-account mapping table. Re-run the full script after application updates that change shared-state protections or accepted workbook file types.
4. Install the [Supabase CLI](https://supabase.com/docs/guides/cli), then open a terminal in this project folder and deploy the Edge Functions. The browser origins `https://m-maz.vercel.app` and `https://projectme-maz.github.io` are explicitly allowed; redeploy these functions after changing their origin allowlists:

   ```powershell
   npx.cmd --yes supabase login
   npx.cmd --yes supabase link --project-ref gyrzbossqkuiawwuqkfo
   npx.cmd --yes supabase functions deploy login-with-username --project-ref gyrzbossqkuiawwuqkfo
   npx.cmd --yes supabase functions deploy provision-stock-users --project-ref gyrzbossqkuiawwuqkfo
   npx.cmd --yes supabase functions deploy admin-users --project-ref gyrzbossqkuiawwuqkfo
   ```

   On PowerShell, use `npx.cmd` rather than `npx` if script execution is blocked. The functions use Supabase's built-in server-side credentials. Never put a secret or `service_role` key in browser code or commit one to GitHub.

5. Publish the updated `index.html` to GitHub Pages before creating the staff accounts. The updated app is required to securely verify the temporary password and force each person to replace it on first login.
6. Run the following in the same PowerShell window to create the 19 staff accounts. It creates a random one-time provisioning key, saves it only as a Supabase Edge Function secret, and calls the protected function. The function generates one random temporary password for newly created accounts; it is shown in the result only once.

   ```powershell
   $bytes = New-Object byte[] 32
   $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
   $rng.GetBytes($bytes)
   $provisionKey = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
   $rng.Dispose()

   npx.cmd --yes supabase secrets set "STOCK_OPNAME_PROVISION_KEY=$provisionKey" --project-ref gyrzbossqkuiawwuqkfo

   $publishableKey = "sb_publishable_wquuvlF0t0GklKqit4LDCg_KnPG002M"
   $headers = @{
     apikey = $publishableKey
     Authorization = "Bearer $publishableKey"
     "x-provisioning-key" = $provisionKey
   }
   $result = Invoke-RestMethod `
     -Uri "https://gyrzbossqkuiawwuqkfo.supabase.co/functions/v1/provision-stock-users" `
     -Method Post -Headers $headers -ContentType "application/json" -Body "{}"
   $result | ConvertTo-Json -Depth 5
   ```

   Confirm that `failed` is empty and check the `created` and `existing` lists. Keep the temporary password private and share it directly with staff. Then disable the one-time provisioning endpoint by removing its key:

   ```powershell
   npx.cmd --yes supabase secrets unset STOCK_OPNAME_PROVISION_KEY --project-ref gyrzbossqkuiawwuqkfo
   Remove-Variable provisionKey, headers, result, publishableKey, bytes, rng
   ```

   To reset a staff password later, create and set a new provisioning key as above, then call the same endpoint with `-Body '{"action":"reset-password","username":"indra"}'` (replace `indra` with the lowercase username). It resets the password to `12345678`; the staff member must change it at their next login. For an administrator-approved bulk reset, use `action: "reset-all-passwords"` with a temporary password supplied in the request body. This resets every listed staff account and forces a password change on next login. Remove the secret again when finished.

7. Open the deployed application. Staff log in with their lowercase username (`indra`, `dinar`, `beni`, `rosadi`, `ivan`, `iyant`, `arief`, `dimas`, `bara`, `rino`, `ahmad`, `rangga`, `dyah`, `putri`, `boniex`, `andri`, `fadhil`, `yusuf`, or `yoga`) and the temporary password. On first login, each person must set a new password of at least 8 characters.
8. The first successful login creates the shared workspace record. If this browser has existing locally saved app data, that data is used to initialize the shared record. Back up important data before setup.

Authenticated staff share one workspace dataset. Changes are saved to Supabase and Supabase Realtime broadcasts updates to other open sessions; a 45-second polling check remains as a fallback if Realtime is unavailable. Saves use an atomic database version check and merge concurrent changes before retrying, preventing one staff member's save from overwriting another's work. A user's selected workspace card is stored locally per account, so navigating between cards does not switch another staff member's screen. If two people change the same value at once, the latest server value is kept. A user's login session is automatically signed out after five hours without activity in any open tab. Each uploaded workbook starts a stock-opname session owned by the uploading staff member; only that owner and the `indra` Owner can change the session, and database triggers enforce the restriction for shared data. Existing active sessions without owner metadata remain available to the Owner; finish those sessions before staff begin new ones. Re-run the full [`supabase-setup.sql`](./supabase-setup.sql) in Supabase → SQL Editor to install the ownership and storage-delete policies, the version column required for safe concurrent saves, and the shared-state table's Realtime publication. Data is no longer limited to the local browser after the shared record has been initialized.

**Jadwal** starts without a visible session card; the app keeps one empty placeholder internally so the owner can delete even the last visible card without leaving shared state unusable. Staff can add a card when they are ready to work. Session item, serial-number, and scan-progress information appears on a schedule card only after a VEF workbook has been uploaded for its active session. The session owner can remove their active session card while no XLSX/CSV workbook is uploaded for that active session. Deleting the active card preserves completed-session archives, including their workbook files, and does not change other staff cards. A card owned by the signed-in user is automatically removed after five minutes without an uploaded workbook. If the owner deletes the uploaded Master VEF data, the five-minute upload window restarts for that session. Cleanup only removes that owner's expired session card and does not change another staff member's session. If Supabase rejects a valid owner deletion, run the latest full [`supabase-setup.sql`](./supabase-setup.sql) in Supabase → SQL Editor to update the deployed ownership trigger. The `indra` Owner manages the shared **Data Resource** lists for brand names and PIC names; names can be pasted from an Excel column to add multiple entries at once, with duplicates skipped. Every account sees those lists in the searchable **Jadwal** fields. A session can start only after its brand, PIC 1, and PIC 2 are selected.

Upload an `.xlsx`, `.xls`, or `.csv` VEF file after starting the schedule. Excel workbooks can use a `Serial No` sheet or the `VEF Master`/`Scan SN` template; sheet matching ignores spaces, underscores, and letter case. The importer searches workbook sheets for a header row containing `Serial No` and `Item Code` (the only required columns); Brand, Warehouse, and Item Name are optional. A file without valid item rows is not reported or archived as a successful import, and the current stock data is preserved. After a successful import, upload is disabled for that active master to prevent accidental replacement; use **Hapus semua data** to clear it before uploading a new workbook. A successful upload opens a themed confirmation dialog with the file name and import summary. The **Master VEF** page displays the file's original creation metadata (or its file timestamp when workbook metadata is absent), upload time, per-warehouse item/quantity totals, and a numbered item table. In **Scan Layout**, Rack cards and the **Tambah Rack** control remain disabled until a VEF file is uploaded for the active session. Once enabled, Scan Layout supports serial scans and manual quantities per rack. Rack labels can contain text as well as numbers; matching scans and manual entries play an audible notification, and duplicate serials mark their rack for review. **Result SO** reconciles SCAN + MANUAL + PJ against VEF. PJ entries require an invoice number and a date/time later than the VEF file timestamp. **Rekap Selisih** lists only mismatched items.

Completing with **SO SELESAI** archives the three worksheets and resets that brand's active schedule card. **Dashboard** summarizes running sessions, including item and quantity totals per warehouse. Its **Stock Opname Recorded** card opens a completed brand's archive by month and week in a dedicated read-only page, which shows PIC 1 and PIC 2 and lets users switch between the archived worksheets. Each worksheet can be printed or saved to PDF from the browser print dialog.

Each valid workbook or CSV uploaded in **Master VEF** is stored privately in the `stock-opname-workbooks` Supabase Storage bucket (maximum 50 MB) and attached to the opname session created by that upload. When the opname is completed, its original source file is listed in **Sesi Stock Opname → Buka sesi** and can be downloaded. The archive detail and print report include Scan Layout, manual entries, Result SO, PJ invoice details, and Rekap Selisih. Deleting an archive or workspace also deletes its associated source files. Run the full `supabase-setup.sql` in Supabase → SQL Editor to create the private bucket, CSV upload support, access policies, and workspace/resource protections on an existing project.

The generated `@users.stock-opname.invalid` addresses are internal identifiers only; staff do not need personal email addresses and cannot receive password recovery email. If someone forgets a password, an administrator must reset it. The SQL keeps the username mapping private from browser users, does not grant database access to anonymous visitors, and does not allow authenticated users to delete the shared record. Every staff account can read and edit the shared stock-opname data; give the temporary password only to trusted staff.

The `indra` account is the workspace Owner. After signing in, Indra can open **Kelola Akun** to create staff usernames, reset their passwords, and disable or re-enable accounts. The account list shows each username with an uppercase display name derived from it; the sidebar shows only that display name and the **Keluar** button. Selecting **Keluar** opens a confirmation dialog before ending the session. Owner actions are checked by the `admin-users` Edge Function against the user's server-managed Supabase `app_metadata`; ordinary staff cannot call these actions by changing browser data. This role grants control inside this workspace application, not ownership of the GitHub repository or Supabase project dashboard.
