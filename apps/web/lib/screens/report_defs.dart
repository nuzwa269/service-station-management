import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:station_core/station_core.dart';

/// How a report column is shown and exported.
enum ColKind { text, money, number, date, dateTime, flag, percent }

class ReportCol {
  const ReportCol(this.key, this.label, [this.kind = ColKind.text]);
  final String key;
  final String label;
  final ColKind kind;

  bool get summable => kind == ColKind.money;
}

/// REQ-059 — one report on SCR-014: where its rows come from, who may run it and its columns.
class ReportDef {
  const ReportDef({
    required this.id,
    required this.title,
    required this.description,
    required this.columns,
    this.fn,
    this.view,
    this.ranged = true,
    this.roles = const {MemberRole.owner, MemberRole.manager},
    this.feature,
    this.where,
  });

  final String id;
  final String title;
  final String description;
  final List<ReportCol> columns;
  final String? fn;            // database function report_*(p_station, p_from, p_to)
  final String? view;          // or a read-only view filtered by station
  final bool ranged;
  final Set<MemberRole> roles;
  final String? feature;
  final bool Function(Map<String, dynamic> row)? where;

  bool allowedFor(MemberRole role) => roles.contains(role);
}

final reportDefs = <ReportDef>[
  const ReportDef(
    id: 'revenue',
    title: 'Monthly revenue',
    description: 'Invoices issued in the period: parts, labour, discounts, tax and refunds. Net = parts + labour − discounts (before tax).',
    fn: 'report_revenue',
    columns: [
      ReportCol('invoices', 'Invoices', ColKind.number),
      ReportCol('parts_paisa', 'Parts', ColKind.money),
      ReportCol('labour_paisa', 'Labour', ColKind.money),
      ReportCol('discount_paisa', 'Discounts', ColKind.money),
      ReportCol('net_paisa', 'Net', ColKind.money),
      ReportCol('tax_paisa', 'Tax', ColKind.money),
      ReportCol('total_paisa', 'Invoiced total', ColKind.money),
      ReportCol('refunds_paisa', 'Refunds', ColKind.money),
    ],
  ),
  const ReportDef(
    id: 'collections',
    title: 'Cash closing',
    description: 'Money received per day and method, with the counted cash of closed days.',
    fn: 'report_collections',
    columns: [
      ReportCol('day', 'Day', ColKind.date),
      ReportCol('method', 'Method'),
      ReportCol('amount_paisa', 'Amount', ColKind.money),
      ReportCol('closed', 'Day closed', ColKind.flag),
      ReportCol('difference', 'Cash difference', ColKind.money),
    ],
  ),
  const ReportDef(
    id: 'stock_value',
    title: 'Stock value',
    description: 'Stock on hand valued at average cost. Owner only.',
    fn: 'report_stock_value',
    ranged: false,
    roles: {MemberRole.owner},
    columns: [
      ReportCol('code', 'Code'),
      ReportCol('name', 'Item'),
      ReportCol('on_hand', 'On hand', ColKind.number),
      ReportCol('unit', 'Unit'),
      ReportCol('avg_cost_paisa', 'Avg cost', ColKind.money),
      ReportCol('value_paisa', 'Value', ColKind.money),
    ],
  ),
  const ReportDef(
    id: 'low_stock',
    title: 'Low stock',
    description: 'Items at or below their minimum, and items below zero.',
    view: 'low_stock_items',
    ranged: false,
    columns: [
      ReportCol('code', 'Code'),
      ReportCol('name', 'Item'),
      ReportCol('on_hand', 'On hand', ColKind.number),
      ReportCol('min_stock', 'Minimum', ColKind.number),
      ReportCol('unit', 'Unit'),
    ],
  ),
  ReportDef(
    id: 'customer_dues',
    title: 'Customer dues',
    description: 'Customers who owe money on delivered or credit-released invoices.',
    view: 'customer_balances',
    ranged: false,
    where: (r) => ((r['dues_paisa'] as num?) ?? 0) > 0,
    columns: const [
      ReportCol('name', 'Customer'),
      ReportCol('mobile', 'Mobile'),
      ReportCol('dues_paisa', 'Dues', ColKind.money),
      ReportCol('credit_paisa', 'Credit', ColKind.money),
    ],
  ),
  ReportDef(
    id: 'supplier_dues',
    title: 'Supplier dues',
    description: 'What the station owes each supplier.',
    view: 'supplier_balances',
    ranged: false,
    feature: Feature.supplierLedger,
    where: (r) => ((r['due_paisa'] as num?) ?? 0) != 0,
    columns: const [
      ReportCol('name', 'Supplier'),
      ReportCol('purchases_paisa', 'Purchases', ColKind.money),
      ReportCol('payments_paisa', 'Paid', ColKind.money),
      ReportCol('due_paisa', 'Due', ColKind.money),
    ],
  ),
  const ReportDef(
    id: 'job_profit',
    title: 'Profit per job',
    description: 'Revenue before tax minus parts at cost, per invoiced job. Owner only.',
    fn: 'report_job_profit',
    roles: {MemberRole.owner},
    feature: Feature.profitReports,
    columns: [
      ReportCol('job_no', 'Job', ColKind.number),
      ReportCol('invoice_no', 'Invoice', ColKind.number),
      ReportCol('plate', 'Vehicle'),
      ReportCol('revenue_paisa', 'Revenue', ColKind.money),
      ReportCol('parts_cost_paisa', 'Parts cost', ColKind.money),
      ReportCol('profit_paisa', 'Profit', ColKind.money),
    ],
  ),
  const ReportDef(
    id: 'part_profit',
    title: 'Profit per part',
    description: 'Parts sold on invoices against their average cost. Owner only.',
    fn: 'report_part_profit',
    roles: {MemberRole.owner},
    feature: Feature.profitReports,
    columns: [
      ReportCol('name', 'Part'),
      ReportCol('qty', 'Qty', ColKind.number),
      ReportCol('sales_paisa', 'Sales', ColKind.money),
      ReportCol('cost_paisa', 'Cost', ColKind.money),
      ReportCol('profit_paisa', 'Profit', ColKind.money),
    ],
  ),
  const ReportDef(
    id: 'mechanics',
    title: 'Mechanic performance',
    description: 'Jobs finished, labour value, reworks, QC fails and average hours from In progress to Quality check.',
    fn: 'report_mechanics',
    feature: Feature.payroll,
    columns: [
      ReportCol('name', 'Mechanic'),
      ReportCol('jobs_completed', 'Jobs', ColKind.number),
      ReportCol('labour_paisa', 'Labour', ColKind.money),
      ReportCol('rework_jobs', 'Reworks', ColKind.number),
      ReportCol('rework_pct', 'Rework rate', ColKind.percent),
      ReportCol('qc_fails', 'QC fails', ColKind.number),
      ReportCol('avg_hours', 'Avg hours', ColKind.number),
    ],
  ),
  const ReportDef(
    id: 'no_shows',
    title: 'No-shows',
    description: 'Bookings the customer did not come for.',
    fn: 'report_no_shows',
    feature: Feature.booking,
    columns: [
      ReportCol('slot_start', 'Slot', ColKind.dateTime),
      ReportCol('customer', 'Customer'),
      ReportCol('mobile', 'Mobile'),
      ReportCol('plate', 'Vehicle'),
      ReportCol('no_shows', 'No-shows', ColKind.number),
      ReportCol('blocked', 'Blocked', ColKind.flag),
    ],
  ),
  const ReportDef(
    id: 'messages',
    title: 'Message usage',
    description: 'Customer messages per event: sent automatically, sent by staff, waiting, skipped, and push.',
    fn: 'report_messages',
    columns: [
      ReportCol('label', 'Message'),
      ReportCol('automatic', 'Automatic', ColKind.number),
      ReportCol('sent_by_staff', 'By staff', ColKind.number),
      ReportCol('waiting', 'Waiting', ColKind.number),
      ReportCol('skipped', 'Skipped', ColKind.number),
      ReportCol('push', 'Push', ColKind.number),
    ],
  ),
];

/// Display text for one cell.
String formatCell(ReportCol c, Object? v) {
  if (v == null) return '';
  switch (c.kind) {
    case ColKind.money:
      return formatPkr(Money.paisa((v as num).round()));
    case ColKind.number:
      final n = v as num;
      return n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(n.abs() < 10 ? 2 : 1);
    case ColKind.percent:
      return '${(v as num).toStringAsFixed(1)}%';
    case ColKind.date:
      return formatDate(DateTime.parse(v as String));
    case ColKind.dateTime:
      final t = toPkt(DateTime.parse(v as String));
      return '${formatDate(t)} ${formatTime(t)}';
    case ColKind.flag:
      return v == true ? 'Yes' : 'No';
    case ColKind.text:
      return v.toString();
  }
}

/// Column totals for money columns (null for the others).
Map<String, int> moneyTotals(ReportDef r, List<Map<String, dynamic>> rows) => {
      for (final c in r.columns.where((c) => c.summable))
        c.key: rows.fold<int>(0, (a, row) => a + ((row[c.key] as num?)?.round() ?? 0)),
    };

/// Excel with rupee amounts as numbers.
Uint8List buildReportWorkbook(ReportDef r, List<Map<String, dynamic>> rows, String period) {
  final excel = Excel.createExcel();
  final sheet = excel.getDefaultSheet()!;
  excel.appendRow(sheet, [TextCellValue(r.title), TextCellValue(period)]);
  excel.appendRow(sheet, [for (final c in r.columns) TextCellValue(c.kind == ColKind.money ? '${c.label} (Rs)' : c.label)]);
  for (final row in rows) {
    excel.appendRow(sheet, [
      for (final c in r.columns)
        switch (c.kind) {
          _ when row[c.key] == null => null,
          ColKind.money => DoubleCellValue((row[c.key] as num) / 100),
          ColKind.number || ColKind.percent => DoubleCellValue((row[c.key] as num).toDouble()),
          _ => TextCellValue(formatCell(c, row[c.key])),
        }
    ]);
  }
  final totals = moneyTotals(r, rows);
  if (totals.isNotEmpty && rows.length > 1) {
    excel.appendRow(sheet, [
      for (final (i, c) in r.columns.indexed)
        totals.containsKey(c.key) ? DoubleCellValue(totals[c.key]! / 100) : (i == 0 ? TextCellValue('Total') : null)
    ]);
  }
  return Uint8List.fromList(excel.encode()!);
}

/// A4 landscape PDF for printing.
Future<Uint8List> buildReportPdf(ReportDef r, List<Map<String, dynamic>> rows, {required String station, required String period}) async {
  final doc = pw.Document(title: r.title);
  final totals = moneyTotals(r, rows);
  pw.Widget cell(String t, {bool bold = false, bool right = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 5),
        child: pw.Text(t, textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : null)),
      );
  bool right(ReportCol c) => c.kind == ColKind.money || c.kind == ColKind.number || c.kind == ColKind.percent;
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(28),
    build: (_) => [
      pw.Text(station, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      pw.Text('${r.title} · $period', style: const pw.TextStyle(fontSize: 11)),
      pw.SizedBox(height: 10),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColor.fromHex('#CBD5E1'), width: 0.5),
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F1F5F9')),
            children: [for (final c in r.columns) cell(c.label, bold: true, right: right(c))],
          ),
          for (final row in rows) pw.TableRow(children: [for (final c in r.columns) cell(formatCell(c, row[c.key]), right: right(c))]),
          if (totals.isNotEmpty && rows.length > 1)
            pw.TableRow(children: [
              for (final (i, c) in r.columns.indexed)
                cell(totals.containsKey(c.key) ? formatPkr(Money.paisa(totals[c.key]!)) : (i == 0 ? 'Total' : ''), bold: true, right: right(c)),
            ]),
        ],
      ),
      if (rows.isEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 12), child: pw.Text('No rows for this period.')),
    ],
  ));
  return doc.save();
}
