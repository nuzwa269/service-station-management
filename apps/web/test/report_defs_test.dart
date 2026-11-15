import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:station_core/station_core.dart';
import 'package:station_web/screens/report_defs.dart';

void main() {
  final revenue = reportDefs.firstWhere((r) => r.id == 'revenue');

  test('TEST-059: revenue row formats and exports the PRD totals', () {
    final row = {
      'invoices': 12, 'parts_paisa': 30000000, 'labour_paisa': 12000000, 'discount_paisa': 1000000,
      'net_paisa': 41000000, 'tax_paisa': 0, 'total_paisa': 41000000, 'refunds_paisa': 0,
    };
    final net = revenue.columns.firstWhere((c) => c.key == 'net_paisa');
    expect(formatCell(net, row['net_paisa']), 'Rs 410,000');
    final xlsx = Excel.decodeBytes(buildReportWorkbook(revenue, [row], 'March'));
    final sheet = xlsx.tables[xlsx.tables.keys.first]!;
    expect(sheet.rows[1].map((c) => c?.value.toString()).toList(), contains('Net (Rs)'));
    expect(num.parse(sheet.rows[2][4]!.value.toString()), 410000);
  });

  test('money columns get a total row; other kinds format', () {
    final dues = reportDefs.firstWhere((r) => r.id == 'customer_dues');
    final rows = [
      {'name': 'Ali', 'mobile': '03001234567', 'dues_paisa': 300000, 'credit_paisa': 0},
      {'name': 'Sara', 'mobile': '03007654321', 'dues_paisa': 150000, 'credit_paisa': 5000},
    ];
    expect(moneyTotals(dues, rows), {'dues_paisa': 450000, 'credit_paisa': 5000});
    expect(dues.where!({'dues_paisa': 0}), isFalse);
    expect(formatCell(const ReportCol('x', 'x', ColKind.percent), 5), '5.0%');
    expect(formatCell(const ReportCol('x', 'x', ColKind.flag), true), 'Yes');
    expect(formatCell(const ReportCol('x', 'x', ColKind.number), 3.5), '3.50');
  });

  test('owner-only and plan-gated reports', () {
    final stock = reportDefs.firstWhere((r) => r.id == 'stock_value');
    expect(stock.allowedFor(MemberRole.owner), isTrue);
    expect(stock.allowedFor(MemberRole.manager), isFalse);
    expect(reportDefs.firstWhere((r) => r.id == 'job_profit').feature, Feature.profitReports);
    expect(reportDefs.firstWhere((r) => r.id == 'mechanics').feature, Feature.payroll);
  });

  test('printable PDF builds', () async {
    final bytes = await buildReportPdf(revenue, const [], station: 'Alpha', period: 'March');
    expect(bytes.length, greaterThan(500));
  });
}
