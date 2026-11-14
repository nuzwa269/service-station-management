import 'package:station_core/station_core.dart';

import 'api.dart';

class Item {
  const Item({
    required this.id,
    required this.code,
    required this.name,
    required this.unit,
    required this.isBulk,
    required this.sellingPrice,
    required this.minStock,
    required this.warrantyDays,
    required this.active,
    this.barcode,
    this.category,
    this.onHand = 0,
    this.avgCost,
  });

  factory Item.fromRow(Map<String, dynamic> r, {num onHand = 0, int? avgCost}) => Item(
        id: r['id'] as String,
        code: r['code'] as String,
        name: r['name'] as String,
        barcode: r['barcode'] as String?,
        category: r['category'] as String?,
        unit: ItemUnit.parse(r['unit'] as String),
        isBulk: r['is_bulk'] as bool,
        sellingPrice: Money.paisa((r['selling_price_paisa'] as num).toInt()),
        minStock: r['min_stock'] as num,
        warrantyDays: r['warranty_days'] as int,
        active: r['active'] as bool,
        onHand: onHand,
        avgCost: avgCost == null ? null : Money.paisa(avgCost),
      );

  final String id;
  final String code;
  final String name;
  final String? barcode;
  final String? category;
  final ItemUnit unit;
  final bool isBulk;
  final Money sellingPrice;
  final num minStock;
  final int warrantyDays;
  final bool active;
  final num onHand;

  /// Owner only; null for other roles (RLS hides item_costs).
  final Money? avgCost;

  bool get isLow => unit != ItemUnit.kit && (onHand < 0 || (minStock > 0 && onHand <= minStock));
}

class Supplier {
  const Supplier({required this.id, required this.name, this.phone, required this.due, required this.purchases, required this.payments});
  final String id;
  final String name;
  final String? phone;
  final Money due;
  final Money purchases;
  final Money payments;
}

class Purchase {
  const Purchase({
    required this.id,
    required this.supplierName,
    required this.billNo,
    required this.billDate,
    required this.total,
    required this.paidNow,
    required this.reversed,
    this.reversalReason,
  });

  factory Purchase.fromRow(Map<String, dynamic> r) => Purchase(
        id: r['id'] as String,
        supplierName: r['supplier_name'] as String,
        billNo: r['bill_no'] as String?,
        billDate: DateTime.parse(r['bill_date'] as String),
        total: Money.paisa((r['total_paisa'] as num).toInt()),
        paidNow: Money.paisa((r['paid_now_paisa'] as num).toInt()),
        reversed: r['status'] == 'reversed',
        reversalReason: r['reversal_reason'] as String?,
      );

  final String id;
  final String supplierName;
  final String? billNo;
  final DateTime billDate;
  final Money total;
  final Money paidNow;
  final bool reversed;
  final String? reversalReason;
}

class ApprovalRequest {
  const ApprovalRequest({
    required this.id,
    required this.type,
    required this.status,
    required this.reason,
    required this.requestedBy,
    required this.requestedByName,
    required this.createdAt,
    required this.payload,
    this.decidedByName,
    this.decidedAt,
    this.decisionNote,
    this.itemName,
    this.itemUnit,
    this.amount,
  });

  factory ApprovalRequest.fromRow(Map<String, dynamic> r) => ApprovalRequest(
        id: r['id'] as String,
        type: r['type'] as String,
        status: r['status'] as String,
        reason: r['reason'] as String,
        requestedBy: r['requested_by'] as String,
        requestedByName: r['requested_by_name'] as String? ?? '',
        createdAt: DateTime.parse(r['created_at'] as String),
        payload: Map<String, dynamic>.from(r['payload'] as Map? ?? const {}),
        decidedByName: r['decided_by_name'] as String?,
        decidedAt: r['decided_at'] == null ? null : DateTime.parse(r['decided_at'] as String),
        decisionNote: r['decision_note'] as String?,
        itemName: r['item_name'] as String?,
        itemUnit: r['item_unit'] == null ? null : ItemUnit.parse(r['item_unit'] as String),
        amount: r['amount_paisa'] == null ? null : Money.paisa((r['amount_paisa'] as num).toInt()),
      );

  final String id;
  final String type;
  final String status;
  final String reason;
  final String requestedBy;
  final String requestedByName;
  final DateTime createdAt;
  final Map<String, dynamic> payload;
  final String? decidedByName;
  final DateTime? decidedAt;
  final String? decisionNote;
  final String? itemName;
  final ItemUnit? itemUnit;
  final Money? amount;

  String get typeLabel => switch (type) {
        'stock_adjustment' => 'Stock adjustment',
        'discount' => 'Discount above limit',
        'refund' => 'Refund / bill cancellation',
        'credit_release' => 'Credit release',
        _ => type,
      };

  String get summary {
    if (type == 'stock_adjustment' && itemUnit != null) {
      final q = payload['qty'] as num;
      return '${itemName ?? 'Item'}: ${q > 0 ? '+' : ''}${formatQty(q, itemUnit!)}';
    }
    return amount == null ? '' : formatPkr(amount!);
  }
}

class CustomerHit {
  const CustomerHit({required this.customerId, required this.name, required this.mobile, this.vehicleId, this.plate, this.make, this.model});
  final String customerId;
  final String name;
  final String mobile;
  final String? vehicleId;
  final String? plate;
  final String? make;
  final String? model;
}

class ImportResult {
  const ImportResult({required this.added, required this.updated, required this.rejectedRows});
  final int added;
  final int updated;
  final List<({int row, String reason})> rejectedRows;
}

/// Phase 2 backend calls (TASK-020…028). All writes go through database functions.
extension InventoryApi on StationApi {
  Future<List<Item>> items(String stationId, {bool withCost = false}) => guard(() async {
        final rows = await client.from('items').select().eq('station_id', stationId).order('name', ascending: true);
        final stock = await client.from('item_stock').select('item_id, on_hand').eq('station_id', stationId);
        final onHand = {for (final s in stock) s['item_id'] as String: s['on_hand'] as num};
        final costs = <String, int>{};
        if (withCost) {
          for (final c in await client.from('item_costs').select('item_id, avg_cost_paisa').eq('station_id', stationId)) {
            costs[c['item_id'] as String] = (c['avg_cost_paisa'] as num).toInt();
          }
        }
        return rows.map((r) => Item.fromRow(r, onHand: onHand[r['id']] ?? 0, avgCost: costs[r['id']])).toList();
      });

  Future<List<({String itemId, num qty})>> kitComponents(String kitId) => guard(() async {
        final rows = await client.from('kit_components').select('component_item_id, qty').eq('kit_item_id', kitId);
        return rows.map((r) => (itemId: r['component_item_id'] as String, qty: r['qty'] as num)).toList();
      });

  Future<String> saveItem(String stationId, Map<String, Object?> item, {List<({String itemId, num qty})>? components}) =>
      guard(() async => await client.rpc('station_save_item', params: {
            'p_station': stationId,
            'p_item': item,
            'p_components': components?.map((c) => {'item_id': c.itemId, 'qty': c.qty}).toList(),
          }) as String);

  Future<void> setItemCost(String itemId, Money cost) =>
      guard(() async => client.rpc('station_set_item_cost', params: {'p_item': itemId, 'p_cost_paisa': cost.paisa}));

  Future<void> requestAdjustment(String stationId, String itemId, num qty, AdjustmentReason reason, String? note) =>
      guard(() async => client.rpc('station_request_stock_adjustment', params: {
            'p_station': stationId,
            'p_item': itemId,
            'p_qty': qty,
            'p_reason': reason.code,
            'p_note': note,
          }));

  // Suppliers and purchases
  Future<List<Supplier>> suppliers(String stationId) => guard(() async {
        final rows = await client.from('supplier_balances').select().eq('station_id', stationId).order('name', ascending: true);
        final phones = {
          for (final s in await client.from('suppliers').select('id, phone').eq('station_id', stationId)) s['id'] as String: s['phone'] as String?
        };
        return rows
            .map((r) => Supplier(
                  id: r['supplier_id'] as String,
                  name: r['name'] as String,
                  phone: phones[r['supplier_id']],
                  due: Money.paisa((r['due_paisa'] as num).toInt()),
                  purchases: Money.paisa((r['purchases_paisa'] as num).toInt()),
                  payments: Money.paisa((r['payments_paisa'] as num).toInt()),
                ))
            .toList();
      });

  Future<List<Map<String, dynamic>>> supplierLedger(String supplierId) => guard(() async =>
      await client.from('supplier_ledger').select().eq('supplier_id', supplierId).order('created_at', ascending: false).limit(200));

  Future<String> saveSupplier(String stationId, {String? id, required String name, String? phone}) => guard(() async =>
      await client.rpc('station_save_supplier', params: {'p_station': stationId, 'p_id': id, 'p_name': name, 'p_phone': phone}) as String);

  Future<void> paySupplier(String supplierId, Money amount, String method, {String? reference}) => guard(() async => client.rpc(
      'station_pay_supplier',
      params: {'p_supplier': supplierId, 'p_amount_paisa': amount.paisa, 'p_method': method, 'p_reference': reference}));

  Future<List<Purchase>> purchases(String stationId) => guard(() async {
        final rows = await client.from('purchases').select().eq('station_id', stationId).order('created_at', ascending: false).limit(200);
        return rows.map(Purchase.fromRow).toList();
      });

  Future<String> postPurchase(
    String stationId, {
    String? supplierId,
    String? supplierName,
    String? billNo,
    required DateTime billDate,
    required List<({String itemId, num qty, Money unitCost})> lines,
    Money paidNow = Money.zero,
  }) =>
      guard(() async => await client.rpc('station_post_purchase', params: {
            'p_station': stationId,
            'p_supplier_id': supplierId,
            'p_supplier_name': supplierName,
            'p_bill_no': billNo,
            'p_bill_date': billDate.toIso8601String().substring(0, 10),
            'p_lines': lines.map((l) => {'item_id': l.itemId, 'qty': l.qty, 'unit_cost_paisa': l.unitCost.paisa}).toList(),
            'p_paid_now_paisa': paidNow.paisa,
          }) as String);

  Future<void> reversePurchase(String purchaseId, String reason) =>
      guard(() async => client.rpc('station_reverse_purchase', params: {'p_purchase': purchaseId, 'p_reason': reason}));

  // Approvals
  Future<List<ApprovalRequest>> approvals(String stationId, {bool pendingOnly = false}) => guard(() async {
        var q = client.from('approval_inbox').select().eq('station_id', stationId);
        if (pendingOnly) q = q.eq('status', 'pending');
        final rows = await q.order('created_at', ascending: false).limit(200);
        return rows.map(ApprovalRequest.fromRow).toList();
      });

  Future<void> decideApproval(String requestId, bool approve, {String? note}) => guard(() async =>
      client.rpc('station_decide_approval', params: {'p_request': requestId, 'p_approve': approve, 'p_note': note}));

  Future<void> setManagerCanApprove(String stationId, bool allowed) => guard(() async =>
      client.rpc('station_set_manager_can_approve', params: {'p_station': stationId, 'p_allowed': allowed}));

  // Customers and vehicles
  Future<List<CustomerHit>> searchCustomers(String stationId, String query) => guard(() async {
        final rows = await client.rpc('station_search_customers', params: {'p_station': stationId, 'p_query': query}) as List;
        return rows
            .cast<Map<String, dynamic>>()
            .map((r) => CustomerHit(
                  customerId: r['customer_id'] as String,
                  name: r['name'] as String,
                  mobile: r['mobile'] as String,
                  vehicleId: r['vehicle_id'] as String?,
                  plate: r['plate'] as String?,
                  make: r['make'] as String?,
                  model: r['model'] as String?,
                ))
            .toList();
      });

  Future<Map<String, dynamic>> customer(String customerId) => guard(() async =>
      await client.from('customers').select('*, vehicles(*)').eq('id', customerId).single());

  Future<String> saveCustomer(String stationId, {String? id, required String name, required String mobile, String? email, String? address}) =>
      guard(() async => await client.rpc('station_save_customer', params: {
            'p_station': stationId,
            'p_id': id,
            'p_name': name,
            'p_mobile': mobile,
            'p_email': email,
            'p_address': address,
          }) as String);

  Future<String> saveVehicle(String stationId,
          {String? id, required String customerId, required String plate, String? make, String? model, int? year, String? colour}) =>
      guard(() async => await client.rpc('station_save_vehicle', params: {
            'p_station': stationId,
            'p_id': id,
            'p_customer': customerId,
            'p_plate': plate,
            'p_make': make,
            'p_model': model,
            'p_year': year,
            'p_colour': colour,
          }) as String);

  Future<List<Map<String, dynamic>>> vehicleHistory(String vehicleId) => guard(() async =>
      (await client.rpc('station_vehicle_history', params: {'p_vehicle': vehicleId}) as List).cast<Map<String, dynamic>>());

  // Import (REQ-034)
  Future<ImportResult> importRows(String stationId, {required bool items, required List<Map<String, Object?>> rows}) =>
      guard(() async {
        final r = await client.rpc(items ? 'station_import_items' : 'station_import_customers',
            params: {'p_station': stationId, 'p_rows': rows}) as Map<String, dynamic>;
        return ImportResult(
          added: r['added'] as int,
          updated: r['updated'] as int,
          rejectedRows: [
            for (final e in (r['rejected_rows'] as List).cast<Map<String, dynamic>>())
              (row: e['row'] as int, reason: e['reason'] as String),
          ],
        );
      });
}
