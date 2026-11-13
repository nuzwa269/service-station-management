import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:station_core/station_core.dart';
import 'package:station_web/screens/import_excel.dart';

void main() {
  test('TEST-034: template round-trips through the parser', () {
    final bytes = buildTemplate(itemColumns, ['F-01', 'Oil filter', '', 'Filters', 'piece', '900', '400', '5', '10', '30']);
    final rows = parseSheet(bytes, itemColumns);
    expect(rows, hasLength(1));
    expect(rows.first['row'], 2);
    expect(rows.first['code'], 'F-01');
    expect(rows.first['selling_price'], '900');
  });

  test('TEST-034: blank rows skipped, row numbers kept for the report', () {
    final excel = Excel.createExcel();
    final s = excel.getDefaultSheet()!;
    excel.appendRow(s, [TextCellValue('Name'), TextCellValue('Mobile'), TextCellValue('Plate')]);
    excel.appendRow(s, [TextCellValue('Ali'), TextCellValue('0300-1234567'), TextCellValue('LEA 1234')]);
    excel.appendRow(s, [TextCellValue(''), TextCellValue(''), TextCellValue('')]);
    excel.appendRow(s, [TextCellValue(''), TextCellValue('03001112223'), null]);
    final rows = parseSheet(Uint8List.fromList(excel.encode()!), customerColumns);
    expect(rows.map((r) => r['row']), [2, 4]);
    expect(rows.first['plate'], 'LEA 1234');
  });

  test('missing required column is reported', () {
    final excel = Excel.createExcel();
    excel.appendRow(excel.getDefaultSheet()!, [TextCellValue('title')]);
    expect(() => parseSheet(Uint8List.fromList(excel.encode()!), itemColumns),
        throwsA(isA<AppError>().having((e) => e.message, 'message', contains('code'))));
  });
}
