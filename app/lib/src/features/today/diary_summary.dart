import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';

import '../../l10n/l10n_helper.dart';
import '../../theme/glass_surface.dart';
import '../../theme/salu_theme.dart';
import '../meals/meal_editor_data.dart';

/// Formats a rolled-up nutrient value across [profiles] for [key], preserving
/// Salu's exact partial/estimated/unknown semantics.
String formatNutrientRollup(
  Iterable<NutrientProfile> profiles,
  NutrientKey key, {
  String partialLabel = 'partial',
}) {
  var sum = NutrientSum.zero;
  var known = false;
  for (final profile in profiles) {
    final value = profile[key];
    known |= value.isKnown;
    sum = sum.adding(value);
  }
  if (!known || !sum.value.isFinite) return '-- ${key.unit}';
  return '${sum.includesEstimate ? '≈' : ''}${mealNumberText(sum.value)} ${key.unit}'
      '${sum.isComplete ? '' : ' · $partialLabel'}'
      '${sum.includesTrace ? ' · includes trace' : ''}';
}

/// Builds a screen-reader-friendly description of a rolled-up nutrient value
/// so partial/estimated/unknown states are never conveyed only by color or `≈`.
String semanticNutrientRollup(
  Iterable<NutrientProfile> profiles,
  NutrientKey key, {
  required String label,
  required String estimatedWord,
  required String unknownWord,
  required String partialWord,
}) {
  var sum = NutrientSum.zero;
  var known = false;
  for (final profile in profiles) {
    final value = profile[key];
    known |= value.isKnown;
    sum = sum.adding(value);
  }
  if (!known || !sum.value.isFinite) return '$label: $unknownWord';
  final parts = <String>[
    '$label: ${mealNumberText(sum.value)} ${key.unit}',
    if (sum.includesEstimate) estimatedWord,
    if (!sum.isComplete) partialWord,
  ];
  return parts.join(', ');
}

/// Hero daily nutrition summary rendered above diary meal cards.
///
/// Optional [targets] are displayed in a visually separate reference strip so
/// recorded intake is never turned into a pressure ring.
class DiarySummary extends StatelessWidget {
  /// Creates a daily summary card.
  const DiarySummary({
    required this.profiles,
    this.isToday = true,
    this.targets = const {},
    super.key,
  });

  /// Nutrient profiles for all logged items on the visible day.
  final List<NutrientProfile> profiles;

  /// Whether the visible day is today (selects heading copy).
  final bool isToday;

  /// Optional user-declared reference targets, kept visually separate.
  final Map<NutrientKey, double> targets;

  static const _keys = [
    NutrientKey.energyKcal,
    NutrientKey.proteinG,
    NutrientKey.carbohydrateG,
    NutrientKey.fatG,
    NutrientKey.fiberG,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = SaluSurfaceTokens.of(context);
    final l10n = saluL10n(context);
    final heading = isToday ? l10n.todayRecordedToday : l10n.todayRecordedOnDay;

    return GlassSurface(
      accentBorder: true,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: theme.textTheme.titleMedium?.copyWith(
              color: tokens.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              for (final key in _keys)
                _NutrientTile(
                  label: localizedNutrientLabel(l10n, key),
                  valueText: formatNutrientRollup(
                    profiles,
                    key,
                    partialLabel: l10n.todayPartialLabel,
                  ),
                  semanticText: semanticNutrientRollup(
                    profiles,
                    key,
                    label: localizedNutrientLabel(l10n, key),
                    estimatedWord: l10n.todayEstimatedSemantics,
                    unknownWord: l10n.todayUnknownSemantics,
                    partialWord: l10n.todayPartialSemantics,
                  ),
                ),
            ],
          ),
          if (targets.isNotEmpty) ...[
            const SizedBox(height: 12),
            Divider(color: tokens.glassBorder, height: 1),
            const SizedBox(height: 10),
            Text(
              l10n.todayOptionalTargets,
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textMuted,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                for (final entry in targets.entries)
                  Text(
                    '${localizedNutrientLabel(l10n, entry.key)}: '
                    '${mealNumberText(entry.value)} ${entry.key.unit}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _NutrientTile extends StatelessWidget {
  const _NutrientTile({
    required this.label,
    required this.valueText,
    required this.semanticText,
  });

  final String label;
  final String valueText;
  final String semanticText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = SaluSurfaceTokens.of(context);
    return Semantics(
      label: semanticText,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            valueText,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
