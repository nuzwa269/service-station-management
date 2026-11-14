import 'dart:typed_data';

import 'package:app_shared/app_shared.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:station_core/station_core.dart';

/// REQ-045 — A4 invoice in English with station branding, lines, discount, tax per
/// category, total, payments and due. Shared as PDF or printed from the browser.
Future<Uint8List> buildInvoicePdf({
  required Map<String, dynamic> station,
  required InvoiceDetail inv,
  required JobSummary job,
  required int odometerKm,
  Uint8List? logo,
}) async {
  final doc = pw.Document(title: 'Invoice ${inv.invoiceNo}');
  final teal = PdfColor.fromHex('#0E7490');
  final grey = PdfColor.fromHex('#64748B');
  String rs(Money m) => formatPkr(m);

  pw.Widget cell(String t, {bool bold = false, pw.TextAlign align = pw.TextAlign.left}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 6),
        child: pw.Text(t, textAlign: align, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : null)),
      );

  pw.Widget total(String k, String v, {bool strong = false}) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
        pw.SizedBox(width: 160, child: pw.Text(k, style: pw.TextStyle(fontSize: strong ? 12 : 10, fontWeight: strong ? pw.FontWeight.bold : null))),
        pw.SizedBox(
          width: 100,
          child: pw.Text(v, textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: strong ? 12 : 10, fontWeight: strong ? pw.FontWeight.bold : null)),
        ),
      ]);

  final taxOn = station['sales_tax_enabled'] == true;
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (context) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (logo != null) pw.Container(width: 56, height: 56, margin: const pw.EdgeInsets.only(right: 12), child: pw.Image(pw.MemoryImage(logo))),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(station['name'] as String, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: teal)),
            if (station['address'] != null) pw.Text(station['address'] as String, style: pw.TextStyle(fontSize: 10, color: grey)),
            if (station['phone'] != null) pw.Text('Phone: ${station['phone']}', style: pw.TextStyle(fontSize: 10, color: grey)),
            if (station['ntn'] != null) pw.Text('NTN: ${station['ntn']}', style: pw.TextStyle(fontSize: 10, color: grey)),
            if (station['strn'] != null) pw.Text('STRN: ${station['strn']}', style: pw.TextStyle(fontSize: 10, color: grey)),
          ]),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('INVOICE', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.Text('No. ${inv.invoiceNo}', style: const pw.TextStyle(fontSize: 11)),
          pw.Text('Date: ${formatDate(inv.issuedAt.toLocal()).replaceAll('-', '/')}', style: const pw.TextStyle(fontSize: 11)),
        ]),
      ]),
      pw.SizedBox(height: 16),
      pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F1F5F9'), borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Text('Customer: ${job.customerName}', style: const pw.TextStyle(fontSize: 10))),
          pw.Expanded(child: pw.Text('Vehicle: ${job.plate} ${job.vehicleName ?? ''}', style: const pw.TextStyle(fontSize: 10))),
          pw.Expanded(child: pw.Text('Odometer: $odometerKm km · Job ${job.jobNo}', style: const pw.TextStyle(fontSize: 10))),
        ]),
      ),
      pw.SizedBox(height: 14),
      pw.Table(
        border: pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColor.fromHex('#E2E8F0'), width: 0.5)),
        columnWidths: {0: const pw.FlexColumnWidth(5), 1: const pw.FlexColumnWidth(1.2), 2: const pw.FlexColumnWidth(2), 3: const pw.FlexColumnWidth(2)},
        children: [
          pw.TableRow(decoration: pw.BoxDecoration(color: PdfColor.fromHex('#E0F2FE')), children: [
            cell('Description', bold: true),
            cell('Qty', bold: true, align: pw.TextAlign.right),
            cell('Rate', bold: true, align: pw.TextAlign.right),
            cell('Amount', bold: true, align: pw.TextAlign.right),
          ]),
          for (final kind in [LineKind.part, LineKind.labour, LineKind.fee])
            for (final l in inv.lines.where((l) => l.kind == kind))
              pw.TableRow(children: [
                cell('${l.description}${kind == LineKind.part ? '' : ' (${kind.label.toLowerCase()})'}'),
                cell('${l.qty}', align: pw.TextAlign.right),
                cell(rs(l.unitPrice), align: pw.TextAlign.right),
                cell(rs(l.total), align: pw.TextAlign.right),
              ]),
        ],
      ),
      pw.SizedBox(height: 12),
      total('Parts', rs(inv.parts)),
      total('Labour & services', rs(inv.labour)),
      if (inv.discountState == 'applied' && inv.discount.paisa > 0) total('Discount', '-${rs(inv.discount)}'),
      if (taxOn) total('Sales tax on parts (${station['parts_tax_pct']}%)', rs(inv.taxParts)),
      if (taxOn) total('Sales tax on services (${station['services_tax_pct']}%)', rs(inv.taxServices)),
      pw.Divider(color: PdfColor.fromHex('#CBD5E1')),
      total('Total', rs(inv.total), strong: true),
      if (inv.credited.paisa > 0) total('Credit notes', '-${rs(inv.credited)}'),
      total('Paid', rs(inv.paid)),
      total('Amount due', rs(inv.due), strong: true),
      pw.SizedBox(height: 14),
      if (inv.payments.isNotEmpty) ...[
        pw.Text('Payments', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        for (final p in inv.payments)
          pw.Text('${formatDate(p.paidOn)}  ${p.method.label}${p.reference == null ? '' : ' (${p.reference})'}  ${rs(p.amount)}',
              style: pw.TextStyle(fontSize: 9, color: grey)),
      ],
      pw.Spacer(),
      pw.Center(child: pw.Text('Thank you for your visit', style: pw.TextStyle(fontSize: 10, color: grey))),
    ]),
  ));
  return doc.save();
}
