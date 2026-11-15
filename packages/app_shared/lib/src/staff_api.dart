import 'package:station_core/station_core.dart';

import 'api.dart';

/// REQ-050 staff record; [salary] and [commissionPct] are null for managers (owner-only data).
class StaffMember {
  const StaffMember({
    required this.id,
    required this.name,
    required this.role,
    required this.joinedOn,
    required this.active,
    this.userId,
    this.mobile,
    this.salary,
    this.commissionPct,
  });

  final String id;
  final String name;
  final String role;
  final DateTime joinedOn;
  final bool active;
  final String? userId;
  final String? mobile;
  final Money? salary;
  final double? commissionPct;

  StaffMember withPay(Money salary, double pct) => StaffMember(
        id: id, name: name, role: role, joinedOn: joinedOn, active: active, userId: userId, mobile: mobile,
        salary: salary, commissionPct: pct);
}

/// REQ-051 daily attendance status.
enum Attendance {
  present('present', 'Present', 'P'),
  absent('absent', 'Absent', 'A'),
  halfDay('half_day', 'Half day', '½'),
  leave('leave', 'Leave (paid)', 'L'),
  off('off', 'Off day', 'O');

  const Attendance(this.code, this.label, this.short);
  final String code;
  final String label;
  final String short;

  static Attendance parse(String c) => values.firstWhere((a) => a.code == c, orElse: () => Attendance.present);
}

/// One line of the monthly payroll sheet (REQ-053).
class PayrollLine {
  const PayrollLine({
    required this.id,
    required this.staffId,
    required this.name,
    required this.daysInMonth,
    required this.paidDays,
    required this.monthly,
    required this.salary,
    required this.labour,
    required this.commissionPct,
    required this.commission,
    required this.advances,
    required this.adjustment,
    required this.net,
    this.adjustmentNote,
  });

  factory PayrollLine.fromRow(Map<String, dynamic> r) => PayrollLine(
        id: r['id'] as String,
        staffId: r['staff_id'] as String,
        name: (r['staff'] as Map<String, dynamic>?)?['name'] as String? ?? '',
        daysInMonth: r['days_in_month'] as int,
        paidDays: (r['paid_days'] as num).toDouble(),
        monthly: Money.paisa(r['monthly_paisa'] as int),
        salary: Money.paisa(r['salary_paisa'] as int),
        labour: Money.paisa(r['labour_paisa'] as int),
        commissionPct: (r['commission_pct'] as num).toDouble(),
        commission: Money.paisa(r['commission_paisa'] as int),
        advances: Money.paisa(r['advances_paisa'] as int),
        adjustment: Money.paisa(r['adjustment_paisa'] as int),
        adjustmentNote: r['adjustment_note'] as String?,
        net: Money.paisa(r['net_paisa'] as int),
      );

  final String id;
  final String staffId;
  final String name;
  final int daysInMonth;
  final double paidDays;
  final Money monthly;
  final Money salary;
  final Money labour;
  final double commissionPct;
  final Money commission;
  final Money advances;
  final Money adjustment;
  final String? adjustmentNote;
  final Money net;
}

class PayrollRun {
  const PayrollRun({required this.id, required this.month, required this.isFinal, required this.lines});
  final String id;
  final DateTime month;
  final bool isFinal;
  final List<PayrollLine> lines;

  Money get total => lines.fold(Money.zero, (a, l) => a + l.net);
}

String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

extension StaffApi on StationApi {
  Future<List<StaffMember>> staff(String stationId, {bool withPay = false}) => guard(() async {
        final rows = await client
            .from('staff')
            .select('id, user_id, name, mobile, role, joined_on, active')
            .eq('station_id', stationId)
            .order('active', ascending: false)
            .order('name', ascending: true);
        final list = [
          for (final r in rows)
            StaffMember(
              id: r['id'] as String,
              userId: r['user_id'] as String?,
              name: r['name'] as String,
              mobile: r['mobile'] as String?,
              role: r['role'] as String,
              joinedOn: DateTime.parse(r['joined_on'] as String),
              active: r['active'] as bool,
            )
        ];
        if (!withPay) return list;
        final pay = {
          for (final p in (await client.rpc('station_staff_pay', params: {'p_station': stationId}) as List))
            p['staff_id'] as String: p as Map<String, dynamic>
        };
        return [
          for (final s in list)
            pay[s.id] == null ? s : s.withPay(Money.paisa(pay[s.id]!['salary_paisa'] as int), (pay[s.id]!['commission_pct'] as num).toDouble())
        ];
      });

  Future<String> saveStaff(String stationId, Map<String, dynamic> staff) =>
      guard(() async => await client.rpc('station_save_staff', params: {'p_station': stationId, 'p': staff}) as String);

  /// Attendance of [day] by staff id (missing = present).
  Future<Map<String, Attendance>> attendance(String stationId, DateTime day) => guard(() async => {
        for (final r in await client.from('attendance').select('staff_id, status').eq('station_id', stationId).eq('day', _d(day)))
          r['staff_id'] as String: Attendance.parse(r['status'] as String)
      });

  Future<void> setAttendance(String staffId, DateTime day, Attendance status) => guard(() async =>
      await client.rpc('station_set_attendance', params: {'p_staff': staffId, 'p_day': _d(day), 'p_status': status.code}));

  Future<void> addAdvance(String staffId, Money amount, {PayMethod method = PayMethod.cash, int months = 1, String? note}) =>
      guard(() async => await client.rpc('station_add_advance', params: {
            'p_staff': staffId,
            'p_amount_paisa': amount.paisa,
            'p_method': method.code,
            'p_months': months,
            'p_note': note,
          }));

  Future<List<Map<String, dynamic>>> advances(String stationId) => guard(() async => List<Map<String, dynamic>>.from(await client
      .from('salary_advances')
      .select('id, given_on, amount_paisa, method, months, note, staff:staff(name)')
      .eq('station_id', stationId)
      .order('given_on', ascending: false)
      .limit(50)));

  /// The month's sheet, or null when it was never generated.
  Future<PayrollRun?> payroll(String stationId, DateTime month) => guard(() async {
        final run = await client
            .from('payroll_runs')
            .select('id, month, status')
            .eq('station_id', stationId)
            .eq('month', _d(DateTime(month.year, month.month)))
            .maybeSingle();
        if (run == null) return null;
        final lines = await client.from('payroll_lines').select('*, staff:staff(name)').eq('run_id', run['id'] as String);
        return PayrollRun(
          id: run['id'] as String,
          month: DateTime.parse(run['month'] as String),
          isFinal: run['status'] == 'final',
          lines: [for (final l in lines) PayrollLine.fromRow(l)]..sort((a, b) => a.name.compareTo(b.name)),
        );
      });

  Future<void> generatePayroll(String stationId, DateTime month) => guard(() async =>
      await client.rpc('payroll_generate', params: {'p_station': stationId, 'p_month': _d(DateTime(month.year, month.month))}));

  Future<void> setPayrollAdjustment(String lineId, Money amount, String? note) => guard(() async =>
      await client.rpc('payroll_set_adjustment', params: {'p_line': lineId, 'p_amount_paisa': amount.paisa, 'p_note': note}));

  Future<void> finalizePayroll(String runId) => guard(() async => await client.rpc('payroll_finalize', params: {'p_run': runId}));

  /// REQ-059 reports: rows of one report function over a date range.
  Future<List<Map<String, dynamic>>> report(String fn, String stationId, {DateTime? from, DateTime? to}) => guard(() async {
        final params = <String, dynamic>{'p_station': stationId};
        if (from != null) params['p_from'] = _d(from);
        if (to != null) params['p_to'] = _d(to);
        return List<Map<String, dynamic>>.from(await client.rpc(fn, params: params) as List);
      });

  /// Read-only report views (low stock, customer dues, supplier dues).
  Future<List<Map<String, dynamic>>> reportView(String view, String stationId) =>
      guard(() async => List<Map<String, dynamic>>.from(await client.from(view).select().eq('station_id', stationId).limit(1000)));

  /// REQ-060 extra dashboard figures.
  Future<Map<String, dynamic>> dashboardTotals(String stationId) => guard(() async =>
      Map<String, dynamic>.from(await client.rpc('station_dashboard_totals', params: {'p_station': stationId}) as Map));
}
