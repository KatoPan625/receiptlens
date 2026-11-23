import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import 'models.dart';

final _vnd = NumberFormat.currency(locale: 'vi_VN', symbol: '₫', decimalDigits: 0);
final _day = DateFormat('dd/MM/yyyy');
final _dayTime = DateFormat('dd/MM/yyyy HH:mm');

String money(int? v) => v == null ? '—' : _vnd.format(v);
String day(DateTime t) => _day.format(toVietnamTime(t));
String dayTime(DateTime t) => _dayTime.format(toVietnamTime(t));

/// For a DateTime that already holds Vietnam wall-clock time (e.g. from the date picker).
String vnDayTime(DateTime vn) => _dayTime.format(vn);

const statusLabel = {'uploaded': 'Reading…', 'parsed': 'Read', 'corrected': 'Corrected', 'failed': 'Failed'};

Color statusColor(String s, ColorScheme c) => switch (s) {
  'parsed' || 'corrected' => Colors.green.shade400,
  'failed' => c.error,
  _ => c.outline,
};
