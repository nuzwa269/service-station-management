import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:station_core/station_core.dart';

import '../download.dart';
import '../main.dart';
import 'common.dart';
import 'report_defs.dart';

/// SCR-014 — REQ-059 reports with a date range, print and Excel export.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late ReportDef _report;
  late DateTimeRange _range;
  Future<List<Map<String, dynamic>>>? _rows;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final now = toPkt(DateTime.now());
    _range = DateTimeRange(start: DateTime(now.year, now.month), end: DateTime(now.year, now.month, now.day));
    _report = _available.first;
    _load();
  }

  List<ReportDef> get _available {
    final role = SessionScope.of(context).role!;
    return reportDefs.where((r) => r.allowedFor(role)).toList();
  }

  bool _locked(ReportDef r) => r.feature != null && !(SessionScope.of(context).entitlements?.has(r.feature!) ?? false);

  void _load() {
    final s = SessionScope.of(context);
    final id = s.current!.stationId;
    final r = _report;
    if (_locked(r)) {
      setState(() => _rows = null);
      return;
    }
    setState(() => _rows = () async {
          final rows = r.fn != null
              ? await s.api.report(r.fn!, id, from: r.ranged ? _range.start : null, to: r.ranged ? _range.end : null)
              : await s.api.reportView(r.view!, id);
          return r.where == null ? rows : rows.where(r.where!).toList();
        }());
  }

  String get _period => _report.ranged ? '${formatDate(_range.start)} – ${formatDate(_range.end)}' : 'As of ${formatDate(toPkt(DateTime.now()))}';

  void _preset(String p) {
    final now = toPkt(DateTime.now());
    final today = DateTime(now.year, now.month, now.day);
    _range = switch (p) {
      'today' => DateTimeRange(start: today, end: today),
      'last' => DateTimeRange(start: DateTime(now.year, now.month - 1), end: DateTime(now.year, now.month, 0)),
      _ => DateTimeRange(start: DateTime(now.year, now.month), end: today),
    };
    _load();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 3), lastDate: now, initialDateRange: _range);
    if (r == null) return;
    _range = r;
    _load();
  }

  Future<void> _export(List<Map<String, dynamic>> rows) async {
    downloadBytes(buildReportWorkbook(_report, rows, _period), '${_report.id}-${formatDate(_range.start)}.xlsx');
  }

  Future<void> _print(List<Map<String, dynamic>> rows) async {
    final station = SessionScope.of(context).current!.stationName;
    final bytes = await buildReportPdf(_report, rows, station: station, period: _period);
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: '${_report.id}.pdf');
  }

  @override
  Widget build(BuildContext context) {
    final header = PageHeader(title: 'Reports', actions: [
      if (_report.ranged) ...[
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'today', label: Text('Today')),
            ButtonSegment(value: 'month', label: Text('This month')),
            ButtonSegment(value: 'last', label: Text('Last month')),
          ],
          selected: const {},
          emptySelectionAllowed: true,
          onSelectionChanged: (v) => _preset(v.first),
        ),
        OutlinedButton.icon(onPressed: _pickRange, icon: const Icon(Icons.date_range), label: Text(_period)),
      ],
    ]);
    final picker = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final r in _available)
          ChoiceChip(
            avatar: _locked(r) ? const Icon(Icons.lock_outline, size: 16) : null,
            label: Text(r.title),
            selected: r.id == _report.id,
            onSelected: (_) {
              _report = r;
              _load();
            },
          ),
      ]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      picker,
      Expanded(
        child: _locked(_report)
            ? LockedFeatureCard(feature: _report.feature!, title: _report.title)
            : FutureBuilder<List<Map<String, dynamic>>>(
                future: _rows,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return ErrorStateView(message: snap.error is AppError ? (snap.error as AppError).message : 'Could not load the report', onRetry: _load);
                  }
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final rows = snap.data!;
                  final table = _ReportTable(report: _report, rows: rows);
                  final side = _ReportSide(report: _report, rows: rows, period: _period, onExport: () => _export(rows), onPrint: () => _print(rows));
                  return LayoutBuilder(builder: (context, c) {
                    if (c.maxWidth >= 1000) {
                      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: table), SizedBox(width: 340, child: side)]);
                    }
                    return ListView(children: [side, SizedBox(height: 520, child: table)]);
                  });
                },
              ),
      ),
    ]);
  }
}

class _ReportTable extends StatelessWidget {
  const _ReportTable({required this.report, required this.rows});
  final ReportDef report;
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.insights_outlined, size: 48),
        SizedBox(height: 12),
        Text('No rows for this period'),
      ]));
    }
    final totals = moneyTotals(report, rows);
    bool numeric(ReportCol c) => c.kind == ColKind.money || c.kind == ColKind.number || c.kind == ColKind.percent;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)),
            columns: [for (final c in report.columns) DataColumn(label: Text(c.label, style: const TextStyle(fontWeight: FontWeight.w700)), numeric: numeric(c))],
            rows: [
              for (final r in rows) DataRow(cells: [for (final c in report.columns) DataCell(Text(formatCell(c, r[c.key])))]),
              if (totals.isNotEmpty && rows.length > 1)
                DataRow(cells: [
                  for (final (i, c) in report.columns.indexed)
                    DataCell(Text(totals.containsKey(c.key) ? formatPkr(Money.paisa(totals[c.key]!)) : (i == 0 ? 'Total' : ''),
                        style: const TextStyle(fontWeight: FontWeight.w800))),
                ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportSide extends StatelessWidget {
  const _ReportSide({required this.report, required this.rows, required this.period, required this.onExport, required this.onPrint});
  final ReportDef report;
  final List<Map<String, dynamic>> rows;
  final String period;
  final VoidCallback onExport;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    final totals = moneyTotals(report, rows);
    final first = rows.length == 1 ? rows.first : null;
    return Card(
      margin: const EdgeInsets.fromLTRB(0, 0, 16, 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(report.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(period, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          Text(report.description, style: const TextStyle(fontSize: 13)),
          const Divider(height: 24),
          Text('${rows.length} row${rows.length == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final c in report.columns.where((c) => totals.containsKey(c.key)).take(4))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Expanded(child: Text(c.label)),
                Text(formatPkr(Money.paisa(first != null ? ((first[c.key] as num?)?.round() ?? 0) : totals[c.key]!)),
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: onExport, icon: const Icon(Icons.table_view), label: const Text('Export to Excel')),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: onPrint, icon: const Icon(Icons.print_outlined), label: const Text('Print')),
        ]),
      ),
    );
  }
}
