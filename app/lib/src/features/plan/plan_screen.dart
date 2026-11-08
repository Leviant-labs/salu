import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import 'batches_screen.dart';
import '../../ui_support.dart';

class PlanScreen extends ConsumerStatefulWidget {
  const PlanScreen({super.key});
  @override
  ConsumerState<PlanScreen> createState() => _PlanState();
}

class _PlanState extends ConsumerState<PlanScreen> {
  List<RecipeVersion> recipes = [];
  List<PlannedMeal> meals = [];
  Map<String, bool> checked = {};
  bool loaded = false;
  int revision = 0;
  String? status;
  LocalWorkspace get store => LocalWorkspace(ref.read(databaseProvider));
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final docs = await store.list('recipe');
      final latest = <String, RecipeVersion>{};
      for (final d in docs) {
        final r = recipeFromSnapshot(d.data);
        if ((latest[r.id]?.revision ?? 0) < r.revision) latest[r.id] = r;
      }
      final plan = await store.read('plan', 'current');
      final groceries = await store.read('groceries', 'current');
      final saved = <PlannedMeal>[];
      for (final v in plan?.data['meals'] as List? ?? []) {
        final j = Map<String, Object?>.from(v as Map);
        saved.add(PlannedMeal(
            MealSlot(j['slot']! as String, j['date']! as String,
                j['label']! as String),
            recipeFromSnapshot(Map<String, Object?>.from(j['recipe']! as Map)),
            Exact.fromJson(Map<String, Object?>.from(j['portions']! as Map)),
            pinned: j['pinned'] == true));
      }
      if (mounted) {
        setState(() {
          recipes = latest.values.toList()
            ..sort((a, b) => a.name.compareTo(b.name));
          meals = saved;
          revision = plan?.revision ?? 0;
          checked = {
            for (final e
                in groceries?.data.entries ?? <MapEntry<String, Object?>>[])
              e.key: e.value == true
          };
          loaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => loaded = true);
        showFailure(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext c) => DefaultTabController(
      length: 3,
      child: Column(children: [
        TabBar(tabs: [
          Tab(text: tr(c, 'Recipes', 'Receitas')),
          Tab(text: tr(c, 'Plan', 'Plano')),
          Tab(text: tr(c, 'Groceries', 'Compras'))
        ]),
        Expanded(
            child: !loaded
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(children: [
                    ListView(padding: const EdgeInsets.all(16), children: [
                      FilledButton.icon(
                          icon: const Icon(Icons.add),
                          label: Text(tr(c, 'Create recipe', 'Criar receita')),
                          onPressed: () => _recipe(c)),
                      Text(tr(
                          c,
                          'Ingredient calculations do not model cooking losses. Equal servings do not require a finished weight.',
                          'Os cálculos dos ingredientes não modelam perdas na confeção. As porções iguais não exigem peso final.')),
                      OutlinedButton(
                          onPressed: () => Navigator.push<void>(
                              c,
                              MaterialPageRoute(
                                  builder: (_) => const BatchesScreen())),
                          child: Text(tr(c, 'View cooked batches',
                              'Ver lotes confecionados'))),
                      for (final r in recipes)
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(r.name),
                            subtitle: Text(
                                '${number(r.servings.toDouble())} ${tr(c, 'servings', 'porções')} · ${r.minutes} min · v${r.revision}'),
                            trailing: PopupMenuButton<String>(
                                onSelected: (action) => action == 'log'
                                    ? _log(c, r, Exact.one)
                                    : action == 'batch'
                                        ? _batch(c, r)
                                        : _recipe(c, r),
                                itemBuilder: (c) => [
                                      PopupMenuItem(
                                          value: 'log',
                                          child: Text(tr(
                                              c,
                                              'Log a consumed portion',
                                              'Registar uma porção consumida'))),
                                      PopupMenuItem(
                                          value: 'batch',
                                          child: Text(tr(
                                              c,
                                              'Record a cooked batch',
                                              'Registar um lote confecionado'))),
                                      PopupMenuItem(
                                          value: 'edit',
                                          child: Text(tr(
                                              c,
                                              'Create revised version',
                                              'Criar versão revista')))
                                    ]))
                    ]),
                    ListView(padding: const EdgeInsets.all(16), children: [
                      Text(tr(
                          c,
                          'Plans organize future meals. Nothing here counts as consumed until you confirm it.',
                          'Os planos organizam refeições futuras. Nada conta como consumido até à tua confirmação.')),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: Text(tr(c, 'Plan seven dinners',
                              'Planear sete jantares')),
                          onPressed:
                              recipes.isEmpty ? null : () => _generate(c)),
                      if (status != null) Text(status!),
                      for (final meal in meals)
                        Card(
                            child: ListTile(
                                title: Text(meal.recipe.name),
                                subtitle: Text(
                                    '${meal.slot.date} · ${number(meal.portions.toDouble())} ${tr(c, 'servings', 'porções')}'),
                                leading: IconButton(
                                    tooltip:
                                        tr(c, 'Pin meal', 'Fixar refeição'),
                                    icon: Icon(meal.pinned
                                        ? Icons.push_pin
                                        : Icons.push_pin_outlined),
                                    onPressed: () => _pin(meal)),
                                trailing: IconButton(
                                    tooltip: tr(c, 'Confirm actual intake',
                                        'Confirmar consumo real'),
                                    icon: const Icon(Icons.restaurant_outlined),
                                    onPressed: () =>
                                        _log(c, meal.recipe, meal.portions))))
                    ]),
                    ListView(padding: const EdgeInsets.all(16), children: [
                      Text(tr(
                          c,
                          'Quantities use the ingredient preparation state recorded in each recipe. No raw/cooked conversion is invented.',
                          'As quantidades usam o estado de preparação registado na receita. Não são inventadas conversões entre cru e confecionado.')),
                      for (final line in groceriesFor(meals))
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: checked[
                                    '${line.foodId}|${line.preparation.name}'] ??
                                false,
                            title: Text(line.name),
                            subtitle: Text(
                                '${number(line.grams.toDouble())} g · ${line.preparation.name}'),
                            onChanged: (v) => _check(line, v ?? false))
                    ]),
                  ]))
      ]));
  Future<void> _recipe(BuildContext c, [RecipeVersion? existing]) async {
    await Navigator.push<void>(c,
        MaterialPageRoute(builder: (_) => _RecipeEditor(existing: existing)));
    await _load();
  }

  Future<void> _save(List<PlannedMeal> value) async {
    await store.put(
        requestId: ref.read(idGeneratorProvider).next(),
        collection: 'plan',
        id: 'current',
        expectedRevision: revision,
        data: {
          'seed': 7,
          'policyVersion': 'planner-v2',
          'meals': [
            for (final m in value)
              {
                'slot': m.slot.id,
                'date': m.slot.date,
                'label': m.slot.label,
                'recipe': recipeSnapshot(m.recipe),
                'portions': m.portions.toJson(),
                'pinned': m.pinned
              }
          ]
        });
    await _load();
  }

  Future<void> _pin(PlannedMeal selected) async {
    try {
      await _save([
        for (final m in meals)
          identical(m, selected)
              ? PlannedMeal(m.slot, m.recipe, m.portions, pinned: !m.pinned)
              : m
      ]);
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> _generate(BuildContext c) async {
    try {
      final profile = await store.read('profile', 'safety');
      final safety = profile == null
          ? const SafetyProfile()
          : SafetyProfile.fromJson(profile.data);
      final now = ref.read(clockProvider).nowUtc();
      final slots = List.generate(7, (i) {
        final d = now.add(Duration(days: i));
        return MealSlot(
            'dinner:$i', DiaryDate(d.year, d.month, d.day).toIso(), 'dinner');
      });
      // Current pinned recipe snapshots remain the candidates for their revisions.
      final candidates = <String, RecipeVersion>{
        for (final r in recipes) '${r.id}:${r.revision}': r
      };
      for (final m in meals) {
        if (m.pinned) {
          candidates['${m.recipe.id}:${m.recipe.revision}'] = m.recipe;
        }
      }
      final context = PlannerContext(
          slots: slots,
          recipes: candidates.values.toList(),
          seed: 7,
          strictExclusions: safety.strictExclusions);
      final result = const PlannerService().repair(context, meals);
      if (result.status == PlannerStatus.validPlan) {
        await _save(result.meals);
        await store.reward('planning:${slots.first.date}');
        if (mounted) {
          setState(() => status = tr(
              this.context,
              'Organization-only plan. No nutritional adequacy claim.',
              'Plano apenas de organização. Sem afirmações de adequação nutricional.'));
        }
      } else if (mounted) {
        setState(() =>
            status = '${result.status.name}: ${result.diagnostics.join('; ')}');
      }
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _log(BuildContext c, RecipeVersion recipe, Exact initial) async {
    final amount = await askText(c,
        title:
            tr(c, 'Servings actually consumed', 'Porções realmente consumidas'),
        initial: initial.toDouble().toString());
    if (amount == null) return;
    try {
      final p = Exact.parse(amount.replaceAll(',', '.'));
      if (!c.mounted) return;
      if (!await confirmAction(
          c,
          tr(c, 'Record consumed recipe?', 'Registar receita consumida?'),
          tr(
              c,
              'Only confirm food you actually consumed. Cooking losses are not modeled.',
              'Confirma apenas o que realmente consumiste. As perdas na confeção não são modeladas.'))) {
        return;
      }
      await LogRecipeHandler(ref.read(entryRepositoryProvider),
              ref.read(clockProvider), ref.read(idGeneratorProvider))
          .handle(LogRecipeCommand(
              requestId: ref.read(idGeneratorProvider).next(),
              recipe: recipe,
              portions: p,
              offsetMinutes: currentOffsetMinutes(),
              confirmed: true,
              channel: EntryChannel.plan));
      ref.invalidate(todayEntriesProvider);
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _batch(BuildContext c, RecipeVersion recipe) async {
    final weight = await askText(c,
        title: tr(c, 'Measured finished weight (g)', 'Peso final medido (g)'));
    if (weight == null) return;
    try {
      if (!c.mounted) return;
      if (!await confirmAction(
          c,
          tr(c, 'Confirm batch ingredients', 'Confirmar ingredientes do lote'),
          tr(
              c,
              'Confirm the measured edible ingredients match this recipe version. If ingredients changed, create a revised recipe first. Cooking losses are not modeled.',
              'Confirma que os ingredientes comestíveis medidos correspondem a esta versão da receita. Se mudaram, cria primeiro uma versão revista. As perdas na confeção não são modeladas.'))) {
        return;
      }
      final g = Exact.parse(weight.replaceAll(',', '.'));
      final id = ref.read(idGeneratorProvider).next();
      final batch = CookedBatch(
          id: id,
          recipe: recipe,
          revision: 1,
          available: g,
          unit: FoodUnit.g,
          finishedWeightG: g);
      await store.put(
          requestId: 'batch:$id',
          collection: 'batch',
          id: id,
          expectedRevision: 0,
          data: {
            'recipe': recipeSnapshot(recipe),
            'available': batch.available.toJson(),
            'finishedWeightG': g.toJson(),
            'unit': 'g',
            'allocations': <Object?>[],
            'createdAt': ref.read(clockProvider).nowUtc().toIso8601String()
          });
      if (c.mounted) {
        ScaffoldMessenger.of(c).showSnackBar(SnackBar(
            content: Text(
                tr(c, 'Cooked batch saved', 'Lote confecionado guardado'))));
      }
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _check(GroceryLine line, bool value) async {
    try {
      final old = await store.read('groceries', 'current');
      final next = {
        ...?old?.data,
        '${line.foodId}|${line.preparation.name}': value
      };
      await store.put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'groceries',
          id: 'current',
          expectedRevision: old?.revision ?? 0,
          data: next);
      if (mounted) {
        setState(() => checked = {
              ...checked,
              '${line.foodId}|${line.preparation.name}': value
            });
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }
}

class _RecipeEditor extends ConsumerStatefulWidget {
  const _RecipeEditor({this.existing});
  final RecipeVersion? existing;
  @override
  ConsumerState<_RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends ConsumerState<_RecipeEditor> {
  final name = TextEditingController(),
      servings = TextEditingController(text: '1'),
      minutes = TextEditingController(text: '20');
  List<RecipeIngredient> ingredients = [];
  List<Food> matches = [];
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    if (r != null) {
      name.text = r.name;
      servings.text = r.servings.toDouble().toString();
      minutes.text = '${r.minutes}';
      ingredients = [...r.ingredients];
    }
  }

  @override
  void dispose() {
    name.dispose();
    servings.dispose();
    minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: Text(tr(c, 'Recipe version', 'Versão da receita'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
            controller: name,
            decoration: InputDecoration(
                labelText: tr(c, 'Recipe name', 'Nome da receita'))),
        TextField(
            controller: servings,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr(c, 'Equal servings in this recipe',
                    'Porções iguais nesta receita'))),
        TextField(
            controller: minutes,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: tr(c, 'Cooking time (minutes)',
                    'Tempo de confeção (minutos)'))),
        for (var i = 0; i < ingredients.length; i++)
          ListTile(
              title: Text(ingredients[i].food.name),
              subtitle: Text('${number(ingredients[i].grams.toDouble())} g'),
              trailing: IconButton(
                  tooltip: tr(c, 'Remove ingredient', 'Remover ingrediente'),
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => ingredients.removeAt(i)))),
        TextField(
            decoration: InputDecoration(
                labelText: tr(c, 'Search ingredient', 'Pesquisar ingrediente')),
            onChanged: (q) async {
              final result = q.length < 2
                  ? <Food>[]
                  : await ref.read(foodRepositoryProvider).search(q);
              if (mounted) {
                setState(() => matches =
                    result.where((f) => f.basisUnit == FoodUnit.g).toList());
              }
            }),
        for (final f in matches)
          ListTile(
              title: Text(f.name),
              onTap: () async {
                final text = await askText(c,
                    title: tr(c, 'Edible ingredient grams',
                        'Gramas comestíveis do ingrediente'));
                if (text == null) return;
                try {
                  final ingredient = RecipeIngredient(
                      f, Exact.parse(text.replaceAll(',', '.')));
                  setState(() {
                    ingredients.add(ingredient);
                    matches = [];
                  });
                } catch (e) {
                  if (c.mounted) showFailure(c, e);
                }
              }),
        const SizedBox(height: 16),
        Text(tr(
            c,
            'Enter actual edible quantities. Cooking losses are not modeled. Allergen metadata remains unknown if any ingredient is unknown.',
            'Introduz quantidades comestíveis reais. As perdas na confeção não são modeladas. Os alergénios permanecem desconhecidos se algum ingrediente for desconhecido.')),
        FilledButton(
            onPressed: saving ? null : _save,
            child: Text(tr(c, 'Save immutable recipe version',
                'Guardar versão imutável da receita')))
      ]));
  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final id = widget.existing?.id ?? ref.read(idGeneratorProvider).next();
      final version = (widget.existing?.revision ?? 0) + 1;
      final r = RecipeVersion(
          id: id,
          revision: version,
          name: name.text.trim(),
          ingredients: ingredients,
          servings: Exact.parse(servings.text.replaceAll(',', '.')),
          minutes: int.parse(minutes.text),
          allergens: ingredients.any((i) => i.food.allergens == null)
              ? null
              : ingredients.expand((i) => i.food.allergens!).toSet());
      if (r.name.isEmpty) throw ArgumentError('Recipe name required');
      await LocalWorkspace(ref.read(databaseProvider)).put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'recipe',
          id: '$id:$version',
          expectedRevision: 0,
          data: recipeSnapshot(r));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}
