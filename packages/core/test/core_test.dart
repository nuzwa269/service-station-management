import 'package:station_core/station_core.dart';
import 'package:test/test.dart';

void main() {
  group('Money (TASK-012, REQ-036)', () {
    test('formats PKR with grouping and whole rupees', () {
      expect(formatPkr(Money.rupees(28000)), 'Rs 28,000');
      expect(formatPkr(Money.rupees(1234567)), 'Rs 1,234,567');
      expect(formatPkr(Money.rupees(900)), 'Rs 900');
      expect(formatPkr(const Money.paisa(-50000)), '-Rs 500');
      expect(formatPkr(const Money.paisa(123450), showPaisa: true), 'Rs 1,234.50');
    });

    test('rounds half up to whole rupees', () {
      expect(const Money.paisa(1049).wholeRupees, 10);
      expect(const Money.paisa(1050).wholeRupees, 11);
      expect(const Money.paisa(-1050).wholeRupees, -11);
    });

    test('percent keeps 2-decimal tax rates exact', () {
      expect(Money.rupees(1000).percent(1700), Money.rupees(170)); // 17%
      expect(Money.rupees(999).percent(1650), const Money.paisa(16484)); // 16.5% of 999 = 164.835
    });

    test('parses user input', () {
      expect(parsePkr('1,250'), Money.rupees(1250));
      expect(parsePkr('Rs 1250.5'), const Money.paisa(125050));
      expect(parsePkr('-500'), Money.rupees(-500));
      expect(parsePkr('12.345'), isNull);
      expect(parsePkr('abc'), isNull);
    });
  });

  group('Mobile (REQ-001, REQ-046)', () {
    test('normalises Pakistani mobiles', () {
      for (final input in ['0300-1234567', '03001234567', '923001234567', '+92 300 1234567', '3001234567']) {
        expect(normalizePkMobile(input), '03001234567', reason: input);
      }
      expect(normalizePkMobile('042-1234567'), isNull);
      expect(normalizePkMobile('0300-123456'), isNull);
      expect(normalizePkMobile(null), isNull);
    });

    test('formats for display and auth', () {
      expect(formatPkMobile('03001234567'), '0300-1234567');
      expect(toE164('03001234567'), '+923001234567');
    });
  });

  group('Plates (REQ-018, REQ-046)', () {
    test('normalises common formats', () {
      expect(normalizePlate('lea 1234'), 'LEA-1234');
      expect(normalizePlate('LEA1234'), 'LEA-1234');
      expect(normalizePlate('LEB-07-1234'), 'LEB-07-1234');
      expect(normalizePlate('ict ab 123'), 'ICT-AB-123');
    });
    test('rejects nonsense', () {
      expect(normalizePlate(''), isNull);
      expect(normalizePlate('ABCDE'), isNull);
      expect(normalizePlate('1234'), isNull);
    });
  });

  group('Dates', () {
    test('Pakistani formats', () {
      final d = DateTime(2026, 11, 3, 14, 5);
      expect(formatDate(d), '03-11-2026');
      expect(formatDateLong(d), '3 Nov 2026');
      expect(formatTime(d), '2:05 PM');
      expect(formatTime(DateTime(2026, 1, 1, 0, 0)), '12:00 AM');
      expect(toPkt(DateTime.utc(2026, 11, 13, 20)), DateTime.utc(2026, 11, 14, 1));
    });
  });

  group('Errors', () {
    test('maps database codes', () {
      final e = AppError.fromDatabase('READ_ONLY', 'Subscription expired — read-only. Ask the owner to renew');
      expect(e.code, AppErrorCode.readOnly);
      expect(e.message, contains('read-only'));
      expect(AppError.fromDatabase('FORBIDDEN', 'FORBIDDEN').message, AppErrorCode.forbidden.defaultMessage);
      expect(AppError.fromDatabase('weird', null).code, AppErrorCode.unknown);
      expect(AppError.fromDatabase('VALIDATION', 'Tax % must be 0–100').message, 'Tax % must be 0–100');
    });
  });

  group('Inventory (REQ-028, REQ-029)', () {
    test('quantity rules per unit', () {
      expect(isValidQty(ItemUnit.litre, 3.5), isTrue);
      expect(isValidQty(ItemUnit.litre, 3.55), isTrue);
      expect(isValidQty(ItemUnit.litre, 3.555), isFalse);
      expect(isValidQty(ItemUnit.piece, 2), isTrue);
      expect(isValidQty(ItemUnit.piece, 1.5), isFalse);
      expect(formatQty(196.5, ItemUnit.litre), '196.50 L');
      expect(formatQty(20, ItemUnit.piece), '20 pcs');
    });

    test('weighted average cost: 10 @ 400 + 10 @ 500 = 450', () {
      expect(weightedAverageCost(onHand: 10, avgCost: 40000, qty: 10, unitCost: 50000), 45000);
      expect(weightedAverageCost(onHand: -2, avgCost: 40000, qty: 10, unitCost: 50000), 50000);
    });

    test('new error codes map', () {
      expect(AppError.fromDatabase('OWNER_ONLY', 'x').code, AppErrorCode.ownerOnly);
      expect(AppError.fromDatabase('APPEND_ONLY', 'x').code, AppErrorCode.appendOnly);
      expect(AppError.fromDatabase('NOT_FOUND', 'Item not found').message, 'Item not found');
    });
  });

  group('Access (REQ-002, REQ-006)', () {
    test('role menus follow the permissions matrix', () {
      expect(menuFor(MemberRole.owner), contains(MenuItem.auditLog));
      expect(menuFor(MemberRole.manager), isNot(contains(MenuItem.auditLog)));
      expect(menuFor(MemberRole.manager), isNot(contains(MenuItem.subscription)));
      expect(menuFor(MemberRole.cashier), isNot(contains(MenuItem.settings)));
      expect(menuFor(MemberRole.mechanic), isEmpty);
    });

    test('locked feature text names the plans', () {
      expect(lockedFeatureText(Feature.booking), 'Available on Standard and Premium');
      expect(lockedFeatureText(Feature.payroll), 'Available on Premium');
    });

    test('entitlements from the station_entitlements view', () {
      final e = Entitlements.fromRow({
        'plan_code': 'basic',
        'effective_plan': 'basic',
        'status': 'read_only',
        'features': ['core'],
        'renews_at': '2026-11-01T00:00:00Z',
      });
      expect(e.isReadOnly, isTrue);
      expect(e.has(Feature.booking), isFalse);
    });

    test('sync overdue after 24 h (REQ-023)', () {
      final s = SyncStatus(online: false, pendingCount: 3, heldCount: 0, lastSyncAt: DateTime(2026, 11, 12, 8));
      expect(s.overdue(DateTime(2026, 11, 13, 7)), isFalse);
      expect(s.overdue(DateTime(2026, 11, 13, 9)), isTrue);
    });
  });
}
