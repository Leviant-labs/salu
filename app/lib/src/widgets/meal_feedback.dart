/// Explicit meal feedback: Like / Not for me / Too much work, plus the
/// skippable weekly check-in.
///
/// Ratings update the profile's explicit liked/disliked ids through a local
/// review; they never auto-replace today's plan. `Too much work` is stored
/// in `preferences/meal-feedback` under recipe id with date and current
/// recipe revision. The weekly check-in asks which meals worked, which were
/// too time-consuming, and whether to prefer more variety; it never requires
/// logging completeness, never infers failure, and never lowers energy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../providers.dart';
import '../ui_support.dart';

/// Feedback collections (all inside the existing `preferences` document).
const mealFeedbackKey = 'meal-feedback';
const recommendationDismissalsKey = 'recommendation-dismissals';

/// Rating of one meal: like, dislike, or too-much-work.
enum MealRating { like, dislike, tooMuchWork }

extension on MealRating {
  String get wire => name;
}

/// Reads the `preferences/meal-feedback` map.
///
/// Shape per recipe id:
/// `{date: 'yyyy-MM-dd', recipeRevision: int, rating: 'like'|'dislike'|'tooMuchWork'}`.
Map<String, Map<String, Object?>> mealFeedbackOf(
    Map<String, Object?> preferences) {
  final raw = preferences[mealFeedbackKey];
  if (raw is! Map) return const {};
  return {
    for (final entry in raw.entries)
      entry.key.toString(): Map<String, Object?>.from(entry.value as Map),
  };
}

/// Writes one rating to `preferences/meal-feedback` and, for like/dislike,
/// mirrors it into the profile's explicit liked/disliked ids via
/// [NutritionProfileStore.save] (which atomically syncs the declaration
/// goal). The profile save never touches today's plan.
Future<void> recordMealRating({
  required WidgetRef ref,
  required String recipeId,
  required int recipeRevision,
  required MealRating rating,
  required DiaryDate date,
}) async {
  final db = ref.read(databaseProvider);
  final workspace = LocalWorkspace(db);
  final prefs = (await workspace.read('preferences', 'app'))?.data ?? {};
  final feedback = mealFeedbackOf(prefs);
  final prefsDoc = await workspace.read('preferences', 'app');
  final nextFeedback = {
    ...feedback,
    recipeId: {
      'date': date.toIso(),
      'recipeRevision': recipeRevision,
      'rating': rating.wire,
    },
  };
  await workspace.put(
    requestId: ref.read(idGeneratorProvider).next(),
    collection: 'preferences',
    id: 'app',
    expectedRevision: prefsDoc?.revision ?? 0,
    data: {...prefs, mealFeedbackKey: nextFeedback},
  );

  if (rating == MealRating.tooMuchWork) return;
  final profileDoc =
      await NutritionProfileStore(db).read();
  if (profileDoc == null) return;
  final profile = NutritionProfile.fromJson(profileDoc.data);
  final liked = Set<String>.of(profile.likedRecipeIds);
  final disliked = Set<String>.of(profile.dislikedRecipeIds);
  if (rating == MealRating.like) {
    liked.add(recipeId);
    disliked.remove(recipeId);
  } else {
    disliked.add(recipeId);
    liked.remove(recipeId);
  }
  final updated = profile.copyWith(
    likedRecipeIds: liked,
    dislikedRecipeIds: disliked,
  );
  await NutritionProfileStore(db).save(
    requestId: ref.read(idGeneratorProvider).next(),
    expectedRevision: profileDoc.revision,
    profile: updated,
  );
  ref.invalidate(nutritionProfileProvider);
}

/// Short local preference review shown after Like / Not for me.
///
/// Explains the effect (future planning only) and gives an explicit confirm;
/// the plan itself is never rewritten here.
Future<void> showRatingReviewDialog(
  BuildContext context,
  WidgetRef ref, {
  required String recipeId,
  required int recipeRevision,
  required MealRating rating,
}) async {
  final date = ref.read(todayDiaryDateProvider);
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(tr(
          context,
          rating == MealRating.like ? 'Liked' : 'Not for you',
          rating == MealRating.like ? 'Gostou' : 'Não é para si')),
      content: Text(tr(
          context,
          'Future plans will prefer or avoid this meal. Today’s plan stays as it is.',
          'Planos futuros vão preferir ou evitar esta refeição. O plano de hoje mantém-se como está.')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'Undo', 'Anular')),
        ),
        FilledButton(
          key: const Key('confirmRating'),
          onPressed: () async {
            await recordMealRating(
              ref: ref,
              recipeId: recipeId,
              recipeRevision: recipeRevision,
              rating: rating,
              date: date,
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(tr(context, 'Save preference', 'Guardar preferência')),
        ),
      ],
    ),
  );
}

/// The Like / Not for me / Too much work row used in meal detail.
class MealFeedbackRow extends ConsumerWidget {
  const MealFeedbackRow({
    super.key,
    required this.recipeId,
    required this.recipeRevision,
    this.currentRating,
  });

  final String recipeId;
  final int recipeRevision;
  final MealRating? currentRating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {

    void act(MealRating rating) async {
      await showRatingReviewDialog(
        context,
        ref,
        recipeId: recipeId,
        recipeRevision: recipeRevision,
        rating: rating,
      );
    }

    return Wrap(spacing: 8, runSpacing: 8, children: [
      OutlinedButton.icon(
        key: const Key('mealLike'),
        onPressed: () => act(MealRating.like),
        icon: Icon(currentRating == MealRating.like
            ? Icons.thumb_up
            : Icons.thumb_up_outlined),
        label: Text(tr(context, 'Like', 'Gosto')),
      ),
      OutlinedButton.icon(
        key: const Key('mealDislike'),
        onPressed: () => act(MealRating.dislike),
        icon: Icon(currentRating == MealRating.dislike
            ? Icons.thumb_down
            : Icons.thumb_down_outlined),
        label: Text(tr(context, 'Not for me', 'Não é para mim')),
      ),
      TextButton(
        key: const Key('mealTooMuchWork'),
        onPressed: () async {
          final date = ref.read(todayDiaryDateProvider);
          await recordMealRating(
            ref: ref,
            recipeId: recipeId,
            recipeRevision: recipeRevision,
            rating: MealRating.tooMuchWork,
            date: date,
          );
        },
        child: Text(tr(context, 'Too much work', 'Demasiado trabalho')),
      ),
    ]);
  }
}

/// Skippable weekly check-in: which meals worked, which were too
/// time-consuming, and whether to prefer more variety.
///
/// Records explicit preferences only. It takes no logging-completeness
/// prerequisite and never changes a calorie target; the user may then ask
/// for a next-week draft. `preferVariety` is saved on the profile only when
/// the user explicitly selects it.
class WeeklyCheckInSheet extends ConsumerStatefulWidget {
  const WeeklyCheckInSheet({super.key});

  @override
  ConsumerState<WeeklyCheckInSheet> createState() =>
      _WeeklyCheckInSheetState();
}

class _WeeklyCheckInSheetState extends ConsumerState<WeeklyCheckInSheet> {
  final _worked = <String>{};
  final _tooSlow = <String>{};
  bool _variety = false;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr(context, 'Weekly check-in', 'Balanço semanal')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(
                  context,
                  'Tell us what worked. You can skip this anytime.',
                  'Diga-nos o que funcionou. Pode saltar isto quando quiser.')),
              const SizedBox(height: 8),
              Text(tr(context, 'Worked well', 'Funcionou bem'),
                  style: Theme.of(context).textTheme.titleSmall),
              if (_worked.isEmpty)
                Text(tr(context, 'Tap a meal chip below to mark it.', 'Toque numa refeição abaixo para a marcar.'),
                    style: Theme.of(context).textTheme.bodySmall),
              Wrap(spacing: 8, children: [
                for (final id in _worked)
                  Chip(label: Text(id), onDeleted: () => setState(() => _worked.remove(id))),
              ]),
              const SizedBox(height: 8),
              Text(tr(context, 'Too time-consuming', 'Demasiado demorado'),
                  style: Theme.of(context).textTheme.titleSmall),
              Wrap(spacing: 8, children: [
                for (final id in _tooSlow)
                  Chip(label: Text(id), onDeleted: () => setState(() => _tooSlow.remove(id))),
              ]),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('weeklyVariety'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr(context, 'Prefer more variety', 'Prefiro mais variedade')),
                value: _variety,
                onChanged: (v) => setState(() => _variety = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('weeklyCheckInSkip'),
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'Skip', 'Saltar')),
        ),
        FilledButton(
          key: const Key('weeklyCheckInSave'),
          onPressed: _saving
              ? null
              : () async {
                  setState(() => _saving = true);
                  try {
                    await _save();
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    if (context.mounted) showFailure(context, e);
                  } finally {
                    if (context.mounted) setState(() => _saving = false);
                  }
                },
          child: Text(tr(context, 'Save check-in', 'Guardar balanço')),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final profileDoc = await NutritionProfileStore(db).read();
    final date = ref.read(todayDiaryDateProvider);
    for (final id in _worked) {
      await recordMealRating(
        ref: ref,
        recipeId: id,
        recipeRevision: 1,
        rating: MealRating.like,
        date: date,
      );
    }
    for (final id in _tooSlow) {
      await recordMealRating(
        ref: ref,
        recipeId: id,
        recipeRevision: 1,
        rating: MealRating.tooMuchWork,
        date: date,
      );
    }
    if (_variety && profileDoc != null) {
      final profile = NutritionProfile.fromJson(profileDoc.data);
      await NutritionProfileStore(db).save(
        requestId: ref.read(idGeneratorProvider).next(),
        expectedRevision: profileDoc.revision,
        profile: profile.copyWith(preferVariety: true),
      );
      ref.invalidate(nutritionProfileProvider);
    }
  }
}

/// Opens the weekly check-in sheet. Returns true when the user saved it.
Future<bool> showWeeklyCheckIn(BuildContext context) async =>
    (await showDialog<bool>(
      context: context,
      builder: (_) => const WeeklyCheckInSheet(),
    )) ??
    false;
