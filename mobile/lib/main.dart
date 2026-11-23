import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'screens/receipts_screen.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ReceiptLensApp(initialServer: await loadServer(), pickImage: pickWithImagePicker));
}

/// Downscaled + recompressed on the phone so uploads stay well under the 10 MB limit.
Future<(Uint8List, String)?> pickWithImagePicker({required bool camera}) async {
  final file = await ImagePicker().pickImage(
    source: camera ? ImageSource.camera : ImageSource.gallery,
    maxWidth: 2000,
    maxHeight: 2000,
    imageQuality: 85,
  );
  if (file == null) return null;
  return (await file.readAsBytes(), file.name);
}

class ReceiptLensApp extends StatefulWidget {
  const ReceiptLensApp({
    super.key,
    required this.initialServer,
    required this.pickImage,
    this.apiFactory = ApiClient.new,
  });

  final String initialServer;
  final PickImage pickImage;
  final ApiClient Function(String baseUrl) apiFactory; // tests inject a MockClient-backed client

  @override
  State<ReceiptLensApp> createState() => _ReceiptLensAppState();
}

class _ReceiptLensAppState extends State<ReceiptLensApp> {
  late ApiClient _api = widget.apiFactory(widget.initialServer);

  ThemeData _theme(Brightness b) => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC8A96A), brightness: b),
    useMaterial3: true,
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ReceiptLens',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: ReceiptsScreen(
      api: _api,
      pickImage: widget.pickImage,
      onServerChanged: (url) async {
        await saveServer(url);
        setState(() => _api = widget.apiFactory(url));
      },
    ),
  );
}
