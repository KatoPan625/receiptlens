import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';

/// Returns (bytes, filename) of a picked photo, or null if the user cancelled.
typedef PickImage = Future<(Uint8List, String)?> Function({required bool camera});

class ReceiptsScreen extends StatefulWidget {
  const ReceiptsScreen({super.key, required this.api, required this.pickImage, required this.onServerChanged});

  final ApiClient api;
  final PickImage pickImage;
  final ValueChanged<String> onServerChanged;

  @override
  State<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends State<ReceiptsScreen> {
  List<Receipt>? _receipts;
  List<MonthStat> _stats = const [];
  String? _error;
  bool _uploading = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReceiptsScreen old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api) _load(); // server address changed
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([widget.api.list(), widget.api.stats()]);
      if (!mounted) return;
      setState(() {
        _receipts = results[0] as List<Receipt>;
        _stats = results[1] as List<MonthStat>;
        _error = null;
      });
      // Keep refreshing while OCR is still working on something.
      _poll?.cancel();
      if (_receipts!.any((r) => r.isReading)) _poll = Timer(const Duration(seconds: 2), _load);
    } catch (e) {
      if (mounted) setState(() => _error = 'Cannot reach the server: $e');
    }
  }

  Future<void> _add(bool camera) async {
    final picked = await widget.pickImage(camera: camera);
    if (picked == null) return;
    setState(() => _uploading = true);
    try {
      await widget.api.upload(picked.$1, picked.$2);
      _snack('Uploaded. Reading the receipt…');
      await _load();
    } catch (e) {
      _snack('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _chooseSource() => showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () {
              Navigator.pop(ctx);
              _add(true);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () {
              Navigator.pop(ctx);
              _add(false);
            },
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ReceiptLens'),
        actions: [
          IconButton(
            tooltip: 'Server settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              final url = await Navigator.push<String>(
                context,
                MaterialPageRoute(builder: (_) => SettingsScreen(current: widget.api.base.toString())),
              );
              if (url != null) widget.onServerChanged(url);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _chooseSource,
        icon: _uploading
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add_a_photo_outlined),
        label: Text(_uploading ? 'Uploading…' : 'Add receipt'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              ),
            if (_stats.isNotEmpty)
              Card(
                margin: const EdgeInsets.all(16),
                child: ListTile(
                  title: Text('Spent in ${_stats.first.month}'),
                  subtitle: Text('${_stats.first.count} receipts'),
                  trailing: Text(money(_stats.first.totalVnd), style: Theme.of(context).textTheme.titleLarge),
                ),
              ),
            if (_receipts == null && _error == null)
              const Center(
                child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()),
              ),
            if (_receipts != null && _receipts!.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No receipts yet. Tap “Add receipt”.')),
              ),
            for (final r in _receipts ?? const <Receipt>[])
              ListTile(
                title: Text(r.merchant ?? '—'),
                subtitle: Text(day(r.purchasedAt ?? r.createdAt)),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(money(r.totalVnd)),
                    Text(
                      statusLabel[r.status] ?? r.status,
                      style: TextStyle(fontSize: 12, color: statusColor(r.status, scheme)),
                    ),
                  ],
                ),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DetailScreen(api: widget.api, id: r.id),
                    ),
                  );
                  _load();
                },
              ),
          ],
        ),
      ),
    );
  }
}
