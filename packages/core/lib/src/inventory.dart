/// Inventory rules shared by the apps (REQ-028…033). The database enforces the same rules.
enum ItemUnit {
  piece('Piece', 'pcs'),
  litre('Litre', 'L'),
  kit('Kit', 'kit');

  const ItemUnit(this.label, this.short);
  final String label;
  final String short;

  static ItemUnit parse(String v) => ItemUnit.values.byName(v);
}

/// Litres allow 2 decimals; pieces and kits are whole numbers.
bool isValidQty(ItemUnit unit, num qty) {
  final scaled = unit == ItemUnit.litre ? qty * 100 : qty;
  return (scaled - scaled.round()).abs() < 1e-9;
}

/// "3.50 L", "12 pcs".
String formatQty(num qty, ItemUnit unit) {
  final text = unit == ItemUnit.litre ? qty.toStringAsFixed(2) : qty.round().toString();
  return '$text ${unit.short}';
}

/// Weighted average cost in paisa (DEC-027): when stock is zero or negative, the new cost wins.
int weightedAverageCost({required num onHand, required int avgCost, required num qty, required int unitCost}) {
  if (onHand <= 0) return unitCost;
  return ((onHand * avgCost + qty * unitCost) / (onHand + qty)).round();
}

enum AdjustmentReason {
  countDifference('count_difference', 'Count difference'),
  damaged('damaged', 'Damaged'),
  expired('expired', 'Expired'),
  other('other', 'Other');

  const AdjustmentReason(this.code, this.label);
  final String code;
  final String label;
}
