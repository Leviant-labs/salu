import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../intake_moment.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import '../plan/guided_draft_review.dart';
import 'meal_content.dart';

Future<void> proposeMealChanges(BuildContext context, WidgetRef ref,
    {required StoredPlan plan, Set<String> slotIds = const {},
      bool nextWeek = false, NutritionProfile? proposedProfile}) async {
  try {
    final profile = await ref.read(nutritionProfileProvider.future);
    if(profile == null) throw StateError('PROFILE_REQUIRED');
    final schedule = PlanSchedule.fromMetadata(plan.document['schedule']);
    final dates = plan.meals.map((meal) => meal.slot.date).toList()..sort();
    final start = schedule == null ? DiaryDate.parse(dates.first) :
        DiaryDate.parse(schedule.startDate);
    final nextStart = schedule == null ? DiaryDate.parse(dates.last).addDays(1) :
        start.addDays(schedule.days);
    final draft = await ref.read(guidedPlanServiceProvider).propose(
        requestId:'meal-change:${ref.read(idGeneratorProvider).next()}',
        expectedProfileRevision:profile.revision,
        startDate:nextWeek ? nextStart : start,
        proposedProfile:proposedProfile, replaceSlotIds:nextWeek ? {} : slotIds);
    if(context.mounted) await showGuidedDraftReview(context,draft:draft);
  } catch(error) { if(context.mounted) showFailure(context,error); }
}

Future<void> confirmMealConsumption(BuildContext context,WidgetRef ref,
    StoredPlan plan,PlannedMeal meal) async {
  final now = ref.read(clockProvider).nowUtc();
  final offset = currentOffsetMinutes();
  final day = DiaryDate.parse(meal.slot.date);
  final wall = now.add(Duration(minutes:offset));
  final stamp = EventStamp(instant:DateTime.utc(day.year,day.month,day.day,
      wall.hour,wall.minute).subtract(Duration(minutes:offset)),offsetMinutes:offset);
  final input = IntakeMomentInput(stamp,day);
  final portions = TextEditingController(text:number(meal.portions.toDouble()));
  String? error;
  final reviewed = await showModalBottomSheet<ReviewedIntakeMoment>(
    context:context,isScrollControlled:true,useSafeArea:true,builder:(sheetContext) =>
      StatefulBuilder(builder:(context,setSheetState) => Padding(
        padding:EdgeInsets.fromLTRB(16,16,16,16 + MediaQuery.viewInsetsOf(context).bottom),
        child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Text(tr(context,'I ate this','Comi isto'),style:Theme.of(context).textTheme.titleLarge),
            const SizedBox(height:16),
            TextField(controller:portions,
              keyboardType:const TextInputType.numberWithOptions(decimal:true),
              decoration:InputDecoration(labelText:tr(context,'Portions','Porções'),errorText:error)),
            ExpansionTile(title:Text(tr(context,'Date and time details','Data e hora')),
              children:[input.fields(context)]),
            FilledButton(onPressed:() {
              try {
                final amount = Exact.parse(portions.text.replaceAll(',','.'));
                if(!amount.positive) throw const FormatException();
                Navigator.pop(sheetContext,(stamp:input.stamp,day:input.diaryDate,multiplier:amount));
              } catch(_) { setSheetState(() => error = tr(context,
                  'Check the portion, date and time.','Verifique a porção, a data e a hora.')); }
            },child:Text(tr(context,'Confirm meal','Confirmar refeição'))),
          ])))));
  input.dispose(); portions.dispose();
  if(reviewed == null) return;
  try {
    await ref.read(guidedPlanServiceProvider).consume(planDocumentId:plan.documentId,
        slotId:meal.slot.id,portions:reviewed.multiplier,stamp:reviewed.stamp,
        diaryDate:reviewed.day,expectedPlanRevision:plan.revision,
        requestId:'meal-intake:${ref.read(idGeneratorProvider).next()}');
    ref.invalidate(planMealStateProvider(plan.documentId));
    ref.invalidate(todayEntriesProvider);
  } catch(error) { if(context.mounted) showFailure(context,error); }
}

Future<void> setMealSkipped(BuildContext context,WidgetRef ref,StoredPlan plan,
    PlannedMeal meal,{required bool undo}) async {
  try {
    final db = ref.read(databaseProvider);
    final row = await LocalWorkspace(db).read('plan-meal-state-v1',
        PlanMealStateService.documentIdFor(plan.documentId,meal.slot.id));
    final service = PlanMealStateService(db);
    final requestId = ref.read(idGeneratorProvider).next();
    if(undo) {
      await service.undo(requestId:requestId,planDocumentId:plan.documentId,
          slotId:meal.slot.id,expectedRevision:row?.revision ?? 0);
    } else {
      await service.skip(requestId:requestId,planDocumentId:plan.documentId,
          slotId:meal.slot.id,date:DiaryDate.parse(meal.slot.date),
          recipe:meal.recipe,plannedPortions:meal.portions,
          expectedPlanRevision:plan.revision,expectedRevision:row?.revision ?? 0);
    }
    ref.invalidate(planMealStateProvider(plan.documentId));
  } catch(error) { if(context.mounted) showFailure(context,error); }
}

Future<void> toggleMealPin(BuildContext context,WidgetRef ref,
    StoredPlan plan,PlannedMeal selected) async {
  try {
    await PlanService(ref.read(databaseProvider),ref.read(clockProvider),
        ref.read(idGeneratorProvider),documentId:plan.documentId).save(
          requestId:ref.read(idGeneratorProvider).next(),expectedPlanRevision:plan.revision,
          meals:[for(final meal in plan.meals)
            if(meal.slot.id == selected.slot.id)PlannedMeal(meal.slot,meal.recipe,
                meal.portions,pinned:!meal.pinned,batchUse:meal.batchUse) else meal]);
    ref.invalidate(planForDateProvider);
  } catch(error) { if(context.mounted) showFailure(context,error); }
}

Future<void> rateMeal(BuildContext context,WidgetRef ref,RecipeVersion recipe,
    String rating) async {
  final accepted = await showDialog<bool>(context:context,builder:(context) => AlertDialog(
    title:Text(tr(context,'Save this preference?','Guardar esta preferência?')),
    content:Text(tr(context,"Today's plan will stay unchanged. Future proposals will use your choice.",
        'O plano de hoje não será alterado. As próximas propostas vão usar esta escolha.')),
    actions:[TextButton(onPressed:() => Navigator.pop(context,false),
      child:Text(tr(context,'Cancel','Cancelar'))),
      FilledButton(onPressed:() => Navigator.pop(context,true),
        child:Text(tr(context,'Save preference','Guardar preferência')))]));
  if(accepted != true) return;
  try {
    final db = ref.read(databaseProvider);
    final profileDoc = await NutritionProfileStore(db).read();
    if(profileDoc == null) throw StateError('PROFILE_REQUIRED');
    final profile = NutritionProfile.fromJson(profileDoc.data);
    final liked = {...profile.likedRecipeIds}..remove(recipe.id);
    final disliked = {...profile.dislikedRecipeIds}..remove(recipe.id);
    if(rating == 'like') liked.add(recipe.id);
    if(rating == 'dislike') disliked.add(recipe.id);
    if(rating == 'tooMuchWork') {
      final workspace = LocalWorkspace(db);
      final old = await workspace.read('preferences','meal-feedback');
      await workspace.put(requestId:ref.read(idGeneratorProvider).next(),
          collection:'preferences',id:'meal-feedback',expectedRevision:old?.revision ?? 0,
          data:{...?old?.data,recipe.id:{'date':ref.read(todayDiaryDateProvider).toIso(),
            'recipeRevision':recipe.revision,'tooMuchWork':true}});
    } else {
      await NutritionProfileStore(db).save(requestId:ref.read(idGeneratorProvider).next(),
          expectedRevision:profileDoc.revision,
          profile:profile.copyWith(likedRecipeIds:liked,dislikedRecipeIds:disliked));
      ref.invalidate(nutritionProfileProvider);
    }
  } catch(error) { if(context.mounted) showFailure(context,error); }
}

void openMealDetail(BuildContext context,WidgetRef ref,StoredPlan plan,
    PlannedMeal meal,MealContent? content,{bool consumed = false}) {
  final settings = ref.read(settingsProvider);
  Navigator.push<void>(context,MaterialPageRoute(builder:(detailContext) =>
    MealDetailScreen(meal:meal,content:content,
      hideCalories:settings['support'] == true || settings['hideCalorieNudges'] == true,
      onConsume:consumed ? null : () => confirmMealConsumption(detailContext,ref,plan,meal),
      onSwap:consumed || meal.pinned ? null : () =>
          proposeMealChanges(detailContext,ref,plan:plan,slotIds:{meal.slot.id}),
      onLikeDislike:(rating) => rateMeal(detailContext,ref,meal.recipe,rating),
      onTooMuchWork:() => rateMeal(detailContext,ref,meal.recipe,'tooMuchWork'))));
}
