import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import '../../widgets/meal_library_status.dart';
import 'onboarding_controller.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key,this.existingUser = false});
  final bool existingUser;
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _householdInvalid = false;
  OnboardingController get controller => ref.read(onboardingControllerProvider.notifier);
  String t(String en,String pt) => tr(context,en,pt);
  Future<void> _finish() async {
    await controller.finish();
    if (mounted && widget.existingUser && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingControllerProvider);
    if (state.loading) return const Scaffold(body:Center(child:CircularProgressIndicator()));
    return Scaffold(appBar:AppBar(
      title:const Text('Salu'),
      leading:state.step > 0 && state.step < 18 ? IconButton(
        tooltip:t('Back','Voltar'),icon:const Icon(Icons.arrow_back),
        onPressed:state.busy ? null : controller.back) : null,
      actions:[if(widget.existingUser) TextButton(onPressed:state.busy ? null :
          () => Navigator.of(context).pop(),child:Text(t('Cancel','Cancelar')))]),
      body:SafeArea(child:Align(alignment:Alignment.topCenter,
        child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:720),
          child:ListView(padding:const EdgeInsets.all(16),children:[
            if(state.step < 18) ...[
              LinearProgressIndicator(value:(state.step + 1)/18),
              const SizedBox(height:8),
              Text(t('Your plan, step ${state.step + 1} of 18',
                  'O seu plano, passo ${state.step + 1} de 18')),
              const SizedBox(height:24),
            ],
            const MealLibraryStatus(),
            ..._page(state),
            if(state.error != null) ...[
              const SizedBox(height:16),
              Text(_error(state.error!),style:TextStyle(color:Theme.of(context).colorScheme.error)),
              if(state.step >= 11 && state.step < 18) TextButton.icon(
                onPressed:state.busy ? null : () => controller.preview(),
                icon:const Icon(Icons.refresh),label:Text(t('Try plan again','Tentar o plano novamente'))),
            ],
            const SizedBox(height:24),
            if(state.busy) const Center(child:CircularProgressIndicator())
            else if(state.step < 17) FilledButton(
              key:const Key('onboarding-next'),
              onPressed:controller.canContinue && !_householdInvalid ? controller.next : null,
              child:Text(state.step == 0 ? t('Start','Começar') :
                state.step == 16 || state.step == 11 && state.answers['wantNumbers'] == false
                ? t('Build my plan','Criar o meu plano') : t('Continue','Continuar'))),
          ])))));
  }
  List<Widget> _heading(String en,String pt,[String? detailEn,String? detailPt]) => [
    Text(t(en,pt),style:Theme.of(context).textTheme.headlineMedium),
    if(detailEn != null) ...[const SizedBox(height:8),Text(t(detailEn,detailPt!))],
    const SizedBox(height:20),
  ];
  Widget _option(String title,Object? value,Object? selected,
      Future<void> Function() onSelect,{String? subtitle}) => Card(
        child:ListTile(minVerticalPadding:12,title:Text(title),
          subtitle:subtitle == null ? null : Text(subtitle),
          trailing:Icon(value == selected ? Icons.radio_button_checked : Icons.radio_button_off),
          selected:value == selected,onTap:onSelect));
  List<Widget> _page(OnboardingState state) {
    final a = state.answers;
    Future<void> answer(String key,Object? value) => controller.answer(key,value);
    switch(state.step) {
      case 0:
        return [..._heading('A meal plan that fits your day','Um plano de refeições à sua medida'),
          const Icon(Icons.restaurant_menu,size:72),const SizedBox(height:24),
          Text(t('A few questions. Real meals. A clear next step.',
              'Algumas perguntas. Refeições reais. Um próximo passo claro.')),
          const SizedBox(height:16),
          DropdownButtonFormField<String>(initialValue:
            ref.watch(settingsProvider)['language'] as String? ?? 'en',
            decoration:InputDecoration(labelText:t('Language','Idioma')),
            items:const [DropdownMenuItem(value:'en',child:Text('English')),
              DropdownMenuItem(value:'pt',child:Text('Português (Portugal)'))],
            onChanged:(value) { if(value != null) ref.read(settingsProvider.notifier).change('language',value); })];
      case 1:
        return [..._heading('What would you like to work towards?','Qual é o seu objetivo?'),
          for(final goal in AdultGoal.values)
            _option(_goal(goal),goal.name,a['goal'],() => answer('goal',goal.name))];
      case 2:
        final labels = (a['mealLabels']! as List).cast<String>();
        return [..._heading('Which meals should we plan?','Que refeições vamos planear?'),
          for(final label in NutritionProfile.allowedMealLabels)
            CheckboxListTile(title:Text(_label(label)),value:labels.contains(label),
              onChanged:(checked) {
                final selected = {...labels};
                checked == true ? selected.add(label) : selected.remove(label);
                if(selected.isNotEmpty) {
                  answer('mealLabels',[
                    for(final ordered in NutritionProfile.allowedMealLabels)
                      if(selected.contains(ordered)) ordered]);
                }
              })];
      case 3:
        return [..._heading('How much cooking time works for you?','Quanto tempo tem para cozinhar?'),
          for(final minutes in [15,30,45,null]) _option(minutes == null ?
            t('Flexible','Flexível') : t('$minutes minutes','$minutes minutos'),
            minutes,a['maximumCookingMinutes'],() => answer('maximumCookingMinutes',minutes))];
      case 4:
        return [..._heading('Do lunches need to work cold?','Os almoços precisam de ser frios?'),
          SwitchListTile(title:Text(t('Cold lunches','Almoços frios')),
            subtitle:Text(t('Meals you can pack and eat without reheating.',
              'Refeições para levar e comer sem aquecer.')),
            value:a['coldLunches'] == true,onChanged:(value) => answer('coldLunches',value))];
      case 5:
        return [..._heading('How many people are you shopping for?','Para quantas pessoas vai fazer compras?'),
          Text(t('Your own portions and targets stay personal. Shopping quantities cover the household.',
              'As suas porções e metas são pessoais. As compras incluem as outras pessoas.')),
          const SizedBox(height:16),
          TextFormField(key:const Key('onboarding-household'),initialValue:'${a['householdServings']}',
            keyboardType:TextInputType.number,decoration:InputDecoration(
              labelText:t('People','Pessoas'),errorText:_householdInvalid ?
                  t('Enter a positive whole number','Introduza um número inteiro positivo') : null),
            onChanged:(value) {
              final parsed = int.tryParse(value);
              setState(() => _householdInvalid = parsed == null || parsed < 1);
              if(parsed != null && parsed > 0) answer('householdServings',parsed);
            })];
      case 6:
        final tags = (a['dietaryTags']! as List).cast<String>();
        final current = tags.contains('vegan') ? 'vegan' : tags.contains('vegetarian') ?
            'vegetarian' : tags.contains('pescatarian') ? 'pescatarian' : 'omnivore';
        return [..._heading('What do you enjoy eating?','Como prefere comer?'),
          for(final diet in ['omnivore','vegetarian','vegan','pescatarian'])
            _option(switch(diet) {'omnivore'=>t('A bit of everything','Um pouco de tudo'),
              'vegetarian'=>t('Vegetarian','Vegetariano'),'vegan'=>t('Vegan','Vegano'),
              _=>t('Fish, but no meat','Peixe, mas sem carne')},diet,current,
              () => answer('dietaryTags',switch(diet){
                'vegan'=>['vegan','vegetarian','pescatarian'],
                'vegetarian'=>['vegetarian','pescatarian'],
                'pescatarian'=>['pescatarian'],_=> <String>[]}))];
      case 7:
        final avoided = (a['avoidedFoodIds']! as List).cast<String>().toSet();
        const groups = {'fish':['814','876','966'],'poultry':['11','284'],
          'eggs':['83'],'dairy':['76'],'legumes':['532','536','538','240002'],'tofu':['545']};
        return [..._heading('Anything you would rather leave out?','Quer deixar algum alimento de fora?'),
          for(final group in groups.entries) CheckboxListTile(
            title:Text(switch(group.key){'fish'=>t('No fish','Sem peixe'),
              'poultry'=>t('Poultry','Aves'),'eggs'=>t('Eggs','Ovos'),
              'dairy'=>t('Dairy','Laticínios'),'legumes'=>t('Beans, chickpeas and lentils','Feijão, grão e lentilhas'),
              _=>'Tofu'}),value:group.value.every((id) => avoided.contains('insa-bdca:$id')),
            onChanged:(checked) {
              final next = {...avoided};
              for(final id in group.value) {
                checked == true ? next.add('insa-bdca:$id') : next.remove('insa-bdca:$id');
              }
              answer('avoidedFoodIds',next.toList()..sort());
            }),
          TextButton(onPressed:_addFood,child:Text(t('Add another food','Adicionar outro alimento')))];
      case 8:
        final selected = (a['strictExclusions']! as List).cast<String>().toSet();
        const allergens = ['milk','egg','fish','crustaceans','molluscs','peanut','nut',
          'soy','gluten','celery','mustard','sesame','sulphites','lupin'];
        return [..._heading('Any food allergies to exclude?','Tem alergias alimentares a excluir?',
          'Optional. Leave blank if none apply.','Opcional. Deixe em branco se não se aplicar.'),
          if(selected.isNotEmpty) Text(t('Check packaging and cross-contact.',
              'Verifique os rótulos e a contaminação cruzada.')),
          for(final id in {...allergens,...selected}) CheckboxListTile(
            title:Text(_allergen(id)),value:selected.contains(id),onChanged:(checked) {
              final next = {...selected};
              checked == true ? next.add(id) : next.remove(id);
              answer('strictExclusions',next.toList()..sort());
            })];
      case 9:
        return [..._heading('What works for your grocery budget?','Qual é a sua preferência para as compras?'),
          for(final budget in NutritionProfile.budgets) _option(switch(budget){
            'lowerCost'=>t('Keep it lower-cost','Poupar nas compras'),
            'standard'=>t('A balanced mix','Uma mistura equilibrada'),
            _=>t('Flexible','Flexível')},budget,a['budget'],() => answer('budget',budget)),
          SwitchListTile(title:Text(t('Anything else to consider?','Há mais alguma coisa a considerar?')),
            subtitle:Text(t('Optional health declarations','Declarações de saúde opcionais')),
            value:a['moreConditions'] == true,onChanged:(value) => answer('moreConditions',value))];
      case 10:
        final conditions = Map<String,Object?>.from(a['conditions']! as Map);
        return [..._heading('Anything else to consider?','Há mais alguma coisa a considerar?',
          'Optional preferences for relative meal guidance.','Preferências opcionais para orientar as refeições.'),
          for(final condition in DeclaredCondition.values) CheckboxListTile(
            title:Text(_condition(condition)),value:conditions[condition.name] == true,
            onChanged:(value) => answer('conditions',{...conditions,condition.name:value}))];
      case 11:
        return [..._heading('Would you like starting calorie and macro estimates?',
          'Quer estimativas iniciais de calorias e macronutrientes?'),
          _option(t('Yes, include starting estimates','Sim, incluir estimativas iniciais'),true,
            a['wantNumbers'],() async {
              await answer('wantNumbers',true);
              await answer('hideCalorieNudges',false);
            }),
          _option(t('Plan without numbers','Planear sem números'),false,a['wantNumbers'],
            () async {
              await answer('wantNumbers',false);
              await answer('hideCalorieNudges',true);
            }),
          SwitchListTile(title:Text(t('Supportive display','Modo de apoio')),
            subtitle:Text(t('Hide calorie, weight and fasting prompts.','Ocultar avisos de calorias, peso e jejum.')),
            value:a['support'] == true,onChanged:(value) => answer('support',value))];
      case 12:
        return [..._heading('How old are you?','Qual é a sua idade?'),
          _number('ageYears',t('Age in years','Idade em anos'),a)];
      case 13:
        return [..._heading('What is your height?','Qual é a sua altura?'),
          _number('heightCm',t('Height (cm)','Altura (cm)'),a)];
      case 14:
        return [..._heading('What is your current weight?','Qual é o seu peso atual?'),
          _number('weightKg',t('Weight (kg)','Peso (kg)'),a)];
      case 15:
        return [..._heading('Which equation branch should we use?','Que ramo da fórmula devemos usar?',
          'Select the Mifflin–St Jeor constant explicitly.','Selecione explicitamente a constante de Mifflin–St Jeor.'),
          _option(t('Male equation (+5)','Equação masculina (+5)'),5,a['equationConstant'],
              () => answer('equationConstant',5)),
          _option(t('Female equation (−161)','Equação feminina (−161)'),-161,a['equationConstant'],
              () => answer('equationConstant',-161))];
      case 16:
        return [..._heading('What does a typical day look like?','Como é um dia habitual?'),
          for(final pal in ['1.4','1.6','1.8','2.0']) _option(switch(pal){
            '1.4'=>t('Mostly seated, little daily activity','Maioritariamente sentado, pouca atividade'),
            '1.6'=>t('Some walking and regular light activity','Algumas caminhadas e atividade ligeira regular'),
            '1.8'=>t('Active work or frequent substantial activity','Trabalho ativo ou atividade intensa frequente'),
            _=>t('Very active work and substantial daily activity','Trabalho muito ativo e atividade diária intensa')},
            pal,a['activityPal'],() => answer('activityPal',pal),subtitle:'PAL $pal')];
      case 17:
        return _review(state);
      case 18:
        final auth = ref.watch(chatGptAuthProvider);
        return [..._heading('Your plan is ready','O seu plano está pronto'),
          Text(t('Optional: connect ChatGPT to ask for practical changes. This connects AI usage, not a Salu account.',
              'Opcional: ligue o ChatGPT para pedir alterações práticas. Isto liga a utilização de IA, não cria uma conta Salu.')),
          const SizedBox(height:16),
          FilledButton(onPressed:() async {
            try { await auth.connect(); if(mounted) await _finish(); }
            catch (_) { if(mounted) setState(() {}); }
          },child:Text(t('Continue with ChatGPT','Continuar com ChatGPT'))),
          if(auth.connectionState.errorCode != null) Text(auth.connectionState.errorCode!),
          TextButton(onPressed:_finish,child:Text(t('Not now','Agora não')))];
      default: return const [];
    }
  }

  Widget _number(String key,String label,Map<String,Object?> answers) => TextFormField(
    key:ValueKey('onboarding-$key'),initialValue:answers[key] as String? ?? '',
    keyboardType:const TextInputType.numberWithOptions(decimal:true),
    decoration:InputDecoration(labelText:label),onChanged:(value) =>
      controller.answer(key,value.replaceAll(',','.')));

  List<Widget> _review(OnboardingState state) {
    final draft = state.draft;
    if(draft == null) return _heading('Build your plan','Criar o seu plano');
    final values = draft.values;
    final profile = NutritionProfile.fromJson(Map<String,Object?>.from(values['profile']! as Map));
    final target = values['target'] == null ? null :
        DeclaredTarget.fromJson(Map<String,Object?>.from(values['target']! as Map));
    final conditions = (state.answers['conditions'] as Map?) ?? const {};
    final cap = profile.maximumCookingMinutes;
    final showGrainCapNote = shouldShowWholeGrainCapNote(
        conditions: conditions,
        maximumCookingMinutes: cap,
        mealLabels: profile.mealLabels);
    final rawMeals = (values['meals']! as List).cast<Map<Object?, Object?>>();
    final content = ref.watch(mealContentProvider).valueOrNull ?? {};
    String? previousDate;
    return [..._heading('A week that fits your answers','Uma semana à sua medida'),
      Text('${_goal(profile.goal)} · ${profile.maximumCookingMinutes == null ? t('Flexible','Flexível') : '${profile.maximumCookingMinutes} min'} · ${profile.householdServings} ${t('person(s)','pessoa(s)')}'),
      if (showGrainCapNote) ...[
        const SizedBox(height:12),
        Card(key:const Key('whole-grain-time-note'),
          color:Theme.of(context).colorScheme.surfaceContainerHighest,
          child:Padding(padding:const EdgeInsets.all(16),
            child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(t(
                'Some whole-grain rice meals take 45 minutes. Your $cap-minute limit excludes them by time; raise it to 45 minutes if you want them considered.',
                'Algumas refeições de arroz integral levam 45 minutos. O seu limite de $cap minutos exclui-as por tempo; aumente para 45 minutos se quiser que sejam consideradas.')),
              TextButton(
                onPressed:state.busy ? null : () async {
                  await controller.answer('maximumCookingMinutes',45);
                  await controller.preview();
                },
                child:Text(t('Raise to 45 minutes','Aumentar para 45 minutos'))),
            ]))),
      ],
      if(target != null && state.answers['support'] != true &&
          state.answers['hideCalorieNudges'] != true) ...[
        const SizedBox(height:16),
        Text('${target.energyKcal.toDouble().round()} kcal'
          '${target.proteinG == null ? '' : ' · ${target.proteinG!.toDouble().round()} g ${t('protein','proteína')}'}'
          '${target.fatG == null ? '' : ' · ${target.fatG!.toDouble().round()} g ${t('fat','gordura')}'}'
          '${target.carbohydrateG == null ? '' : ' · ${target.carbohydrateG!.toDouble().round()} g ${t('carbs','hidratos')}'}'),
        if(target.origin == TargetOrigin.calculatedEstimate) ...[
          Text(t('Starting estimate—not a measurement','Estimativa inicial — não é uma medição')),
          ExpansionTile(title:Text(t('Calculation details','Detalhes do cálculo')),
            children:[Padding(padding:const EdgeInsets.all(16),child:Text(t(
              'Mifflin–St Jeor × selected PAL; goal adjustment: −10% / unchanged / +5%. No exercise add-back. Protein: max(0.83 g/kg, 15% of energy); fat: 30%; carbohydrate: remainder after a 50 kcal fibre allocation.',
              'Mifflin–St Jeor × PAL selecionado; ajuste do objetivo: −10% / sem alteração / +5%. Sem somar exercício. Proteína: máximo de 0,83 g/kg ou 15% da energia; gordura: 30%; hidratos: restante após 50 kcal atribuídas à fibra.')))])
        ],
      ],
      const SizedBox(height:16),
      for(final raw in rawMeals) ...[
        if(previousDate != raw['date']) ...[
          const SizedBox(height:12),
          Text(previousDate = raw['date']! as String,
              style:Theme.of(context).textTheme.titleLarge),
        ],
        Builder(builder:(context) {
          final recipe = recipeFromSnapshot(Map<String,Object?>.from(raw['recipe']! as Map));
          final meta = content[recipe.id];
          final titles = meta?['titles'] as Map?;
          final locale = Localizations.localeOf(context).languageCode == 'pt' ? 'pt-PT' : 'en';
          final portion = Exact.fromJson(Map<String,Object?>.from(raw['portions']! as Map));
          return Card(child:ListTile(title:Text(titles?[locale] as String? ?? recipe.name),
            subtitle:Text('${_label(raw['label']! as String)} · ${recipe.minutes} min · ${portion.toDouble()} ${t('portion(s)','porção(ões)')}'),
            trailing:IconButton(tooltip:t('Swap','Trocar'),icon:const Icon(Icons.swap_horiz),
              onPressed:state.busy ? null : () => controller.swap(raw['slot']! as String))));
        }),
      ],
      const SizedBox(height:16),
      FilledButton(key:const Key('onboarding-accept'),onPressed:state.busy ? null : controller.accept,
        child:Text(t('Use this plan','Usar este plano'))),
      TextButton(onPressed:state.busy ? null : controller.back,child:Text(t('Edit answers','Editar respostas'))),
    ];
  }
  Future<void> _addFood() async {
    final input = TextEditingController();
    Food? selected;
    List<Food> results = [];
    await showDialog<void>(context:context,builder:(dialogContext) =>
      StatefulBuilder(builder:(context,setDialogState) => AlertDialog(
        title:Text(t('Leave out a food','Excluir um alimento')),
        content:SizedBox(width:500,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:input,decoration:InputDecoration(labelText:t('Search foods','Pesquisar alimentos')),
            onChanged:(query) async {
              final found = query.trim().length < 2 ? <Food>[] :
                  await ref.read(foodRepositoryProvider).search(query);
              if(dialogContext.mounted) setDialogState(() => results = found.take(12).toList());
            }),
          for(final food in results) ListTile(title:Text(food.name),onTap:() {
            selected = food; Navigator.of(dialogContext).pop();
          }),
        ]))),actions:[TextButton(onPressed:() => Navigator.of(dialogContext).pop(),
          child:Text(t('Cancel','Cancelar')))])));
    input.dispose();
    if(selected != null && mounted) {
      final previous = (ref.read(onboardingControllerProvider).answers['avoidedFoodIds']! as List).cast<String>();
      await controller.answer('avoidedFoodIds',{...previous,selected!.id}.toList()..sort());
    }
  }
  String _error(Object error) {
    if(error is GuidedPlanException) return error.message;
    if(error is TargetEstimateException) {
      return error.code == 'TARGET_INPUT_REQUIRED'
          ? t('Complete these estimate inputs: ${error.missingInputs.join(', ')}',
              'Preencha estes dados: ${error.missingInputs.join(', ')}')
          : t('These inputs do not produce a usable estimate. Review your answers.',
              'Estes dados não produzem uma estimativa utilizável. Reveja as respostas.');
    }
    return t('Your answers are saved. Review your choices and try again.',
        'As respostas estão guardadas. Reveja as escolhas e tente novamente.');
  }
  String _goal(AdultGoal goal) => switch(goal) {
    AdultGoal.loseWeight=>t('Lose weight','Perder peso'),
    AdultGoal.maintainWeight=>t('Maintain weight','Manter peso'),
    AdultGoal.gainWeight=>t('Gain weight','Ganhar peso'),
    AdultGoal.notDeclared=>t('Eat more consistently','Comer com mais regularidade')};
  String _label(String label) => switch(label) {
    'breakfast'=>t('Breakfast','Pequeno-almoço'),'lunch'=>t('Lunch','Almoço'),
    'snack'=>t('Snack','Lanche'),_=>t('Dinner','Jantar')};
  String _allergen(String id) => switch(id) {
    'milk'=>t('Milk','Leite'),'egg'=>t('Egg','Ovo'),'fish'=>t('Fish','Peixe'),
    'crustaceans'=>t('Crustaceans','Crustáceos'),'molluscs'=>t('Molluscs','Moluscos'),
    'peanut'=>t('Peanuts','Amendoim'),'nut'=>t('Tree nuts','Frutos de casca rija'),
    'soy'=>t('Soy','Soja'),'gluten'=>t('Gluten','Glúten'),'celery'=>t('Celery','Aipo'),
    'mustard'=>t('Mustard','Mostarda'),'sesame'=>t('Sesame','Sésamo'),
    'sulphites'=>t('Sulphites','Sulfitos'),'lupin'=>t('Lupin','Tremoço'),_=>id};
  String _condition(DeclaredCondition condition) => switch(condition) {
    DeclaredCondition.highTriglycerides=>t('High triglycerides','Triglicéridos elevados'),
    DeclaredCondition.diabetes=>t('Diabetes','Diabetes'),
    DeclaredCondition.highCholesterol=>t('High cholesterol','Colesterol elevado'),
    DeclaredCondition.lowBloodGlucoseHistoryOrRisk=>t('Low blood glucose history','Historial de glicemia baixa'),
    DeclaredCondition.highBloodPressure=>t('High blood pressure','Tensão arterial elevada'),
    DeclaredCondition.chronicKidneyDisease=>t('Kidney disease','Doença renal'),
    DeclaredCondition.eatingDisorderConcerns=>t('Eating-related concerns','Preocupações alimentares'),
    DeclaredCondition.lactoseIntolerance=>t('Lactose intolerance','Intolerância à lactose'),
    DeclaredCondition.gout=>t('Gout','Gota'),
    DeclaredCondition.irritableBowelSyndrome=>t('Irritable bowel syndrome','Síndrome do intestino irritável'),
    DeclaredCondition.foodAllergy=>t('Food allergy','Alergia alimentar'),
    DeclaredCondition.coeliacDisease=>t('Coeliac disease','Doença celíaca')};
}

/// True when a lipid declaration is active, the plan includes a main meal, and
/// the cooking cap excludes every source-verified 45-minute whole-grain rice
/// option. The note must not imply that all whole grains are excluded: shorter
/// whole-grain oats/toast meals remain eligible.
bool shouldShowWholeGrainCapNote({
  required Map<Object?, Object?> conditions,
  required int? maximumCookingMinutes,
  required Iterable<String> mealLabels,
}) =>
    (conditions['highTriglycerides'] == true ||
        conditions['highCholesterol'] == true) &&
    (mealLabels.contains('lunch') || mealLabels.contains('dinner')) &&
    maximumCookingMinutes != null &&
    maximumCookingMinutes < 45;
