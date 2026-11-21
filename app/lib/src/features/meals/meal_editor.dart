import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../assistant/assistant.dart';
import '../search/food_library.dart';
import 'meal_editor_ai.dart';
import 'meal_editor_data.dart';
import 'meal_editor_dialogs.dart';
import 'meal_editor_images.dart';
import 'meal_estimation.dart';

/// Route for logging a new meal or revising one already in the diary.
class MealEditor extends StatelessWidget {
  const MealEditor({
    super.key,
    this.meal,
    required this.repository,
    required this.assistant,
    required this.foods,
    required this.date,
    required this.newId,
    this.activeEstimates,
    this.estimateStatusStore,
    this.initialDescription = '',
    this.initialFood,
    this.today,
    this.onLogged,
    this.initialItems = const [],
    this.initialSlot,
    this.initialCorrection = '',
    this.library,
  });

  final PhotoMeal? meal;
  final PhotoMealRepository repository;
  final SaluAssistant assistant;
  final ActiveMealEstimates? activeEstimates;
  final MealEstimateStatusStore? estimateStatusStore;
  final FoodRepository foods;
  final DiaryDate date;
  final String Function() newId;
  final String initialDescription;
  final Food? initialFood;
  final DiaryDate? today;
  final ValueChanged<DiaryDate>? onLogged;
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
  late final _openedAt = DateTime.now();
  late final _caption = TextEditingController(
    text: _original?.caption ?? widget.editor.initialDescription,
  );
  late final _correction =
      TextEditingController(text: widget.editor.initialCorrection);
  final _picker = ImagePicker();
  final _draftImages = <String>{};
  // If a write throws, its outcome could be unknown. Keep any affected file
  // rather than deleting evidence that the repository may already reference.
  final _protectedImages = <String>{};

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
    if (_initialFood != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editFood(0);
      });
    }
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
      unawaited(discardMealImage(path));
    }
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
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
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
      final path = await storeMealImage(photo, widget.editor.newId());
      if (!mounted) {
        await discardMealImage(path);
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

  Future<Map<String, dynamic>> _transcribeLabel(String path) async =>
      widget.editor.assistant.ask(
          instructions: mealLabelInstructions,
          prompt: 'Transcribe the selected nutrition label.',
          images: [await encodeMealUpload(path)],
          task: InferenceTask.labelOcr);

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
        unawaited(discardMealImage(path));
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
      final id = _requestId;
      final editor = widget.editor;
      final meal = PhotoMeal(
        id: id,
        date: _date,
        slot: _slot,
        caption: caption,
        createdAt: DateTime.now(),
        recordedOffsetMinutes: _openedAt.timeZoneOffset.inMinutes,
        photoPath: photoPath,
        items: _withIds(_items),
        estimateStatus:
            withEstimate ? MealEstimateStatus.pending : MealEstimateStatus.none,
      );
      final paths = _protectForWrite(meal);
      final repository = editor.repository;
      if (!await repository.saveNew(meal)) {
        final matching = (await repository.listFor(
          meal.date,
        ))
            .where((saved) => saved.id == id)
            .firstOrNull;
        final matchedPaths = {
          matching?.photoPath,
          for (final item in matching?.items ?? const <PhotoMealItem>[])
            ...item.labelPaths,
        };
        _release(paths.where((path) => !matchedPaths.contains(path)).toSet());
        if (matching == null) {
          _showError('Could not save the meal. Try again.');
          return;
        }
        _saved('This meal was already saved under ${matching.slot.label}.');
        return;
      }
      if (withEstimate) {
        unawaited(estimateSavedMeal(
          meal: meal,
          repository: repository,
          assistant: editor.assistant,
          newId: editor.newId,
          activeEstimates: editor.activeEstimates,
          statusStore: editor.estimateStatusStore,
        ));
      }
      if (mounted) editor.onLogged?.call(meal.date);
      _saved('Saved under ${meal.slot.label} · ${meal.date.toIso()}.');
    } catch (_) {
      _showError('Could not save the meal. Try again.');
    } finally {
      _finish();
    }
  }

  List<PhotoMealItem> _withIds(List<PhotoMealItem> items) => [
        for (final item in items)
          item.id == null ? item.copyWith(id: widget.editor.newId()) : item,
      ];

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
    final updated = original.copyWith(
      slot: _slot,
      caption: _caption.text.trim(),
      items: _withIds(_items),
      estimateStatus: original.estimateStatus == MealEstimateStatus.pending
          ? MealEstimateStatus.none
          : original.estimateStatus,
    );
    _start('Saving changes…');
    final paths = _protectForWrite(updated);
    try {
      if (await widget.editor.repository.replace(updated, original.revision)) {
        _saved('Meal updated.');
      } else {
        _release(paths);
        if (!mounted) return;
        setState(() => _conflict = true);
        _showError(
            'This meal changed or was removed while you were editing. Go back and reopen it to edit the latest version.');
      }
    } catch (_) {
      _showError('Could not save your changes. Try again.');
    } finally {
      _finish();
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
        appBar: AppBar(title: Text(isNew ? 'Log a meal' : 'Edit meal')),
        body: SafeArea(
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
                  if (_photoPath case final path?)
                    SizedBox(
                      height: 216,
                      child: Image.file(
                        File(path),
                        fit: BoxFit.contain,
                        cacheWidth: 1200,
                        semanticLabel: 'Meal photo',
                        errorBuilder: (context, error, stackTrace) =>
                            const Center(
                          child: Text('Meal photo unavailable.'),
                        ),
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
                  if (isNew)
                    TextButton.icon(
                        onPressed: _busy ? null : _pickDate,
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(ambiguousDate
                            ? 'Choose which diary date'
                            : 'Diary date: ${_date.toIso()}'))
                  else
                    Text('Diary date: ${_date.toIso()}'),
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
                      hintText: isNew ? 'e.g. Lunch: soup and a roll' : null,
                      counterText: '',
                    ),
                    onChanged: isNew
                        ? (value) => setState(() {
                              if (!_slotWasSelected) {
                                _slot = mealSlotFor(value, _openedAt.hour);
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
                    OutlinedButton(
                      onPressed: canSaveNew
                          ? () => _saveNew(withEstimate: false)
                          : null,
                      child: Text(
                          _items.isEmpty ? 'Save without AI' : 'Save meal'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Foods',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_items.isEmpty) const Text('No foods identified yet.'),
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
                      onPressed:
                          _busy || _conflict || _correction.text.trim().isEmpty
                              ? null
                              : _requestCorrection,
                      child: const Text('Preview correction with AI'),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy || _conflict ? null : _saveChanges,
                      child: const Text('Save changes'),
                    ),
                  ],
                ],
              ),
            ),
          ),
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
