import 'package:flutter/material.dart';

/// Placeholder for deterministic meal planning.
///
/// The tab exists so the navigation shape is real, but nothing here pretends to
/// plan: the planner needs the recipe catalogue, constraint solving, and portion
/// bounds from the spec, and faking output would be worse than an empty state.
class PlanScreen extends StatelessWidget {
  /// Creates the screen.
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Not built yet', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Planning is a core feature, not an AI add-on: eligible recipes, '
                  'portion search against targets, and an editable grocery list are '
                  'all local and deterministic. Nothing is generated here until that '
                  'pipeline is implemented and tested.',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Planned pipeline', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        const _Step(
          index: 1,
          text: 'Collect schedule, targets, exclusions and preferences.',
        ),
        const _Step(
          index: 2,
          text: 'Filter recipes by hard constraints (allergies, diet, time).',
        ),
        const _Step(
          index: 3,
          text: 'Select meals and adjust portions by bounded local search.',
        ),
        const _Step(
          index: 4,
          text: 'Validate totals after every swap; never relax a hard constraint.',
        ),
        const _Step(
          index: 5,
          text: 'Aggregate ingredients into an editable grocery list.',
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(radius: 14, child: Text('$index')),
      title: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
