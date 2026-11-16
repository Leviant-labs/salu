import 'package:flutter/material.dart';
import '../../ui_support.dart';

/// One before/after meal row in a plan review.
final class GuidedMealChange {
  const GuidedMealChange({
    required this.slotLabel,
    required this.date,
    required this.beforeTitle,
    required this.afterTitle,
    this.detail,
  });

  final String slotLabel;
  final String date;
  final String beforeTitle;
  final String afterTitle;
  final String? detail;
}

/// Reusable reviewed-draft surface shared by onboarding, manual swaps and
/// the assistant.
///
/// Renders an actual before/after meal list with locally computed nutrition
/// deltas. Apply commits through the caller's acceptance callback; Keep
/// leaves the stored plan byte-equivalent (no write has happened yet).
class GuidedPlanReviewScreen extends StatelessWidget {
  const GuidedPlanReviewScreen({
    super.key,
    required this.changes,
    this.rationale,
    this.nutritionDelta,
    this.groceryAdditions = const [],
    this.groceryRemovals = const [],
    required this.onApply,
    required this.onKeep,
  });

  final List<GuidedMealChange> changes;
  final String? rationale;
  final String? nutritionDelta;
  final List<String> groceryAdditions;
  final List<String> groceryRemovals;
  final Future<void> Function() onApply;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Review plan changes', 'Rever alterações ao plano'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (rationale != null && rationale!.isNotEmpty) ...[
          Text(rationale!, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
        ],
        if (nutritionDelta != null && nutritionDelta!.isNotEmpty) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(nutritionDelta!),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(tr(context, 'Meals', 'Refeições'),
            style: Theme.of(context).textTheme.titleMedium),
        for (final change in changes)
          Card(
            child: ListTile(
              title: Text('${change.date} · ${change.slotLabel}'),
              subtitle: Text(
                  '${tr(context, 'Before', 'Antes')}: ${change.beforeTitle}\n'
                  '${tr(context, 'After', 'Depois')}: ${change.afterTitle}'
                  '${change.detail == null ? '' : '\n${change.detail!}'}'),
              isThreeLine: true,
            ),
          ),
        if (groceryAdditions.isNotEmpty || groceryRemovals.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(tr(context, 'Groceries', 'Compras'),
              style: Theme.of(context).textTheme.titleMedium),
          if (groceryAdditions.isNotEmpty)
            Text('${tr(context, 'Added', 'Adicionado')}: ${groceryAdditions.join(', ')}'),
          if (groceryRemovals.isNotEmpty)
            Text('${tr(context, 'Removed', 'Removido')}: ${groceryRemovals.join(', ')}'),
        ],
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('reviewKeep'),
                onPressed: onKeep,
                child: Text(tr(context, 'Keep current plan', 'Manter plano atual')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                key: const Key('reviewApply'),
                onPressed: () async {
                  try {
                    await onApply();
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    if (context.mounted) showFailure(context, e);
                  }
                },
                child: Text(tr(context, 'Apply changes', 'Aplicar alterações')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Opens the shared review surface. Returns true when applied.
Future<bool> showGuidedPlanReview(
  BuildContext context, {
  required List<GuidedMealChange> changes,
  String? rationale,
  String? nutritionDelta,
  List<String> groceryAdditions = const [],
  List<String> groceryRemovals = const [],
  required Future<void> Function() onApply,
  required VoidCallback onKeep,
}) async =>
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => GuidedPlanReviewScreen(
          changes: changes,
          rationale: rationale,
          nutritionDelta: nutritionDelta,
          groceryAdditions: groceryAdditions,
          groceryRemovals: groceryRemovals,
          onApply: onApply,
          onKeep: onKeep,
        ),
      ),
    ) ??
    false;
