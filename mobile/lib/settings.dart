import 'package:shared_preferences/shared_preferences.dart';

/// Where the API lives. 10.0.2.2 is the host machine as seen from the Android emulator;
/// on a real phone use the PC's LAN or Tailscale address.
const defaultServer = 'https://10.0.2.2/api';
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
