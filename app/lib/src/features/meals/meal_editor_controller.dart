import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../assistant/assistant.dart';
import '../../assistant/operation_fence.dart';
import '../../data_transfer/data_write_gate.dart';
import '../../media/managed_media_store.dart';
import 'meal_editor_ai.dart';
import 'meal_editor_data.dart';
import 'meal_editor_images.dart';
import 'meal_estimation.dart';

export 'package:salu_data/salu_data.dart'
    show MealEstimateStatusStore, MealMutationRepository;

sealed class SaveNewOutcome {
  const SaveNewOutcome();
}

final class SaveNewSaved extends SaveNewOutcome {
  const SaveNewSaved({required this.meal, required this.message});
  final PhotoMeal meal;
  final String message;
}

final class SaveNewAlreadySaved extends SaveNewOutcome {
  const SaveNewAlreadySaved({required this.message});
  final String message;
}

final class SaveNewFailed extends SaveNewOutcome {
  const SaveNewFailed(this.message);
  final String message;
}

sealed class SaveChangesOutcome {
  const SaveChangesOutcome();
}

final class SaveChangesApplied extends SaveChangesOutcome {
  const SaveChangesApplied({
    required this.oldDate,
    required this.newDate,
    required this.message,
  });
  final DiaryDate oldDate;
  final DiaryDate newDate;
  final String message;
}

final class SaveChangesConflict extends SaveChangesOutcome {
  const SaveChangesConflict(this.message);
  final String message;
}

final class SaveChangesFailed extends SaveChangesOutcome {
  const SaveChangesFailed(this.message);
  final String message;
}

sealed class DeleteMealOutcome {
  const DeleteMealOutcome();
}

final class DeleteMealApplied extends DeleteMealOutcome {
  const DeleteMealApplied({required this.mealDate, this.undoToken});
  final DiaryDate mealDate;
  final String? undoToken;
}

final class DeleteMealConflict extends DeleteMealOutcome {
  const DeleteMealConflict(this.message);
  final String message;
}

final class DeleteMealFailed extends DeleteMealOutcome {
  const DeleteMealFailed(this.message);
  final String message;
}

/// Coordinates persistence, mutation, and AI estimation for the meal editor.
class MealEditorController extends ChangeNotifier {
  MealEditorController({
    required this.repository,
    this.mutations,
    required this.assistant,
    required this.media,
    this.gate,
    this.fence,
    this.clock = const SystemClock(),
    required this.ids,
    this.estimateStatusStore,
    this.activeEstimates,
  });

  final PhotoMealRepository repository;
  final MealMutationRepository? mutations;
  final SaluAssistant assistant;
  final ManagedMediaStore media;
  final DataWriteGate? gate;
  final OperationFence? fence;
  final Clock clock;
  final IdGenerator ids;
  final MealEstimateStatusStore? estimateStatusStore;
  final ActiveMealEstimates? activeEstimates;

  bool _busy = false;
  String? _busyLabel;
  bool _conflict = false;
  bool _disposed = false;

  bool get busy => _busy;
  String? get busyLabel => _busyLabel;
  bool get conflict => _conflict;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _start(String label) {
    _busy = true;
    _busyLabel = label;
    _safeNotify();
  }

  void _finish() {
    _busy = false;
    _busyLabel = null;
    _safeNotify();
  }

  Future<T> _runWrite<T>(Future<T> Function() work) =>
      gate != null ? gate!.runWrite(work) : work();

  List<PhotoMealItem> _withIds(List<PhotoMealItem> items) => [
        for (final item in items)
          item.id == null ? item.copyWith(id: ids.next()) : item,
      ];

  Future<Map<String, dynamic>> transcribeLabel(String path) async {
    final token = fence?.capture();
    final response = await assistant.ask(
      instructions: mealLabelInstructions,
      prompt: 'Transcribe the selected nutrition label.',
      images: [await encodeMealUpload(path, media: media)],
      task: InferenceTask.labelOcr,
    );
    if (token != null && !fence!.isCurrent(token)) {
      throw StateError('Cancelled');
    }
    return response;
  }

  Future<SaveNewOutcome> saveNew({
    required String requestId,
    required DiaryDate date,
    required MealSlot slot,
    required String caption,
    required String? photoPath,
    required List<PhotoMealItem> items,
    required int recordedOffsetMinutes,
    required bool withEstimate,
    Set<String> Function(PhotoMeal meal)? onProtect,
    void Function(Set<String> paths)? onRelease,
  }) async {
    if (_busy) return const SaveNewFailed('Busy');
    final trimmed = caption.trim();
    if (photoPath == null && trimmed.isEmpty && items.isEmpty) {
      return const SaveNewFailed('Nothing to save.');
    }
    _start('Saving meal…');
    try {
      final meal = PhotoMeal(
        id: requestId,
        date: date,
        slot: slot,
        caption: trimmed,
        createdAt: clock.nowUtc(),
        recordedOffsetMinutes: recordedOffsetMinutes,
        photoPath: photoPath,
        items: _withIds(items),
        estimateStatus:
            withEstimate ? MealEstimateStatus.pending : MealEstimateStatus.none,
      );
      final paths = onProtect?.call(meal) ?? const <String>{};
      final savedNew = await _runWrite(() => repository.saveNew(meal));
      if (!savedNew) {
        final matching = (await repository.listFor(meal.date))
            .where((saved) => saved.id == requestId)
            .firstOrNull;
        final matchedPaths = {
          matching?.photoPath,
          for (final item in matching?.items ?? const <PhotoMealItem>[])
            ...item.labelPaths,
        };
        onRelease?.call(
          paths.where((path) => !matchedPaths.contains(path)).toSet(),
        );
        if (matching == null) {
          return const SaveNewFailed('Could not save the meal. Try again.');
        }
        return SaveNewAlreadySaved(
          message: 'This meal was already saved under ${matching.slot.label}.',
        );
      }
      if (withEstimate) {
        unawaited(
          estimateSavedMeal(
            meal: meal,
            repository: repository,
            assistant: assistant,
            media: media,
            newId: ids.next,
            activeEstimates: activeEstimates,
            statusStore: estimateStatusStore,
            fence: fence,
            gate: gate,
          ),
        );
      }
      return SaveNewSaved(
        meal: meal,
        message: 'Saved under ${meal.slot.label} · ${meal.date.toIso()}.',
      );
    } catch (_) {
      return const SaveNewFailed('Could not save the meal. Try again.');
    } finally {
      _finish();
    }
  }

  Future<SaveChangesOutcome> saveChanges({
    required PhotoMeal original,
    required DiaryDate date,
    required DiaryDate today,
    required MealSlot slot,
    required String caption,
    required String? photoPath,
    required List<PhotoMealItem> items,
    required String requestId,
    Set<String> Function(PhotoMeal meal)? onProtect,
    void Function(Set<String> paths)? onRelease,
  }) async {
    if (_busy || _conflict) {
      return const SaveChangesFailed('Cannot save changes right now.');
    }
    if (date.compareTo(today) > 0) {
      return const SaveChangesFailed('Diary date cannot be in the future.');
    }
    final trimmed = caption.trim();
    final updated = original.copyWith(
      date: date,
      slot: slot,
      caption: trimmed,
      items: _withIds(items),
      photoPath: photoPath,
      clearPhoto: photoPath == null,
      estimateStatus: original.estimateStatus == MealEstimateStatus.pending
          ? MealEstimateStatus.none
          : original.estimateStatus,
    );
    _start('Saving changes…');
    final paths = onProtect?.call(updated) ?? const <String>{};
    try {
      final mutationRepo = mutations;
      if (mutationRepo != null) {
        final onlyDateChanged = date != original.date &&
            slot == original.slot &&
            trimmed == original.caption &&
            photoPath == original.photoPath &&
            items.length == original.items.length &&
            items.indexed.every((e) => e.$2 == original.items[e.$1]);
        Future<MealMutationResult> applyMutation() => onlyDateChanged
            ? mutationRepo.apply(
                MoveMeal(
                  requestId: requestId,
                  mealId: original.id,
                  expectedRevision: original.revision,
                  date: date,
                  today: today,
                ),
              )
            : mutationRepo.apply(
                ReviseMeal(
                  requestId: requestId,
                  meal: updated,
                  expectedRevision: original.revision,
                ),
              );
        final result = await _runWrite(applyMutation);
        switch (result.status) {
          case MutationStatus.applied:
          case MutationStatus.alreadyApplied:
            return SaveChangesApplied(
              oldDate: original.date,
              newDate: date,
              message: date != original.date
                  ? 'Meal moved to ${date.toIso()}.'
                  : 'Meal updated.',
            );
          case MutationStatus.stale:
            onRelease?.call(paths);
            _conflict = true;
            _safeNotify();
            return const SaveChangesConflict(
              'This meal changed or was removed while you were editing. Go back and reopen it to edit the latest version.',
            );
          case MutationStatus.notFound:
            onRelease?.call(paths);
            _conflict = true;
            _safeNotify();
            return const SaveChangesConflict('This meal was already removed.');
          case MutationStatus.invalidDate:
            onRelease?.call(paths);
            return const SaveChangesFailed(
              'Diary date cannot be in the future.',
            );
          case MutationStatus.expired:
            onRelease?.call(paths);
            return const SaveChangesFailed(
              'Could not save your changes. Try again.',
            );
        }
      }

      final replaced =
          await _runWrite(() => repository.replace(updated, original.revision));
      if (replaced) {
        return SaveChangesApplied(
          oldDate: original.date,
          newDate: date,
          message: 'Meal updated.',
        );
      }
      onRelease?.call(paths);
      _conflict = true;
      _safeNotify();
      return const SaveChangesConflict(
        'This meal changed or was removed while you were editing. Go back and reopen it to edit the latest version.',
      );
    } catch (_) {
      return const SaveChangesFailed('Could not save your changes. Try again.');
    } finally {
      _finish();
    }
  }

  Future<DeleteMealOutcome> deleteMeal({
    required PhotoMeal original,
    required String requestId,
  }) async {
    if (_busy || _conflict) {
      return const DeleteMealFailed('Cannot delete meal right now.');
    }
    final mutationRepo = mutations;
    if (mutationRepo == null) {
      return const DeleteMealFailed('Delete is unavailable right now.');
    }
    _start('Deleting meal…');
    try {
      final result = await _runWrite(
        () => mutationRepo.apply(
          DeleteMeal(
            requestId: requestId,
            mealId: original.id,
            expectedRevision: original.revision,
          ),
        ),
      );
      switch (result.status) {
        case MutationStatus.applied:
        case MutationStatus.alreadyApplied:
          return DeleteMealApplied(
            mealDate: original.date,
            undoToken: result.undoToken,
          );
        case MutationStatus.stale:
          _conflict = true;
          _safeNotify();
          return const DeleteMealConflict(
            'This meal changed while you were editing. Go back and reopen it before deleting.',
          );
        case MutationStatus.notFound:
          _conflict = true;
          _safeNotify();
          return const DeleteMealConflict('This meal was already removed.');
        case MutationStatus.invalidDate:
        case MutationStatus.expired:
          return const DeleteMealFailed(
            'Could not delete this meal. Try again.',
          );
      }
    } catch (_) {
      return const DeleteMealFailed('Could not delete this meal. Try again.');
    } finally {
      _finish();
    }
  }

  static Future<MealMutationResult> undoDelete({
    required MealMutationRepository mutations,
    required String undoToken,
    required String requestId,
    DataWriteGate? gate,
  }) {
    Future<MealMutationResult> applyUndo() => mutations.apply(
          UndoMeal(requestId: requestId, undoToken: undoToken),
        );
    return gate != null ? gate.runWrite(applyUndo) : applyUndo();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
