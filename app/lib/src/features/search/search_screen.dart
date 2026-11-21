import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../providers.dart';
import '../meals/meal_editor.dart';
import '../meals/meal_editor_data.dart';
import '../plan/recipe_library.dart';
import '../plan/cooked_batches.dart';
import 'food_library.dart';

/// Local food search, with editable portions in the meal editor.
class SearchScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  String _query = '';
  Set<String> _favorites = const {};
  FoodLibrary get _library => FoodLibrary(ref.read(documentStoreProvider));

  @override
  void initState() {
    super.initState();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    try {
      final saved = await _library.favorites();
      if (mounted) setState(() => _favorites = saved);
    } catch (_) {/* Catalogue search remains usable. */}
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openMeal(
      {Food? food,
      String description = '',
      List<PhotoMealItem> items = const []}) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => MealEditor(
        repository: ref.read(photoMealRepositoryProvider),
        assistant: ref.read(assistantProvider),
        media: ref.read(managedMediaStoreProvider),
        activeEstimates: ref.read(activeMealEstimatesProvider),
        estimateStatusStore: ref.read(mealEstimateStatusStoreProvider),
        foods: ref.read(foodRepositoryProvider),
        date: ref.read(todayDiaryDateProvider),
        newId: ref.read(idGeneratorProvider).next,
        initialFood: food,
        initialDescription: description,
        initialItems: items,
        library: _library,
      ),
    ));
    if (mounted) ref.invalidate(todayMealsProvider);
  }

  Future<void> _saveFood({SavedFood? saved}) async {
    final result = await editSavedFood(
        context, saved?.id ?? ref.read(idGeneratorProvider).next(),
        saved: saved);
    if (result == null || !mounted) return;
    try {
      await _library.saveFood(result);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not save. The barcode may already be in your library.')));
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Food saved in your library.')));
    }
  }

  Future<void> _openSavedFood(SavedFood food) async {
    final item = await pickSavedFoodPortion(context, food);
    if (mounted && item != null) await _openMeal(items: [item]);
  }

  Future<void> _openLibrary() async {
    final repo = ref.read(photoMealRepositoryProvider);
    final recipes = RecipeLibrary(
        ref.read(foodRepositoryProvider), ref.read(documentStoreProvider));
    try {
      final foods = await _library.foods();
      final meals = await _library.meals();
      final recipeList = await recipes.load();
      final today = ref.read(todayDiaryDateProvider);
      final recent = (await Future.wait(
              [for (var i = 0; i < 7; i++) repo.listFor(today.addDays(-i))]))
          .expand((group) => group.reversed)
          .where((meal) => meal.items.isNotEmpty)
          .take(12)
          .toList();
      final favorites = (await Future.wait(
              _favorites.map(ref.read(foodRepositoryProvider).findById)))
          .whereType<Food>()
          .toList();
      if (!mounted) return;
      final action = await showDialog<Future<void> Function()>(
          context: context,
          builder: (context) =>
              SimpleDialog(title: const Text('Your food library'), children: [
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Saved foods and favorite catalogue items')),
                for (final food in foods)
                  SimpleDialogOption(
                      onPressed: () =>
                          Navigator.pop(context, () => _openSavedFood(food)),
                      child: Text(food.name)),
                for (final food in favorites)
                  SimpleDialogOption(
                      onPressed: () =>
                          Navigator.pop(context, () => _openMeal(food: food)),
                      child: Text('★ ${food.name}')),
                if (foods.isNotEmpty)
                  const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Edit saved foods')),
                for (final food in foods)
                  SimpleDialogOption(
                      onPressed: () =>
                          Navigator.pop(context, () => _saveFood(saved: food)),
                      child: Text('Edit ${food.name}')),
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Recipes and saved meals')),
                for (final recipe in recipeList)
                  SimpleDialogOption(
                      onPressed: () =>
                          Navigator.pop(context, () => _useRecipe(recipe)),
                      child: Text(recipe.version == 1
                          ? recipe.name
                          : '${recipe.name} · v${recipe.version}')),
                for (final recipe in recipeList.where((recipe) =>
                    recipeList.every((other) =>
                        other.id != recipe.id ||
                        other.version <= recipe.version)))
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, () async {
                            final isLocal =
                                recipe.id.startsWith('local-recipe:');
                            await createRecipe(
                                this.context,
                                recipes,
                                isLocal
                                    ? recipe.id
                                    : 'local-recipe:${ref.read(idGeneratorProvider).next()}',
                                previous: recipe,
                                version: isLocal ? recipe.version + 1 : 1);
                          }),
                      child: Text('Adapt ${recipe.name}')),
                for (final meal in meals)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(
                          context,
                          () => _openMeal(
                              description: meal.name, items: meal.items)),
                      child: Text(meal.name)),
                const Padding(
                    padding: EdgeInsets.all(12), child: Text('Recent meals')),
                for (final meal in recent)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(
                          context,
                          () => _openMeal(
                              description: meal.items
                                  .map((item) => item.name)
                                  .join(', '),
                              items: meal.items
                                  .map((item) => PhotoMealItem(
                                      name: item.name,
                                      portion: item.portion,
                                      nutrients: item.nutrients,
                                      source: item.source,
                                      reviewIssues: item.reviewIssues))
                                  .toList())),
                      child: Text(
                          '${meal.date.toIso()} · ${meal.items.map((item) => item.name).join(', ')}')),
              ]));
      if (mounted) await action?.call();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not load your food library.')));
      }
    }
  }

  Future<void> _useRecipe(RecipeVersion recipe) async {
    var text = '1';
    final choice = await showDialog<({double servings, bool batch})>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(recipe.name),
                scrollable: true,
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(recipe.method),
                  if (recipe.finishedGrams != null)
                    Text('Recorded finished weight: ${recipe.finishedGrams} g'),
                  TextFormField(
                      initialValue: text,
                      onChanged: (value) => text = value,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText:
                              'Servings (${recipe.minServings}–${recipe.maxServings})'))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () {
                        final value = mealNumber(text);
                        if (value != null && value > 0) {
                          Navigator.pop(
                              context, (servings: value, batch: true));
                        }
                      },
                      child: const Text('Save cooked batch')),
                  FilledButton(
                      onPressed: () {
                        final value = mealNumber(text);
                        if (value != null && recipe.accepts(value)) {
                          Navigator.pop(
                              context, (servings: value, batch: false));
                        }
                      },
                      child: const Text('Log separately'))
                ]));
    if (!mounted || choice == null) return;
    if (!choice.batch) {
      await _openMeal(
          description: recipe.name, items: recipe.snapshot(choice.servings));
      return;
    }
    var grams = '';
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Record cooked yield'),
                content: TextField(
                    onChanged: (value) => grams = value,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Measured finished weight (g, optional)')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () {
                        if (grams.trim().isEmpty ||
                            (mealNumber(grams) ?? 0) > 0) {
                          Navigator.pop(context, true);
                        }
                      },
                      child: const Text('Save batch'))
                ]));
    if (!mounted || confirmed != true) return;
    await CookedBatches(ref.read(documentStoreProvider)).add(
        ref.read(idGeneratorProvider).next(),
        CookedRecipeBatch(
            recipe: recipe,
            cookedServings: choice.servings,
            finishedGrams: mealNumber(grams)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Batch saved in Leftovers.')));
    }
  }

  Future<void> _leftovers() async {
    final store = CookedBatches(ref.read(documentStoreProvider));
    try {
      final batches = await store.available();
      if (!mounted) return;
      final chosen = await showDialog<StoredBatch>(
          context: context,
          builder: (context) =>
              SimpleDialog(title: const Text('Leftovers'), children: [
                if (batches.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'Save a cooked batch from a recipe to track leftovers.')),
                for (final value in batches)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, value),
                      child: Text(
                          '${value.batch.recipe.name} · ${(value.batch.remainingFraction * value.batch.cookedServings).toStringAsFixed(2)} servings left')),
              ]));
      if (!mounted || chosen == null) return;
      final batch = chosen.batch;
      var units = MealUnit.servings;
      var amount = '1';
      var slot = mealSlotFor('', DateTime.now().hour);
      String? issue;
      final selection = await showDialog<
              ({MealPortion portion, MealSlot slot})>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text('Log ${batch.recipe.name} leftovers'),
                    scrollable: true,
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                          'Logging deducts this portion from the available batch.'),
                      DropdownButton<MealUnit>(
                          value: units,
                          items: [
                            for (final unit in [
                              MealUnit.servings,
                              if (batch.finishedGrams != null) MealUnit.grams
                            ])
                              DropdownMenuItem(
                                  value: unit, child: Text(unit.label))
                          ],
                          onChanged: (value) =>
                              update(() => units = value ?? units)),
                      TextFormField(
                          initialValue: amount,
                          onChanged: (value) => amount = value,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration:
                              const InputDecoration(labelText: 'Amount eaten')),
                      DropdownButton<MealSlot>(
                          value: slot,
                          items: [
                            for (final meal in MealSlot.values)
                              DropdownMenuItem(
                                  value: meal, child: Text(meal.label))
                          ],
                          onChanged: (value) =>
                              update(() => slot = value ?? slot)),
                      if (issue != null) Text(issue!),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () {
                            final n = mealNumber(amount);
                            final portion = n == null || n <= 0
                                ? null
                                : MealPortion(n, units);
                            if (portion == null ||
                                batch.consumptionFraction(portion) == null) {
                              update(() => issue =
                                  'Enter an amount within the remaining batch.');
                              return;
                            }
                            Navigator.pop(
                                context, (portion: portion, slot: slot));
                          },
                          child: const Text('Confirm and log'))
                    ],
                  )));
      if (!mounted || selection == null) return;
      final stamp = DateTime.now();
      await store.log(
          chosen.id,
          selection.portion,
          PhotoMeal(
              id: ref.read(idGeneratorProvider).next(),
              date: DiaryDate.ofLocal(stamp),
              slot: selection.slot,
              caption: batch.recipe.name,
              createdAt: stamp,
              recordedOffsetMinutes: stamp.timeZoneOffset.inMinutes));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Leftovers logged.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not log this batch. Check what remains and try again.')));
      }
    }
  }

  Future<void> _barcode() async {
    var code = '';
    final selected = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Look up a barcode'),
                content: TextField(
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    onChanged: (value) => code = value.trim(),
                    decoration:
                        const InputDecoration(labelText: 'Printed digits')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () async {
                        final result = await Navigator.of(context).push<String>(
                            MaterialPageRoute(
                                builder: (_) => const _BarcodeCamera()));
                        if (result != null && context.mounted) {
                          Navigator.pop(context, result);
                        }
                      },
                      child: const Text('Scan')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, code),
                      child: const Text('Look up'))
                ]));
    if (!mounted || selected == null || selected.isEmpty) return;
    try {
      final match = (await _library.foods())
          .where((food) => food.barcode == selected)
          .firstOrNull;
      if (!mounted) return;
      if (match == null) {
        final repo = ref.read(foodRepositoryProvider);
        final matches = repo is DriftFoodRepository
            ? await repo.findByBarcode(selected)
            : const <Food>[];
        if (!mounted) return;
        if (matches.isNotEmpty) {
          final chosen = matches.length == 1
              ? matches.single
              : await showDialog<Food>(
                  context: context,
                  builder: (context) => SimpleDialog(
                          title: const Text('Choose a product'),
                          children: [
                            for (final food in matches)
                              SimpleDialogOption(
                                  onPressed: () => Navigator.pop(context, food),
                                  child: Text(
                                      '${food.name} · ${food.source.dataset}')),
                          ]));
          if (mounted && chosen != null) await _openMeal(food: chosen);
          return;
        }
        final add = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('Barcode not in your library'),
                    content: const Text(
                        'Save the name and label values once so you can find this product again.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Add reusable food'))
                    ]));
        if (mounted && add == true) {
          await _saveFood(saved: (
            id: ref.read(idGeneratorProvider).next(),
            name: '',
            barcode: selected,
            nutrition: BoundedNutrition(
                MealPortion(100, MealUnit.grams), const NutrientProfile.empty())
          ));
        }
      } else {
        await _openSavedFood(match);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read your food library.')));
      }
    }
  }

  Future<void> _installPack() async {
    try {
      final file = await openFile(acceptedTypeGroups: const [
        XTypeGroup(
            label: 'Salu catalogue pack',
            extensions: ['json'],
            uniformTypeIdentifiers: ['public.json'],
            mimeTypes: ['application/json'])
      ]);
      if (file == null || !mounted) return;
      if (await file.length() > CataloguePack.maxBytes) {
        throw const FormatException('Pack too large');
      }
      final pack = CataloguePack.parse(await file.readAsBytes());
      if (!mounted) return;
      final consent = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text('Install ${pack.dataset} · ${pack.edition}?'),
                content: Text(
                    '${pack.foods.length} foods · ${pack.barcodes.length} barcodes\n\n${pack.attribution}\n${pack.licence}\n\nThis replaces any older pack from the same dataset. Diary entries are unchanged.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Install pack'))
                ],
              ));
      if (consent != true || !mounted) return;
      await pack.install(DriftFoodRepository(ref.read(databaseProvider)));
      if (!mounted) return;
      ref.invalidate(foodSearchProvider);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Catalogue pack installed for offline search.')));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not install this catalogue pack. Your catalogue is unchanged.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(foodSearchProvider(_query));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search foods',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            ActionChip(
                avatar: const Icon(Icons.bookmark_border),
                label: const Text('Library'),
                onPressed: _openLibrary),
            const SizedBox(width: 8),
            ActionChip(
                avatar: const Icon(Icons.add),
                label: const Text('Add food'),
                onPressed: () => _saveFood()),
            const SizedBox(width: 8),
            ActionChip(
                avatar: const Icon(Icons.qr_code_scanner),
                label: const Text('Barcode'),
                onPressed: _barcode),
            const SizedBox(width: 8),
            ActionChip(label: const Text('Leftovers'), onPressed: _leftovers),
            const SizedBox(width: 8),
            ActionChip(
                label: const Text('Install pack'), onPressed: _installPack),
            const SizedBox(width: 8),
            ActionChip(
                label: const Text('New recipe'),
                onPressed: () async {
                  try {
                    await createRecipe(
                        context,
                        RecipeLibrary(ref.read(foodRepositoryProvider),
                            ref.read(documentStoreProvider)),
                        'local-recipe:${ref.read(idGeneratorProvider).next()}');
                  } catch (_) {
                    if (mounted) {
                      ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(
                              content: Text('Could not save that recipe.')));
                    }
                  }
                }),
          ]),
        ),
        Expanded(
          child: results.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(child: Text('$error')),
            data: (foods) {
              if (_query.trim().length < 2) {
                return const _Hint(
                  text: 'Type at least two characters to search the catalogue.',
                );
              }
              if (foods.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No catalogue match'),
                      TextButton(
                        onPressed: () => _openMeal(description: _query.trim()),
                        child: const Text('Log it in a meal'),
                      ),
                    ],
                  ),
                );
              }
              return ListView.separated(
                itemCount: foods.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final food = foods[index];
                  final energy = food.per100g[NutrientKey.energyKcal];
                  return ListTile(
                    title: Text(food.name),
                    subtitle: Text(
                      energy.isKnown
                          ? '${energy.numericValue!.round()} kcal / 100 g · '
                              '${food.source.dataset}'
                          : 'energy unknown · ${food.source.dataset}',
                    ),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          tooltip: 'Toggle favorite',
                          icon: Icon(_favorites.contains(food.id)
                              ? Icons.star
                              : Icons.star_border),
                          onPressed: () async {
                            try {
                              await _library.toggleFavorite(food.id);
                              await _loadFavorites();
                            } catch (_) {
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'Could not update favorites.')));
                              }
                            }
                          }),
                      IconButton(
                        tooltip: 'Add to a meal',
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () => _openMeal(food: food),
                      ),
                    ]),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _BarcodeCamera extends StatefulWidget {
  const _BarcodeCamera();
  @override
  State<_BarcodeCamera> createState() => _BarcodeCameraState();
}

class _BarcodeCameraState extends State<_BarcodeCamera> {
  bool _selected = false;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Scan food barcode')),
      body: MobileScanner(
          onDetect: (capture) {
            if (_selected || !mounted) return;
            final code = capture.barcodes
                .map((barcode) => barcode.rawValue)
                .whereType<String>()
                .where((value) => RegExp(r'^\d{8,14}$').hasMatch(value))
                .firstOrNull;
            if (code != null) {
              _selected = true;
              Navigator.pop(context, code);
            }
          },
          errorBuilder: (context, error, child) => Center(
              child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                      'Camera unavailable. Enter the printed barcode instead.')))));
}
