/// Billing rules shared by the apps (REQ-036…044). The database enforces the same rules.
library;

import 'money.dart';

enum PayMethod {
  cash('cash', 'Cash'),
  jazzcash('jazzcash', 'JazzCash'),
  easypaisa('easypaisa', 'Easypaisa'),
  bank('bank', 'Bank transfer'),
  card('card', 'Card machine'),
  credit('credit', 'Customer credit');

  const PayMethod(this.code, this.label);
  final String code;
  final String label;

  static PayMethod parse(String v) => values.firstWhere((m) => m.code == v);

  /// Methods a cashier can choose for money received (credit is used separately).
  static const receivable = [cash, jazzcash, easypaisa, bank, card];

  bool get needsReference => this != cash && this != credit;
}

/// REQ-038: change to return when the customer hands over more cash.
Money changeToReturn({required Money due, required Money cashReceived}) =>
    cashReceived > due ? cashReceived - due : Money.zero;

/// REQ-037: can this discount apply without approval?
bool discountWithinLimit({required Money discount, required Money subtotal, required num limitPct}) =>
    discount.paisa * 100 <= limitPct * subtotal.paisa;

/// REQ-043: storage charge = days beyond the free days × daily rate.
Money storageCharge({required int daysReady, required int freeDays, required Money perDay}) {
  final extra = daysReady - freeDays;
  return extra <= 0 ? Money.zero : Money.paisa(perDay.paisa * extra);
}

/// REQ-040: allocate a payment to dues, oldest first. Returns paisa taken per due, same order.
List<int> allocateOldestFirst(int amount, List<int> duesOldestFirst) {
  var left = amount;
  return [
    for (final d in duesOldestFirst)
      () {
        final take = left < d ? left : d;
        left -= take;
        return take;
      }(),
  ];
}

enum InvoiceStatus {
  unpaid('unpaid', 'Unpaid'),
  partlyPaid('partly_paid', 'Partly paid'),
  paid('paid', 'Paid'),
  onCredit('on_credit', 'On credit'),
  discountPending('discount_pending', 'Discount awaiting approval');

  const InvoiceStatus(this.code, this.label);
  final String code;
  final String label;

  static InvoiceStatus parse(String v) => values.firstWhere((s) => s.code == v);
}
