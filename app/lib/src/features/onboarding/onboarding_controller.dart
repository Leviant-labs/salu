import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

/// Serializes guided onboarding navigation and atomic persistence.
class OnboardingController extends ChangeNotifier {
  OnboardingController(this.store);

  final OnboardingStore store;

  OnboardingDraft draft = const OnboardingDraft();
  bool busy = false;
  bool loaded = false;
  String? error;

  Future<void> load() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      draft = await store.load();
      loaded = true;
    } catch (_) {
      error = 'Could not load saved setup. Try again.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> next(PlanningProfile profile) async {
    if (busy || draft.step == OnboardingStep.review) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final step = OnboardingStep.values[draft.step.index + 1];
      final candidate = draft.copyWith(step: step, profile: profile);
      if (!await store.save(candidate)) {
        error = 'Setup changed. Reopen the latest step and try again.';
        return false;
      }
      draft = await store.load();
      return true;
    } catch (_) {
      error = 'Could not save progress. Your answers are still here.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> back() async {
    if (busy || draft.step == OnboardingStep.welcome) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final step = OnboardingStep.values[draft.step.index - 1];
      final candidate = draft.copyWith(step: step);
      if (!await store.save(candidate)) {
        error = 'Setup changed. Reopen the latest step and try again.';
        return false;
      }
      draft = await store.load();
      return true;
    } catch (_) {
      error = 'Could not save progress. Your answers are still here.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> skipStep() async {
    if (busy || draft.step == OnboardingStep.review) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final step = OnboardingStep.values[draft.step.index + 1];
      final candidate = draft.copyWith(step: step);
      if (!await store.save(candidate)) {
        error = 'Setup changed. Reopen the latest step and try again.';
        return false;
      }
      draft = await store.load();
      return true;
    } catch (_) {
      error = 'Could not save progress. Your answers are still here.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> finish() async {
    if (busy || draft.step != OnboardingStep.review) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (!await store.complete(draft)) {
        error = 'Setup changed. Reopen the latest step and try again.';
        return false;
      }
      draft = await store.load();
      return true;
    } catch (_) {
      error = 'Could not finish setup. Your answers are still here.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> skipSetup() async {
    if (busy) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await store.skip();
      draft = await store.load();
      return true;
    } catch (_) {
      error = 'Could not skip setup. Please try again.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
