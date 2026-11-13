import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:station_core/station_core.dart';

/// Template columns. The header row of the uploaded sheet must use these names.
const itemColumns = ['code', 'name', 'barcode', 'category', 'unit', 'selling_price', 'purchase_price', 'min_stock', 'opening_qty', 'warranty_days'];
const customerColumns = ['name', 'mobile', 'email', 'address', 'plate', 'make', 'model', 'year', 'colour'];

/// Reads the first sheet; row 1 = headers. Returns rows as maps with their Excel row number.
List<Map<String, Object?>> parseSheet(Uint8List bytes, List<String> columns) {
  final excel = Excel.decodeBytes(bytes);
  final sheet = excel.tables.values.first;
  final rows = sheet.rows;
  if (rows.isEmpty) return const [];
  final headers = [for (final c in rows.first) (c?.value?.toString() ?? '').trim().toLowerCase().replaceAll(' ', '_')];
  final missing = columns.where((c) => !headers.contains(c) && (c == 'name' || c == 'code' || c == 'mobile')).toList();
  if (missing.isNotEmpty) {
    throw AppError(AppErrorCode.validation, 'Missing column(s): ${missing.join(', ')}. Use the template.');
  }
  final out = <Map<String, Object?>>[];
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    if (row.every((c) => (c?.value?.toString() ?? '').trim().isEmpty)) continue;
    final m = <String, Object?>{'row': r + 1};
    for (var i = 0; i < headers.length && i < row.length; i++) {
      if (columns.contains(headers[i])) m[headers[i]] = row[i]?.value?.toString().trim();
    }
    out.add(m);
  }
  return out;
}

Uint8List buildTemplate(List<String> columns, List<String> example) {
  final excel = Excel.createExcel();
  final name = excel.getDefaultSheet()!;
  excel.appendRow(name, [for (final c in columns) TextCellValue(c)]);
  excel.appendRow(name, [for (final v in example) TextCellValue(v)]);
  return Uint8List.fromList(excel.encode()!);
}
