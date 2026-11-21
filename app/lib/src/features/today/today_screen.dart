import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';

import '../../assistant/assistant.dart';
import '../../media/managed_media_store.dart';
import '../../providers.dart';
import '../meals/meal_editor.dart';
import '../meals/meal_editor_ai.dart';
import '../meals/meal_editor_data.dart';
import '../meals/meal_estimation.dart';
import '../settings/connections_screen.dart';
import 'check_in_screen.dart';
import '../search/food_library.dart';

/// The photo diary. Original single-food logs still appear and count here.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, PhotoMeal? meal,
      {String correction = ''}) async {
    final today = ref.read(todayDiaryDateProvider);
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => MealEditor(
        meal: meal,
        repository: ref.read(photoMealRepositoryProvider),
        mutations: ref.read(mealMutationRepositoryProvider),
        assistant: ref.read(assistantProvider),
        media: ref.read(managedMediaStoreProvider),
        activeEstimates: ref.read(activeMealEstimatesProvider),
        estimateStatusStore: ref.read(mealEstimateStatusStoreProvider),
        foods: ref.read(foodRepositoryProvider),
        date: ref.read(visibleDiaryDateProvider),
        today: today,
        initialCorrection: correction,
        library: FoodLibrary(ref.read(documentStoreProvider)),
        onLogged: (date) => ref.read(diarySelectionProvider.notifier).state =
            date == today ? null : date,
        onMutated: (_, __) {
          ref.invalidate(todayMealsProvider);
          ref.invalidate(todayEntriesProvider);
        },
        newId: ref.read(idGeneratorProvider).next,
      ),
    ));
    if (context.mounted) ref.invalidate(todayMealsProvider);
  }

  Future<void> _calendar(BuildContext context, WidgetRef ref, DiaryDate date,
      DiaryDate today) async {
    final selected = await showDatePicker(
        context: context,
        initialDate: date.localMidnight,
        firstDate: DateTime(1900),
        lastDate: today.localMidnight);
    if (selected != null && context.mounted) {
      ref.read(diarySelectionProvider.notifier).state =
          DiaryDate.ofLocal(selected);
    }
  }

  Future<void> _findCorrection(BuildContext context, WidgetRef ref) async {
    var text = '';
    final request = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Find a meal to correct'),
              content: TextField(
                  autofocus: true,
                  maxLength: 500,
                  decoration: const InputDecoration(
                      hintText: 'I only ate half of Tuesday’s pasta'),
                  onChanged: (value) => text = value),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, text.trim()),
                    child: const Text('Find meal'))
              ],
            ));
    if (request == null || request.isEmpty || !context.mounted) return;
    final today = ref.read(todayDiaryDateProvider);
    final date = mealDateFromIntent(request, today) ??
        ref.read<DiaryDate>(visibleDiaryDateProvider);
    final repository = ref.read(photoMealRepositoryProvider);
    try {
      final candidates = await repository.listFor(date);
      if (!context.mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'No meals found on ${date.toIso()}. Choose another date in the diary.')));
        return;
      }
      final meal = await showDialog<PhotoMeal>(
          context: context,
          builder: (context) => SimpleDialog(
                title: Text('Which meal on ${date.toIso()}?'),
                children: [
                  for (final candidate in candidates)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, candidate),
                        child: Text(
                            '${candidate.slot.label} · ${candidate.items.isEmpty ? candidate.caption : candidate.items.map((item) => item.name).join(', ')}')),
                ],
              ));
      if (meal != null && context.mounted) {
        await _edit(context, ref, meal, correction: request);
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read that diary date.')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(todayDiaryDateProvider);
    final date = ref.watch(visibleDiaryDateProvider);
    final meals = ref.watch(todayMealsProvider);
    final entries = ref.watch(todayEntriesProvider);
    final photos = meals.valueOrNull ?? const <PhotoMeal>[];
    final legacy = entries.valueOrNull ?? const <LoggedEntry>[];
    final profiles = [
      for (final entry in legacy)
        for (final item in entry.items) item.nutrients,
      for (final meal in photos)
        if (meal.items.isEmpty)
          NutrientProfile({})
        else
          for (final item in meal.items) item.nutrients,
    ];
    final theme = Theme.of(context);
    final ready = meals.hasValue && entries.hasValue;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(children: [
          IconButton(
              tooltip: 'Previous day',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => ref.read(diarySelectionProvider.notifier).state =
                  date.addDays(-1)),
          Expanded(
              child: TextButton.icon(
                  onPressed: () => _calendar(context, ref, date, today),
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(date.toIso()))),
          IconButton(
              tooltip: 'Next day',
              icon: const Icon(Icons.chevron_right),
              onPressed: date.compareTo(today) >= 0
                  ? null
                  : () => ref.read(diarySelectionProvider.notifier).state =
                      date.addDays(1)),
        ]),
        const SizedBox(height: 8),
        Text('Meal diary',
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('A little more awareness, one meal at a time.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: () => _edit(context, ref, null),
          icon: const Icon(Icons.add_a_photo_outlined),
          label: const Text('Log a meal'),
        ),
        TextButton.icon(
            onPressed: () => _findCorrection(context, ref),
            icon: const Icon(Icons.edit_note),
            label: const Text('Find and correct a meal')),
        TextButton.icon(
            onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => CheckInScreen(date: date))),
            icon: const Icon(Icons.insights_outlined),
            label: const Text('Weekly check-in')),
        const SizedBox(height: 12),
        if (meals.hasError || entries.hasError)
          OutlinedButton(
            onPressed: () {
              ref.invalidate(todayMealsProvider);
              ref.invalidate(todayEntriesProvider);
            },
            child: const Text('Could not load all meals. Try again'),
          )
        else if (!ready)
          const LinearProgressIndicator(),
        if (ready && profiles.isEmpty) ...[
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      backgroundColor: theme.colorScheme.secondaryContainer,
                      child: Icon(Icons.restaurant_outlined,
                          color: theme.colorScheme.onSecondaryContainer),
                    ),
                    const SizedBox(height: 16),
                    Text('Nothing logged yet',
                        style: theme.textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text(
                        'Start with a meal photo, a description, or a food search.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ]),
            ),
          ),
        ],
        for (final slot in MealSlot.values)
          if (photos.any((meal) => meal.slot == slot)) ...[
            const SizedBox(height: 16),
            Text(slot.label, style: theme.textTheme.titleLarge),
            for (final meal in photos.where((meal) => meal.slot == slot))
              _MealCard(
                meal: meal,
                onTap: () => _edit(context, ref, meal),
                openConnections: () =>
                    Navigator.of(context, rootNavigator: true).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ConnectionsScreen(
                      controller: ref.read(connectionsControllerProvider),
                    ),
                  ),
                ),
                retry: () async {
                  await estimateSavedMeal(
                    meal: meal,
                    repository: ref.read(photoMealRepositoryProvider),
                    assistant: ref.read(assistantProvider),
                    media: ref.read(managedMediaStoreProvider),
                    newId: ref.read(idGeneratorProvider).next,
                    activeEstimates: ref.read(activeMealEstimatesProvider),
                    statusStore: ref.read(mealEstimateStatusStoreProvider),
                  );
                  if (context.mounted) {
                    ref.invalidate(mealEstimateErrorProvider);
                  }
                },
              ),
          ],
        if (legacy.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Individual foods', style: theme.textTheme.titleLarge),
          for (final entry in legacy)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.restaurant_outlined),
              title: Text(entry.items.map((item) => item.name).join(', ')),
              subtitle: Text('${mealNumberText(entry.grams)} g · '
                  '${_total(entry.items.map((item) => item.nutrients), NutrientKey.energyKcal)}'),
            ),
        ],
        if (ready && profiles.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      date == today ? 'Recorded today' : 'Recorded on this day',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      for (final key in const [
                        NutrientKey.energyKcal,
                        NutrientKey.proteinG,
                        NutrientKey.carbohydrateG,
                        NutrientKey.fatG,
                        NutrientKey.fiberG
                      ])
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(key.label),
                            Text(_total(profiles, key))
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MealCard extends ConsumerWidget {
  const _MealCard({
    required this.meal,
    required this.onTap,
    required this.retry,
    required this.openConnections,
  });

  final PhotoMeal meal;
  final VoidCallback onTap;
  final VoidCallback retry;
  final VoidCallback openConnections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final path = meal.photoPath;
    final title = meal.caption.isNotEmpty
        ? meal.caption
        : meal.items.isEmpty
            ? meal.slot.label
            : meal.items.map((item) => item.name).join(', ');
    final estimated =
        meal.items.any((item) => isAiMealEstimateSource(item.source));
    final needsRecovery =
        meal.items.isEmpty && meal.estimateStatus != MealEstimateStatus.none;
    final activeEstimates =
        needsRecovery ? ref.watch(activeMealEstimatesProvider) : null;
    final errorCode =
        needsRecovery && meal.estimateStatus == MealEstimateStatus.unavailable
            ? ref
                .watch(mealEstimateErrorProvider(
                  (mealId: meal.id, revision: meal.revision),
                ))
                .valueOrNull
            : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (path != null)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ManagedMediaImage(
                  reference: path,
                  media: ref.watch(managedMediaStoreProvider),
                  fit: BoxFit.cover,
                  cacheWidth: 1200,
                  semanticLabel: '${meal.slot.label} photo',
                  unavailableText: 'Meal photo unavailable',
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  if (meal.items.isNotEmpty && meal.caption.isNotEmpty)
                    Text(meal.items.map((item) => item.name).join(', ')),
                  Text(meal.items.isEmpty
                      ? 'Foods and portions not identified yet'
                      : '${_total(meal.items.map((item) => item.nutrients), NutrientKey.energyKcal)}'
                          '${estimated ? ' · AI estimate' : ''}'),
                  Text('Review or correct', style: theme.textTheme.labelLarge),
                  if (needsRecovery && activeEstimates != null)
                    ValueListenableBuilder<Set<String>>(
                      valueListenable: activeEstimates,
                      builder: (context, active, child) {
                        if (active.contains(meal.id)) {
                          return const Text('Estimating…');
                        }
                        return _EstimateRecovery(
                          errorCode: errorCode,
                          retry: retry,
                          openConnections: openConnections,
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EstimateRecovery extends StatelessWidget {
  const _EstimateRecovery({
    required this.errorCode,
    required this.retry,
    required this.openConnections,
  });

  final SaluAssistantErrorCode? errorCode;
  final VoidCallback retry;
  final VoidCallback openConnections;

  @override
  Widget build(BuildContext context) {
    final code = errorCode;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (code != null)
            Text(
              SaluAssistantException(code).message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (code == SaluAssistantErrorCode.notConnected ||
                  code == SaluAssistantErrorCode.authenticationFailed)
                FilledButton.tonal(
                  onPressed: openConnections,
                  child: const Text('Open AI connections'),
                )
              else if (code == SaluAssistantErrorCode.quotaExceeded ||
                  code == SaluAssistantErrorCode.rateLimited)
                OutlinedButton(
                  onPressed: openConnections,
                  child: const Text('Switch or check connection'),
                ),
              TextButton(
                onPressed: retry,
                child: Text(
                  code == SaluAssistantErrorCode.busy
                      ? 'Wait and retry AI estimate'
                      : 'Retry AI estimate',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _total(Iterable<NutrientProfile> profiles, NutrientKey key) {
  var sum = NutrientSum.zero;
  var known = false;
  for (final profile in profiles) {
    final value = profile[key];
    known |= value.isKnown;
    sum = sum.adding(value);
  }
  if (!known || !sum.value.isFinite) return '-- ${key.unit}';
  return '${sum.includesEstimate ? '≈' : ''}${mealNumberText(sum.value)} ${key.unit}'
      '${sum.isComplete ? '' : ' · partial'}${sum.includesTrace ? ' · includes trace' : ''}';
}
