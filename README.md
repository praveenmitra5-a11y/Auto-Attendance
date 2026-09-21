# Attendance Android APK

This repository packages `index.html` as an Android APK using Capacitor and GitHub Actions.

## Build the APK

1. Create a new GitHub repository.
2. Upload all files/folders from this project, including `.github/workflows/build-apk.yml`.
3. Open **Actions** → **Build Attendance APK**.
4. Choose **Run workflow**.
5. After the workflow completes, download `attendance-debug-apk` from the workflow artifacts.

The workflow sets up Node 20 and Java 17, creates the Capacitor Android project, adds the required location/foreground-service permissions, and builds `app-debug.apk`.

## Important Android permission note

Background location requires explicit Android permission from the user. The APK cannot silently grant background location permission. For continuous background operation, Android may require the user to enable the appropriate background/all-the-time location permission in system settings.


## Auto check-in when the app is closed + PDF export (native-setup.sh)

`native-setup.sh` adds two things the plain web page cannot do inside an APK:

- **Native geofence** – Android itself watches the office circle, so arrival is recorded even when the app is closed
  (no always-on notification). The calendar shows the check-in the next time you open the app.
- **PDF export** – the 🖨️ buttons build a real PDF and open the share sheet (Save to Files / Drive / Print / WhatsApp).

Add this step to `.github/workflows/build-apk.yml` **after** `npx cap add android` and **before** the Gradle build step:

```yaml
      - name: Add native geofence + PDF support
        run: bash native-setup.sh
```

Upload `native-setup.sh` to the repository root (next to `index.html`), then run the workflow again.

### Phone settings (needed once)
1. Settings → Apps → Attendance → Permissions → Location → **Allow all the time** + **Use precise location**.
2. Settings → Apps → Attendance → Battery → **Unrestricted / No restrictions**.
3. Xiaomi / Redmi / Realme / Oppo / Vivo: also enable **Autostart** for the app and lock it in Recent apps.
4. Keep phone Location switched on. Arrival is normally detected within 1–3 minutes.
