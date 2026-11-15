import 'package:app_shared/app_shared.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual WhatsApp row opens wa.me with the number and text (REQ-062)', () {
    final m = OutboxMessage.fromRow({
      'id': 7,
      'event': 'invoice_issued',
      'channel': 'whatsapp',
      'status': 'manual',
      'title': 'Invoice issued',
      'body': 'Your invoice INV-0042 from Basic Garage: Rs 9,500. Thank you!',
      'created_at': '2026-11-19T05:00:00+00:00',
      'to_mobile': '03215550000',
      'manual_reason': null,
      'ref_id': 'inv1',
      'customer': {'name': 'Bilal'},
    });
    expect(m.status.needsStaff, isTrue);
    expect(m.customerName, 'Bilal');
    expect(m.whatsAppUrl, startsWith('https://wa.me/923215550000?text=Your%20invoice%20INV-0042'));
  });

  test('no number → no link', () {
    final m = OutboxMessage.fromRow({
      'id': 8, 'event': 'vehicle_ready', 'channel': 'whatsapp', 'status': 'manual', 'title': 'Vehicle ready',
      'body': 'x', 'created_at': '2026-11-19T05:00:00+00:00', 'to_mobile': null, 'manual_reason': 'No WhatsApp number',
    });
    expect(m.whatsAppUrl, isNull);
    expect(m.manualReason, 'No WhatsApp number');
  });

  test('staff notification row', () {
    final n = StaffNotification.fromRow({
      'id': 1, 'kind': 'approval_request', 'title': 'Discount approval needed', 'body': 'Old customer · Rs 2,000',
      'ref_id': 'r1', 'created_at': '2026-11-19T05:00:00+00:00', 'read_at': null,
    });
    expect(n.read, isFalse);
    expect(n.kind, 'approval_request');
  });

  test('TASK-072: update offered for an older build, required below the minimum', () {
    final u = AppUpdate.fromRow({'build': 5, 'version': '1.2.0', 'min_build': 3, 'apk_url': 'https://x/app.apk', 'notes': null});
    expect(u.needFor(5), UpdateNeed.none);
    expect(u.needFor(4), UpdateNeed.optional);
    expect(u.needFor(2), UpdateNeed.required);
  });
}
