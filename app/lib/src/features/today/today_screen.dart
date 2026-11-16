import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import '../../widgets/meal_card.dart';
import '../../widgets/meal_library_status.dart';
import '../meal/meal_actions.dart';
import '../meal/meal_content.dart';
import '../plan/guided_draft_review.dart';

final recommendationDismissalsProvider = FutureProvider<Set<String>>((ref) async {
  final row = await LocalWorkspace(ref.watch(databaseProvider))
      .read('preferences','recommendation-dismissals');
  return (row?.data['keys'] as List? ?? []).cast<String>().toSet();
});

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});
  @override
  Widget build(BuildContext context,WidgetRef ref) {
    final date = ref.watch(todayDiaryDateProvider);
    final plan = ref.watch(planForDateProvider(date));
    return plan.when(loading:() => const Center(child:CircularProgressIndicator()),
      error:(error,stack) => Center(child:Column(mainAxisSize:MainAxisSize.min,children:[
        Text(tr(context,'Your plan could not be loaded.','Não foi possível carregar o plano.')),
        TextButton(onPressed:() => ref.invalidate(planForDateProvider(date)),
          child:Text(tr(context,'Retry','Tentar novamente'))),
        TextButton(onPressed:() => context.push('/diary'),child:Text(tr(context,'View diary','Ver diário'))),
      ])),data:(plan) => _content(context,ref,date,plan));
  }

  Widget _content(BuildContext context,WidgetRef ref,DiaryDate date,StoredPlan? plan) {
    final profileDoc = ref.watch(nutritionProfileProvider).valueOrNull;
    final profile = profileDoc == null ? null : NutritionProfile.fromJson(profileDoc.data);
    final content = ref.watch(mealContentProvider).valueOrNull ?? {};
    final states = plan == null ? <PlanMealStateRecord>[] :
        ref.watch(planMealStateProvider(plan.documentId)).valueOrNull ?? [];
    final stateBySlot = {for(final state in states)state.slotId:state};
    final todayMeals = plan?.meals.where((meal) => meal.slot.date == date.toIso()).toList() ?? [];
    final pending = todayMeals.where((meal) => !stateBySlot.containsKey(meal.slot.id)).toList();
    const hours = {'breakfast':8,'lunch':13,'snack':16,'dinner':19};
    final wall = ref.watch(clockProvider).nowUtc().add(Duration(minutes:currentOffsetMinutes()));
    final isToday = date == DiaryDate.ofLocal(DateTime(wall.year, wall.month, wall.day));
    final next = isToday
        ? (pending.where((meal) =>
            (hours[meal.slot.label] ?? 19) * 60 >= wall.hour * 60 + wall.minute)
            .firstOrNull ?? pending.lastOrNull)
        : pending.firstOrNull;
    final guided = plan?.document['guided'] as Map?;
    final recommendation = const DailyRecommendationService().recommend(date:date,
        profile:profile,profileRevision:profileDoc?.revision ?? 0,
        planRevision:plan?.revision ?? 0,planProfileRevision:guided?['profileRevision'] as int?,
        meals:plan?.meals ?? [],slotStates:{for(final state in states)state.slotId:state.state.name},
        coldSuitableByRecipeId:{for(final entry in content.entries)
          if(entry.value['coldSuitable'] is bool)entry.key:entry.value['coldSuitable']! as bool},
        dismissedKeys:ref.watch(recommendationDismissalsProvider).valueOrNull ?? {});
    final primary = <Widget>[
      if(plan == null || todayMeals.isEmpty) Card(child:Padding(padding:const EdgeInsets.all(20),
        child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(tr(context,profile == null ? 'Your personal plan starts here' : 'Ready for your next week?',
            profile == null ? 'O seu plano pessoal começa aqui' : 'Vamos preparar a próxima semana?'),
            style:Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height:12),
          FilledButton(onPressed:() => profile == null ? context.push('/onboarding') :
              _createPlan(context,ref,date),
            child:Text(tr(context,profile == null ? 'Create my plan' : 'Plan this week',
                profile == null ? 'Criar o meu plano' : 'Planear esta semana'))),
        ]))),
      if(next != null) ...[
        Text(tr(context,'Your next meal','A sua próxima refeição'),
            style:Theme.of(context).textTheme.titleLarge),
        _card(context,ref,plan!,next,content,stateBySlot[next.slot.id],isNext:true),
      ],
      if(todayMeals.isNotEmpty) ...[
        const SizedBox(height:16),
        Text(tr(context,'Your day','O seu dia'),style:Theme.of(context).textTheme.titleLarge),
        for(final meal in todayMeals)
          if(meal.slot.id != next?.slot.id)_card(context,ref,plan!,meal,content,stateBySlot[meal.slot.id]),
      ],
    ];
    final secondary = <Widget>[
      if(recommendation != null && plan != null)
        _recommendation(context,ref,plan,recommendation),
      if(plan != null) _summary(context,ref,plan,todayMeals),
      Card(child:Column(children:[
        ListTile(leading:const Icon(Icons.water_drop_outlined),
          title:Text(tr(context,'Water and diary','Água e diário')),
          trailing:const Icon(Icons.chevron_right),onTap:() => context.push('/diary')),
        ListTile(leading:const Icon(Icons.auto_awesome_outlined),
          title:Text(tr(context,'Ask for a practical change','Peça uma alteração prática')),
          trailing:const Icon(Icons.chevron_right),onTap:() => context.go('/assistant')),
      ])),
    ];
    return LayoutBuilder(builder:(context,constraints) => ListView(
      padding:const EdgeInsets.all(16),children:[Center(child:ConstrainedBox(
        constraints:BoxConstraints(maxWidth:constraints.maxWidth >= 840 ? 1100 : 720),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Row(children:[Expanded(child:Text(tr(context,'A clear plan for today','Um plano claro para hoje'),
            style:Theme.of(context).textTheme.headlineMedium)),
            IconButton(tooltip:tr(context,'Previous day','Dia anterior'),icon:const Icon(Icons.chevron_left),
              onPressed:() => ref.read(selectedDiaryDateProvider.notifier).state = date.addDays(-1)),
            IconButton(tooltip:tr(context,'Next day','Dia seguinte'),icon:const Icon(Icons.chevron_right),
              onPressed:() => ref.read(selectedDiaryDateProvider.notifier).state = date.addDays(1))]),
          Text(date.toIso()),const SizedBox(height:16),const MealLibraryStatus(),
          if(constraints.maxWidth >= 840) Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Expanded(flex:2,child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:primary)),
            const SizedBox(width:16),
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:secondary)),
          ]) else ...[...primary,...secondary],
        ])))]));
  }

  Widget _card(BuildContext context,WidgetRef ref,StoredPlan plan,PlannedMeal meal,
      Map<String,Map<String,Object?>> all,PlanMealStateRecord? state,{bool isNext = false}) {
    final content = mealContentFor(all,meal.recipe.id,context);
    final consumed = state?.state == PlanMealState.consumed;
    final skipped = state?.state == PlanMealState.skipped;
    return MealCard(meal:meal,content:content,isNext:isNext,
      state:consumed ? MealDisplayState.consumed : skipped ? MealDisplayState.skipped : MealDisplayState.pending,
      fitReason:isNext ? tr(context,'Chosen for your routine and food preferences.',
          'Escolhida para a sua rotina e preferências alimentares.') : null,
      onViewRecipe:() => openMealDetail(context,ref,plan,meal,content,consumed:consumed),
      onConsume:consumed || skipped ? null : () => confirmMealConsumption(context,ref,plan,meal),
      onSwap:consumed || skipped || meal.pinned ? null : () =>
          proposeMealChanges(context,ref,plan:plan,slotIds:{meal.slot.id}),
      onSkip:consumed || skipped ? null : () => setMealSkipped(context,ref,plan,meal,undo:false),
      onUndoSkip:skipped ? () => setMealSkipped(context,ref,plan,meal,undo:true) : null,
      onPinToggle:consumed ? null : () => toggleMealPin(context,ref,plan,meal));
  }

  Widget _summary(BuildContext context,WidgetRef ref,StoredPlan plan,List<PlannedMeal> meals) {
    final settings = ref.watch(settingsProvider);
    if(settings['support'] == true) return const SizedBox.shrink();
    final guided = plan.document['guided'] as Map?;
    final rawTarget = guided?['targetSnapshot'];
    final target = rawTarget is Map ? DeclaredTarget.fromJson(Map<String,Object?>.from(rawTarget)) : null;
    return Card(child:ExpansionTile(title:Text(tr(context,'Planned nutrition','Nutrição planeada')),
      children:[Padding(padding:const EdgeInsets.all(16),child:Column(
        crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          for(final key in [if(settings['hideCalorieNudges'] != true)NutrientKey.energyKcal,
              NutrientKey.proteinG,NutrientKey.fatG]) Builder(builder:(context) {
            var total = Exact.zero;
            var complete = meals.isNotEmpty;
            for(final meal in meals) {
              final value = meal.nutrients[key];
              if(value == null || !value.isComplete) complete = false;
              if(value != null) total += value.exactValue;
            }
            final goal = switch(key){NutrientKey.energyKcal=>target?.energyKcal,
              NutrientKey.proteinG=>target?.proteinG,_=>target?.fatG};
            return Text('${nutrientLabel(context,key.wire)}: ${number(total.toDouble())} ${key.unit}'
              '${complete ? '' : ' (${tr(context,'partial','parcial')})'}'
              '${goal == null ? '' : ' · ${tr(context,'starting target','meta inicial')} ${goal.toDouble().round()}'}');
          }),
          if(target?.origin == TargetOrigin.calculatedEstimate)
            Text(tr(context,'Starting estimate—not a measurement','Estimativa inicial — não é uma medição')),
        ]))]));
  }

  Widget _recommendation(BuildContext context,WidgetRef ref,StoredPlan plan,DailyRecommendation rec) {
    final message = switch(rec.reasonCode){
      'disliked-upcoming'=>tr(context,'A meal you disliked is coming up.','Está prevista uma refeição de que não gostou.'),
      'profile-plan-mismatch'=>tr(context,'Your preferences changed. Review how this week fits.','As preferências mudaram. Reveja esta semana.'),
      'cold-lunch-mismatch'=>tr(context,'Make your upcoming lunch work cold.','Prepare o próximo almoço para comer frio.'),
      'week-ended'=>tr(context,'Your next week is ready to plan.','Está na altura de planear a próxima semana.'),
      _=>tr(context,'Create your personal plan.','Crie o seu plano pessoal.')};
    return Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(
      crossAxisAlignment:CrossAxisAlignment.stretch,children:[Text(message),
        FilledButton.tonal(onPressed:() {
          switch(rec.action) {
            case RecommendationAction.completeSetup:context.push('/onboarding');
            case RecommendationAction.createNextWeek:proposeMealChanges(context,ref,plan:plan,nextWeek:true);
            case RecommendationAction.replaceMeals:proposeMealChanges(context,ref,plan:plan,slotIds:rec.slotIds.toSet());
            case RecommendationAction.reviewPreferences:
              final consumed = ref.read(planMealStateProvider(plan.documentId))
                  .valueOrNull?.where((state) => state.state == PlanMealState.consumed)
                  .map((state) => state.slotId).toSet() ?? <String>{};
              final slots = plan.meals.where((meal) =>
                  meal.slot.date.compareTo(ref.read(todayDiaryDateProvider).toIso()) >= 0 &&
                  !meal.pinned && !consumed.contains(meal.slot.id))
                  .map((meal) => meal.slot.id).toSet();
              proposeMealChanges(context,ref,plan:plan,slotIds:slots);
          }
        },child:Text(tr(context,'Review','Rever'))),
        TextButton(onPressed:() async {
          final workspace = LocalWorkspace(ref.read(databaseProvider));
          final previous = await workspace.read('preferences','recommendation-dismissals');
          final keys = (previous?.data['keys'] as List? ?? []).cast<String>().toSet()
            ..add(rec.dismissalKey);
          await workspace.put(requestId:ref.read(idGeneratorProvider).next(),collection:'preferences',
            id:'recommendation-dismissals',expectedRevision:previous?.revision ?? 0,
            data:{'date':ref.read(todayDiaryDateProvider).toIso(),'keys':keys.toList()..sort()});
          ref.invalidate(recommendationDismissalsProvider);
        },child:Text(tr(context,'Dismiss','Ignorar'))),
      ])));
  }
  Future<void> _createPlan(BuildContext context,WidgetRef ref,DiaryDate date) async {
    try {
      final profile = await ref.read(nutritionProfileProvider.future);
      if(profile == null) return;
      final draft = await ref.read(guidedPlanServiceProvider).propose(
        requestId:ref.read(idGeneratorProvider).next(),expectedProfileRevision:profile.revision,startDate:date);
      if(context.mounted) await showGuidedDraftReview(context,draft:draft);
    } catch(error) { if(context.mounted) showFailure(context,error); }
  }
}
