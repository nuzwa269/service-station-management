import 'package:app_shared/app_shared.dart';
import 'package:flutter/material.dart';
import 'package:station_core/station_core.dart';

/// Rupee input validator (whole rupees or up to 2 decimals).
String? moneyValidator(String? v, {bool required = true}) {
  if ((v ?? '').trim().isEmpty) return required ? 'Required' : null;
  final m = parsePkr(v!);
  if (m == null) return 'Enter an amount like 1,250';
  if (m.isNegative) return 'Cannot be negative';
  return null;
}

String? qtyValidator(String? v, ItemUnit unit, {bool allowNegative = false, bool allowZero = false}) {
  final n = num.tryParse((v ?? '').trim());
  if (n == null) return 'Enter a number';
  if (!allowNegative && n < 0) return 'Cannot be negative';
  if (!allowZero && n == 0) return 'Cannot be 0';
  if (!isValidQty(unit, n)) return unit == ItemUnit.litre ? 'Max 2 decimals' : 'Whole numbers only';
  return null;
}

/// Runs an action, shows errors as a snackbar and returns whether it succeeded.
Future<bool> runAction(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
    }
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Asks for a mandatory reason (reversals, rejections).
Future<String?> askReason(BuildContext context, {required String title, String label = 'Reason', bool required = true}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (required && c.text.trim().length < 3) return;
            Navigator.pop(ctx, c.text.trim());
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.actions = const []});
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(width: 16),
            ...actions,
          ],
        ),
      );
}
