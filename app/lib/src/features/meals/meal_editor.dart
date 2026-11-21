import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:salu_core/salu_core.dart';

import '../../assistant/assistant.dart';
import '../../assistant/operation_fence.dart';
import '../../data_transfer/data_write_gate.dart';
import '../../media/managed_media_store.dart';
import '../../theme/glass_surface.dart';
import '../../theme/tactile_controls.dart';
import '../search/food_library.dart';
import 'meal_editor_ai.dart';
import 'meal_editor_controller.dart';
import 'meal_editor_data.dart';
import 'meal_editor_dialogs.dart';
import 'meal_estimation.dart';

/// Route for logging a new meal or revising one already in the diary.
class MealEditor extends StatelessWidget {
  const MealEditor({
    super.key,
    this.meal,
    required this.repository,
    this.mutations,
    required this.assistant,
    required this.foods,
    required this.date,
    required this.newId,
    this.media,
    this.activeEstimates,
    this.estimateStatusStore,
    this.gate,
    this.fence,
    this.initialDescription = '',
    this.initialFood,
    this.today,
    this.onLogged,
    this.onMutated,
    this.initialItems = const [],
    this.initialSlot,
    this.initialCorrection = '',
    this.library,
  });

  final PhotoMeal? meal;
  final PhotoMealRepository repository;
  final MealMutationRepository? mutations;
  final SaluAssistant assistant;
  final ManagedMediaStore? media;
  final ActiveMealEstimates? activeEstimates;
  final MealEstimateStatusStore? estimateStatusStore;
  final DataWriteGate? gate;
  final OperationFence? fence;
  final FoodRepository foods;
  final DiaryDate date;
  final String Function() newId;
  final String initialDescription;
  final Food? initialFood;
  final DiaryDate? today;
  final ValueChanged<DiaryDate>? onLogged;
  final void Function(DiaryDate oldDate, DiaryDate newDate)? onMutated;
  final List<PhotoMealItem> initialItems;
  final MealSlot? initialSlot;
  final String initialCorrection;
  final FoodLibrary? library;

  @override
  Widget build(BuildContext context) => _MealEditorRoute(editor: this);
}

class _MealEditorRoute extends StatefulWidget {
  const _MealEditorRoute({required this.editor});

  final MealEditor editor;

  @override
  State<_MealEditorRoute> createState() => _MealEditorRouteState();
}

class _MealEditorRouteState extends State<_MealEditorRoute> {
  late final _original = widget.editor.meal;
  late DiaryDate _date = _original?.date ??
      mealDateFromIntent(widget.editor.initialDescription,
          widget.editor.today ?? widget.editor.date) ??
      widget.editor.date;
  late final _requestId = widget.editor.newId();
  String? _saveRequestId;
  String? _deleteRequestId;
  late final _openedAt = DateTime.now();
  late final _caption = TextEditingController(
    text: _original?.caption ?? widget.editor.initialDescription,
  );
  late final _correction =
      TextEditingController(text: widget.editor.initialCorrection);
  late final ManagedMediaStore _media = widget.editor.media ??
      ManagedMediaStore(
        directory: getApplicationSupportDirectory,
        newId: widget.editor.newId,
      );
  late final MealEditorController _controller = MealEditorController(
    repository: widget.editor.repository,
    mutations: widget.editor.mutations,
    assistant: widget.editor.assistant,
    media: _media,
    gate: widget.editor.gate,
    fence: widget.editor.fence,
    ids: _CallbackIdGenerator(widget.editor.newId),
    estimateStatusStore: widget.editor.estimateStatusStore,
    activeEstimates: widget.editor.activeEstimates,
  );
  final _picker = ImagePicker();
  final _draftImages = <String>{};
  // If a write throws, its outcome could be unknown. Keep any affected file
  // rather than deleting evidence that the repository may already reference.
  final _protectedImages = <String>{};
  List<XFile> _recoveredPickerImages = const [];

  late MealSlot _slot = _original?.slot ??
      widget.editor.initialSlot ??
      mealSlotFor(widget.editor.initialDescription, _openedAt.hour);
  late List<PhotoMealItem> _items = [
    ...?_original?.items,
    ...widget.editor.initialItems,
    if (widget.editor.initialFood case final food?)
      catalogueMealItem(food, null),
  ];
  Food? _initialFood;
  late String? _photoPath = _original?.photoPath;
  late bool _slotWasSelected = widget.editor.initialSlot != null;
  bool _dateWasSelected = false;
  bool _conflict = false;
  String? _work;
  String? _error;
  String? _providerLabel;

  bool get _busy => _work != null;

  @override
  void initState() {
    super.initState();
    _initialFood = widget.editor.initialFood;
    _loadProviderLabel();
    if (_original == null) {
      _checkLostPickerImages();
    }
    if (_initialFood != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editFood(0);
      });
    }
  }

  Future<void> _checkLostPickerImages() async {
    try {
      final recovered = await _media.recoverLostPickerImages();
      if (mounted && recovered.isNotEmpty) {
        setState(() => _recoveredPickerImages = recovered);
      }
    } on Object {
      // Lost-data recovery is best-effort and never blocks editing.
    }
  }

  Future<void> _attachRecoveredPhoto() async {
    if (_busy || _recoveredPickerImages.isEmpty) return;
    final recovered = _recoveredPickerImages.first;
    _start('Attaching recovered photo…');
    try {
      final ref = await _media.importImage(recovered);
      if (!mounted) {
        await _media.removeUnreferenced(ref, _protectedImages);
        return;
      }
      _draftImages.add(ref);
      setState(() {
        _photoPath = ref;
        _recoveredPickerImages = const [];
      });
    } catch (_) {
      _showError(
        'Could not attach the recovered photo. Try choosing a photo again.',
      );
    } finally {
      _finish();
    }
  }

  void _discardRecoveredPhotos() {
    setState(() => _recoveredPickerImages = const []);
  }

  Future<void> _loadProviderLabel() async {
    try {
      final label = await widget.editor.assistant.activeProviderLabel;
      if (mounted && label != null) {
        setState(() => _providerLabel = label);
      }
    } on Object {
      // Keep neutral fallback label if provider lookup fails.
    }
  }

  @override
  void dispose() {
    for (final path in _draftImages.difference(_protectedImages)) {
      unawaited(_media.removeUnreferenced(path, _protectedImages));
    }
    _controller.dispose();
    _caption.dispose();
    _correction.dispose();
    super.dispose();
  }

  void _start(String work) {
    FocusScope.of(context).unfocus();
    setState(() {
      _work = work;
      _error = null;
    });
  }

  void _finish() {
    if (mounted) setState(() => _work = null);
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  Future<String?> _pickImage(ImageSource source) async {
    if (_busy) return null;
    _start('Opening photo…');
    try {
      final photo = await _picker.pickImage(
        source: source,
        requestFullMetadata: false,
      );
      if (photo == null || !mounted) return null;
      final path = await _media.importImage(photo);
      if (!mounted) {
        await _media.removeUnreferenced(path, _protectedImages);
        return null;
      }
      _draftImages.add(path);
      return path;
    } catch (_) {
      _showError(
        'Could not add the photo. Try again or choose a different image.',
      );
      return null;
    } finally {
      _finish();
    }
  }

  Future<void> _pickMealPhoto(ImageSource source) async {
    final path = await _pickImage(source);
    if (mounted && path != null) setState(() => _photoPath = path);
  }

  Future<void> _addFood() async {
    final result = await editMealItem(context);
    if (mounted && result != null) setState(() => _items.add(result));
  }

  Future<void> _addSavedFood() async {
    final library = widget.editor.library!;
    try {
      final foods = await library.foods();
      if (!mounted) return;
      final selected = await showDialog<SavedFood>(
          context: context,
          builder: (context) => SimpleDialog(
                title: const Text('Saved foods'),
                children: [
                  if (foods.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                            'No saved foods. Add a food in your Food library.')),
                  for (final food in foods)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, food),
                        child: Text(food.name)),
                ],
              ));
      if (selected == null || !mounted) return;
      final item = await pickSavedFoodPortion(context, selected);
      if (item != null && mounted) setState(() => _items.add(item));
    } catch (_) {
      _showError('Could not open saved foods.');
    }
  }

  Future<void> _saveFavoriteFood(PhotoMealItem item) async {
    final food =
        await editSavedFood(context, widget.editor.newId(), item: item);
    if (food == null || !mounted) return;
    try {
      await widget.editor.library!.saveFood(food);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Food saved in your library.')));
      }
    } catch (_) {
      _showError('Could not save this food in your library.');
    }
  }

  Future<void> _saveTemplate() async {
    var name =
        _caption.text.trim().isEmpty ? _items.first.name : _caption.text.trim();
    final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Save meal for reuse'),
              content: TextFormField(
                  initialValue: name,
                  onChanged: (value) => name = value.trim(),
                  maxLength: 100,
                  decoration:
                      const InputDecoration(labelText: 'Saved meal name')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () {
                      if (name.isNotEmpty) Navigator.pop(context, name);
                    },
                    child: const Text('Save to library'))
              ],
            ));
    if (title == null || !mounted) return;
    try {
      await widget.editor.library!.saveMeal((
        id: _original?.id ?? _requestId,
        name: title,
        items: List.of(_items)
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Meal saved for reuse.')));
      }
    } catch (_) {
      _showError('Could not save this meal in your library.');
    }
  }

  Future<void> _addCatalogueFood() async {
    final food = await findMealFood(context, widget.editor.foods);
    if (!mounted || food == null) return;
    final result = await editMealItem(context, food: food);
    if (mounted && result != null) setState(() => _items.add(result));
  }

  Future<void> _editFood(int index) async {
    final item = _items[index];
    final food = _initialFood;
    final result =
        food != null && item.name == food.name && item.labelPath == null
            ? await editMealItem(context, item: item, food: food)
            : await editMealItem(context, item: item);
    if (mounted && result != null) setState(() => _items[index] = result);
  }

  Future<void> _addLabel([int? index]) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take label photo'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose label photo'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    final path = await _pickImage(source);
    if (!mounted || path == null) return;
    if (index != null) {
      await _enterLabel(index, path);
      return;
    }
    final label = await widget.editor.assistant.activeProviderLabel;
    if (!mounted) return;
    final destination = label ?? _providerLabel ?? 'your selected AI provider';
    final read = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Match this label to a food'),
              content: Text(
                  'Salu can read the printed product name and nutrition. This sends only the selected label photo to $destination. Provider plan limits or user-funded API billing may apply.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Choose food myself')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Read label with AI'))
              ],
            ));
    if (read == null || !mounted) return;
    Map<String, dynamic>? response;
    if (read) {
      _start('Reading product label…');
      try {
        response = await _transcribeLabel(path);
      } catch (_) {
        _showError('Could not read this label. You can attach it manually.');
      } finally {
        _finish();
      }
    }
    if (!mounted) return;
    final name = response == null ? null : labelProductName(response);
    final match = matchLabelProduct(name, _items);
    final chosen = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
                title: const Text('Which food uses this label?'),
                children: [
                  if (name != null)
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('Printed product: $name')),
                  for (final (i, item) in _items.indexed)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, i),
                        child: Text(i == match
                            ? '${item.name} (suggested match)'
                            : item.name)),
                ]));
    if (chosen != null && mounted) {
      await _enterLabel(chosen, path, initialResponse: response);
    }
  }

  Future<Map<String, dynamic>> _transcribeLabel(String path) =>
      _controller.transcribeLabel(path);

  Future<void> _enterLabel(int index, String path,
      {Map<String, dynamic>? initialResponse}) async {
    LabelTranscription? initial;
    if (initialResponse != null) {
      try {
        initial = parseMealLabel(initialResponse);
      } on FormatException {/* Attach without guessed values. */}
    }
    final result = await editMealLabel(
      context,
      item: _items[index],
      labelPath: path,
      media: _media,
      initial: initial,
      providerLabel: _providerLabel,
      readLabel: () async => parseMealLabel(await _transcribeLabel(path)),
    );
    if (mounted && result != null) setState(() => _items[index] = result);
  }

  Set<String> _protectForWrite(PhotoMeal meal) {
    final referenced = {
      if (meal.photoPath case final path?) path,
      for (final item in meal.items) ...item.labelPaths,
    };
    final newlyProtected =
        referenced.intersection(_draftImages).difference(_protectedImages);
    _protectedImages.addAll(newlyProtected);
    return newlyProtected;
  }

  void _release(Set<String> paths) {
    _protectedImages.removeAll(paths);
    if (!mounted) {
      for (final path in paths) {
        unawaited(_media.removeUnreferenced(path, _protectedImages));
      }
    }
  }

  void _saved(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveNew({required bool withEstimate}) async {
    if (_busy) return;
    final caption = _caption.text.trim();
    final photoPath = _photoPath;
    if (photoPath == null && caption.isEmpty && _items.isEmpty) return;
    _start('Saving meal…');
    try {
      final outcome = await _controller.saveNew(
        requestId: _requestId,
        date: _date,
        slot: _slot,
        caption: caption,
        photoPath: photoPath,
        items: _items,
        recordedOffsetMinutes: _openedAt.timeZoneOffset.inMinutes,
        withEstimate: withEstimate,
        onProtect: _protectForWrite,
        onRelease: _release,
      );
      switch (outcome) {
        case SaveNewSaved(:final meal, :final message):
          if (mounted) widget.editor.onLogged?.call(meal.date);
          _saved(message);
        case SaveNewAlreadySaved(:final message):
          _saved(message);
        case SaveNewFailed(:final message):
          _showError(message);
      }
    } finally {
      _finish();
    }
  }

  Future<void> _pickDate() async {
    final today = widget.editor.today ?? widget.editor.date;
    final picked = await showDatePicker(
        context: context,
        initialDate: _date.localMidnight,
        firstDate: DateTime(1900),
        lastDate: today.localMidnight);
    if (mounted && picked != null) {
      setState(() {
        _date = DiaryDate.ofLocal(picked);
        _dateWasSelected = true;
      });
    }
  }

  Future<void> _saveChanges() async {
    if (_busy || _conflict) return;
    final original = _original!;
    final today = widget.editor.today ?? widget.editor.date;
    _start('Saving changes…');
    try {
      final outcome = await _controller.saveChanges(
        original: original,
        date: _date,
        today: today,
        slot: _slot,
        caption: _caption.text,
        photoPath: _photoPath,
        items: _items,
        requestId: _saveRequestId ??= widget.editor.newId(),
        onProtect: _protectForWrite,
        onRelease: _release,
      );
      switch (outcome) {
        case SaveChangesApplied(:final oldDate, :final newDate, :final message):
          widget.editor.onMutated?.call(oldDate, newDate);
          _saved(message);
        case SaveChangesConflict(:final message):
          if (!mounted) return;
          setState(() => _conflict = true);
          _showError(message);
        case SaveChangesFailed(:final message):
          _showError(message);
      }
    } finally {
      _finish();
    }
  }

  Future<void> _deleteMeal() async {
    if (_busy || _conflict) return;
    final original = _original!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this meal?'),
        content: const Text(
          'This removes the meal from your diary. You can undo this for 10 seconds from the diary. Deleting a meal logged from a cooked batch does not replenish remaining batch stock.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete meal'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final mutations = widget.editor.mutations;
    if (mutations == null) {
      _showError('Delete is unavailable right now.');
      return;
    }

    _start('Deleting meal…');
    try {
      final outcome = await _controller.deleteMeal(
        original: original,
        requestId: _deleteRequestId ??= widget.editor.newId(),
      );
      switch (outcome) {
        case DeleteMealApplied(:final mealDate, :final undoToken):
          if (!mounted) return;
          final messenger = ScaffoldMessenger.of(context);
          final onMutated = widget.editor.onMutated;
          final newId = widget.editor.newId;
          final gate = widget.editor.gate;
          onMutated?.call(mealDate, mealDate);
          Navigator.of(context).pop();
          messenger.showSnackBar(SnackBar(
            duration: const Duration(seconds: 10),
            content: const Text('Meal deleted.'),
            action: undoToken == null
                ? null
                : SnackBarAction(
                    label: 'Undo',
                    onPressed: () => _undoDelete(
                      messenger: messenger,
                      mutations: mutations,
                      undoToken: undoToken,
                      newId: newId,
                      mealDate: mealDate,
                      onMutated: onMutated,
                      gate: gate,
                    ),
                  ),
          ));
        case DeleteMealConflict(:final message):
          if (!mounted) return;
          setState(() => _conflict = true);
          _showError(message);
        case DeleteMealFailed(:final message):
          _showError(message);
      }
    } finally {
      _finish();
    }
  }

  static Future<void> _undoDelete({
    required ScaffoldMessengerState messenger,
    required MealMutationRepository mutations,
    required String undoToken,
    required String Function() newId,
    required DiaryDate mealDate,
    required void Function(DiaryDate oldDate, DiaryDate newDate)? onMutated,
    DataWriteGate? gate,
  }) async {
    try {
      final undone = await MealEditorController.undoDelete(
        mutations: mutations,
        undoToken: undoToken,
        requestId: newId(),
        gate: gate,
      );
      switch (undone.status) {
        case MutationStatus.applied:
        case MutationStatus.alreadyApplied:
          onMutated?.call(mealDate, mealDate);
          messenger.showSnackBar(
            const SnackBar(content: Text('Meal restored.')),
          );
        case MutationStatus.expired:
          messenger.showSnackBar(
            const SnackBar(
              content:
                  Text('Could not undo: the 24-hour undo window has expired.'),
            ),
          );
        case MutationStatus.stale:
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                  'Could not undo: this meal was already changed or restored.'),
            ),
          );
        case MutationStatus.notFound:
        case MutationStatus.invalidDate:
          messenger.showSnackBar(
            const SnackBar(content: Text('Could not undo the deletion.')),
          );
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not undo the deletion.')),
      );
    }
  }

  Future<void> _requestCorrection() async {
    final correction = _correction.text.trim();
    if (_busy || _conflict || correction.isEmpty) return;
    final before = (slot: _slot, items: List<PhotoMealItem>.of(_items));
    MealCorrection? after;
    _start('Preparing correction preview…');
    try {
      final response = await widget.editor.assistant.ask(
        instructions: mealCorrectionInstructions,
        prompt: mealCorrectionPrompt(correction, before.slot, before.items),
        task: InferenceTask.naturalLanguageLog,
      );
      after = parseMealCorrection(response, before.slot, before.items);
      if (after == null) {
        _showError(
          'No clear changes were suggested. Try rephrasing or edit the items directly.',
        );
      }
    } on SaluAssistantException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError(
        'Could not prepare a correction. You can still edit the meal directly.',
      );
    } finally {
      _finish();
    }
    if (!mounted || after == null) return;
    final proposed = after;
    final apply = await previewMealCorrection(
      context,
      date: _date,
      before: before,
      after: proposed,
    );
    if (!mounted || !apply) return;
    setState(() {
      _items = proposed.items;
      _slot = proposed.slot;
      _correction.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isNew = _original == null;
    final ambiguousDate = !_dateWasSelected &&
        mealDatesFromIntent(
                    _caption.text, widget.editor.today ?? widget.editor.date)
                .length >
            1;
    final canSaveNew = !_busy &&
        !ambiguousDate &&
        (_photoPath != null ||
            _caption.text.trim().isNotEmpty ||
            _items.isNotEmpty);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(title: Text(isNew ? 'Log a meal' : 'Edit meal')),
        body: Column(
          children: [
            Expanded(
              child: SafeArea(
                bottom: false,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_work case final work?) ...[
                          const LinearProgressIndicator(),
                          const SizedBox(height: 8),
                          Semantics(liveRegion: true, child: Text(work)),
                          const SizedBox(height: 12),
                        ],
                        if (_error case final error?) ...[
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              error,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (_recoveredPickerImages.isNotEmpty) ...[
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Recovered photo from interrupted picker',
                                    style:
                                        Theme.of(context).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'Attach it to this meal draft or discard it. Nothing is uploaded or saved automatically.',
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      FilledButton(
                                        onPressed: _busy
                                            ? null
                                            : _attachRecoveredPhoto,
                                        child: const Text('Attach to meal'),
                                      ),
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : _discardRecoveredPhotos,
                                        child: const Text('Discard'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (_photoPath case final path?)
                          SizedBox(
                            height: 216,
                            child: ManagedMediaImage(
                              reference: path,
                              media: _media,
                              fit: BoxFit.contain,
                              cacheWidth: 1200,
                              semanticLabel: 'Meal photo',
                              unavailableText: 'Meal photo unavailable.',
                            ),
                          ),
                        if (isNew) ...[
                          Text(
                            'Meal photo',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            'Take a picture or choose one from your gallery.',
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _pickMealPhoto(ImageSource.camera),
                                icon: const Icon(Icons.photo_camera_outlined),
                                label: const Text('Camera'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _pickMealPhoto(ImageSource.gallery),
                                icon: const Icon(Icons.photo_library_outlined),
                                label: const Text('Gallery'),
                              ),
                              if (_photoPath != null)
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => setState(() => _photoPath = null),
                                  child: const Text('Remove photo'),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextButton.icon(
                            style: isNew
                                ? null
                                : TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                  ),
                            onPressed: _busy || _conflict ? null : _pickDate,
                            icon: const Icon(Icons.calendar_today_outlined,
                                size: 18),
                            label: Text(isNew && ambiguousDate
                                ? 'Choose which diary date'
                                : 'Diary date: ${_date.toIso()}')),
                        TextField(
                          controller: _caption,
                          enabled: !_busy,
                          minLines: 1,
                          maxLines: 3,
                          maxLength: 1000,
                          decoration: InputDecoration(
                            labelText: isNew
                                ? 'What did you have? (optional with photo)'
                                : 'Meal notes (optional)',
                            hintText:
                                isNew ? 'e.g. Lunch: soup and a roll' : null,
                            counterText: '',
                          ),
                          onChanged: isNew
                              ? (value) => setState(() {
                                    if (!_slotWasSelected) {
                                      _slot =
                                          mealSlotFor(value, _openedAt.hour);
                                    }
                                    if (!_dateWasSelected) {
                                      _date = mealDateFromIntent(
                                              value,
                                              widget.editor.today ??
                                                  widget.editor.date) ??
                                          widget.editor.date;
                                    }
                                  })
                              : null,
                        ),
                        const SizedBox(height: 8),
                        InputDecorator(
                          decoration: const InputDecoration(labelText: 'Meal'),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<MealSlot>(
                              isExpanded: true,
                              value: _slot,
                              items: [
                                for (final slot in MealSlot.values)
                                  DropdownMenuItem(
                                    value: slot,
                                    child: Text(slot.label),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (slot) {
                                      if (slot == null) return;
                                      setState(() {
                                        _slot = slot;
                                        _slotWasSelected = true;
                                      });
                                    },
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (isNew) ...[
                          if (_items.isEmpty) ...[
                            FilledButton.icon(
                              onPressed: canSaveNew
                                  ? () => _saveNew(withEstimate: true)
                                  : null,
                              icon: const Icon(Icons.auto_awesome_outlined),
                              label: const Text('Save with AI estimate'),
                            ),
                            Text(
                              'Save with AI sends the selected meal photo and any text above to ${_providerLabel ?? 'your selected AI provider'}. Provider plan limits or user-funded API billing may apply. The meal is saved with any available estimates, or locally without estimates if the provider is unavailable.',
                            ),
                          ],
                        ],
                        const SizedBox(height: 16),
                        Text(
                          'Foods',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_items.isEmpty)
                          const Text('No foods identified yet.'),
                        for (var i = 0; i < _items.length; i++) _itemCard(i),
                        Text('Meal totals: ${mealTotalDetails(_items)}'),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: _busy ? null : _addFood,
                              child: const Text('Add food by name'),
                            ),
                            OutlinedButton(
                              onPressed: _busy ? null : _addCatalogueFood,
                              child: const Text('Search catalogue'),
                            ),
                            if (_items.isNotEmpty)
                              OutlinedButton(
                                  onPressed: _busy ? null : () => _addLabel(),
                                  child: const Text('Match a label photo')),
                            if (widget.editor.library != null) ...[
                              OutlinedButton(
                                  onPressed: _busy ? null : _addSavedFood,
                                  child: const Text('Saved foods')),
                              if (_items.isNotEmpty)
                                TextButton(
                                    onPressed: _busy ? null : _saveTemplate,
                                    child: const Text('Save meal for reuse')),
                            ],
                          ],
                        ),
                        if (!isNew) ...[
                          const SizedBox(height: 16),
                          Text(
                            'Describe a correction',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          TextField(
                            controller: _correction,
                            enabled: !_busy && !_conflict,
                            maxLength: 1000,
                            maxLines: 3,
                            minLines: 1,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Correction',
                              hintText: 'e.g. I ate two rolls, not one',
                              counterText: '',
                            ),
                          ),
                          Text(
                            'Preview with AI sends this correction, the meal slot, and current food names and amounts to ${_providerLabel ?? 'your selected AI provider'}. No photos or meal notes are sent. Provider plan limits or user-funded API billing may apply.',
                          ),
                          OutlinedButton(
                            onPressed: _busy ||
                                    _conflict ||
                                    _correction.text.trim().isEmpty
                                ? null
                                : _requestCorrection,
                            child: const Text('Preview correction with AI'),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _busy || _conflict
                                    ? null
                                    : () => _pickMealPhoto(ImageSource.camera),
                                icon: const Icon(Icons.photo_camera_outlined),
                                label: const Text('Camera'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _busy || _conflict
                                    ? null
                                    : () => _pickMealPhoto(ImageSource.gallery),
                                icon: const Icon(Icons.photo_library_outlined),
                                label: const Text('Gallery'),
                              ),
                              if (_photoPath != null)
                                TextButton(
                                  onPressed: _busy || _conflict
                                      ? null
                                      : () => setState(() {
                                            _photoPath = null;
                                            _saveRequestId = null;
                                          }),
                                  child: const Text('Remove photo'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (widget.editor.mutations != null) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed:
                                  _busy || _conflict ? null : _deleteMeal,
                              icon: Icon(
                                Icons.delete_outline,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              label: Text(
                                'Delete meal',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: SizedBox(
                width: double.infinity,
                child: GlassSurface(
                  borderRadius: BorderRadius.zero,
                  accentBorder: true,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: isNew
                      ? SaluTactileButton(
                          primary: _items.isNotEmpty,
                          onPressed: canSaveNew
                              ? () => _saveNew(withEstimate: false)
                              : null,
                          child: Text(
                            _items.isEmpty ? 'Save without AI' : 'Save meal',
                          ),
                        )
                      : SaluTactileButton(
                          onPressed: _busy || _conflict ? null : _saveChanges,
                          child: const Text('Save changes'),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemCard(int index) {
    final item = _items[index];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.name, style: Theme.of(context).textTheme.titleSmall),
            Text(mealPortionText(item.portion) ?? 'Amount unknown'),
            Text(mealNutrientDetails(item.nutrients)),
            if (isAiMealEstimateSource(item.source)) const Text('AI estimate'),
            if (item.source == 'nutrition-label')
              const Text('Nutrition label values'),
            if (item.labelPath != null) const Text('Label photo attached'),
            if (item.reviewIssues.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  Text(
                    'Needs review',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                ],
              ),
              for (final issue in item.reviewIssues)
                Text(
                  mealNutritionIssueText(issue),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
            ],
            Wrap(
              children: [
                TextButton(
                  onPressed: _busy ? null : () => _editFood(index),
                  child: const Text('Edit food'),
                ),
                TextButton(
                    onPressed: _busy ? null : () => _addLabel(index),
                    child: const Text('Add label photo')),
                if (widget.editor.library != null)
                  TextButton(
                      onPressed: _busy ? null : () => _saveFavoriteFood(item),
                      child: const Text('Save as food')),
                for (final (number, label) in item.labelPaths.indexed)
                  TextButton(
                    onPressed: _busy ? null : () => _enterLabel(index, label),
                    child: Text('Label ${number + 1}'),
                  ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _items.removeAt(index)),
                  child: const Text('Remove food'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _CallbackIdGenerator implements IdGenerator {
  const _CallbackIdGenerator(this._next);

  final String Function() _next;

  @override
  String next() => _next();
}
