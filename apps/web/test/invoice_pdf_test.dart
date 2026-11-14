import 'package:app_shared/app_shared.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:station_core/station_core.dart';
import 'package:station_web/screens/invoice_pdf.dart';

void main() {
  test('TEST-045: A4 invoice PDF builds with lines, tax and payments', () async {
    final inv = InvoiceDetail(
      id: 'i1',
      invoiceNo: 17,
      issuedAt: DateTime(2026, 11, 16),
      parts: Money.rupees(8000),
      labour: Money.rupees(1500),
      discount: Money.zero,
      discountState: 'none',
      taxParts: Money.rupees(1440),
      taxServices: Money.rupees(240),
      total: Money.rupees(11180),
      paid: Money.rupees(5000),
      credited: Money.zero,
      due: Money.rupees(6180),
      status: InvoiceStatus.partlyPaid,
      locked: true,
      lines: [
        InvoiceLine(id: 'l1', kind: LineKind.part, description: 'Shock absorber', qty: 1, unitPrice: Money.rupees(8000), total: Money.rupees(8000), returnedQty: 0),
        InvoiceLine(id: 'l2', kind: LineKind.labour, description: 'Fitting', qty: 1, unitPrice: Money.rupees(1500), total: Money.rupees(1500), returnedQty: 0),
      ],
      payments: [Payment(id: 'p1', kind: 'payment', method: PayMethod.cash, amount: Money.rupees(5000), paidOn: DateTime(2026, 11, 16))],
      creditNotes: const [],
      customerId: 'c1',
      customerCredit: Money.zero,
    );
    final job = JobSummary(
      id: 'j1',
      jobNo: 1042,
      kind: 'normal',
      stage: JobStage.ready,
      customerName: 'Hamza',
      plate: 'LEB-555',
      vehicleName: 'Honda City',
      createdAt: DateTime(2026, 11, 16),
    );
    final bytes = await buildInvoicePdf(
      station: {'name': 'Billing Motors', 'address': 'Lahore', 'ntn': '1234567-8', 'sales_tax_enabled': true, 'parts_tax_pct': 18, 'services_tax_pct': 16},
      inv: inv,
      job: job,
      odometerKm: 85000,
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(bytes.length, greaterThan(1000));
  });
}
