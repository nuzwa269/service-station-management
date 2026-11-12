/// Pakistani formats: mobile 03XX-XXXXXXX, number plates, dd-MM-yyyy dates.
library;

final _mobileDigits = RegExp(r'^03\d{9}$');

/// Normalises 0300-1234567 / 923001234567 / +92 300 1234567 / 3001234567
/// to "03001234567". Returns null when it is not a Pakistani mobile.
String? normalizePkMobile(String? raw) {
  if (raw == null) return null;
  var d = raw.replaceAll(RegExp(r'\D'), '');
  if (RegExp(r'^923\d{9}$').hasMatch(d)) d = '0${d.substring(2)}';
  if (RegExp(r'^3\d{9}$').hasMatch(d)) d = '0$d';
  return _mobileDigits.hasMatch(d) ? d : null;
}

/// "0300-1234567" for display.
String formatPkMobile(String normalized) =>
    '${normalized.substring(0, 4)}-${normalized.substring(4)}';

/// "+923001234567" — the form Supabase Auth expects for phone sign-in.
String toE164(String normalized) => '+92${normalized.substring(1)}';

/// Number plates are stored upper-case with single dashes: "LEA-1234", "LEB-07-1234",
/// "ICT-AB-123". Returns null when the text cannot be a plate.
String? normalizePlate(String? raw) {
  if (raw == null) return null;
  final parts = raw
      .toUpperCase()
      .split(RegExp(r'[^A-Z0-9]+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  // Split glued letter/digit runs: "LEA1234" -> LEA, 1234.
  final tokens = <String>[];
  for (final p in parts) {
    tokens.addAll(RegExp(r'[A-Z]+|\d+').allMatches(p).map((m) => m[0]!));
  }
  final plate = tokens.join('-');
  final ok = RegExp(r'^[A-Z]{1,4}(-[A-Z0-9]{1,4}){1,3}$').hasMatch(plate) &&
      RegExp(r'\d').hasMatch(plate) &&
      plate.replaceAll('-', '').length <= 10;
  return ok ? plate : null;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _two(int n) => n.toString().padLeft(2, '0');

/// "13-11-2026" (Pakistani day-first order).
String formatDate(DateTime d) => '${_two(d.day)}-${_two(d.month)}-${d.year}';

/// "13 Nov 2026" for headings and messages.
String formatDateLong(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// "2:05 PM".
String formatTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${_two(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// Station times are always Pakistan Standard Time (UTC+5, no daylight saving).
DateTime toPkt(DateTime utc) => utc.toUtc().add(const Duration(hours: 5));
