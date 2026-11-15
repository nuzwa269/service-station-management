import 'package:app_shared/app_shared.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:station_core/station_core.dart';

void main() {
  test('slot rows: free never below zero (overbooked)', () {
    final s = Slot.fromRow({'slot_start': '2026-11-21T05:00:00+00:00', 'slot_end': '2026-11-21T06:00:00+00:00', 'capacity': 4, 'booked': 5});
    expect(s.free, 0);
    expect(formatSlot(s.start), 'Sat 21-11-2026 10:00');
  });

  test('staff booking row with joins', () {
    final b = Booking.fromRow({
      'id': 'b1',
      'slot_start': '2026-11-21T05:00:00+00:00',
      'status': 'no_show',
      'customer_id': 'c1',
      'vehicle_id': 'v1',
      'source': 'app',
      'overbooked': true,
      'customer': {'name': 'Ali Raza', 'mobile': '03001234567'},
      'vehicle': {'plate': 'LEA-1234'},
      'service': {'name': 'Oil change'},
    });
    expect(b.status, BookingStatus.noShow);
    expect(b.plate, 'LEA-1234');
    expect(b.service, 'Oil change');
    expect(b.overbooked, isTrue);
  });

  test('TEST-047: linked station row', () {
    final s = LinkedStation.fromRow({
      'station_id': 's1',
      'name': 'Alpha Service',
      'city': 'Lahore',
      'phone': null,
      'station_code': 'K7P2QX',
      'customer_id': 'c1',
      'customer_name': 'Ali Raza',
      'blocked': true,
      'read_only': false,
    });
    expect(s.blocked, isTrue);
    expect(s.code, 'K7P2QX');
  });

  test('settings: not set up until hours exist', () {
    expect(BookingSettings.empty.isSetUp, isFalse);
    expect(
      const BookingSettings(bays: 4, slotMinutes: 60, noShowLimit: 3, daysAhead: 30, hours: [DayHours(2, 540, 1080)], offDays: []).isSetUp,
      isTrue,
    );
  });
}
