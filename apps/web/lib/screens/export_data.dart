import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../download.dart';
import '../main.dart';

/// REQ-013 — full Excel export of the station's data, one sheet per table.
/// The owner can read every table through RLS, so the browser builds the file.
const exportTables = [
  'stations', 'station_members', 'customers', 'vehicles', 'items', 'item_stock', 'item_costs', 'kit_components',
  'suppliers', 'supplier_ledger', 'purchases', 'purchase_lines', 'services', 'job_cards', 'job_lines',
  'job_checklist_items', 'invoices', 'invoice_lines', 'payments', 'credit_notes', 'day_closings',
  'approval_requests', 'subscription_payments', 'audit_log',
];

Uint8List buildExportWorkbook(Map<String, List<Map<String, dynamic>>> data) {
  final excel = Excel.createExcel();
  final first = excel.getDefaultSheet()!;
  for (final entry in data.entries) {
    final rows = entry.value;
    final sheet = entry.key.length > 31 ? entry.key.substring(0, 31) : entry.key;
    final columns = <String>{for (final r in rows) ...r.keys}.toList();
    if (columns.isEmpty) {
      excel.appendRow(sheet, [TextCellValue('no rows')]);
      continue;
    }
    excel.appendRow(sheet, [for (final c in columns) TextCellValue(c)]);
    for (final r in rows) {
      excel.appendRow(sheet, [
        for (final c in columns)
          switch (r[c]) {
            null => null,
            final int v => IntCellValue(v),
            final double v => DoubleCellValue(v),
            final bool v => BoolCellValue(v),
            final Object v => TextCellValue(v.toString()),
          },
      ]);
    }
  }
  if (data.isNotEmpty) excel.delete(first);
  return Uint8List.fromList(excel.encode()!);
}

Future<void> exportStationData(BuildContext context) async {
  final s = SessionScope.of(context);
  final station = s.current!.stationId;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Preparing export…')));
  try {
    final data = <String, List<Map<String, dynamic>>>{};
    for (final t in exportTables) {
      final rows = <Map<String, dynamic>>[];
      for (var from = 0;; from += 1000) {
        final q = s.api.client.from(t).select();
        final page = await (t == 'stations' ? q.eq('id', station) : q.eq('station_id', station)).range(from, from + 999);
        rows.addAll(page);
        if (page.length < 1000) break;
      }
      data[t] = rows;
    }
    downloadBytes(buildExportWorkbook(data), 'station-export-${DateTime.now().toIso8601String().substring(0, 10)}.xlsx');
    messenger.showSnackBar(const SnackBar(content: Text('Export downloaded')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e is AppError ? e.message : 'Export failed — please try again')));
  }
}
