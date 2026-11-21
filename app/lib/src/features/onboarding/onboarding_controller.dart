import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../data_transfer/data_write_gate.dart';

/// Serializes guided onboarding navigation and atomic persistence.
class OnboardingController extends ChangeNotifier {
  OnboardingController(this.store, {DataWriteGate? gate}) : _gate = gate;

  final OnboardingStore store;
  final DataWriteGate? _gate;

  Future<T> _runWrite<T>(Future<T> Function() work) =>
      _gate != null ? _gate.runWrite(work) : work();

  OnboardingDraft draft = const OnboardingDraft();
  bool busy = false;
  bool loaded = false;
  String? error;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    if (_disposed || busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      final loadedDraft = await store.load();
      if (_disposed) return;
      draft = loadedDraft;
      loaded = true;
    } catch (_) {
      if (!_disposed) {
        error = 'Could not load saved setup. Try again.';
      }
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<bool> next(PlanningProfile profile) async {
    if (_disposed || busy || draft.step == OnboardingStep.review) return false;
    busy = true;
    error = null;
    _notify();
    try {
      final step = OnboardingStep.values[draft.step.index + 1];
      final candidate = draft.copyWith(step: step, profile: profile);
      final saved = await _runWrite(() => store.save(candidate));
      if (_disposed) return false;
      if (!saved) {
        error = 'Setup changed. Reopen the latest step and try again.';
        return false;
      }
      final reloaded = await store.load();
      if (_disposed) return false;
      draft = reloaded;
      return true;
    } catch (_) {
      if (!_disposed) {
        error = 'Could not save progress. Your answers are still here.';
      }
      return false;
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<bool> back() async {
    if (_disposed || busy || draft.step == OnboardingStep.welcome) return false;
    busy = true;
    error = null;
    _notify();
    try {
      final step = OnboardingStep.values[draft.step.index - 1];
      final candidate = draft.copyWith(step: step);
      final saved = await _runWrite(() => store.save(candidate));
      if (_disposed) return false;
      if (!saved) {
        error = 'Setup changed. Reopen the latest step and try again.';
        return false;
      }
      final reloaded = await store.load();
      if (_disposed) return false;
      draft = reloaded;
      return true;
    } catch (_) {
      if (!_disposed) {
        error = 'Could not save progress. Your answers are still here.';
      }
      return false;
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<bool> skipStep() async {
    if (_disposed || busy || draft.step == OnboardingStep.review) return false;
    busy = true;
    error = null;
    _notify();
    try {
      final step = OnboardingStep.values[draft.step.index + 1];
      final candidate = draft.copyWith(step: step);
      final saved = await _runWrite(() => store.save(candidate));
      if (_disposed) return false;
      if (!saved) {
        error = 'Setup changed. Reopen the latest step and try again.';
        return false;
      }
      final reloaded = await store.load();
      if (_disposed) return false;
      draft = reloaded;
      return true;
    } catch (_) {
      if (!_disposed) {
        error = 'Could not save progress. Your answers are still here.';
      }
      return false;
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<bool> finish() async {
    if (_disposed || busy || draft.step != OnboardingStep.review) return false;
    busy = true;
    error = null;
    _notify();
    try {
      final completed = await _runWrite(() => store.complete(draft));
      if (_disposed) return false;
      if (!completed) {
        error = 'Setup changed. Reopen the latest step and try again.';
        return false;
      }
      final reloaded = await store.load();
      if (_disposed) return false;
      draft = reloaded;
      return true;
    } catch (_) {
      if (!_disposed) {
        error = 'Could not finish setup. Your answers are still here.';
      }
      return false;
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<bool> skipSetup() async {
    if (_disposed || busy) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await _runWrite(() => store.skip());
      if (_disposed) return false;
      final reloaded = await store.load();
      if (_disposed) return false;
      draft = reloaded;
      return true;
    } catch (_) {
      if (!_disposed) {
        error = 'Could not skip setup. Please try again.';
      }
      return false;
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
      }
    }
  }
}
