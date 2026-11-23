import 'package:http/http.dart' as http;

/// Web build: the browser's fetch, which uses the browser's trust store.
final http.Client platformClient = http.Client();
