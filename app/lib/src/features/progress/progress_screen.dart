import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import '../meal/meal_actions.dart';
import '../meal/meal_content.dart';
import '../today/weight_visibility.dart';
import 'checkin_details.dart';

class ProgressScreen extends ConsumerWidget {
  const ProgressScreen({super.key});
  @override
  Widget build(BuildContext context,WidgetRef ref) {
    final date = ref.watch(todayDiaryDateProvider);
    final plan = ref.watch(planForDateProvider(date)).valueOrNull;
    final settings = ref.watch(settingsProvider);
    return Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:720),
      child:ListView(padding:const EdgeInsets.all(16),children:[
        Text(tr(context,'What is working for you?','O que está a funcionar para si?'),
          style:Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height:16),
        Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(tr(context,'A quick weekly check-in','Um balanço semanal rápido'),
              style:Theme.of(context).textTheme.titleLarge),
            Text(tr(context,'Keep the meals you liked. Make next week easier.',
              'Guarde as refeições de que gostou. Facilite a próxima semana.')),
            const SizedBox(height:12),
            FilledButton(onPressed:() => showWeeklyMealFeedback(context,ref,plan),
              child:Text(tr(context,'Review my week','Rever a minha semana'))),
            TextButton(onPressed:() => showCheckInDetails(context,ref,date),
              child:Text(tr(context,'Recording and nutrition details','Detalhes dos registos e da nutrição'))),
          ]))),
        ListTile(leading:const Icon(Icons.book_outlined),title:Text(tr(context,'Diary','Diário')),
          trailing:const Icon(Icons.chevron_right),onTap:() => context.push('/diary')),
        ListTile(leading:const Icon(Icons.water_drop_outlined),title:Text(tr(context,'Water records','Registos de água')),
          trailing:const Icon(Icons.chevron_right),onTap:() => context.push('/diary')),
        if(!hidesWeight(settings)) ListTile(leading:const Icon(Icons.monitor_weight_outlined),
          title:Text(tr(context,'Weight records','Registos de peso')),
          trailing:const Icon(Icons.chevron_right),onTap:() => context.push('/weight')),
        ListTile(leading:const Icon(Icons.pets_outlined),title:Text(tr(context,'Rewards','Recompensas')),
          trailing:const Icon(Icons.chevron_right),onTap:() => context.push('/rewards')),
      ])));
  }
}

Future<void> showWeeklyMealFeedback(BuildContext context,WidgetRef ref,StoredPlan? plan) async {
  final row = await ref.read(nutritionProfileProvider.future);
  if(!context.mounted) return;
  if(row == null) { await context.push('/onboarding'); return; }
  final profile = NutritionProfile.fromJson(row.data);
  final liked = {...profile.likedRecipeIds}, disliked = {...profile.dislikedRecipeIds};
  final tooMuchWork = <String>{};
  final recipes = {for(final meal in plan?.meals ?? <PlannedMeal>[])meal.recipe.id:meal.recipe};
  final content = ref.read(mealContentProvider).valueOrNull ?? {};
  var variety = profile.preferVariety;
  var cap = profile.maximumCookingMinutes;
  var saving = false;
  String? error;
  final reviewNext = await showModalBottomSheet<bool>(context:context,
    isScrollControlled:true,useSafeArea:true,builder:(sheetContext) =>
      StatefulBuilder(builder:(context,setSheetState) => Padding(
        padding:EdgeInsets.fromLTRB(16,16,16,16 + MediaQuery.viewInsetsOf(context).bottom),
        child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Text(tr(context,'Which meals worked?','Que refeições resultaram?'),
              style:Theme.of(context).textTheme.headlineSmall),
            for(final recipe in recipes.values) Card(child:Padding(padding:const EdgeInsets.all(12),
              child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(mealContentFor(content,recipe.id,context)?.title ?? recipe.name,
                  style:Theme.of(context).textTheme.titleMedium),
                Wrap(spacing:8,runSpacing:8,children:[
                  FilterChip(label:Text(tr(context,'Like','Gosto')),selected:liked.contains(recipe.id),
                    onSelected:(selected) => setSheetState(() {
                      selected ? liked.add(recipe.id) : liked.remove(recipe.id);
                      if(selected) disliked.remove(recipe.id);
                    })),
                  FilterChip(label:Text(tr(context,'Not for me','Não é para mim')),selected:disliked.contains(recipe.id),
                    onSelected:(selected) => setSheetState(() {
                      selected ? disliked.add(recipe.id) : disliked.remove(recipe.id);
                      if(selected) liked.remove(recipe.id);
                    })),
                  FilterChip(label:Text(tr(context,'Too much work','Demasiado trabalho')),selected:tooMuchWork.contains(recipe.id),
                    onSelected:(selected) => setSheetState(() =>
                      selected ? tooMuchWork.add(recipe.id) : tooMuchWork.remove(recipe.id))),
                ]),
              ]))),
            SwitchListTile(title:Text(tr(context,'Prefer more variety','Preferir mais variedade')),
              value:variety,onChanged:(value) => setSheetState(() => variety = value)),
            DropdownButtonFormField<int>(initialValue:cap,
              decoration:InputDecoration(labelText:tr(context,'Cooking time preference','Preferência de tempo de preparação')),
              items:[for(final minutes in [15,30,45,null])DropdownMenuItem<int>(value:minutes,
                child:Text(minutes == null ? tr(context,'Flexible','Flexível') : '$minutes min'))],
              onChanged:(value) => setSheetState(() => cap = value)),
            if(error != null) Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error)),
            const SizedBox(height:16),
            for(final next in [false,true]) Padding(padding:const EdgeInsets.only(bottom:8),
              child:FilledButton.tonal(onPressed:saving ? null : () async {
                setSheetState(() { saving = true; error = null; });
                try {
                  final db = ref.read(databaseProvider);
                  final workspace = LocalWorkspace(db);
                  await db.transaction(() async {
                    await NutritionProfileStore(db).save(requestId:ref.read(idGeneratorProvider).next(),
                      expectedRevision:row.revision,profile:profile.copyWith(likedRecipeIds:liked,
                        dislikedRecipeIds:disliked,maximumCookingMinutes:cap,preferVariety:variety));
                    if(tooMuchWork.isNotEmpty) {
                      final old = await workspace.read('preferences','meal-feedback');
                      await workspace.put(requestId:ref.read(idGeneratorProvider).next(),
                        collection:'preferences',id:'meal-feedback',expectedRevision:old?.revision ?? 0,
                        data:{...?old?.data,for(final id in tooMuchWork)id:{
                          'date':ref.read(todayDiaryDateProvider).toIso(),
                          'recipeRevision':recipes[id]!.revision,'tooMuchWork':true}});
                    }
                    await workspace.reward('checkin:${ref.read(todayDiaryDateProvider).toIso()}');
                  });
                  ref.invalidate(nutritionProfileProvider);
                  if(sheetContext.mounted) Navigator.pop(sheetContext,next);
                } catch(_) {
                  setSheetState(() { saving = false;
                    error = tr(context,'Preferences changed. Close and review again.',
                      'As preferências mudaram. Feche e reveja novamente.'); });
                }
              },child:Text(next ? tr(context,'Save and review next week','Guardar e rever a próxima semana') :
                  tr(context,'Save preferences','Guardar preferências')))),
            TextButton(onPressed:saving ? null : () => Navigator.pop(sheetContext),
              child:Text(tr(context,'Skip this check-in','Saltar este balanço'))),
          ])))));
  if(reviewNext == true && context.mounted) {
    if(plan != null) {
      await proposeMealChanges(context,ref,plan:plan,nextWeek:true);
    } else { await context.push('/plan'); }
  }
}
