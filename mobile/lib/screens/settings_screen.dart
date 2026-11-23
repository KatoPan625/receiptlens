import 'package:material_ui/material_ui.dart';

import '../settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.current});

  final String current;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  late final _url = TextEditingController(text: widget.current.replaceAll(RegExp(r'/$'), ''));

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Server')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: _url,
            decoration: const InputDecoration(labelText: 'API address', helperText: 'Emulator: https://10.0.2.2/api'),
            keyboardType: TextInputType.url,
            autocorrect: false,
            validator: validateServer,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              if (_form.currentState!.validate()) Navigator.pop(context, _url.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
