import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

/// Where the API lives.
/// - Web build: served by the edge itself (`https://HOST/m/`), so the API is on the same origin.
/// - Android: 10.0.2.2 is the host machine as seen from the emulator; on a phone use the PC's LAN/Tailscale address.
String get defaultServer => kIsWeb ? '${Uri.base.origin}/api' : 'https://10.0.2.2/api';
const _key = 'server_url';

Future<String> loadServer() async => (await SharedPreferences.getInstance()).getString(_key) ?? defaultServer;

Future<void> saveServer(String url) async => (await SharedPreferences.getInstance()).setString(_key, url);

/// HTTPS only: receipts contain personal data and the edge only listens on 443.
String? validateServer(String? value) {
  final uri = Uri.tryParse((value ?? '').trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    return 'Enter an https:// address, e.g. https://192.168.1.10/api';
  }
  return null;
}
