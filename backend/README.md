# Telemetry backend (Google Apps Script)

Uploads from the website's debug menu (click the title, then **Save telemetry**) land as JSON files in your Google Drive, folder **Battery Optimizer telemetry**. Free, no server to run.

1. Go to https://script.google.com and click **New project**.
2. Replace the code with the contents of `telemetry.gs` and save.
3. **Deploy > New deployment**, type **Web app**. Execute as: **Me**. Who has access: **Anyone**. Click **Deploy** and allow access to Drive.
4. Copy the web app URL (ends in `/exec`) and put it in `web/index.html` as `TELEMETRY_URL`.

The URL only lets people add files to that one folder; it cannot read or delete anything.
