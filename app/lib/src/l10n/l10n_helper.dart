import 'package:flutter/widgets.dart';
import 'package:salu_core/salu_core.dart';

import '../../l10n/app_localizations.dart';
import '../assistant/assistant.dart';

/// Resolves [AppLocalizations] from [context], falling back to English when a
/// widget is mounted standalone without localization delegates (e.g. unit tests).
AppLocalizations saluL10n(BuildContext context) {
  return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      lookupAppLocalizations(const Locale('en'));
}

/// Returns a safe user-facing provider display name, stripping any URL, query,
/// or credential-like content.
String localizedProviderName(String? displayName) {
  final trimmed = displayName?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  if (trimmed.contains('://') ||
      trimmed.contains('?') ||
      trimmed.contains('Bearer ') ||
      trimmed.contains('sk-')) {
    return '';
  }
  return trimmed;
}

/// Maps a [SaluAssistantErrorCode] to a localized UI message.
String localizedErrorMessage(
  AppLocalizations l10n,
  SaluAssistantErrorCode code,
) =>
    switch (code) {
      SaluAssistantErrorCode.notConnected => l10n.errorNotConnected,
      SaluAssistantErrorCode.authenticationFailed => l10n.errorAuthFailed,
      SaluAssistantErrorCode.quotaExceeded => l10n.errorQuotaExceeded,
      SaluAssistantErrorCode.rateLimited => l10n.errorRateLimited,
      _ => l10n.errorGeneric,
    };

/// Maps a [NutrientKey] to its localized display label.
String localizedNutrientLabel(AppLocalizations l10n, NutrientKey key) =>
    switch (key) {
      NutrientKey.energyKcal => l10n.nutrientEnergy,
      NutrientKey.proteinG => l10n.nutrientProtein,
      NutrientKey.carbohydrateG => l10n.nutrientCarbs,
      NutrientKey.fatG => l10n.nutrientFat,
      NutrientKey.fiberG => l10n.nutrientFiber,
      _ => key.name,
    };

/// Maps a [MealSlot] to its localized display label.
String localizedMealSlotLabel(AppLocalizations l10n, MealSlot slot) =>
    switch (slot) {
      MealSlot.breakfast => l10n.mealSlotBreakfast,
      MealSlot.lunch => l10n.mealSlotLunch,
      MealSlot.dinner => l10n.mealSlotDinner,
      MealSlot.snack => l10n.mealSlotSnack,
    };
