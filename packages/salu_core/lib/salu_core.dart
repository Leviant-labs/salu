/// Salu's pure-Dart core: domain model, nutrition arithmetic, diary time
/// semantics, typed commands, and the ports the app implements.
///
/// Dependency rule: this package depends on nothing but the Dart SDK. No Flutter,
/// no database driver, no HTTP client. If a change needs one of those, the code
/// belongs in `salu_data` or the app package instead.
library;

export 'src/application/ids.dart';
export 'src/application/log_food.dart';
export 'src/application/ports.dart';
export 'src/domain/allergens.dart';
export 'src/domain/entry.dart';
export 'src/domain/check_in.dart';
export 'src/domain/food.dart';
export 'src/domain/nutrients.dart';
export 'src/domain/nutrition_screening.dart';
export 'src/domain/onboarding_draft.dart';
export 'src/domain/photo_meal.dart';
export 'src/domain/planning_profile.dart';
export 'src/domain/recipes.dart';
export 'src/domain/quantity.dart';
export 'src/domain/time.dart';
export 'src/platform/health.dart';
export 'src/providers/endpoint_profile.dart';
export 'src/providers/inference.dart';
