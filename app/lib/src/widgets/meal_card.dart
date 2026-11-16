import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../ui_support.dart';
import '../features/meal/meal_content.dart';

/// Meal state shown on cards. Never inferred from diary counts.
enum MealDisplayState { pending, consumed, skipped }

extension on MealDisplayState {
  String label(BuildContext c) => switch (this) {
        MealDisplayState.consumed => tr(c, 'Eaten', 'Comido'),
        MealDisplayState.skipped => tr(c, 'Skipped', 'Saltado'),
        MealDisplayState.pending => tr(c, 'Planned', 'Planeado'),
      };

  IconData get icon => switch (this) {
        MealDisplayState.consumed => Icons.check_circle,
        MealDisplayState.skipped => Icons.remove_circle_outline,
        MealDisplayState.pending => Icons.schedule,
      };
}

/// Reusable meal card for Today, My plan and review surfaces.
///
/// Receives concrete callbacks; no navigation or business logic lives here.
/// Shows actual recipe content (title/time/portions/fit reason) with a
/// Material food icon — no invented photography.
class MealCard extends StatelessWidget {
  const MealCard({
    super.key,
    required this.meal,
    this.content,
    this.state = MealDisplayState.pending,
    this.fitReason,
    this.isNext = false,
    this.onViewRecipe,
    this.onSwap,
    this.onConsume,
    this.onSkip,
    this.onUndoSkip,
    this.onPinToggle,
    this.onMoreActions,
  });

  final PlannedMeal meal;
  final MealContent? content;
  final MealDisplayState state;
  final String? fitReason;
  final bool isNext;
  final VoidCallback? onViewRecipe;
  final VoidCallback? onSwap;
  final VoidCallback? onConsume;
  final VoidCallback? onSkip;
  final VoidCallback? onUndoSkip;
  final VoidCallback? onPinToggle;
  final void Function()? onMoreActions;

  String get _title => content?.title ?? meal.recipe.name;

  @override
  Widget build(BuildContext context) {
    final recipe = meal.recipe;
    final timeLabel = '${recipe.minutes} min';
    final portionLabel =
        '${number(meal.portions.toDouble())} ${tr(context, 'servings', 'porções')}';
    return Card(
      key: Key('mealCard:${meal.slot.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_categoryIcon(meal.slot.label), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_title, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        '${_slotLabel(context)} · $timeLabel · $portionLabel',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Chip(
                  avatar: Icon(state.icon, size: 16),
                  label: Text(state.label(context)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (isNext) ...[
              const SizedBox(height: 4),
              Text(tr(context, 'Next meal', 'Próxima refeição'),
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ],
            if (fitReason != null && fitReason!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(fitReason!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (content?.description != null && content!.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(content!.description!,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (onViewRecipe != null)
                  OutlinedButton.icon(
                    key: Key('viewRecipe:${meal.slot.id}'),
                    onPressed: onViewRecipe,
                    icon: const Icon(Icons.menu_book_outlined),
                    label: Text(tr(context, 'View recipe', 'Ver receita')),
                  ),
                if (onSwap != null && state == MealDisplayState.pending)
                  OutlinedButton.icon(
                    key: Key('swap:${meal.slot.id}'),
                    onPressed: onSwap,
                    icon: const Icon(Icons.swap_horiz_outlined),
                    label: Text(tr(context, 'Swap', 'Trocar')),
                  ),
                if (onConsume != null && state == MealDisplayState.pending)
                  FilledButton.icon(
                    key: Key('consume:${meal.slot.id}'),
                    onPressed: onConsume,
                    icon: const Icon(Icons.check),
                    label: Text(tr(context, 'I ate this', 'Comi isto')),
                  ),
                if (onSkip != null && state == MealDisplayState.pending)
                  TextButton(
                    key: Key('skip:${meal.slot.id}'),
                    onPressed: onSkip,
                    child: Text(tr(context, 'Skip', 'Saltar')),
                  ),
                if (onUndoSkip != null && state == MealDisplayState.skipped)
                  TextButton(
                    key: Key('undoSkip:${meal.slot.id}'),
                    onPressed: onUndoSkip,
                    child: Text(tr(context, 'Undo skip', 'Anular salto')),
                  ),
                if (onPinToggle != null)
                  IconButton(
                    tooltip: meal.pinned
                        ? tr(context, 'Unpin meal', 'Desafixar refeição')
                        : tr(context, 'Pin meal', 'Fixar refeição'),
                    icon: Icon(meal.pinned
                        ? Icons.push_pin
                        : Icons.push_pin_outlined),
                    onPressed: onPinToggle,
                  ),
                if (onMoreActions != null)
                  IconButton(
                    tooltip: tr(context, 'Meal options', 'Opções da refeição'),
                    icon: const Icon(Icons.more_vert),
                    onPressed: onMoreActions,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _slotLabel(BuildContext c) => switch (meal.slot.label) {
        'breakfast' => tr(c, 'Breakfast', 'Pequeno-almoço'),
        'lunch' => tr(c, 'Lunch', 'Almoço'),
        'snack' => tr(c, 'Snack', 'Lanche'),
        'dinner' => tr(c, 'Dinner', 'Jantar'),
        _ => meal.slot.label,
      };

  IconData _categoryIcon(String label) => switch (label) {
        'breakfast' => Icons.breakfast_dining_outlined,
        'lunch' => Icons.lunch_dining_outlined,
        'snack' => Icons.cookie_outlined,
        'dinner' => Icons.dinner_dining_outlined,
        _ => Icons.restaurant_outlined,
      };
}

/// Slot-state lookup from plan-meal-state records.
Map<String, MealDisplayState> mealDisplayStates(
    Map<String, PlanMealStateRecord> records) =>
    {
      for (final e in records.entries)
        e.key: e.value.state == PlanMealState.consumed
            ? MealDisplayState.consumed
            : MealDisplayState.skipped,
    };
