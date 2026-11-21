// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Salu';

  @override
  String get navToday => 'Today';

  @override
  String get navFood => 'Food';

  @override
  String get navPlan => 'Plan';

  @override
  String get navSettings => 'Settings';

  @override
  String get profileOpenErrorTitle => 'Could not open your profile';

  @override
  String get profileOpenErrorBody =>
      'Try again, or continue to your diary and set up your profile later.';

  @override
  String get actionTryAgain => 'Try again';

  @override
  String get actionContinueToDiary => 'Continue to diary';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionBack => 'Back';

  @override
  String get actionNext => 'Next';

  @override
  String get actionSkipSetup => 'Skip setup';

  @override
  String get actionSaveProfile => 'Save profile';

  @override
  String get actionSaveWithoutAi => 'Save without AI';

  @override
  String get actionSave => 'Save';

  @override
  String get actionClose => 'Close';

  @override
  String get todayTitle => 'Meal diary';

  @override
  String get todaySubtitle => 'A little more awareness, one meal at a time.';

  @override
  String get todayPreviousDay => 'Previous day';

  @override
  String get todayNextDay => 'Next day';

  @override
  String get todayLogMeal => 'Log a meal';

  @override
  String get todayFindCorrectMeal => 'Find and correct a meal';

  @override
  String get todayWeeklyCheckIn => 'Weekly check-in';

  @override
  String get todayReuseFromLibrary => 'Reuse from library';

  @override
  String get todayRecordedToday => 'Recorded today';

  @override
  String get todayRecordedOnDay => 'Recorded on this day';

  @override
  String get todayOptionalTargets => 'Declared targets (reference only)';

  @override
  String get todayNothingLoggedTitle => 'Nothing logged yet';

  @override
  String get todayNothingLoggedBody =>
      'Start with a meal photo, a description, or a food search.';

  @override
  String get todayIndividualFoods => 'Individual foods';

  @override
  String get todayLoadError => 'Could not load all meals. Try again';

  @override
  String get todayReviewOrCorrect => 'Review or correct';

  @override
  String get todayEstimating => 'Estimating…';

  @override
  String get todayFoodsNotIdentified => 'Foods and portions not identified yet';

  @override
  String get todayPhotoUnavailable => 'Meal photo unavailable';

  @override
  String get todayAiEstimate => 'AI estimate';

  @override
  String get todayPartialLabel => 'partial';

  @override
  String get todayEstimatedSemantics => 'estimated';

  @override
  String get todayUnknownSemantics => 'unknown';

  @override
  String get todayPartialSemantics => 'partial total';

  @override
  String get todayOpenConnections => 'Open AI connections';

  @override
  String get todaySwitchConnection => 'Switch or check connection';

  @override
  String get libraryTitle => 'Your food library';

  @override
  String get librarySearchHint => 'Search your library';

  @override
  String get libraryTabFoods => 'Foods';

  @override
  String get libraryTabMeals => 'Meals';

  @override
  String get libraryTabRecipes => 'Recipes';

  @override
  String get libraryTabLeftovers => 'Leftovers';

  @override
  String get libraryEmptyFoods => 'No saved foods match your search.';

  @override
  String get libraryEmptyMeals => 'No saved meals match your search.';

  @override
  String get libraryEmptyRecipes => 'No recipes match your search.';

  @override
  String get libraryEmptyLeftovers => 'No cooked batches available.';

  @override
  String get libraryLoadError => 'Could not load your food library.';

  @override
  String get libraryFavoriteLabel => 'Favorite';

  @override
  String libraryServingsRemaining(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count servings left',
      one: '1 serving left',
    );
    return '$_temp0';
  }

  @override
  String get nutrientEnergy => 'Energy';

  @override
  String get nutrientProtein => 'Protein';

  @override
  String get nutrientCarbs => 'Carbs';

  @override
  String get nutrientFat => 'Fat';

  @override
  String get nutrientFiber => 'Fiber';

  @override
  String get mealSlotBreakfast => 'Breakfast';

  @override
  String get mealSlotLunch => 'Lunch';

  @override
  String get mealSlotDinner => 'Dinner';

  @override
  String get mealSlotSnack => 'Snack';

  @override
  String get mealSlotOther => 'Other';

  @override
  String get errorNotConnected => 'No AI provider is connected.';

  @override
  String get errorAuthFailed =>
      'AI provider authentication failed. Check your connection.';

  @override
  String get errorQuotaExceeded => 'AI provider quota exceeded.';

  @override
  String get errorRateLimited =>
      'AI provider rate limit reached. Try again shortly.';

  @override
  String get errorGeneric => 'Something went wrong. Try again.';
}
