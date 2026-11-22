import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('pt'),
    Locale('pt', 'PT')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Salu'**
  String get appTitle;

  /// No description provided for @navToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get navToday;

  /// No description provided for @navFood.
  ///
  /// In en, this message translates to:
  /// **'Food'**
  String get navFood;

  /// No description provided for @navPlan.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get navPlan;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @profileOpenErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not open your profile'**
  String get profileOpenErrorTitle;

  /// No description provided for @profileOpenErrorBody.
  ///
  /// In en, this message translates to:
  /// **'Try again, or continue to your diary and set up your profile later.'**
  String get profileOpenErrorBody;

  /// No description provided for @actionTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get actionTryAgain;

  /// No description provided for @actionContinueToDiary.
  ///
  /// In en, this message translates to:
  /// **'Continue to diary'**
  String get actionContinueToDiary;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get actionBack;

  /// No description provided for @actionNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get actionNext;

  /// No description provided for @actionSkipSetup.
  ///
  /// In en, this message translates to:
  /// **'Skip setup'**
  String get actionSkipSetup;

  /// No description provided for @actionSaveProfile.
  ///
  /// In en, this message translates to:
  /// **'Save profile'**
  String get actionSaveProfile;

  /// No description provided for @actionSaveWithoutAi.
  ///
  /// In en, this message translates to:
  /// **'Save without AI'**
  String get actionSaveWithoutAi;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @actionClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// No description provided for @todayTitle.
  ///
  /// In en, this message translates to:
  /// **'Meal diary'**
  String get todayTitle;

  /// No description provided for @todaySubtitle.
  ///
  /// In en, this message translates to:
  /// **'A little more awareness, one meal at a time.'**
  String get todaySubtitle;

  /// No description provided for @todayPreviousDay.
  ///
  /// In en, this message translates to:
  /// **'Previous day'**
  String get todayPreviousDay;

  /// No description provided for @todayNextDay.
  ///
  /// In en, this message translates to:
  /// **'Next day'**
  String get todayNextDay;

  /// No description provided for @todayLogMeal.
  ///
  /// In en, this message translates to:
  /// **'Log a meal'**
  String get todayLogMeal;

  /// No description provided for @todayFindCorrectMeal.
  ///
  /// In en, this message translates to:
  /// **'Find and correct a meal'**
  String get todayFindCorrectMeal;

  /// No description provided for @todayWeeklyCheckIn.
  ///
  /// In en, this message translates to:
  /// **'Weekly check-in'**
  String get todayWeeklyCheckIn;

  /// No description provided for @todayReuseFromLibrary.
  ///
  /// In en, this message translates to:
  /// **'Reuse from library'**
  String get todayReuseFromLibrary;

  /// No description provided for @todayRecordedToday.
  ///
  /// In en, this message translates to:
  /// **'Recorded today'**
  String get todayRecordedToday;

  /// No description provided for @todayRecordedOnDay.
  ///
  /// In en, this message translates to:
  /// **'Recorded on this day'**
  String get todayRecordedOnDay;

  /// No description provided for @todayOptionalTargets.
  ///
  /// In en, this message translates to:
  /// **'Declared targets (reference only)'**
  String get todayOptionalTargets;

  /// No description provided for @todayNothingLoggedTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing logged yet'**
  String get todayNothingLoggedTitle;

  /// No description provided for @todayNothingLoggedBody.
  ///
  /// In en, this message translates to:
  /// **'Start with a meal photo, a description, or a food search.'**
  String get todayNothingLoggedBody;

  /// No description provided for @todayIndividualFoods.
  ///
  /// In en, this message translates to:
  /// **'Individual foods'**
  String get todayIndividualFoods;

  /// No description provided for @todayLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load all meals. Try again'**
  String get todayLoadError;

  /// No description provided for @todayReviewOrCorrect.
  ///
  /// In en, this message translates to:
  /// **'Review or correct'**
  String get todayReviewOrCorrect;

  /// No description provided for @todayEstimating.
  ///
  /// In en, this message translates to:
  /// **'Estimating…'**
  String get todayEstimating;

  /// No description provided for @todayFoodsNotIdentified.
  ///
  /// In en, this message translates to:
  /// **'Foods and portions not identified yet'**
  String get todayFoodsNotIdentified;

  /// No description provided for @todayPhotoUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Meal photo unavailable'**
  String get todayPhotoUnavailable;

  /// No description provided for @todayAiEstimate.
  ///
  /// In en, this message translates to:
  /// **'AI estimate'**
  String get todayAiEstimate;

  /// No description provided for @todayPartialLabel.
  ///
  /// In en, this message translates to:
  /// **'partial'**
  String get todayPartialLabel;

  /// No description provided for @todayIncludesTrace.
  ///
  /// In en, this message translates to:
  /// **'includes trace'**
  String get todayIncludesTrace;

  /// No description provided for @mealEditorEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit meal'**
  String get mealEditorEditTitle;

  /// No description provided for @mealEditorSaveMeal.
  ///
  /// In en, this message translates to:
  /// **'Save meal'**
  String get mealEditorSaveMeal;

  /// No description provided for @mealEditorSaveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save changes'**
  String get mealEditorSaveChanges;

  /// No description provided for @todayEstimatedSemantics.
  ///
  /// In en, this message translates to:
  /// **'estimated'**
  String get todayEstimatedSemantics;

  /// No description provided for @todayUnknownSemantics.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get todayUnknownSemantics;

  /// No description provided for @todayPartialSemantics.
  ///
  /// In en, this message translates to:
  /// **'partial total'**
  String get todayPartialSemantics;

  /// No description provided for @todayOpenConnections.
  ///
  /// In en, this message translates to:
  /// **'Open AI connections'**
  String get todayOpenConnections;

  /// No description provided for @todaySwitchConnection.
  ///
  /// In en, this message translates to:
  /// **'Switch or check connection'**
  String get todaySwitchConnection;

  /// No description provided for @libraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Your food library'**
  String get libraryTitle;

  /// No description provided for @librarySearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search your library'**
  String get librarySearchHint;

  /// No description provided for @libraryTabFoods.
  ///
  /// In en, this message translates to:
  /// **'Foods'**
  String get libraryTabFoods;

  /// No description provided for @libraryTabMeals.
  ///
  /// In en, this message translates to:
  /// **'Meals'**
  String get libraryTabMeals;

  /// No description provided for @libraryTabRecipes.
  ///
  /// In en, this message translates to:
  /// **'Recipes'**
  String get libraryTabRecipes;

  /// No description provided for @libraryTabLeftovers.
  ///
  /// In en, this message translates to:
  /// **'Leftovers'**
  String get libraryTabLeftovers;

  /// No description provided for @libraryEmptyFoods.
  ///
  /// In en, this message translates to:
  /// **'No saved foods match your search.'**
  String get libraryEmptyFoods;

  /// No description provided for @libraryEmptyMeals.
  ///
  /// In en, this message translates to:
  /// **'No saved meals match your search.'**
  String get libraryEmptyMeals;

  /// No description provided for @libraryEmptyRecipes.
  ///
  /// In en, this message translates to:
  /// **'No recipes match your search.'**
  String get libraryEmptyRecipes;

  /// No description provided for @libraryEmptyLeftovers.
  ///
  /// In en, this message translates to:
  /// **'No cooked batches available.'**
  String get libraryEmptyLeftovers;

  /// No description provided for @libraryLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load your food library.'**
  String get libraryLoadError;

  /// No description provided for @libraryFavoriteLabel.
  ///
  /// In en, this message translates to:
  /// **'Favorite'**
  String get libraryFavoriteLabel;

  /// No description provided for @libraryServingsRemaining.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 serving left} other{{count} servings left}}'**
  String libraryServingsRemaining(num count);

  /// No description provided for @nutrientEnergy.
  ///
  /// In en, this message translates to:
  /// **'Energy'**
  String get nutrientEnergy;

  /// No description provided for @nutrientProtein.
  ///
  /// In en, this message translates to:
  /// **'Protein'**
  String get nutrientProtein;

  /// No description provided for @nutrientCarbs.
  ///
  /// In en, this message translates to:
  /// **'Carbs'**
  String get nutrientCarbs;

  /// No description provided for @nutrientFat.
  ///
  /// In en, this message translates to:
  /// **'Fat'**
  String get nutrientFat;

  /// No description provided for @nutrientFiber.
  ///
  /// In en, this message translates to:
  /// **'Fiber'**
  String get nutrientFiber;

  /// No description provided for @mealSlotBreakfast.
  ///
  /// In en, this message translates to:
  /// **'Breakfast'**
  String get mealSlotBreakfast;

  /// No description provided for @mealSlotLunch.
  ///
  /// In en, this message translates to:
  /// **'Lunch'**
  String get mealSlotLunch;

  /// No description provided for @mealSlotDinner.
  ///
  /// In en, this message translates to:
  /// **'Dinner'**
  String get mealSlotDinner;

  /// No description provided for @mealSlotSnack.
  ///
  /// In en, this message translates to:
  /// **'Snack'**
  String get mealSlotSnack;

  /// No description provided for @mealSlotOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get mealSlotOther;

  /// No description provided for @errorNotConnected.
  ///
  /// In en, this message translates to:
  /// **'No AI provider is connected.'**
  String get errorNotConnected;

  /// No description provided for @errorAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'AI provider authentication failed. Check your connection.'**
  String get errorAuthFailed;

  /// No description provided for @errorQuotaExceeded.
  ///
  /// In en, this message translates to:
  /// **'AI provider quota exceeded.'**
  String get errorQuotaExceeded;

  /// No description provided for @errorRateLimited.
  ///
  /// In en, this message translates to:
  /// **'AI provider rate limit reached. Try again shortly.'**
  String get errorRateLimited;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Try again.'**
  String get errorGeneric;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'pt':
      {
        switch (locale.countryCode) {
          case 'PT':
            return AppLocalizationsPtPt();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
