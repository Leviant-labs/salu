import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart' hide MealSlot;

import '../onboarding/onboarding_screen.dart';
import '../onboarding/planning_profile.dart';
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
    this.now,
    this.recipePlanning,
    this.onLogRecipe,
  });

  final WeekPlanStore? store;
  final PlanningProfileStore? profileStore;
  final PlanSuggestionSource? suggestions;
  final DateTime Function()? now;
  final RecipePlanning? recipePlanning;
  final Future<void> Function(
          RecipeVersion recipe, double servings, MealSlot slot, DiaryDate date)?
      onLogRecipe;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

enum _Workspace { meals, groceries }

class _PlanScreenState extends State<PlanScreen> {
  WeekPlanStore get _store => widget.store ?? WeekPlanStore.local;
  PlanningProfileStore get _profiles =>
      widget.profileStore ?? PlanningProfileStore.local;
  PlanSuggestionSource get _suggestions =>
      widget.suggestions ?? const AssistantPlanSuggestionSource();
  DateTime get _now => (widget.now ?? DateTime.now)();

  final _scroll = ScrollController();
  late DateTime _week = startOfPlanWeek(_now);
  WeekPlan? _plan;
  _Workspace _workspace = _Workspace.meals;
  bool _loadFailed = false;
  bool _saving = false;
  bool _drafting = false;
  bool _reviewing = false;
  PlanningProfile? _profile;
  Map<String, RecipeVersion> _recipes = const {};
  bool get _busy => _plan == null || _saving || _drafting || _reviewing;

  @override
  void initState() {
    super.initState();
    _load(_week);
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await _profiles.load();
      if (mounted) setState(() => _profile = profile);
    } catch (_) {
      // A missing profile does not prevent editing this week.
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load(DateTime week) async {
    try {
      final plan = await _store.load(week);
      final recipes = await widget.recipePlanning?.library.load();
      if (!mounted || _week != week) return;
      setState(() {
        _plan = plan;
        if (recipes != null) {
          _recipes = {for (final recipe in recipes) recipe.key: recipe};
        }
      });
    } catch (_) {
      if (!mounted || _week != week) return;
      setState(() => _loadFailed = true);
    }
  }

  void _goToWeek(DateTime week) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _week = week;
      _plan = null;
      _loadFailed = false;
    });
    _load(week);
  }

  Future<void> _save(WeekPlan next) async {
    setState(() => _saving = true);
    try {
      await _store.save(next);
      if (mounted) {
        setState(() => _plan = next.copyWith(revision: next.revision + 1));
      }
    } catch (_) {
      if (mounted) {
        _notify('Could not save this change. Your previous plan is unchanged.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
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
      setState(
          () => _recipes = {for (final recipe in recipes) recipe.key: recipe});
      final edit = await chooseRecipe(
          context, planner.eligible(recipes, profile), saved);
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

  void _editPreferences() =>
      Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => FoodPreferencesScreen(store: _profiles),
        ),
      );

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
                        ? 'Salu sends your food preferences and request to OpenAI to choose meals. It may include recipe names, locally suggested portions and existing meal names. Weight, targets and activity stay on this device.'
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
    setState(() => _drafting = true);
    try {
      final preferences = (await _profiles.load()).preferences;
      if (!mounted) return;
      final planner = widget.recipePlanning;
      if (planner != null) {
        final profile = await _profiles.load();
        final recipes = await planner.library.load();
        final proposal = await planner.propose(plan, recipes, profile, request,
            useAI: useAI);
        if (!mounted || !identical(plan, _plan)) return;
        setState(() =>
            _recipes = {for (final recipe in recipes) recipe.key: recipe});
        if (proposal.isEmpty) {
          _notify(
              'No eligible recipe changes were found for these slots. Your plan is unchanged.');
          return;
        }
        await _confirmRecipePlan(
            plan, {...plan.meals, ...proposal}, proposal.keys.toSet(), profile);
        return;
      }
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
    } on PlanAssistantNotConnected {
      if (mounted) {
        _notify('Connect an assistant in Settings to request suggestions.');
      }
    } catch (_) {
      if (mounted) {
        _notify('Could not get usable suggestions. Nothing was added.');
      }
    } finally {
      if (mounted) setState(() => _drafting = false);
    }
  }

  Future<void> _confirmRecipePlan(
      WeekPlan before,
      Map<MealPosition, PlannedMeal> meals,
      Set<MealPosition> changes,
      PlanningProfile profile) async {
    final next = reconcileGroceries(before.copyWith(meals: meals), _recipes);
    setState(() => _reviewing = true);
    final accepted = await reviewRecipePlan(
        context, before, next, _recipes, profile, changes);
    if (!mounted) return;
    setState(() => _reviewing = false);
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
    await _save(next);
  }

  Future<String?> _confirmDraft(WeekPlan plan, PlanDraft selected) async {
    try {
      final preferences = (await _profiles.load()).preferences;
      if (selected.mentionsExclusion(preferences)) {
        return 'A selected item mentions a food marked “Must exclude”. Edit or deselect it.';
      }
      final updated = selected.applyTo(plan);
      await _store.save(updated);
      if (mounted) setState(() => _plan = updated);
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
              FilledButton.icon(
                onPressed: _busy ? null : () => _editGrocery(),
                icon: const Icon(Icons.add),
                label: const Text('Add grocery item'),
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
        if (meals)
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
