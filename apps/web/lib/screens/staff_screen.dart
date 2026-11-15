import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:station_core/station_core.dart';

import '../download.dart';
import '../main.dart';
import 'common.dart';
import 'report_defs.dart';

/// SCR-015 / SCR-016 — staff records, daily attendance and advances (REQ-050…052) and the
/// monthly payroll sheet with commission (REQ-053). Premium; pay is owner only.
class StaffScreen extends StatelessWidget {
  const StaffScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final owner = SessionScope.of(context).role == MemberRole.owner;
    return DefaultTabController(
      length: owner ? 2 : 1,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: 'Staff', actions: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [const Tab(text: 'Staff & attendance'), if (owner) const Tab(text: 'Payroll')],
          ),
        ]),
        Expanded(child: TabBarView(children: [const _StaffTab(), if (owner) const _PayrollTab()])),
      ]),
    );
  }
}

const _roles = ['mechanic', 'helper', 'cashier', 'manager', 'owner', 'other'];

class _StaffTab extends StatefulWidget {
  const _StaffTab();

  @override
  State<_StaffTab> createState() => _StaffTabState();
}

class _StaffData {
  const _StaffData(this.staff, this.attendance, this.advances);
  final List<StaffMember> staff;
  final Map<String, Attendance> attendance;
  final List<Map<String, dynamic>> advances;
}

class _StaffTabState extends State<_StaffTab> {
  late Future<_StaffData> _data;
  late DateTime _day;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final t = toPkt(DateTime.now());
    _day = DateTime(t.year, t.month, t.day);
    _reload();
  }

  bool get _owner => SessionScope.of(context).role == MemberRole.owner;

  void _reload() {
    final s = SessionScope.of(context);
    final id = s.current!.stationId;
    final owner = _owner;
    Future<_StaffData> load() async => _StaffData(
          await s.api.staff(id, withPay: owner),
          await s.api.attendance(id, _day),
          owner ? await s.api.advances(id) : const [],
        );
    setState(() => _data = load());
  }

  bool get _isToday {
    final t = toPkt(DateTime.now());
    return _day.year == t.year && _day.month == t.month && _day.day == t.day;
  }

  Future<void> _set(StaffMember m, Attendance a) async {
    final api = SessionScope.of(context).api;
    if (await runAction(context, () => api.setAttendance(m.id, _day, a))) _reload();
  }

  Future<void> _edit([StaffMember? m]) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _StaffDialog(existing: m));
    if (ok == true) _reload();
  }

  Future<void> _advance(StaffMember m) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _AdvanceDialog(staff: m));
    if (ok == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_StaffData>(
      future: _data,
      builder: (context, snap) {
        if (snap.hasError) {
          return ErrorStateView(message: snap.error is AppError ? (snap.error as AppError).message : 'Could not load staff', onRetry: _reload);
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        final active = d.staff.where((m) => m.active).toList();
        final canEdit = _owner || _isToday;
        final list = ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
          Row(children: [
            IconButton(
              tooltip: 'Previous day',
              onPressed: _owner ? () { _day = _day.subtract(const Duration(days: 1)); _reload(); } : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Text('Attendance · ${formatDateLong(_day)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            IconButton(
              tooltip: 'Next day',
              onPressed: _isToday ? null : () { _day = _day.add(const Duration(days: 1)); _reload(); },
              icon: const Icon(Icons.chevron_right),
            ),
          ]),
          if (!canEdit) const Text('Only the owner can change another day.', style: TextStyle(fontSize: 12)),
          if (active.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No staff yet'))),
          for (final m in d.staff)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 8, children: [
                  SizedBox(
                    width: 240,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.name + (m.active ? '' : ' (left)'), style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                        [
                          m.role[0].toUpperCase() + m.role.substring(1),
                          if (m.mobile != null) formatPkMobile(m.mobile!),
                          if (m.salary != null) 'Salary ${formatPkr(m.salary!)}',
                          if ((m.commissionPct ?? 0) > 0) '${m.commissionPct!.toStringAsFixed(m.commissionPct! % 1 == 0 ? 0 : 1)}% commission',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ]),
                  ),
                  if (m.active)
                    SegmentedButton<Attendance>(
                      showSelectedIcon: false,
                      segments: [for (final a in Attendance.values) ButtonSegment(value: a, label: Text(a.short), tooltip: a.label)],
                      selected: {d.attendance[m.id] ?? Attendance.present},
                      onSelectionChanged: canEdit ? (v) => _set(m, v.first) : null,
                    ),
                  if (_owner) ...[
                    TextButton(onPressed: () => _edit(m), child: const Text('Edit')),
                    if (m.active) TextButton(onPressed: () => _advance(m), child: const Text('Advance')),
                  ],
                ]),
              ),
            ),
        ]);
        final counts = {for (final a in Attendance.values) a: active.where((m) => (d.attendance[m.id] ?? Attendance.present) == a).length};
        final side = ListView(padding: const EdgeInsets.fromLTRB(0, 8, 16, 16), children: [
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('This day', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(spacing: 18, runSpacing: 8, children: [
                  for (final a in Attendance.values)
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${counts[a]}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      Text(a.label, style: const TextStyle(fontSize: 12)),
                    ]),
                ]),
                const SizedBox(height: 8),
                const Text('Days without a mark count as present.', style: TextStyle(fontSize: 12)),
                if (_owner) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.person_add_alt), label: const Text('Add staff')),
                ],
              ]),
            ),
          ),
          if (_owner)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Recent advances', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (d.advances.isEmpty) const Text('None'),
                  for (final a in d.advances.take(8))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(children: [
                        Expanded(child: Text('${(a['staff'] as Map?)?['name'] ?? ''} · ${formatDate(DateTime.parse(a['given_on'] as String))}'
                            '${(a['months'] as int) > 1 ? ' · over ${a['months']} months' : ''}')),
                        Text(formatPkr(Money.paisa(a['amount_paisa'] as int)), style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  const SizedBox(height: 6),
                  const Text('Advances are deducted in the payroll of the month they are given.', style: TextStyle(fontSize: 12)),
                ]),
              ),
            )
          else
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('Managers mark today\'s attendance. Salaries, advances and payroll are visible to the owner only.'),
              ),
            ),
        ]);
        return LayoutBuilder(builder: (context, c) => c.maxWidth >= 1000
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: list), SizedBox(width: 340, child: side)])
            : Column(children: [SizedBox(height: 300, child: side), Expanded(child: list)]));
      },
    );
  }
}

class _StaffDialog extends StatefulWidget {
  const _StaffDialog({this.existing});
  final StaffMember? existing;

  @override
  State<_StaffDialog> createState() => _StaffDialogState();
}

class _StaffDialogState extends State<_StaffDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _mobile = TextEditingController(text: widget.existing?.mobile);
  late final _salary = TextEditingController(text: widget.existing?.salary == null ? '' : (widget.existing!.salary!.paisa ~/ 100).toString());
  late final _pct = TextEditingController(text: widget.existing?.commissionPct?.toString() ?? '0');
  late String _role = widget.existing?.role ?? 'mechanic';
  late bool _active = widget.existing?.active ?? true;
  String? _userId;
  List<Member> _logins = const [];

  @override
  void initState() {
    super.initState();
    _userId = widget.existing?.userId;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_logins.isEmpty) {
      final s = SessionScope.of(context);
      s.api.members(s.current!.stationId).then((m) {
        if (mounted) setState(() => _logins = m);
      });
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final s = SessionScope.of(context);
    final salary = parsePkr(_salary.text.isEmpty ? '0' : _salary.text)!;
    final ok = await runAction(context, () => s.api.saveStaff(s.current!.stationId, {
          'id': widget.existing?.id,
          'user_id': _userId,
          'name': _name.text.trim(),
          'mobile': _mobile.text.trim().isEmpty ? null : _mobile.text.trim(),
          'role': _role,
          'salary_paisa': salary.paisa,
          'commission_pct': double.tryParse(_pct.text.trim()) ?? 0,
          'active': _active,
        }), success: 'Saved');
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? 'Add staff' : 'Edit ${widget.existing!.name}'),
        content: SizedBox(
          width: 380,
          child: Form(
            key: _form,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) => (v ?? '').trim().length < 2 ? 'Required' : null),
              const SizedBox(height: 8),
              TextFormField(controller: _mobile, decoration: const InputDecoration(labelText: 'Mobile (optional)', hintText: '0300-1234567'),
                  validator: (v) => (v ?? '').trim().isEmpty || normalizePkMobile(v) != null ? null : 'Like 0300-1234567'),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [for (final r in _roles) DropdownMenuItem(value: r, child: Text(r[0].toUpperCase() + r.substring(1)))],
                onChanged: (v) => setState(() => _role = v!),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                initialValue: _userId,
                decoration: const InputDecoration(labelText: 'App login', helperText: 'Link a mechanic\'s login to pay commission on their jobs'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('No login')),
                  for (final m in _logins) DropdownMenuItem(value: m.userId, child: Text('${m.name} (${m.role.label})')),
                ],
                onChanged: (v) => setState(() => _userId = v),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextFormField(controller: _salary, decoration: const InputDecoration(labelText: 'Monthly salary (Rs)'),
                    validator: (v) => moneyValidator(v, required: false))),
                const SizedBox(width: 12),
                SizedBox(
                  width: 130,
                  child: TextFormField(controller: _pct, decoration: const InputDecoration(labelText: 'Commission %', helperText: 'On labour'),
                      validator: (v) {
                        final n = double.tryParse((v ?? '').trim());
                        return n == null || n < 0 || n > 100 ? '0–100' : null;
                      }),
                ),
              ]),
              if (widget.existing != null)
                SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Still working here'), value: _active,
                    onChanged: (v) => setState(() => _active = v)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

class _AdvanceDialog extends StatefulWidget {
  const _AdvanceDialog({required this.staff});
  final StaffMember staff;

  @override
  State<_AdvanceDialog> createState() => _AdvanceDialogState();
}

class _AdvanceDialogState extends State<_AdvanceDialog> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  PayMethod _method = PayMethod.cash;
  int _months = 1;

  Future<void> _save() async {
    final m = parsePkr(_amount.text);
    if (m == null || m.paisa <= 0) return;
    final api = SessionScope.of(context).api;
    final ok = await runAction(context, () => api.addAdvance(widget.staff.id, m, method: _method, months: _months, note: _note.text.trim()),
        success: 'Advance recorded');
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Advance to ${widget.staff.name}'),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _amount, autofocus: true, decoration: const InputDecoration(labelText: 'Amount (Rs)')),
            const SizedBox(height: 8),
            DropdownButtonFormField<PayMethod>(
              initialValue: _method,
              decoration: const InputDecoration(labelText: 'Paid by'),
              items: [for (final p in PayMethod.values.where((p) => p != PayMethod.credit)) DropdownMenuItem(value: p, child: Text(p.label))],
              onChanged: (v) => setState(() => _method = v!),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: _months,
              decoration: const InputDecoration(labelText: 'Deduct over'),
              items: [for (var i = 1; i <= 6; i++) DropdownMenuItem(value: i, child: Text(i == 1 ? 'This month' : '$i months'))],
              onChanged: (v) => setState(() => _months = v!),
            ),
            const SizedBox(height: 8),
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

const _payrollReport = ReportDef(
  id: 'payroll',
  title: 'Payroll',
  description: 'Monthly payroll sheet',
  columns: [
    ReportCol('name', 'Staff'),
    ReportCol('paid_days', 'Paid days', ColKind.number),
    ReportCol('monthly_paisa', 'Monthly salary', ColKind.money),
    ReportCol('salary_paisa', 'Salary earned', ColKind.money),
    ReportCol('commission_paisa', 'Commission', ColKind.money),
    ReportCol('advances_paisa', 'Advances', ColKind.money),
    ReportCol('adjustment_paisa', 'Adjustment', ColKind.money),
    ReportCol('net_paisa', 'Net pay', ColKind.money),
  ],
);

class _PayrollTab extends StatefulWidget {
  const _PayrollTab();

  @override
  State<_PayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends State<_PayrollTab> {
  late DateTime _month;
  late Future<PayrollRun?> _run;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final t = toPkt(DateTime.now());
    _month = DateTime(t.year, t.month - 1);   // last month is the one usually finalised
    _reload();
  }

  void _reload() {
    final s = SessionScope.of(context);
    setState(() => _run = s.api.payroll(s.current!.stationId, _month));
  }

  String get _label => '${const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][_month.month - 1]} ${_month.year}';

  Future<void> _generate() async {
    final s = SessionScope.of(context);
    if (await runAction(context, () => s.api.generatePayroll(s.current!.stationId, _month), success: 'Payroll calculated')) _reload();
  }

  Future<void> _finalize(PayrollRun r) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Finalise $_label?'),
        content: Text('Net pay ${formatPkr(r.total)}. The sheet, its attendance and advances will be locked.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Finalise')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final api = SessionScope.of(context).api;
    if (await runAction(context, () => api.finalizePayroll(r.id), success: 'Payroll finalised')) _reload();
  }

  Future<void> _adjust(PayrollLine l) async {
    final amount = TextEditingController(text: l.adjustment.paisa == 0 ? '' : (l.adjustment.paisa / 100).toStringAsFixed(0));
    final note = TextEditingController(text: l.adjustmentNote);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Adjustment · ${l.name}'),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: amount, decoration: const InputDecoration(labelText: 'Amount (Rs, minus to deduct)')),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final raw = amount.text.trim();
    final neg = raw.startsWith('-');
    final m = parsePkr(neg ? raw.substring(1) : (raw.isEmpty ? '0' : raw));
    if (m == null) return;
    final api = SessionScope.of(context).api;
    if (await runAction(context, () => api.setPayrollAdjustment(l.id, neg ? -m : m, note.text.trim()))) _reload();
  }

  List<Map<String, dynamic>> _rows(PayrollRun r) => [
        for (final l in r.lines)
          {
            'name': l.name,
            'paid_days': l.paidDays,
            'monthly_paisa': l.monthly.paisa,
            'salary_paisa': l.salary.paisa,
            'commission_paisa': l.commission.paisa,
            'advances_paisa': l.advances.paisa,
            'adjustment_paisa': l.adjustment.paisa,
            'net_paisa': l.net.paisa,
          }
      ];

  @override
  Widget build(BuildContext context) {
    final now = toPkt(DateTime.now());
    final atCurrent = _month.year == now.year && _month.month == now.month;
    return FutureBuilder<PayrollRun?>(
      future: _run,
      builder: (context, snap) {
        if (snap.hasError) {
          return ErrorStateView(message: snap.error is AppError ? (snap.error as AppError).message : 'Could not load payroll', onRetry: _reload);
        }
        if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final r = snap.data;
        final monthBar = Row(children: [
          IconButton(onPressed: () { _month = DateTime(_month.year, _month.month - 1); _reload(); }, icon: const Icon(Icons.chevron_left)),
          Text(_label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          IconButton(onPressed: atCurrent ? null : () { _month = DateTime(_month.year, _month.month + 1); _reload(); }, icon: const Icon(Icons.chevron_right)),
          const SizedBox(width: 8),
          if (r?.isFinal ?? false)
            const Chip(label: Text('Final — locked'), avatar: Icon(Icons.lock, size: 16))
          else
            FilledButton.icon(onPressed: _generate, icon: const Icon(Icons.calculate_outlined), label: Text(r == null ? 'Calculate payroll' : 'Recalculate')),
        ]);
        final table = r == null || r.lines.isEmpty
            ? const Center(child: Text('Not calculated yet. Mark attendance and advances, then press Calculate.'))
            : Card(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(columns: const [
                    DataColumn(label: Text('Staff')),
                    DataColumn(label: Text('Paid days'), numeric: true),
                    DataColumn(label: Text('Salary earned'), numeric: true),
                    DataColumn(label: Text('Commission'), numeric: true),
                    DataColumn(label: Text('Advances'), numeric: true),
                    DataColumn(label: Text('Adjustment'), numeric: true),
                    DataColumn(label: Text('Net pay'), numeric: true),
                  ], rows: [
                    for (final l in r.lines)
                      DataRow(cells: [
                        DataCell(Text(l.name)),
                        DataCell(Text('${l.paidDays % 1 == 0 ? l.paidDays.toInt() : l.paidDays} / ${l.daysInMonth}')),
                        DataCell(Text(formatPkr(l.salary))),
                        DataCell(Tooltip(
                          message: '${l.commissionPct}% of ${formatPkr(l.labour)} paid labour',
                          child: Text(formatPkr(l.commission)),
                        )),
                        DataCell(Text(l.advances.paisa == 0 ? '—' : '− ${formatPkr(l.advances)}')),
                        DataCell(
                          Text(l.adjustment.paisa == 0 ? (r.isFinal ? '—' : 'Add') : formatPkr(l.adjustment)),
                          onTap: r.isFinal ? null : () => _adjust(l),
                        ),
                        DataCell(Text(formatPkr(l.net), style: const TextStyle(fontWeight: FontWeight.w800))),
                      ]),
                  ]),
                ),
              );
        final side = Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(_label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(r == null ? 'Not calculated' : formatPkr(r.total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const Text('Total net pay'),
              const Divider(height: 24),
              const Text('Salary earned = salary ÷ days in month × paid days. Paid days = present + leave + off + ½ half days. '
                  'Commission = % × labour on that mechanic\'s invoices paid this month (shared jobs split equally).',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              if (r != null && !r.isFinal)
                OutlinedButton.icon(
                  onPressed: atCurrent ? null : () => _finalize(r),
                  icon: const Icon(Icons.lock_outline),
                  label: Text(atCurrent ? 'Finalise after month end' : 'Finalise'),
                ),
              if (r != null && r.lines.isNotEmpty) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => downloadBytes(buildReportWorkbook(_payrollReport, _rows(r), _label), 'payroll-${_month.year}-${_month.month}.xlsx'),
                  icon: const Icon(Icons.table_view),
                  label: const Text('Export to Excel'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final station = SessionScope.of(context).current!.stationName;
                    final bytes = await buildReportPdf(_payrollReport, _rows(r), station: station, period: _label);
                    await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'payroll.pdf');
                  },
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Print'),
                ),
              ],
            ]),
          ),
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            monthBar,
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(builder: (context, c) => c.maxWidth >= 1000
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: SingleChildScrollView(child: table)),
                      const SizedBox(width: 12),
                      SizedBox(width: 320, child: side),
                    ])
                  : ListView(children: [side, const SizedBox(height: 12), table])),
            ),
          ]),
        );
      },
    );
  }
}
