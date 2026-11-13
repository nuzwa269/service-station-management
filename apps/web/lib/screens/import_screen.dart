import 'package:app_shared/app_shared.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

import '../download.dart';
import '../main.dart';
import 'common.dart';
import 'import_excel.dart';

/// SCR-020 — REQ-034 Excel templates and import with a row-by-row rejection report.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _items = true;
  bool _busy = false;
  ImportResult? _result;
  int _sent = 0;

  Future<void> _import() async {
    final s = SessionScope.of(context);
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (f == null || !mounted) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    await runAction(context, () async {
      final rows = parseSheet(await f.readAsBytes(), _items ? itemColumns : customerColumns);
      if (rows.isEmpty) throw const AppError(AppErrorCode.validation, 'The sheet has no rows');
      if (rows.length > 5000) throw const AppError(AppErrorCode.validation, 'At most 5,000 rows per import');
      _sent = rows.length;
      _result = await s.api.importRows(s.current!.stationId, items: _items, rows: rows);
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const PageHeader(title: 'Import from Excel'),
      SegmentedButton<bool>(
        segments: const [ButtonSegment(value: true, label: Text('Items & opening stock')), ButtonSegment(value: false, label: Text('Customers & vehicles'))],
        selected: {_items},
        onSelectionChanged: (v) => setState(() {
          _items = v.first;
          _result = null;
        }),
      ),
      const SizedBox(height: 16),
      Text(_items
          ? 'Columns: ${itemColumns.join(', ')}. Unit is piece or litre (create kits in Inventory). Prices in rupees. '
              'Opening quantity is added only for new codes; re-importing a code updates the item.'
          : 'Columns: ${customerColumns.join(', ')}. Mobile like 0300-1234567; plate optional. Re-importing a mobile updates the customer.'),
      const SizedBox(height: 16),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          onPressed: () => downloadBytes(
            _items
                ? buildTemplate(itemColumns, ['F-01', 'Oil filter', '', 'Filters', 'piece', '900', '400', '5', '10', '30'])
                : buildTemplate(customerColumns, ['Ali Raza', '0300-1234567', '', 'Lahore', 'LEA-1234', 'Toyota', 'Corolla', '2018', 'White']),
            _items ? 'items_template.xlsx' : 'customers_template.xlsx',
          ),
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download template'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _import,
          icon: const Icon(Icons.upload_file_outlined),
          label: Text(_busy ? 'Importing…' : 'Choose .xlsx and import'),
        ),
      ]),
      if (r != null) ...[
        const Divider(height: 32),
        Text('Rows read: $_sent · Added: ${r.added} · Updated: ${r.updated} · Rejected: ${r.rejectedRows.length}',
            style: Theme.of(context).textTheme.titleMedium),
        for (final e in r.rejectedRows) ListTile(dense: true, leading: Text('Row ${e.row}'), title: Text(e.reason)),
      ],
    ]);
  }
}
