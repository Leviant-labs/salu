import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../catalogue/built_in_catalogue.dart';
import '../catalogue/starter_meals.dart';
import '../providers.dart';
import '../ui_support.dart';

/// A failed bundled installation never hides the user's existing records.
class MealLibraryStatus extends ConsumerStatefulWidget {
  const MealLibraryStatus({super.key});
  @override
  ConsumerState<MealLibraryStatus> createState() => _MealLibraryStatusState();
}

class _MealLibraryStatusState extends ConsumerState<MealLibraryStatus> {
  bool _repairing = false;
  Future<void> _repair() async {
    setState(() => _repairing = true);
    try {
      final db = ref.read(databaseProvider);
      await provisionBundledCatalogue(db);
      final result = await provisionStarterMeals(db);
      ref.read(starterMealProvisioningProvider.notifier).state =
          StarterMealProvisioningOutcome.installed(result);
      ref.invalidate(installedCataloguesProvider);
      ref.invalidate(mealContentProvider);
    } catch (error) {
      ref.read(starterMealProvisioningProvider.notifier).state =
          StarterMealProvisioningOutcome.failed(error);
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    final outcome = ref.watch(starterMealProvisioningProvider);
    if (outcome?.failure == null) return const SizedBox.shrink();
    return Card(child: Padding(padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr(context, 'Starter meals need repair',
            'As refeições iniciais precisam de reparação'),
            style: Theme.of(context).textTheme.titleMedium),
        Text(tr(context, 'Your saved plans and diary are still available.',
            'Os seus planos e diário guardados continuam disponíveis.')),
        const SizedBox(height: 8),
        FilledButton.tonal(onPressed: _repairing ? null : _repair,
          child: Text(_repairing ? tr(context, 'Repairing…', 'A reparar…') :
              tr(context, 'Repair meal library', 'Reparar refeições'))),
      ])));
  }
}
