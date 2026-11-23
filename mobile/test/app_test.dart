import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receiptlens/api.dart';
import 'package:receiptlens/main.dart';
import 'package:receiptlens/screens/receipts_screen.dart';
import 'package:receiptlens/settings.dart';

// 1x1 transparent PNG, so Image.memory can decode it in the detail screen.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const receipt = {
  'id': 'r1',
  'status': 'parsed',
  'merchant': 'CÀ PHÊ SÁNG',
  'total_vnd': 125000,
  'purchased_at': '2026-11-20T02:30:00Z', // 09:30 in Vietnam
  'created_at': '2026-11-22T10:00:00Z',
  'confidence': 0.98,
  'updated_at': '2026-11-22T10:00:05Z',
};

/// A fake server that records what the app sent.
class FakeServer {
  final requests = <http.BaseRequest>[];
  final bodies = <String>[];

  http.Client get client => MockClient((req) async {
    requests.add(req);
    bodies.add(req.body);
    final path = req.url.path;
    Map<String, String> json = {'content-type': 'application/json; charset=utf-8'};
    if (req.method == 'GET' && path == '/api/receipts') return http.Response(jsonEncode([receipt]), 200, headers: json);
    if (req.method == 'GET' && path == '/api/stats/monthly') {
      return http.Response(
        jsonEncode([
          {'month': '2026-11', 'count': 1, 'total_vnd': 125000},
        ]),
        200,
        headers: json,
      );
    }
    if (req.method == 'GET' && path == '/api/receipts/r1') {
      return http.Response(jsonEncode({...receipt, 'raw_text': 'TỔNG CỘNG: 125.000đ'}), 200, headers: json);
    }
    if (req.method == 'GET' && path == '/api/receipts/r1/image') return http.Response.bytes(png, 200);
    if (req.method == 'PATCH' && path == '/api/receipts/r1') {
      return http.Response(
        jsonEncode({...receipt, ...jsonDecode(req.body) as Map, 'status': 'corrected'}),
        200,
        headers: json,
      );
    }
    return http.Response('{"detail":"not found"}', 404, headers: json);
  });
}

/// MockClient handles multipart uploads too, but the request arrives as a stream; capture it.
class UploadRecorder extends http.BaseClient {
  UploadRecorder(this.inner);
  final http.Client inner;
  http.MultipartRequest? upload;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.MultipartRequest) {
      upload = request;
      final body = jsonEncode({...receipt, 'id': 'r2', 'status': 'parsed'});
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        201,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return inner.send(request);
  }
}

Widget app(http.Client client, {PickImage? pick}) => ReceiptLensApp(
  initialServer: 'https://server.test/api',
  pickImage: pick ?? ({required bool camera}) async => null,
  apiFactory: (url) => ApiClient(url, client: client),
);

void main() {
  testWidgets('lists receipts with total, status and the month summary', (tester) async {
    await tester.pumpWidget(app(FakeServer().client));
    await tester.pumpAndSettle();
    expect(find.text('CÀ PHÊ SÁNG'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.textContaining('125.000'), findsWidgets);
    expect(find.text('Spent in 2026-11'), findsOneWidget);
    expect(find.text('20/11/2026'), findsOneWidget); // shown in Vietnam time
  });

  testWidgets('picks a photo and uploads it as multipart', (tester) async {
    final recorder = UploadRecorder(FakeServer().client);
    var asked = false;
    await tester.pumpWidget(
      app(
        recorder,
        pick: ({required bool camera}) async {
          asked = true;
          return (Uint8List.fromList(png), 'receipt.png');
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add receipt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from gallery'));
    await tester.pumpAndSettle();
    expect(asked, isTrue);
    expect(recorder.upload?.url.toString(), 'https://server.test/api/receipts');
    expect(recorder.upload?.files.single.field, 'file');
    expect(recorder.upload?.files.single.filename, 'receipt.png');
    expect(find.textContaining('Uploaded'), findsOneWidget);
  });

  testWidgets('opens a receipt and saves a correction', (tester) async {
    final server = FakeServer();
    await tester.pumpWidget(app(server.client));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CÀ PHÊ SÁNG'));
    await tester.pumpAndSettle();
    expect(find.text('20/11/2026 09:30'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Total (VND)'), '130000');
    await tester.ensureVisible(find.text('Save correction')); // below the fold on the 800x600 test screen
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save correction'));
    await tester.pumpAndSettle();

    final patch = server.bodies[server.requests.indexWhere((r) => r.method == 'PATCH')];
    expect(jsonDecode(patch), {
      'merchant': 'CÀ PHÊ SÁNG',
      'total_vnd': 130000,
      'purchased_at': '2026-11-20T09:30:00+07:00',
    });
    expect(find.text('Corrected'), findsOneWidget);
  });

  testWidgets('rejects an invalid total before calling the server', (tester) async {
    final server = FakeServer();
    await tester.pumpWidget(app(server.client));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CÀ PHÊ SÁNG'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Total (VND)'), '-5');
    await tester.ensureVisible(find.text('Save correction')); // below the fold on the 800x600 test screen
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save correction'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a whole number of đồng'), findsOneWidget);
    expect(server.requests.where((r) => r.method == 'PATCH'), isEmpty);
  });

  test('server address must be https', () {
    expect(validateServer('https://192.168.1.10/api'), isNull);
    expect(validateServer('http://192.168.1.10/api'), isNotNull);
    expect(validateServer('not a url'), isNotNull);
  });

  test('API errors become readable messages', () async {
    final api = ApiClient(
      'https://server.test/api',
      client: MockClient((_) async => http.Response('{"detail":"Only JPEG, PNG or WebP images are accepted"}', 415)),
    );
    expect(
      () => api.upload(Uint8List(4), 'x.txt'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('JPEG'))),
    );
    final blocked = ApiClient('https://server.test/api', client: MockClient((_) async => http.Response('<html>', 403)));
    expect(
      () => blocked.list(),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('firewall'))),
    );
  });
}
