import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';

import '../../providers.dart';

/// The diary for the day the app was opened on.
class TodayScreen extends ConsumerWidget {
  /// Creates the screen.
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(todayEntriesProvider);
    final date = ref.watch(todayDiaryDateProvider);

    return entries.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => _ErrorState(
        message: '$error',
        onRetry: () => ref.invalidate(todayEntriesProvider),
      ),
      data: (list) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _DaySummary(entries: list, date: date),
          const SizedBox(height: 24),
          if (list.isEmpty)
            const _EmptyState()
          else
            for (final entry in list) _EntryTile(entry: entry),
        ],
      ),
    );
  }
}

/// Energy and macro totals with explicit data-coverage wording.
class _DaySummary extends StatelessWidget {
  const _DaySummary({required this.entries, required this.date});

  final List<LoggedEntry> entries;
  final DiaryDate date;

  static double _sum(List<LoggedEntry> entries, NutrientKey key) =>
      entries.fold(0, (total, entry) => total + entry.nutrientSum(key).value);

  static bool _covered(List<LoggedEntry> entries, NutrientKey key) =>
      entries.isNotEmpty &&
      entries.every((entry) => entry.nutrientSum(key).isComplete);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final energy = _sum(entries, NutrientKey.energyKcal);
    final energyCovered = _covered(entries, NutrientKey.energyKcal);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(date.toIso(), style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(_format(energy), style: theme.textTheme.displaySmall),
                const SizedBox(width: 6),
                Text('kcal', style: theme.textTheme.titleMedium),
              ],
            ),
            if (!energyCovered)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Partial: at least one item has no energy value recorded',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                for (final key in const [
                  NutrientKey.proteinG,
                  NutrientKey.carbohydrateG,
                  NutrientKey.fatG,
                  NutrientKey.fiberG,
                ])
                  _MacroChip(
                    label: _label(key),
                    grams: _sum(entries, key),
                    covered: _covered(entries, key),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One macro reading; unknown coverage is shown as `--`, never as 0 g.
class _MacroChip extends StatelessWidget {
  const _MacroChip({
    required this.label,
    required this.grams,
    required this.covered,
  });

  final String label;
  final double grams;
  final bool covered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        Text(
          covered ? '${_format(grams)} g' : '-- g',
          style: theme.textTheme.titleSmall,
        ),
      ],
    );
  }
}

/// One logged entry.
class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final LoggedEntry entry;

  @override
  Widget build(BuildContext context) {
    final local = entry.stamp.localWallTime;
    final time =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final names = entry.items.map((item) => item.name).join(', ');
    final energy = entry.nutrientSum(NutrientKey.energyKcal);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(child: Text(time)),
      title: Text(names),
      subtitle: Text(
        [
          '${_format(entry.grams)} g',
          energy.isComplete
              ? '${_format(energy.value)} kcal'
              : 'energy unknown',
          entry.channel.label,
        ].join(' · '),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(
            Icons.restaurant_outlined,
            size: 40,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('Nothing logged yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Search the Food tab to log something. Everything here is stored on '
            'this device.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(
              'Could not read the diary',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

String _format(double value) {
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toStringAsFixed(1);
}

String _label(NutrientKey key) => switch (key) {
  NutrientKey.proteinG => 'Protein',
  NutrientKey.carbohydrateG => 'Carbs',
  NutrientKey.fatG => 'Fat',
  NutrientKey.fiberG => 'Fiber',
  NutrientKey.sugarsG => 'Sugars',
  NutrientKey.saturatedFatG => 'Sat. fat',
  NutrientKey.sodiumMg => 'Sodium',
  NutrientKey.energyKcal => 'Energy',
};
