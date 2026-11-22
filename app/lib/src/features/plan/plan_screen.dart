import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart' hide MealSlot;

import '../../assistant/assistant.dart';
import '../onboarding/onboarding_screen.dart';
import '../../theme/tactile_controls.dart';
import '../onboarding/planning_profile.dart';
import 'plan_controller.dart';
import 'plan_draft_preview.dart';
import 'plan_item_editor.dart';
import 'plan_suggestions.dart';
import 'recipe_plan_review.dart';
import 'recipe_planning.dart';
import 'week_plan.dart';

/// Full-width workspace for meals and shopping, within the app's Plan tab.
class PlanScreen extends StatefulWidget {
  const PlanScreen({
    super.key,
    this.store,
    this.profileStore,
    this.suggestions,
    this.assistant,
    this.now,
    this.recipePlanning,
    this.onLogRecipe,
  });

  final WeekPlanStore? store;
  final PlanningProfileStore? profileStore;
  final PlanSuggestionSource? suggestions;
  final SaluAssistant? assistant;
  final DateTime Function()? now;
  final RecipePlanning? recipePlanning;
  final Future<void> Function(
          RecipeVersion recipe, double servings, MealSlot slot, DiaryDate date)?
      onLogRecipe;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

enum _Workspace { meals, groceries }

final class _DisconnectedPlanSuggestionSource implements PlanSuggestionSource {
  const _DisconnectedPlanSuggestionSource();

  @override
  Future<PlanDraft> suggest(
    FoodPreferences preferences, {
    PlanSuggestionContext? context,
  }) =>
      Future.error(const PlanAssistantNotConnected());
}

class _PlanScreenState extends State<PlanScreen> {
  WeekPlanStore get _store => widget.store ?? WeekPlanStore.local;
  PlanningProfileStore get _profiles =>
      widget.profileStore ?? PlanningProfileStore.local;
  PlanSuggestionSource get _suggestions =>
      widget.suggestions ??
      (widget.assistant != null
          ? AssistantPlanSuggestionSource(assistant: widget.assistant!)
          : const _DisconnectedPlanSuggestionSource());
  DateTime get _now => (widget.now ?? DateTime.now)();

  final _scroll = ScrollController();
  late final PlanController _controller = PlanController(
    store: _store,
    profileStore: _profiles,
    recipePlanning: widget.recipePlanning,
    suggestions: _suggestions,
    initialWeek: startOfPlanWeek(_now),
  )..addListener(_onControllerChanged);

  DateTime get _week => _controller.week;
  WeekPlan? get _plan => _controller.plan;
  _Workspace _workspace = _Workspace.meals;
  bool get _loadFailed => _controller.loadFailed;
  bool get _saving => _controller.saving;
  bool get _drafting => _controller.drafting;
  bool get _reviewing => _controller.reviewing;
  PlanningProfile? get _profile => _controller.profile;
  Map<String, RecipeVersion> get _recipes => _controller.recipes;
  bool get _busy => _controller.busy;

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _load(_week);
    _loadProfile();
  }

  Future<void> _loadProfile() => _controller.loadProfile();

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load(DateTime week) => _controller.loadWeek(week);

  void _goToWeek(DateTime week) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(week);
  }

  Future<void> _save(WeekPlan next) async {
    final saved = await _controller.savePlan(next);
    if (!saved && mounted) {
      _notify('Could not save this change. Your previous plan is unchanged.');
    }
  }

  void _notify(String message) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _editMeal(MealPosition position) async {
    final plan = _plan!;
    final saved = plan.meals[position];
    final planner = widget.recipePlanning;
    if (planner != null) {
      final profile = await _profiles.load();
      final recipes = await planner.library.load();
      if (!mounted || !identical(plan, _plan)) return;
      final byKey = {for (final recipe in recipes) recipe.key: recipe};
      _controller.updateRecipes(recipes);
      final latest = <String, RecipeVersion>{};
      for (final recipe in recipes) {
        if ((latest[recipe.id]?.version ?? 0) < recipe.version) {
          latest[recipe.id] = recipe;
        }
      }
      final currentConflicts = saved?.pinned == true
          ? findPinnedConflicts(
                WeekPlan(plan.monday, meals: {position: saved!}),
                byKey,
                profile,
              ).firstOrNull?.reasons ??
              const <String>[]
          : const <String>[];
      final edit = await chooseRecipe(
        context,
        planner.eligible(latest.values, profile),
        saved,
        ineligibleReasons: planner.ineligibilityReasons(latest.values, profile),
        currentConflictReasons: currentConflicts,
        onEditPreferences: _editPreferences,
      );
      if (!mounted || edit == null || !identical(plan, _plan)) return;
      final meals = {...plan.meals};
      if (edit.meal case final meal?) {
        meals[position] = meal;
      } else {
        meals.remove(position);
      }
      await _confirmRecipePlan(plan, meals, {position}, profile);
      return;
    }
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(plan.dateFor(position.day));
    final edit = await editPlanItem(
      context,
      title: '${position.slot.label} · $date',
      grocery: false,
      name: saved?.name ?? '',
      details: saved?.details ?? '',
      allowDelete: saved != null,
    );
    if (!mounted || edit == null) return;
    final meals = Map<MealPosition, PlannedMeal>.of(plan.meals);
    final name = edit.name;
    if (name == null) {
      meals.remove(position);
    } else {
      meals[position] = PlannedMeal(name, details: edit.details);
    }
    await _save(plan.copyWith(meals: meals));
  }

  Future<void> _editGrocery([int? index]) async {
    final plan = _plan!;
    final item = index == null ? null : plan.groceries[index];
    final edit = await editPlanItem(
      context,
      title: index == null ? 'Add grocery item' : 'Edit grocery item',
      grocery: true,
      name: item?.name ?? '',
      details: item?.amount ?? '',
      allowDelete: index != null,
    );
    if (!mounted || edit == null) return;
    final groceries = plan.groceries.toList();
    final name = edit.name;
    if (name == null) {
      if (index == null) return;
      groceries.removeAt(index);
    } else {
      final next = GroceryItem(
        name,
        amount: edit.details,
        checked: item?.checked ?? false,
        requirementKey: item?.requirementKey,
        requiredGrams: item?.requiredGrams,
        override: item?.requirementKey != null,
        changed: item?.changed ?? false,
      );
      if (index == null) {
        groceries.add(next);
      } else {
        groceries[index] = next;
      }
    }
    await _save(plan.copyWith(groceries: groceries));
  }

  void _checkGrocery(int index, bool checked) {
    final plan = _plan!;
    final next = plan.groceries.toList();
    next[index] = next[index].withChecked(checked);
    _save(plan.copyWith(groceries: next));
  }

  Future<void> _editPreferences() async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FoodPreferencesScreen(store: _profiles),
      ),
    );
    if (mounted) await _loadProfile();
  }

  Future<void> _editProfile() async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
          builder: (context) => OnboardingScreen(
                store: _profiles,
                onSaved: () => Navigator.of(context).pop(),
              )),
    );
    if (mounted) await _loadProfile();
  }

  Future<void> _requestDraft({bool useAI = true}) async {
    final plan = _plan!;
    final providerLabel = useAI
        ? await (widget.assistant ?? widget.recipePlanning?.assistant)
            ?.activeProviderLabel
        : null;
    if (!mounted) return;
    final destination = providerLabel ?? 'your selected AI provider';
    var text = '';
    final keep = <int>{};
    final request = await showDialog<PlanSuggestionContext>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: Text(useAI
                    ? 'Request meal suggestions?'
                    : 'Fill empty slots locally'),
                scrollable: true,
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(useAI
                        ? 'Salu sends your food preferences and request to $destination to choose meals. It may include recipe names, locally suggested portions and existing meal names. Weight, targets and activity stay on this device. Provider plan limits or user-funded API billing may apply.'
                        : 'Choose meals from your local recipes and declared targets. Existing meals stay in place.'),
                    if (useAI)
                      TextField(
                        maxLength: PlanSuggestionContext.maxRequestLength,
                        maxLines: 2,
                        decoration: const InputDecoration(
                            labelText: 'What should change?',
                            hintText: 'Quicker dinners, no carbonara'),
                        onChanged: (value) => update(() => text = value),
                      ),
                    const Text('Keep these days unchanged'),
                    Wrap(spacing: 4, children: [
                      for (final (day, label) in [
                        'Mon',
                        'Tue',
                        'Wed',
                        'Thu',
                        'Fri',
                        'Sat',
                        'Sun'
                      ].indexed)
                        FilterChip(
                            label: Text(label),
                            selected: keep.contains(day),
                            onSelected: (selected) => update(() {
                                  if (selected) {
                                    keep.add(day);
                                  } else {
                                    keep.remove(day);
                                  }
                                })),
                    ]),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: PlanSuggestionContext.validateRequest(text) !=
                            null
                        ? null
                        : () {
                            try {
                              Navigator.of(context).pop(
                                  PlanSuggestionContext.forWeek(plan,
                                      request: text, keepDays: keep));
                            } on FormatException {
                              Navigator.of(context).pop();
                              _notify('Could not prepare the plan context.');
                            }
                          },
                    child: const Text('Request suggestions'),
                  ),
                ],
              )),
    );
    if (!mounted || request == null || _busy) return;
    _controller.setDrafting(true);
    List<PinnedMealConflict>? pinnedConflictsToReport;
    ({
      Map<RecipeVersion, List<String>> excluded,
      List<String> unresolved,
    })? emptyReport;
    try {
      final preferences = (await _profiles.load()).preferences;
      if (!mounted) return;
      final planner = widget.recipePlanning;
      if (planner != null) {
        final profile = await _profiles.load();
        final recipes = await planner.library.load();
        if (!mounted || !identical(plan, _plan)) return;
        _controller.updateRecipes(recipes);
        final proposal = await planner.propose(plan, recipes, profile, request,
            useAI: useAI);
        if (!mounted || !identical(plan, _plan)) return;
        if (proposal.isEmpty) {
          final latest = <String, RecipeVersion>{};
          for (final recipe in recipes) {
            if ((latest[recipe.id]?.version ?? 0) < recipe.version) {
              latest[recipe.id] = recipe;
            }
          }
          final limit = RecipePlanning.parseCookingLimit(request.request);
          final hasEligible = planner
              .eligible(latest.values, profile, cookingLimit: limit)
              .isNotEmpty;
          final unresolved =
              resolveStrictAllergens(profile.preferences.allergenItems)
                  .unresolved;
          if (!hasEligible || unresolved.isNotEmpty) {
            final excluded = planner.ineligibilityReasons(
              latest.values,
              profile,
              cookingLimit: limit,
            );
            emptyReport = (excluded: excluded, unresolved: unresolved);
          } else {
            _notify(
                'No eligible recipe changes were found for these slots. Your plan is unchanged.');
          }
        } else {
          await _confirmRecipePlan(plan, {...plan.meals, ...proposal},
              proposal.keys.toSet(), profile);
        }
      } else {
        final reply = await _suggestions.suggest(preferences,
            context: request.isEmpty ? null : request);
        final draft = reply.withoutMealsOn(request.keepDays);
        if (!mounted) return;
        if (draft.isEmpty) {
          _notify(
            'No suggestions were returned. You can still build your plan by hand.',
          );
        } else if (draft.mentionsExclusion(preferences)) {
          _notify(
            'The suggestions mentioned a food marked “Must exclude”. Nothing was added.',
          );
        } else {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => PlanDraftPreview(
                plan: plan,
                draft: draft,
                onConfirm: (selected) => _confirmDraft(plan, selected),
              ),
            ),
          );
        }
      }
    } on PinnedMealConflictException catch (error) {
      if (mounted) {
        pinnedConflictsToReport = error.conflicts;
      }
    } on PlanAssistantNotConnected {
      if (mounted) {
        _notify('Connect an AI provider in Settings to request suggestions.');
      }
    } on SaluAssistantException catch (error) {
      if (mounted) {
        _notify(error.message);
      }
    } catch (_) {
      if (mounted) {
        _notify('Could not get usable suggestions. Nothing was added.');
      }
    } finally {
      if (mounted) _controller.setDrafting(false);
    }
    if (!mounted) return;
    if (pinnedConflictsToReport != null) {
      await _showPinnedConflictsDialog(pinnedConflictsToReport);
    } else if (emptyReport != null) {
      await _showIneligibilityDialog(
        title: 'No eligible recipes found',
        excluded: emptyReport.excluded,
        unresolved: emptyReport.unresolved,
      );
    }
  }

  Future<void> _showPinnedConflictsDialog(
      List<PinnedMealConflict> conflicts) async {
    final openPreferences = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pinned meal conflicts with exclusions'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A pinned meal cannot override your strict allergies or exclusions. Replace, unpin, or remove the conflicting slot, or update your food preferences.',
            ),
            const SizedBox(height: 10),
            for (final conflict in conflicts)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${conflict.position.slot.label}: ${conflict.meal.name} — ${conflict.reasons.map(describeIneligibilityReason).join(' ')}',
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Dismiss'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Edit food preferences'),
          ),
        ],
      ),
    );
    if (openPreferences == true && mounted) {
      await _editPreferences();
    }
  }

  Future<void> _showIneligibilityDialog({
    required String title,
    required Map<RecipeVersion, List<String>> excluded,
    required List<String> unresolved,
  }) async {
    final openPreferences = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (unresolved.isNotEmpty) ...[
              Text(
                'Unrecognized strict allergy term(s): ${unresolved.join(', ')}. Select a canonical allergen category or move ingredient names to "Must exclude".',
              ),
              const SizedBox(height: 8),
            ],
            for (final entry in excluded.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${entry.key.name}: ${entry.value.map(describeIneligibilityReason).join(' ')}',
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Edit food preferences'),
          ),
        ],
      ),
    );
    if (openPreferences == true && mounted) {
      await _editPreferences();
    }
  }

  Future<void> _confirmRecipePlan(
      WeekPlan before,
      Map<MealPosition, PlannedMeal> meals,
      Set<MealPosition> changes,
      PlanningProfile profile) async {
    final next = reconcileGroceries(before.copyWith(meals: meals), _recipes);
    _controller.setReviewing(true);
    final accepted = await reviewRecipePlan(
        context, before, next, _recipes, profile, changes);
    if (!mounted) return;
    _controller.setReviewing(false);
    if (!accepted || !identical(before, _plan)) {
      return;
    }
    final current = await _profiles.load();
    if (!mounted || !identical(before, _plan)) return;
    if (current.targets.length != profile.targets.length ||
        current.targets.entries
            .any((entry) => profile.targets[entry.key] != entry.value)) {
      _notify(
          'Your declared target changed. Review this plan again before saving.');
      return;
    }
    final allowed = widget.recipePlanning!
        .eligible(_recipes.values, current)
        .map((recipe) => recipe.key)
        .toSet();
    for (final position in changes) {
      final meal = next.meals[position];
      if (meal?.recipeKey != null && !allowed.contains(meal!.recipeKey)) {
        _notify(
            'The food exclusions changed. Review a new plan before saving.');
        return;
      }
    }
    final beforeConflicts = findPinnedConflicts(before, _recipes, current);
    final afterConflicts = findPinnedConflicts(next, _recipes, current);
    final changedHasConflict =
        afterConflicts.any((conflict) => changes.contains(conflict.position));
    final resolvedExistingConflict = beforeConflicts.isNotEmpty &&
        afterConflicts.length < beforeConflicts.length &&
        !changedHasConflict;
    if (afterConflicts.isNotEmpty && !resolvedExistingConflict) {
      _notify(
          'A pinned meal conflicts with your strict allergies or exclusions. Update or unpin it before saving.');
      return;
    }
    await _save(next);
  }

  Future<String?> _confirmDraft(WeekPlan plan, PlanDraft selected) async {
    try {
      final preferences = (await _profiles.load()).preferences;
      if (selected.mentionsExclusion(preferences)) {
        return 'A selected item mentions a food marked “Must exclude”. Edit or deselect it.';
      }
      final updated = selected.applyTo(plan);
      final saved = await _controller.savePlan(updated);
      if (!saved) {
        return 'Could not save the selected items. Your draft is still here.';
      }
      return null;
    } catch (_) {
      return 'Could not save the selected items. Your draft is still here.';
    }
  }

  Widget _weekBar(BuildContext context) {
    final dates = MaterialLocalizations.of(context);
    final thisWeek = startOfPlanWeek(_now);
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous week',
          onPressed: _saving || _drafting
              ? null
              : () => _goToWeek(_week.subtract(const Duration(days: 7))),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                '${dates.formatShortDate(_week)} – ${dates.formatShortDate(_week.add(const Duration(days: 6)))}',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              if (_week != thisWeek)
                TextButton(
                  onPressed:
                      _saving || _drafting ? null : () => _goToWeek(thisWeek),
                  child: const Text('Back to this week'),
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Next week',
          onPressed: _saving || _drafting
              ? null
              : () => _goToWeek(_week.add(const Duration(days: 7))),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  Widget _dayCard(BuildContext context, WeekPlan plan, int day) {
    final date = plan.dateFor(day);
    final today = DateUtils.isSameDay(date, _now);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '${MaterialLocalizations.of(context).formatMediumDate(date)}${today ? ' · Today' : ''}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_profile?.targets.isNotEmpty == true &&
                widget.recipePlanning != null)
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    targetSummary(plan.meals, day, _recipes, _profile!.targets),
                  )),
            LayoutBuilder(
              builder: (context, viewport) {
                final tiles = [
                  for (final slot in MealSlot.values)
                    _mealTile(plan, (day: day, slot: slot)),
                ];
                return viewport.maxWidth >= 660
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final tile in tiles) Expanded(child: tile),
                        ],
                      )
                    : Column(children: tiles);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _mealTile(WeekPlan plan, MealPosition position) {
    final meal = plan.meals[position];
    return ListTile(
      key: ValueKey('meal-${position.day}-${position.slot.name}'),
      enabled: !_busy,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Text(position.slot.label),
      subtitle: Text(
        meal == null
            ? 'Add meal'
            : [
                meal.name,
                meal.details,
              ].where((value) => value.isNotEmpty).join('\n'),
      ),
      trailing: widget.onLogRecipe != null &&
              plan.dateFor(position.day).compareTo(
                      DateTime.utc(_now.year, _now.month, _now.day)) <=
                  0 &&
              _recipes[meal?.recipeKey] != null
          ? IconButton(
              tooltip: 'Log separately',
              icon: const Icon(Icons.restaurant_menu_outlined),
              onPressed: _busy
                  ? null
                  : () => widget.onLogRecipe!(
                      _recipes[meal!.recipeKey]!,
                      meal.servings!,
                      position.slot,
                      DiaryDate.ofLocal(plan.dateFor(position.day))))
          : Icon(meal?.pinned == true
              ? Icons.push_pin
              : meal == null
                  ? Icons.add
                  : Icons.edit_outlined),
      onTap: _busy ? null : () => _editMeal(position),
    );
  }

  Widget _groceryRow(GroceryItem item, int index) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: CheckboxListTile(
                value: item.checked,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(item.name),
                subtitle: item.amount.isEmpty && !item.changed
                    ? null
                    : Text(
                        '${item.amount}${item.changed ? ' · Required amount increased; check purchase' : ''}'),
                onChanged: _busy
                    ? null
                    : (value) => _checkGrocery(index, value ?? false),
              ),
            ),
            IconButton(
              tooltip: 'Edit ${item.name}',
              onPressed: _busy ? null : () => _editGrocery(index),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
      );

  Widget _content(BuildContext context) {
    final plan = _plan;
    if (plan == null) {
      return Center(
        child: _loadFailed
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not open this week’s plan.'),
                  TextButton(
                    onPressed: () => _goToWeek(_week),
                    child: const Text('Retry'),
                  ),
                ],
              )
            : const CircularProgressIndicator(),
      );
    }
    final meals = _workspace == _Workspace.meals;
    final checked = plan.groceries.where((item) => item.checked).length;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (!meals)
              SaluTactileButton(
                onPressed: _busy ? null : () => _editGrocery(),
                icon: const Icon(Icons.add),
                child: const Text('Add grocery item'),
              ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _editPreferences,
              icon: const Icon(Icons.tune),
              label: const Text('Food preferences'),
            ),
            if (meals && widget.recipePlanning != null)
              OutlinedButton(
                  onPressed: _busy ? null : () => _requestDraft(useAI: false),
                  child: const Text('Fill empty slots offline')),
            OutlinedButton.icon(
              onPressed: _busy ? null : _requestDraft,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: Text(
                _drafting
                    ? 'Requesting suggestions…'
                    : 'Suggest meals & groceries',
              ),
            ),
          ],
        ),
        if ((_drafting && !_reviewing) || _saving)
          const LinearProgressIndicator(),
        if (meals) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Planning profile'),
            subtitle: Text(switch (_profile?.dailyEnergyKcal) {
              final target? =>
                'Your declared target: ${target.toStringAsFixed(0)} kcal/day',
              null => 'Set your starting weight and goals',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _editProfile,
          ),
          if (widget.recipePlanning != null && _profile != null) ...[
            if (findPinnedConflicts(plan, _recipes, _profile!)
                case final conflicts when conflicts.isNotEmpty)
              Card(
                key: const ValueKey('pinned-conflicts-card'),
                color: Theme.of(context).colorScheme.errorContainer,
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pinned meal conflict',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                      ),
                      const SizedBox(height: 4),
                      for (final conflict in conflicts)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '${conflict.position.slot.label}: ${conflict.meal.name} — ${conflict.reasons.map(describeIneligibilityReason).join(' ')}',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                          ),
                        ),
                      Text(
                        'Tap a conflicting slot to replace, unpin, or remove it.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _busy ? null : _editPreferences,
                          child: const Text('Edit food preferences'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (resolveStrictAllergens(_profile!.preferences.allergenItems)
                    .unresolved
                case final unresolved when unresolved.isNotEmpty)
              Card(
                key: const ValueKey('unresolved-allergens-card'),
                color: Theme.of(context).colorScheme.errorContainer,
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Unrecognized strict allergy term(s): ${unresolved.join(', ')}. '
                        'Select a canonical category or move ingredient names to "Must exclude" — recipes stay excluded until resolved.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _busy ? null : _editPreferences,
                          child: const Text('Edit food preferences'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
        const SizedBox(height: 12),
        if (meals)
          for (var day = 0; day < 7; day++) _dayCard(context, plan, day)
        else if (plan.groceries.isEmpty)
          const Text(
            'No groceries for this week yet. Add items by hand or review assistant suggestions.',
          )
        else ...[
          Text(
            '$checked of ${plan.groceries.length} checked off',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < plan.groceries.length; i++)
            _groceryRow(plan.groceries[i], i),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Column(
          children: [
            _weekBar(context),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<_Workspace>(
                  segments: const [
                    ButtonSegment(
                        value: _Workspace.meals, label: Text('Meals')),
                    ButtonSegment(
                      value: _Workspace.groceries,
                      label: Text('Groceries'),
                    ),
                  ],
                  selected: {_workspace},
                  onSelectionChanged: (value) {
                    if (value.single == _workspace) return;
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                    setState(() => _workspace = value.single);
                  },
                ),
              ),
            ),
            Expanded(child: _content(context)),
          ],
        ),
      );
}
