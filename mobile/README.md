# ReceiptLens mobile (Flutter)

Android client for the ReceiptLens API: take or pick a photo of a receipt, upload it, watch it get read, and correct the result.

| Screen | What it does |
|---|---|
| Receipts | List with status (Reading… / Read / Corrected / Failed), this month's total, pull to refresh, auto-refresh while OCR runs. "Add receipt" opens the camera or gallery |
| Receipt | Photo (pinch to zoom), merchant / total / date form to correct the OCR, raw OCR text |
| Server | API address, HTTPS only |

Photos are downscaled to 2000 px and re-compressed on the phone before upload, so they stay under the server's 10 MB limit.

## Run the tests (no device needed)

```powershell
flutter analyze; flutter test
```

The tests drive the real screens against a fake API (`package:http/testing.dart`) and a fake photo picker.

## Run on the Android emulator

1. Start the backend on the PC (`docker compose up -d` in the repo root).
2. In the emulator, install the local CA so it trusts the dev server: copy the file `rootCA.pem` from the folder printed by `mkcert -CAROOT` to the emulator (drag and drop onto it), then **Settings → Security → Encryption & credentials → Install a certificate → CA certificate**.
3. `flutter run` — the default server address `https://10.0.2.2/api` is the PC as seen from the emulator.

## Run on a phone

1. Re-issue the edge certificate so it includes the PC's current LAN / Tailscale address, then restart the edge:
   `powershell -NoProfile -File scripts\init-env.ps1 -RenewCert` and `docker compose restart edge` (repo root).
2. Install `rootCA.pem` on the phone as above.
3. Build and install a debug APK: `flutter build apk --debug`, then `flutter install` (USB debugging on) or copy `build/app/outputs/flutter-apk/app-debug.apk` to the phone.
4. In the app: Settings → `https://<PC address>/api` (e.g. `https://192.168.1.3/api`). The phone must be on the same Wi-Fi or Tailscale network, and Windows Firewall must allow inbound TCP 443.

**Why debug only:** `android/app/src/main/res/xml/network_security_config.xml` lets *debug* builds trust CAs the user installed (the mkcert CA). Release builds trust only the system CAs and need a server with a publicly trusted certificate.
