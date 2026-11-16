import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import '../../widgets/meal_card.dart';
import '../meal/meal_actions.dart';
import '../meal/meal_content.dart';
import 'guided_draft_review.dart';
import 'week_groceries.dart';

class MyPlanScreen extends ConsumerStatefulWidget {
  const MyPlanScreen({super.key});
  @override
  ConsumerState<MyPlanScreen> createState() => _MyPlanScreenState();
}
class _MyPlanScreenState extends ConsumerState<MyPlanScreen> {
  bool _nextWeek = false, _groceries = false, _building = false;
  @override
  Widget build(BuildContext context) {
    final today = ref.watch(todayDiaryDateProvider);
    final current = ref.watch(planForDateProvider(today));
    return current.when(loading:() => const Center(child:CircularProgressIndicator()),
      error:(error,stack) => Center(child:TextButton(onPressed:() => ref.invalidate(planForDateProvider(today)),
        child:Text(tr(context,'Retry plan','Voltar a carregar plano')))),
      data:(currentPlan) {
        final schedule = PlanSchedule.fromMetadata(currentPlan?.document['schedule']);
        final nextDate = schedule == null ? today.addDays(7) :
            DiaryDate.parse(schedule.startDate).addDays(schedule.days);
        final selected = _nextWeek ? ref.watch(planForDateProvider(nextDate)) : current;
        return selected.when(loading:() => const Center(child:CircularProgressIndicator()),
          error:(error,stack) => Center(child:TextButton(
            onPressed:() => ref.invalidate(planForDateProvider(nextDate)),
            child:Text(tr(context,'Retry next week','Voltar a carregar próxima semana')))),
          data:(plan) => _week(context,plan,_nextWeek ? nextDate : today));
      });
  }
  Widget _week(BuildContext context,StoredPlan? plan,DiaryDate date) {
    final allContent = ref.watch(mealContentProvider).valueOrNull ?? {};
    final states = plan == null ? <PlanMealStateRecord>[] :
        ref.watch(planMealStateProvider(plan.documentId)).valueOrNull ?? [];
    final stateBySlot = {for(final state in states)state.slotId:state.state};
    final dates = plan?.meals.map((meal) => meal.slot.date).toSet().toList() ?? [];
    dates.sort();
    return Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:720),
      child:ListView(padding:const EdgeInsets.all(16),children:[
        Wrap(spacing:8,runSpacing:8,children:[
          ChoiceChip(label:Text(tr(context,'Current week','Semana atual')),selected:!_nextWeek,
            onSelected:(_) => setState(() => _nextWeek = false)),
          ChoiceChip(label:Text(tr(context,'Next week','Próxima semana')),selected:_nextWeek,
            onSelected:(_) => setState(() => _nextWeek = true)),
        ]),
        const SizedBox(height:16),
        Wrap(spacing:8,runSpacing:8,children:[
          OutlinedButton.icon(onPressed:plan == null ? null : () => setState(() => _groceries = !_groceries),
            icon:Icon(_groceries ? Icons.calendar_month_outlined : Icons.shopping_basket_outlined),
            label:Text(_groceries ? tr(context,'Meal schedule','Plano de refeições') : tr(context,'Grocery list','Lista de compras'))),
          TextButton.icon(onPressed:() => context.push('/onboarding'),icon:const Icon(Icons.tune),
            label:Text(tr(context,'Edit preferences','Editar preferências'))),
          TextButton.icon(onPressed:() => context.push('/plan-tools'),icon:const Icon(Icons.menu_book_outlined),
            label:Text(tr(context,'Recipes and tools','Receitas e ferramentas'))),
        ]),
        if(plan == null) Card(child:Padding(padding:const EdgeInsets.all(20),child:Column(
          crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(tr(context,'A practical week, ready for review','Uma semana prática para rever'),
              style:Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height:12),
            FilledButton(onPressed:_building ? null : () => _buildPlan(date),
              child:Text(tr(context,'Create this week','Criar esta semana'))),
            if(_building) const Padding(padding:EdgeInsets.all(16),child:CircularProgressIndicator()),
          ])))
        else if(_groceries) WeekGroceries(plan:plan)
        else ...[
          if(dates.isNotEmpty) Text('${dates.first} — ${dates.last}',style:Theme.of(context).textTheme.titleMedium),
          for(final day in dates) ...[
            const SizedBox(height:20),Text(day,style:Theme.of(context).textTheme.titleLarge),
            for(final meal in plan.meals.where((meal) => meal.slot.date == day)) Builder(builder:(context) {
              final content = mealContentFor(allContent,meal.recipe.id,context);
              final consumed = stateBySlot[meal.slot.id] == PlanMealState.consumed;
              final skipped = stateBySlot[meal.slot.id] == PlanMealState.skipped;
              return MealCard(meal:meal,content:content,
                state:consumed ? MealDisplayState.consumed : skipped ? MealDisplayState.skipped : MealDisplayState.pending,
                onViewRecipe:() => openMealDetail(context,ref,plan,meal,content,consumed:consumed),
                onSwap:consumed || meal.pinned ? null : () => proposeMealChanges(context,ref,plan:plan,slotIds:{meal.slot.id}),
                onConsume:consumed || skipped ? null : () => confirmMealConsumption(context,ref,plan,meal),
                onSkip:consumed || skipped ? null : () => setMealSkipped(context,ref,plan,meal,undo:false),
                onUndoSkip:skipped ? () => setMealSkipped(context,ref,plan,meal,undo:true) : null,
                onPinToggle:consumed ? null : () => toggleMealPin(context,ref,plan,meal));
            }),
          ],
        ],
      ])));
  }
  Future<void> _buildPlan(DiaryDate date) async {
    setState(() => _building = true);
    try {
      final profile = await ref.read(nutritionProfileProvider.future);
      if(profile == null) {
        if(mounted) await context.push('/onboarding');
      } else {
        final draft = await ref.read(guidedPlanServiceProvider).propose(
          requestId:ref.read(idGeneratorProvider).next(),
          expectedProfileRevision:profile.revision,startDate:date);
        if(mounted) await showGuidedDraftReview(context,draft:draft);
      }
    } catch(error) { if(mounted) showFailure(context,error); }
    finally { if(mounted) setState(() => _building = false); }
  }
}
