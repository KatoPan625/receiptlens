import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => message;
}

/// Talks to the ReceiptLens API through the edge (TLS + WAF). The http.Client is injected so
/// tests can use http's MockClient.
class ApiClient {
  ApiClient(String baseUrl, {http.Client? client})
    : base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
      _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;
  static const _timeout = Duration(seconds: 20);

  Uri _u(String path, [Map<String, String>? query]) => base.resolve(path).replace(queryParameters: query);

  Future<http.Response> _check(Future<http.Response> call) async {
    final r = await call.timeout(_timeout);
    if (r.statusCode >= 200 && r.statusCode < 300) return r;
    var message = switch (r.statusCode) {
      403 => 'Blocked by the server firewall',
      413 => 'Image is larger than 10 MB',
      415 => 'Only JPEG, PNG or WebP images are accepted',
      429 => 'Too many uploads, wait a moment',
      _ => 'Server error (${r.statusCode})',
    };
    try {
      final detail = (jsonDecode(r.body) as Map<String, dynamic>)['detail'];
      if (detail is String) message = detail;
    } catch (_) {
      /* not JSON: keep the generic message */
    }
    throw ApiException(r.statusCode, message);
  }

  Map<String, dynamic> _obj(http.Response r) => jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  List<dynamic> _list(http.Response r) => jsonDecode(utf8.decode(r.bodyBytes)) as List<dynamic>;

  Future<List<Receipt>> list() async =>
      _list(await _check(_client.get(_u('receipts', {'limit': '100'}))))
          .map((e) => Receipt.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<Receipt> get(String id) async => Receipt.fromJson(_obj(await _check(_client.get(_u('receipts/$id')))));

  Future<List<MonthStat>> stats() async =>
      _list(await _check(_client.get(_u('stats/monthly'))))
          .map((e) => MonthStat.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<Uint8List> image(String id) async => (await _check(_client.get(_u('receipts/$id/image')))).bodyBytes;

  Future<Receipt> upload(Uint8List bytes, String filename) async {
    final req = http.MultipartRequest('POST', _u('receipts'))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await _client.send(req).timeout(_timeout);
    return Receipt.fromJson(_obj(await _check(http.Response.fromStream(streamed))));
  }

  /// Send only the fields the user filled in; the API marks the receipt as corrected.
  Future<Receipt> correct(String id, {String? merchant, int? totalVnd, DateTime? purchasedAtVietnam}) async {
    final purchasedAt = purchasedAtVietnam == null ? null : '${_isoNoZone(purchasedAtVietnam)}+07:00';
    final body = <String, dynamic>{'merchant': ?merchant, 'total_vnd': ?totalVnd, 'purchased_at': ?purchasedAt};
    final r = await _check(
      _client.patch(_u('receipts/$id'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)),
    );
    return Receipt.fromJson(_obj(r));
  }

  static String _isoNoZone(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:00';
  }
}
