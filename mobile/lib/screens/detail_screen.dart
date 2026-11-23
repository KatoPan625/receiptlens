import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../api.dart';
import '../format.dart';
import '../models.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.api, required this.id});

  final ApiClient api;
  final String id;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final _form = GlobalKey<FormState>();
  final _merchant = TextEditingController();
  final _total = TextEditingController();
  Receipt? _receipt;
  Uint8List? _image;
  DateTime? _date; // Vietnam time
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _merchant.dispose();
    _total.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.get(widget.id);
      if (!mounted) return;
      setState(() {
        _receipt = r;
        _merchant.text = r.merchant ?? '';
        _total.text = r.totalVnd?.toString() ?? '';
        _date = r.purchasedAt == null ? null : toVietnamTime(r.purchasedAt!);
      });
      final img = await widget.api.image(widget.id);
      if (mounted) setState(() => _image = img);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _pickDate() async {
    final now = toVietnamTime(DateTime.now());
    final d = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_date ?? now));
    setState(() => _date = DateTime(d.year, d.month, d.day, t?.hour ?? 0, t?.minute ?? 0));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final r = await widget.api.correct(
        widget.id,
        merchant: _merchant.text.trim().isEmpty ? null : _merchant.text.trim(),
        totalVnd: _total.text.trim().isEmpty ? null : int.parse(_total.text.trim()),
        purchasedAtVietnam: _date,
      );
      if (!mounted) return;
      setState(() => _receipt = r);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Not saved: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _receipt;
    return Scaffold(
      appBar: AppBar(title: Text(r == null ? 'Receipt' : statusLabel[r.status] ?? r.status)),
      body: _error != null
          ? Center(
              child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
            )
          : r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Fixed height keeps the correction form on screen; pinch to zoom into the photo.
                SizedBox(
                  height: 360,
                  child: _image == null
                      ? const Center(child: CircularProgressIndicator())
                      : InteractiveViewer(
                          child: Image.memory(_image!, fit: BoxFit.contain, semanticLabel: 'Receipt photo'),
                        ),
                ),
                const SizedBox(height: 16),
                Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _merchant,
                        decoration: const InputDecoration(labelText: 'Merchant'),
                        maxLength: 200,
                      ),
                      TextFormField(
                        controller: _total,
                        decoration: const InputDecoration(labelText: 'Total (VND)'),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null;
                          final n = int.tryParse(v.trim());
                          return n == null || n < 0 || n > 1000000000000 ? 'Enter a whole number of đồng' : null;
                        },
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.event_outlined),
                        label: Text(_date == null ? 'Set date' : vnDayTime(_date!)),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: Text(_saving ? 'Saving…' : 'Save correction'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ExpansionTile(title: const Text('OCR text'), children: [SelectableText(r.rawText ?? '(no text yet)')]),
              ],
            ),
    );
  }
}
