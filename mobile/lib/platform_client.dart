import 'dart:io' show Platform;

import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;

/// One shared client for the app. On Android it is Cronet, which uses the platform's TLS
/// trust (res/xml/network_security_config.xml): dart:io's own client ignores CAs the user
/// installed, so a debug build could not reach a dev server signed by the local mkcert CA.
final http.Client platformClient = Platform.isAndroid ? CronetClient.defaultCronetEngine() : http.Client();
