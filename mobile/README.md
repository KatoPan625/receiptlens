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

## Run on an iPhone (web build, no Mac needed)

The same Flutter code is built for the web and served by the edge at `/m/`. In Safari it behaves like the app: the camera opens from "Add receipt", and it can be added to the home screen.

1. Build it (from `mobile/`), then start the stack (repo root). The edge mounts `mobile/build/web`:

   ```powershell
   flutter build web --release --base-href /m/ --no-web-resources-cdn --csp --web-content-hash
   ```

   The web build uses the API on the same origin, so no server address needs to be entered.
2. Re-issue the edge certificate for the PC's LAN address if it changed: `powershell -NoProfile -File scripts\init-env.ps1 -RenewCert`, then `docker compose restart edge`.
3. Trust the local CA on the iPhone. Send **only** `rootCA.pem` (from the folder printed by `mkcert -CAROOT`) to the phone, e.g. by e-mail to yourself or via iCloud Drive, and open it.
   Then **Settings → General → VPN & Device Management** → install the profile, and **Settings → General → About → Certificate Trust Settings** → turn on full trust for the mkcert CA.
   > Never copy `rootCA-key.pem` anywhere: with that key, anyone could impersonate any website to a device that trusts this CA. Remove the profile from the iPhone when you are done testing.
4. On the same Wi-Fi, open `https://<PC LAN address>/m/` in Safari (e.g. `https://192.168.1.3/m/`) → Share → **Add to Home Screen**.
   If it does not load, Windows Firewall may be blocking inbound TCP 443 from the LAN.

The edge serves `/m/` with its own CSP: `script-src 'self' 'wasm-unsafe-eval'` (CanvasKit is WebAssembly, the build uses `--csp` so no JavaScript eval), inline styles (Flutter injects them), and fonts from `fonts.gstatic.com` (Flutter's text fallback).

## Run on an Android phone

1. Re-issue the edge certificate so it includes the PC's current LAN / Tailscale address, then restart the edge:
   `powershell -NoProfile -File scripts\init-env.ps1 -RenewCert` and `docker compose restart edge` (repo root).
2. Install `rootCA.pem` on the phone as above.
3. Build and install a debug APK: `flutter build apk --debug`, then `flutter install` (USB debugging on) or copy `build/app/outputs/flutter-apk/app-debug.apk` to the phone.
4. In the app: Settings → `https://<PC address>/api` (e.g. `https://192.168.1.3/api`). The phone must be on the same Wi-Fi or Tailscale network, and Windows Firewall must allow inbound TCP 443.

**Why debug only:** `android/app/src/main/res/xml/network_security_config.xml` lets *debug* builds trust CAs the user installed (the mkcert CA). Release builds trust only the system CAs and need a server with a publicly trusted certificate.
