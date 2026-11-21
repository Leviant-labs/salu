// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'Salu';

  @override
  String get navToday => 'Hoje';

  @override
  String get navFood => 'Alimentos';

  @override
  String get navPlan => 'Plano';

  @override
  String get navSettings => 'Definições';

  @override
  String get profileOpenErrorTitle => 'Não foi possível abrir o teu perfil';

  @override
  String get profileOpenErrorBody =>
      'Tenta novamente ou continua para o diário e configura o perfil mais tarde.';

  @override
  String get actionTryAgain => 'Tentar novamente';

  @override
  String get actionContinueToDiary => 'Continuar para o diário';

  @override
  String get actionCancel => 'Cancelar';

  @override
  String get actionBack => 'Voltar';

  @override
  String get actionNext => 'Seguinte';

  @override
  String get actionSkipSetup => 'Ignorar configuração';

  @override
  String get actionSaveProfile => 'Guardar perfil';

  @override
  String get actionSaveWithoutAi => 'Guardar sem IA';

  @override
  String get actionSave => 'Guardar';

  @override
  String get actionClose => 'Fechar';

  @override
  String get todayTitle => 'Diário alimentar';

  @override
  String get todaySubtitle =>
      'Um pouco mais de consciência, uma refeição de cada vez.';

  @override
  String get todayPreviousDay => 'Dia anterior';

  @override
  String get todayNextDay => 'Dia seguinte';

  @override
  String get todayLogMeal => 'Registar refeição';

  @override
  String get todayFindCorrectMeal => 'Encontrar e corrigir refeição';

  @override
  String get todayWeeklyCheckIn => 'Balanço semanal';

  @override
  String get todayReuseFromLibrary => 'Reutilizar da biblioteca';

  @override
  String get todayRecordedToday => 'Registado hoje';

  @override
  String get todayRecordedOnDay => 'Registado neste dia';

  @override
  String get todayOptionalTargets => 'Objetivos declarados (apenas referência)';

  @override
  String get todayNothingLoggedTitle => 'Nada registado ainda';

  @override
  String get todayNothingLoggedBody =>
      'Começa com uma foto da refeição, uma descrição ou uma pesquisa de alimentos.';

  @override
  String get todayIndividualFoods => 'Alimentos individuais';

  @override
  String get todayLoadError =>
      'Não foi possível carregar todas as refeições. Tentar novamente';

  @override
  String get todayReviewOrCorrect => 'Rever ou corrigir';

  @override
  String get todayEstimating => 'A estimar…';

  @override
  String get todayFoodsNotIdentified =>
      'Alimentos e porções ainda não identificados';

  @override
  String get todayPhotoUnavailable => 'Foto da refeição indisponível';

  @override
  String get todayAiEstimate => 'Estimativa de IA';

  @override
  String get todayPartialLabel => 'parcial';

  @override
  String get todayEstimatedSemantics => 'estimado';

  @override
  String get todayUnknownSemantics => 'desconhecido';

  @override
  String get todayPartialSemantics => 'total parcial';

  @override
  String get todayOpenConnections => 'Abrir ligações de IA';

  @override
  String get todaySwitchConnection => 'Mudar ou verificar ligação';

  @override
  String get libraryTitle => 'A tua biblioteca alimentar';

  @override
  String get librarySearchHint => 'Pesquisar na biblioteca';

  @override
  String get libraryTabFoods => 'Alimentos';

  @override
  String get libraryTabMeals => 'Refeições';

  @override
  String get libraryTabRecipes => 'Receitas';

  @override
  String get libraryTabLeftovers => 'Sobras';

  @override
  String get libraryEmptyFoods =>
      'Nenhum alimento guardado corresponde à pesquisa.';

  @override
  String get libraryEmptyMeals =>
      'Nenhuma refeição guardada corresponde à pesquisa.';

  @override
  String get libraryEmptyRecipes => 'Nenhuma receita corresponde à pesquisa.';

  @override
  String get libraryEmptyLeftovers => 'Nenhum lote cozinhado disponível.';

  @override
  String get libraryLoadError =>
      'Não foi possível carregar a biblioteca alimentar.';

  @override
  String get libraryFavoriteLabel => 'Favorito';

  @override
  String libraryServingsRemaining(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses restantes',
      one: '1 dose restante',
    );
    return '$_temp0';
  }

  @override
  String get nutrientEnergy => 'Energia';

  @override
  String get nutrientProtein => 'Proteína';

  @override
  String get nutrientCarbs => 'Hidratos';

  @override
  String get nutrientFat => 'Gordura';

  @override
  String get nutrientFiber => 'Fibra';

  @override
  String get mealSlotBreakfast => 'Pequeno-almoço';

  @override
  String get mealSlotLunch => 'Almoço';

  @override
  String get mealSlotDinner => 'Jantar';

  @override
  String get mealSlotSnack => 'Lanche';

  @override
  String get mealSlotOther => 'Outro';

  @override
  String get errorNotConnected => 'Nenhum fornecedor de IA está ligado.';

  @override
  String get errorAuthFailed =>
      'A autenticação do fornecedor de IA falhou. Verifica a ligação.';

  @override
  String get errorQuotaExceeded => 'Quota do fornecedor de IA excedida.';

  @override
  String get errorRateLimited =>
      'Limite de pedidos do fornecedor de IA atingido. Tenta novamente em breve.';

  @override
  String get errorGeneric => 'Ocorreu um erro. Tenta novamente.';
}

/// The translations for Portuguese, as used in Portugal (`pt_PT`).
class AppLocalizationsPtPt extends AppLocalizationsPt {
  AppLocalizationsPtPt() : super('pt_PT');

  @override
  String get appTitle => 'Salu';

  @override
  String get navToday => 'Hoje';

  @override
  String get navFood => 'Alimentos';

  @override
  String get navPlan => 'Plano';

  @override
  String get navSettings => 'Definições';

  @override
  String get profileOpenErrorTitle => 'Não foi possível abrir o teu perfil';

  @override
  String get profileOpenErrorBody =>
      'Tenta novamente ou continua para o diário e configura o perfil mais tarde.';

  @override
  String get actionTryAgain => 'Tentar novamente';

  @override
  String get actionContinueToDiary => 'Continuar para o diário';

  @override
  String get actionCancel => 'Cancelar';

  @override
  String get actionBack => 'Voltar';

  @override
  String get actionNext => 'Seguinte';

  @override
  String get actionSkipSetup => 'Ignorar configuração';

  @override
  String get actionSaveProfile => 'Guardar perfil';

  @override
  String get actionSaveWithoutAi => 'Guardar sem IA';

  @override
  String get actionSave => 'Guardar';

  @override
  String get actionClose => 'Fechar';

  @override
  String get todayTitle => 'Diário alimentar';

  @override
  String get todaySubtitle =>
      'Um pouco mais de consciência, uma refeição de cada vez.';

  @override
  String get todayPreviousDay => 'Dia anterior';

  @override
  String get todayNextDay => 'Dia seguinte';

  @override
  String get todayLogMeal => 'Registar refeição';

  @override
  String get todayFindCorrectMeal => 'Encontrar e corrigir refeição';

  @override
  String get todayWeeklyCheckIn => 'Balanço semanal';

  @override
  String get todayReuseFromLibrary => 'Reutilizar da biblioteca';

  @override
  String get todayRecordedToday => 'Registado hoje';

  @override
  String get todayRecordedOnDay => 'Registado neste dia';

  @override
  String get todayOptionalTargets => 'Objetivos declarados (apenas referência)';

  @override
  String get todayNothingLoggedTitle => 'Nada registado ainda';

  @override
  String get todayNothingLoggedBody =>
      'Começa com uma foto da refeição, uma descrição ou uma pesquisa de alimentos.';

  @override
  String get todayIndividualFoods => 'Alimentos individuais';

  @override
  String get todayLoadError =>
      'Não foi possível carregar todas as refeições. Tentar novamente';

  @override
  String get todayReviewOrCorrect => 'Rever ou corrigir';

  @override
  String get todayEstimating => 'A estimar…';

  @override
  String get todayFoodsNotIdentified =>
      'Alimentos e porções ainda não identificados';

  @override
  String get todayPhotoUnavailable => 'Foto da refeição indisponível';

  @override
  String get todayAiEstimate => 'Estimativa de IA';

  @override
  String get todayPartialLabel => 'parcial';

  @override
  String get todayEstimatedSemantics => 'estimado';

  @override
  String get todayUnknownSemantics => 'desconhecido';

  @override
  String get todayPartialSemantics => 'total parcial';

  @override
  String get todayOpenConnections => 'Abrir ligações de IA';

  @override
  String get todaySwitchConnection => 'Mudar ou verificar ligação';

  @override
  String get libraryTitle => 'A tua biblioteca alimentar';

  @override
  String get librarySearchHint => 'Pesquisar na biblioteca';

  @override
  String get libraryTabFoods => 'Alimentos';

  @override
  String get libraryTabMeals => 'Refeições';

  @override
  String get libraryTabRecipes => 'Receitas';

  @override
  String get libraryTabLeftovers => 'Sobras';

  @override
  String get libraryEmptyFoods =>
      'Nenhum alimento guardado corresponde à pesquisa.';

  @override
  String get libraryEmptyMeals =>
      'Nenhuma refeição guardada corresponde à pesquisa.';

  @override
  String get libraryEmptyRecipes => 'Nenhuma receita corresponde à pesquisa.';

  @override
  String get libraryEmptyLeftovers => 'Nenhum lote cozinhado disponível.';

  @override
  String get libraryLoadError =>
      'Não foi possível carregar a biblioteca alimentar.';

  @override
  String get libraryFavoriteLabel => 'Favorito';

  @override
  String libraryServingsRemaining(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count doses restantes',
      one: '1 dose restante',
    );
    return '$_temp0';
  }

  @override
  String get nutrientEnergy => 'Energia';

  @override
  String get nutrientProtein => 'Proteína';

  @override
  String get nutrientCarbs => 'Hidratos';

  @override
  String get nutrientFat => 'Gordura';

  @override
  String get nutrientFiber => 'Fibra';

  @override
  String get mealSlotBreakfast => 'Pequeno-almoço';

  @override
  String get mealSlotLunch => 'Almoço';

  @override
  String get mealSlotDinner => 'Jantar';

  @override
  String get mealSlotSnack => 'Lanche';

  @override
  String get mealSlotOther => 'Outro';

  @override
  String get errorNotConnected => 'Nenhum fornecedor de IA está ligado.';

  @override
  String get errorAuthFailed =>
      'A autenticação do fornecedor de IA falhou. Verifica a ligação.';

  @override
  String get errorQuotaExceeded => 'Quota do fornecedor de IA excedida.';

  @override
  String get errorRateLimited =>
      'Limite de pedidos do fornecedor de IA atingido. Tenta novamente em breve.';

  @override
  String get errorGeneric => 'Ocorreu um erro. Tenta novamente.';
}
