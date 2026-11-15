/// Booking rules shared by the web dashboard and the Customer app (REQ-014…017, REQ-049).
/// The database is the authority; these mirror it for the UI.
library;

import 'formats.dart';

enum BookingStatus {
  booked('Booked'),
  arrived('Arrived'),
  noShow('No-show'),
  cancelled('Cancelled');

  const BookingStatus(this.label);
  final String label;

  String get code => this == noShow ? 'no_show' : name;
  static BookingStatus parse(String v) => values.firstWhere((s) => s.code == v);
}

/// Allowed slot lengths in minutes (REQ-014).
const slotLengths = [30, 60, 90, 120];

/// Weekday names, ISO order (1 = Monday).
const weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Opening hours of one weekday, in minutes after midnight (Pakistan time).
class DayHours {
  const DayHours(this.weekday, this.opensMin, this.closesMin);

  factory DayHours.fromRow(Map<String, dynamic> r) =>
      DayHours(r['weekday'] as int, parseHm(r['opens'] as String), parseHm(r['closes'] as String));

  final int weekday;
  final int opensMin;
  final int closesMin;

  Map<String, Object> toJson() => {'weekday': weekday, 'opens': formatHm(opensMin), 'closes': formatHm(closesMin)};
}

/// "09:00" or "09:00:00" → 540.
int parseHm(String v) {
  final p = v.split(':');
  return int.parse(p[0]) * 60 + int.parse(p[1]);
}

String formatHm(int minutes) => '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// Slot start times (minutes after midnight) of a day: e.g. 4 bays, 60 min, 09:00–18:00 → 9 slots.
List<int> slotStarts(DayHours? hours, int slotMinutes) {
  if (hours == null || !slotLengths.contains(slotMinutes)) return const [];
  return [for (var t = hours.opensMin; t + slotMinutes <= hours.closesMin; t += slotMinutes) t];
}

/// Customers may cancel or reschedule online until 1 hour before the slot (REQ-016).
bool customerCanChange(DateTime slotStart, DateTime now) => now.isBefore(slotStart.subtract(const Duration(hours: 1)));

/// Default next service: 3 months and 5,000 km after this visit (REQ-049, PROPOSED).
({DateTime date, int km}) defaultNextService(DateTime visit, int odometerKm) =>
    (date: DateTime(visit.year, visit.month + 3, visit.day), km: odometerKm + 5000);

/// "Sat 22-11-2026 10:00" in Pakistan time.
String formatSlot(DateTime utc) {
  final t = toPkt(utc);
  return '${weekdayNames[t.weekday - 1].substring(0, 3)} ${formatDate(t)} ${formatHm(t.hour * 60 + t.minute)}';
}
