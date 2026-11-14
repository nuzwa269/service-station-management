import 'package:station_core/station_core.dart';

import 'api.dart';

class Service {
  const Service({required this.id, required this.name, required this.rate, required this.warrantyDays, required this.active});
  factory Service.fromRow(Map<String, dynamic> r) => Service(
        id: r['id'] as String,
        name: r['name'] as String,
        rate: Money.paisa((r['rate_paisa'] as num).toInt()),
        warrantyDays: r['warranty_days'] as int,
        active: r['active'] as bool,
      );
  final String id;
  final String name;
  final Money rate;
  final int warrantyDays;
  final bool active;
}

class Payment {
  const Payment({required this.id, required this.kind, required this.method, required this.amount, required this.paidOn, this.reference, this.reason, this.reversed = false});
  factory Payment.fromRow(Map<String, dynamic> r, {bool reversed = false}) => Payment(
        id: r['id'] as String,
        kind: r['kind'] as String,
        method: PayMethod.parse(r['method'] as String),
        amount: Money.paisa((r['amount_paisa'] as num).toInt()),
        paidOn: DateTime.parse(r['paid_on'] as String),
        reference: r['reference'] as String?,
        reason: r['reason'] as String?,
        reversed: reversed,
      );
  final String id;
  final String kind;
  final PayMethod method;
  final Money amount;
  final DateTime paidOn;
  final String? reference;
  final String? reason;
  final bool reversed;

  bool get reversible => !reversed && (kind == 'payment' || kind == 'advance' || kind == 'credit_use');
}

class InvoiceLine {
  const InvoiceLine({required this.id, required this.kind, required this.description, required this.qty, required this.unitPrice, required this.total, required this.returnedQty});
  factory InvoiceLine.fromRow(Map<String, dynamic> r) => InvoiceLine(
        id: r['id'] as String,
        kind: LineKind.parse(r['kind'] as String),
        description: r['description'] as String,
        qty: r['qty'] as num,
        unitPrice: Money.paisa((r['unit_price_paisa'] as num).toInt()),
        total: Money.paisa((r['total_paisa'] as num).toInt()),
        returnedQty: r['returned_qty'] as num,
      );
  final String id;
  final LineKind kind;
  final String description;
  final num qty;
  final Money unitPrice;
  final Money total;
  final num returnedQty;
}

class InvoiceDetail {
  const InvoiceDetail({
    required this.id,
    required this.invoiceNo,
    required this.issuedAt,
    required this.parts,
    required this.labour,
    required this.discount,
    required this.discountState,
    required this.taxParts,
    required this.taxServices,
    required this.total,
    required this.paid,
    required this.credited,
    required this.due,
    required this.status,
    required this.locked,
    required this.lines,
    required this.payments,
    required this.creditNotes,
    required this.customerId,
    required this.customerCredit,
  });

  final String id;
  final int invoiceNo;
  final DateTime issuedAt;
  final Money parts;
  final Money labour;
  final Money discount;
  final String discountState;
  final Money taxParts;
  final Money taxServices;
  final Money total;
  final Money paid;
  final Money credited;
  final Money due;
  final InvoiceStatus status;
  final bool locked;
  final List<InvoiceLine> lines;
  final List<Payment> payments;
  final List<Map<String, dynamic>> creditNotes;
  final String customerId;
  final Money customerCredit;

  Money get subtotal => parts + labour;
}

class DaySummary {
  const DaySummary({required this.day, required this.expected, required this.count, required this.closed, this.closing});
  final DateTime day;
  final Map<PayMethod, Money> expected;
  final int count;
  final bool closed;
  final Map<String, dynamic>? closing;

  Money get expectedCash => expected[PayMethod.cash] ?? Money.zero;
}

Money _m(Object? v) => Money.paisa((v as num? ?? 0).toInt());

/// Phase 4 billing calls (TASK-038…045). All money changes go through database functions.
extension BillingApi on StationApi {
  // Services (REQ-035)
  Future<List<Service>> services(String stationId) => guard(() async {
        final rows = await client.from('services').select().eq('station_id', stationId).order('name', ascending: true);
        return rows.map(Service.fromRow).toList();
      });

  Future<void> saveService(String stationId, {String? id, required String name, required Money rate, required int warrantyDays, bool active = true}) =>
      guard(() async => client.rpc('station_save_service', params: {
            'p_station': stationId,
            'p_id': id,
            'p_name': name,
            'p_rate_paisa': rate.paisa,
            'p_warranty_days': warrantyDays,
            'p_active': active,
          }));

  Future<void> addService(String jobId, String serviceId, {num qty = 1, Money? price}) => guard(() async =>
      client.rpc('job_add_service', params: {'p_job': jobId, 'p_service': serviceId, 'p_qty': qty, 'p_price_paisa': price?.paisa}));

  Future<void> setBillingRules(String stationId, {required num discountLimitPct, required int storageFreeDays, required Money storagePerDay}) =>
      guard(() async => client.rpc('station_set_billing_rules', params: {
            'p_station': stationId,
            'p_discount_limit_pct': discountLimitPct,
            'p_storage_free_days': storageFreeDays,
            'p_storage_charge_paisa': storagePerDay.paisa,
          }));

  // Invoices (REQ-036, REQ-037)
  Future<String?> invoiceIdForJob(String jobId) => guard(() async {
        final r = await client.from('invoices').select('id').eq('job_id', jobId).maybeSingle();
        return r?['id'] as String?;
      });

  Future<String> createInvoice(String jobId) => guard(() async => await client.rpc('station_create_invoice', params: {'p_job': jobId}) as String);

  Future<InvoiceDetail> invoice(String invoiceId) => guard(() async {
        final i = await client.from('invoices').select().eq('id', invoiceId).single();
        final b = await client.from('invoice_balances').select().eq('invoice_id', invoiceId).single();
        final lines = await client.from('invoice_lines').select().eq('invoice_id', invoiceId).order('kind', ascending: true);
        final pays = await client
            .from('payments')
            .select()
            .or('invoice_id.eq.$invoiceId,and(invoice_id.is.null,job_id.eq.${i['job_id']})')
            .order('created_at', ascending: true);
        final reversedIds = {for (final p in pays) if (p['reverses_id'] != null) p['reverses_id'] as String};
        final cns = await client.from('credit_notes').select().eq('invoice_id', invoiceId).order('cn_no', ascending: true);
        final cb = await client.from('customer_balances').select('credit_paisa').eq('customer_id', i['customer_id'] as String).single();
        return InvoiceDetail(
          id: invoiceId,
          invoiceNo: i['invoice_no'] as int,
          issuedAt: DateTime.parse(i['issued_at'] as String),
          parts: _m(i['parts_paisa']),
          labour: _m(i['labour_paisa']),
          discount: _m(i['discount_paisa']),
          discountState: i['discount_state'] as String,
          taxParts: _m(i['tax_parts_paisa']),
          taxServices: _m(i['tax_services_paisa']),
          total: _m(i['total_paisa']),
          paid: _m(b['paid_paisa']),
          credited: _m(b['credited_paisa']),
          due: _m(b['due_paisa']),
          status: InvoiceStatus.parse(b['status'] as String),
          locked: i['locked'] as bool,
          lines: lines.map(InvoiceLine.fromRow).toList(),
          payments: [for (final p in pays) Payment.fromRow(p, reversed: reversedIds.contains(p['id']))],
          creditNotes: List<Map<String, dynamic>>.from(cns),
          customerId: i['customer_id'] as String,
          customerCredit: _m(cb['credit_paisa']),
        );
      });

  Future<String> setDiscount(String invoiceId, Money amount, {String? reason}) => guard(() async =>
      await client.rpc('invoice_set_discount', params: {'p_invoice': invoiceId, 'p_amount_paisa': amount.paisa, 'p_reason': reason}) as String);

  Future<void> refreshInvoice(String invoiceId) => guard(() async => client.rpc('invoice_refresh', params: {'p_invoice': invoiceId}));

  // Payments (REQ-038, REQ-042)
  Future<void> recordPayment(String invoiceId, Money amount, PayMethod method, {String? reference}) => guard(() async => client.rpc(
      'invoice_record_payment',
      params: {'p_invoice': invoiceId, 'p_amount_paisa': amount.paisa, 'p_method': method.code, 'p_reference': reference}));

  Future<void> recordAdvance(String jobId, Money amount, PayMethod method, {String? reference}) => guard(() async =>
      client.rpc('job_record_advance', params: {'p_job': jobId, 'p_amount_paisa': amount.paisa, 'p_method': method.code, 'p_reference': reference}));

  Future<void> useCredit(String invoiceId, Money amount) =>
      guard(() async => client.rpc('invoice_use_credit', params: {'p_invoice': invoiceId, 'p_amount_paisa': amount.paisa}));

  Future<void> reversePayment(String paymentId, String reason) =>
      guard(() async => client.rpc('payment_reverse', params: {'p_payment': paymentId, 'p_reason': reason}));

  // Credit, dues, refunds (REQ-039…041)
  Future<String> requestCredit(String invoiceId, String reason) =>
      guard(() async => await client.rpc('invoice_request_credit', params: {'p_invoice': invoiceId, 'p_reason': reason}) as String);

  Future<String> requestRefund(String invoiceId, Money amount, {required String mode, required String reason, List<({String lineId, num qty})> returns = const []}) =>
      guard(() async => await client.rpc('invoice_request_refund', params: {
            'p_invoice': invoiceId,
            'p_amount_paisa': amount.paisa,
            'p_mode': mode,
            'p_reason': reason,
            'p_returns': [for (final r in returns) {'invoice_line_id': r.lineId, 'qty': r.qty}],
          }) as String);

  Future<({Money dues, Money credit})> customerBalance(String customerId) => guard(() async {
        final r = await client.from('customer_balances').select('dues_paisa, credit_paisa').eq('customer_id', customerId).single();
        return (dues: _m(r['dues_paisa']), credit: _m(r['credit_paisa']));
      });

  Future<void> collectDues(String customerId, Money amount, PayMethod method, {String? reference}) => guard(() async => client.rpc(
      'customer_collect_dues',
      params: {'p_customer': customerId, 'p_amount_paisa': amount.paisa, 'p_method': method.code, 'p_reference': reference}));

  // Day closing (REQ-044)
  Future<DaySummary> daySummary(String stationId, DateTime day) => guard(() async {
        final r = await client.rpc('station_day_summary', params: {'p_station': stationId, 'p_day': _date(day)}) as Map<String, dynamic>;
        return DaySummary(
          day: DateTime.parse(r['day'] as String),
          expected: {for (final e in (r['expected'] as Map).entries) PayMethod.parse(e.key as String): _m(e.value)},
          count: r['count'] as int,
          closed: r['closed'] as bool,
          closing: r['closing'] as Map<String, dynamic>?,
        );
      });

  Future<Money> closeDay(String stationId, DateTime day, Money countedCash, {String? note}) => guard(() async => _m(await client.rpc(
      'station_close_day',
      params: {'p_station': stationId, 'p_day': _date(day), 'p_counted_cash_paisa': countedCash.paisa, 'p_note': note})));

  Future<void> reopenDay(String stationId, DateTime day, String reason) =>
      guard(() async => client.rpc('station_reopen_day', params: {'p_station': stationId, 'p_day': _date(day), 'p_reason': reason}));

  Future<List<Map<String, dynamic>>> recentClosings(String stationId) => guard(() async =>
      await client.from('day_closings').select().eq('station_id', stationId).order('day', ascending: false).limit(14));
}

String _date(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
