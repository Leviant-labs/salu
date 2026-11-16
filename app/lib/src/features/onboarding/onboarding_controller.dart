import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';

final onboardingControllerProvider = StateNotifierProvider.autoDispose<
    OnboardingController, OnboardingState>((ref) => OnboardingController(ref));

final class OnboardingState {
  const OnboardingState({this.step = 0, this.answers = const {},
    this.loading = true, this.busy = false, this.error, this.draft});
  final int step;
  final Map<String,Object?> answers;
  final bool loading, busy;
  final Object? error;
  final MealDraft? draft;
}

class OnboardingController extends StateNotifier<OnboardingState> {
  OnboardingController(this.ref) : super(const OnboardingState()) { _load(); }
  final Ref ref;
  NutritionProfile? _savedProfile;
  Map<String,Object?> _safety = {}, _health = {};
  int _profileRevision = 0;
  bool _disposed = false;
  Future<void> _writes = Future.value();
  LocalWorkspace get _workspace => LocalWorkspace(ref.read(databaseProvider));
  String _id() => ref.read(idGeneratorProvider).next();
  void _set({int? step, Map<String,Object?>? answers, bool? loading,
    bool? busy, Object? error, MealDraft? draft, bool clearDraft = false}) {
    if (_disposed) return;
    state = OnboardingState(step:step ?? state.step,answers:answers ?? state.answers,
        loading:loading ?? state.loading,busy:busy ?? state.busy,error:error,
        draft:clearDraft ? null : draft ?? state.draft);
  }
  Future<void> _load() async {
    try {
      final profile = await _workspace.read('nutrition-profile-v1','current');
      _profileRevision = profile?.revision ?? 0;
      _savedProfile = profile == null ? null : NutritionProfile.fromJson(profile.data);
      _safety = (await _workspace.read('profile','safety'))?.data ?? {};
      _health = (await _workspace.read('health-declaration','current'))?.data ?? {};
      final saved = _savedProfile;
      final answers = <String,Object?>{
        'mealLabels':saved?.mealLabels ?? ['breakfast','lunch','dinner'],
        'maximumCookingMinutes':saved?.maximumCookingMinutes ?? 30,
        'coldLunches':saved?.coldLunches ?? false,
        'householdServings':saved?.householdServings ?? 1,
        'dietaryTags':saved?.dietaryTags.toList() ?? <String>[],
        'avoidedFoodIds':saved?.avoidedFoodIds.toList() ?? <String>[],
        'strictExclusions':SafetyProfile.fromJson(_safety).strictExclusions.toList(),
        'budget':saved?.budget ?? 'standard','wantNumbers':true,
        'support':ref.read(settingsProvider)['support'] == true,
        'hideCalorieNudges':ref.read(settingsProvider)['hideCalorieNudges'] == true,
        'conditions':_health['conditions'] ?? <String,Object?>{},
        if (saved != null) ...{
          'goal':saved.goal.name,
          'ageYears':saved.ageYears?.toString(),
          'heightCm':saved.heightCm?.toDouble().toString(),
          'weightKg':saved.weightKg?.toDouble().toString(),
          'equationConstant':saved.equationConstant,
          'activityPal':saved.activityPal?.toDouble().toString(),
        },
      };
      final partial = await _workspace.read('preferences','onboarding-v2');
      var step = 0;
      MealDraft? draft;
      if (partial?.data['schemaVersion'] == 2) {
        final raw = partial!.data['answers'];
        if (raw is Map) {
          for (final entry in raw.entries) {
            if (entry.key is String && _validAnswer(entry.key as String,entry.value)) {
              answers[entry.key as String] = entry.value;
            }
          }
        }
        final savedStep = partial.data['step'];
        if (savedStep is int && savedStep >= 0 && savedStep <= 18) step = savedStep;
        final draftId = partial.data['draftId'];
        if (draftId is String) {
          draft = await MealDraftStore(ref.read(databaseProvider)).read(draftId);
          if (draft?.status != DraftStatus.review) draft = null;
        }
        if (step == 17 && draft == null) step = 11;
      }
      _set(step:step,answers:answers,loading:false,draft:draft);
    } catch (error) { _set(loading:false,error:error); }
  }

  static bool _validAnswer(String key,Object? value) => switch(key) {
    'goal' => value is String && AdultGoal.values.any((goal) => goal.name == value),
    'mealLabels' => value is List && value.isNotEmpty &&
        value.toSet().length == value.length && value.every(NutritionProfile.allowedMealLabels.contains),
    'maximumCookingMinutes' => value == null || value is int && value > 0,
    'coldLunches' || 'wantNumbers' || 'moreConditions' ||
    'support' || 'hideCalorieNudges' => value is bool,
    'householdServings' => value is int && value > 0,
    'dietaryTags' => value is List && value.every((tag) =>
        const ['vegan','vegetarian','pescatarian'].contains(tag)),
    'avoidedFoodIds' || 'strictExclusions' => value is List &&
        value.every((id) => id is String && id.isNotEmpty),
    'budget' => NutritionProfile.budgets.contains(value),
    'ageYears' || 'heightCm' || 'weightKg' => value == null || value is String,
    'activityPal' => value == null || const ['1.4','1.6','1.8','2.0'].contains(value),
    'equationConstant' => value == null || value == 5 || value == -161,
    'conditions' => value is Map && value.keys.every((key) => key is String),
    _ => false,
  };

  Future<void> _persist() {
    final snapshot = state;
    _writes = _writes.then((_) async {
      final old = await _workspace.read('preferences','onboarding-v2');
      await _workspace.put(requestId:'onboarding:${_id()}',
          collection:'preferences',id:'onboarding-v2',expectedRevision:old?.revision ?? 0,
          data:{'schemaVersion':2,'step':snapshot.step,'answers':snapshot.answers,
            if(snapshot.draft != null)'draftId':snapshot.draft!.id});
    });
    return _writes;
  }

  Future<void> answer(String key,Object? value) async {
    if (!_validAnswer(key,value)) throw ArgumentError('Invalid onboarding answer');
    _set(answers:{...state.answers,key:value},clearDraft:true);
    await _persist();
  }

  bool get canContinue {
    final a = state.answers;
    bool positive(String key) {
      try { return Exact.parse(a[key] as String? ?? '').positive; }
      catch (_) { return false; }
    }
    return switch(state.step) {
      1 => a['goal'] != null,
      12 => (int.tryParse(a['ageYears'] as String? ?? '') ?? 0) > 0,
      13 => positive('heightCm'),
      14 => positive('weightKg'),
      15 => a['equationConstant'] != null,
      16 => a['activityPal'] != null,
      _ => true,
    };
  }

  Future<void> next() async {
    if (!canContinue || state.busy) return;
    if (state.step == 16 || state.step == 11 && state.answers['wantNumbers'] == false) {
      await preview(); return;
    }
    var next = state.step + 1;
    if (next == 10 && state.answers['moreConditions'] != true) next = 11;
    _set(step:next); await _persist();
  }
  Future<void> back() async {
    var previous = state.step - 1;
    if (state.step == 17 && state.answers['wantNumbers'] == false) previous = 11;
    if (previous == 10 && state.answers['moreConditions'] != true) previous = 9;
    _set(step:previous.clamp(0,18)); await _persist();
  }

  NutritionProfile get proposedProfile {
    final a = state.answers;
    final numbers = a['wantNumbers'] == true;
    Exact? amount(String key) => !numbers || a[key] == null ? null :
        Exact.parse(a[key] as String);
    return NutritionProfile(goal:AdultGoal.values.byName(a['goal']! as String),
        ageYears:numbers ? int.parse(a['ageYears']! as String) : _savedProfile?.ageYears,
        heightCm:numbers ? amount('heightCm') : _savedProfile?.heightCm,
        weightKg:numbers ? amount('weightKg') : _savedProfile?.weightKg,
        equationConstant:numbers ? a['equationConstant'] as int? : _savedProfile?.equationConstant,
        activityPal:numbers ? amount('activityPal') : _savedProfile?.activityPal,
        mealLabels:(a['mealLabels']! as List).cast<String>(),
        maximumCookingMinutes:a['maximumCookingMinutes'] as int?,
        coldLunches:a['coldLunches'] == true,budget:a['budget']! as String,
        householdServings:a['householdServings']! as int,
        dietaryTags:(a['dietaryTags']! as List).cast<String>().toSet(),
        avoidedFoodIds:(a['avoidedFoodIds']! as List).cast<String>().toSet(),
        likedRecipeIds:_savedProfile?.likedRecipeIds ?? {},
        dislikedRecipeIds:_savedProfile?.dislikedRecipeIds ?? {},
        preferVariety:_savedProfile?.preferVariety ?? false);
  }

  Future<void> preview({Set<String> replaceSlotIds = const {}}) async {
    _set(busy:true);
    try {
      await _writes;
      final profile = proposedProfile;
      final safety = SafetyProfile.fromJson({..._safety,
        'strictExclusions':state.answers['strictExclusions']});
      final health = <String,Object?>{..._health,'schemaVersion':1,
        'goal':profile.goal.name,'conditions':state.answers['conditions']};
      final draft = await ref.read(guidedPlanServiceProvider).propose(
          requestId:'onboard:${_id()}',expectedProfileRevision:_profileRevision,
          startDate:ref.read(todayDiaryDateProvider),proposedProfile:profile,
          proposedSafety:safety,proposedHealthDeclaration:health,
          proposedSettings:{
            'support':state.answers['support'] == true,
            'hideCalorieNudges':state.answers['hideCalorieNudges'] == true,
          },
          recalculateTarget:state.answers['wantNumbers'] == true,
          completesOnboarding:true,replaceSlotIds:replaceSlotIds);
      _set(step:17,busy:false,draft:draft);
      await _persist();
    } catch (error) { _set(busy:false,error:error); }
  }

  Future<void> accept() async {
    final draft = state.draft;
    if (draft == null || state.busy) return;
    _set(busy:true);
    try {
      await ref.read(guidedPlanServiceProvider).accept(draftId:draft.id,
          expectedDraftRevision:draft.revision,
          expectedPlanRevision:draft.values['expectedPlanRevision']! as int,
          requestId:'onboarding:accept:${draft.id}');
      ref.invalidate(nutritionProfileProvider);
      ref.invalidate(planForDateProvider);
      ref.invalidate(groceryListProvider);
      _set(step:18,busy:false);
      await _persist();
    } catch (error) { _set(busy:false,error:error); }
  }
  Future<void> swap(String slotId) async {
    final draft = state.draft;
    if (draft == null || state.busy) return;
    _set(busy:true);
    try {
      final updated = await ref.read(guidedPlanServiceProvider).swapDraft(
          draftId:draft.id,expectedDraftRevision:draft.revision,
          slotId:slotId,requestId:'onboarding:swap:${_id()}');
      _set(draft:updated,busy:false);
      await _persist();
    } catch (error) { _set(busy:false,error:error); }
  }

  Future<void> finish() async {
    await _writes;
    final old = await _workspace.read('preferences', 'onboarding-v2');
    if (old != null) {
      await _workspace.put(requestId:'onboarding:finished:${_id()}',
          collection:'preferences',id:'onboarding-v2',
          expectedRevision:old.revision,
          data:{'schemaVersion':2,'step':0,'answers':<String,Object?>{}});
    }
    await ref.read(settingsProvider.notifier).reload();
  }

  @override
  void dispose() { _disposed = true; super.dispose(); }
}
