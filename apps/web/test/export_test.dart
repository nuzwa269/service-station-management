import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:station_web/screens/export_data.dart';

void main() {
  test('TEST-013: full export puts each table on its own sheet with headers', () {
    final bytes = buildExportWorkbook({
      'customers': [
        {'id': 'c1', 'name': 'Ali Raza', 'mobile': '03001234567'},
        {'id': 'c2', 'name': 'Sara', 'mobile': '03211234567', 'email': 's@example.com'},
      ],
      'payments': [
        {'id': 'p1', 'amount_paisa': 500000, 'method': 'cash', 'reverses_id': null},
      ],
      'items': <Map<String, dynamic>>[],
    });
    final book = Excel.decodeBytes(bytes);
    expect(book.tables.keys, containsAll(['customers', 'payments', 'items']));
    final customers = book.tables['customers']!.rows;
    expect(customers.first.map((c) => c?.value.toString()), ['id', 'name', 'mobile', 'email']);
    expect(customers, hasLength(3));
    expect(book.tables['payments']!.rows[1][1]?.value.toString(), '500000');
  });
}
