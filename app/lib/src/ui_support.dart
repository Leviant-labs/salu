import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_data/salu_data.dart';
import 'providers.dart';

String tr(BuildContext c, String en, String pt) =>
    Localizations.localeOf(c).languageCode == 'pt' ? pt : en;
String number(double n) =>
    n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(1);
final initialSettingsProvider =
    Provider<Map<String, Object?>>((ref) => const {});
final settingsProvider =
    StateNotifierProvider<SettingsController, Map<String, Object?>>(
        (ref) => SettingsController(ref, ref.watch(initialSettingsProvider)));

class SettingsController extends StateNotifier<Map<String, Object?>> {
  SettingsController(this.ref, Map<String, Object?> initial)
      : super(Map.unmodifiable(initial));
  final Ref ref;
  void reset() => state = const {};
  Future<void> reload() async {
    final saved = await LocalWorkspace(ref.read(databaseProvider))
        .read('preferences', 'app');
    state = Map.unmodifiable(saved?.data ?? const {});
  }

  Future<void> change(String key, Object? value) async {
    final workspace = LocalWorkspace(ref.read(databaseProvider));
    final old = await workspace.read('preferences', 'app');
    final next = {...state, key: value};
    await workspace.put(
        requestId: ref.read(idGeneratorProvider).next(),
        collection: 'preferences',
        id: 'app',
        expectedRevision: old?.revision ?? 0,
        data: next);
    state = Map.unmodifiable(next);
  }
}

Future<String?> askText(BuildContext context,
    {required String title,
    String initial = '',
    bool secret = false,
    String? hint}) async {
  return showDialog<String>(
      context: context,
      builder: (_) => _TextPrompt(
          title: title, initial: initial, secret: secret, hint: hint));
}

class _TextPrompt extends StatefulWidget {
  const _TextPrompt(
      {required this.title,
      required this.initial,
      required this.secret,
      this.hint});
  final String title, initial;
  final bool secret;
  final String? hint;
  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text(widget.title),
          content: TextField(
              controller: controller,
              autofocus: true,
              obscureText: widget.secret,
              decoration: InputDecoration(
                  labelText: widget.title, hintText: widget.hint)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(c, 'Cancel', 'Cancelar'))),
            FilledButton(
                onPressed: () => Navigator.pop(c, controller.text.trim()),
                child: Text(tr(c, 'Continue', 'Continuar')))
          ]);
}

Future<bool> confirmAction(
        BuildContext context, String title, String detail) async =>
    await showDialog<bool>(
        context: context,
        builder: (c) =>
            AlertDialog(title: Text(title), content: Text(detail), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: Text(tr(c, 'Cancel', 'Cancelar'))),
              FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: Text(tr(c, 'Confirm', 'Confirmar')))
            ])) ??
    false;
void showFailure(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(tr(context, 'Could not complete this action: $error',
          'Não foi possível concluir esta ação: $error'))));
}

String nutrientLabel(BuildContext c, String key) => switch (key) {
      'energy_kcal' => tr(c, 'Energy', 'Energia'),
      'energy_kj' => tr(c, 'Energy', 'Energia'),
      'protein_g' => tr(c, 'Protein', 'Proteína'),
      'fat_g' => tr(c, 'Fat', 'Lípidos'),
      'saturated_fat_g' => tr(c, 'Saturated fat', 'Ácidos gordos saturados'),
      'carbohydrate_g' => tr(c, 'Carbohydrate', 'Hidratos de carbono'),
      'fiber_g' => tr(c, 'Fibre', 'Fibra'),
      'sugars_g' => tr(c, 'Total sugars', 'Açúcares totais'),
      'free_sugars_g' => tr(c, 'Free sugars', 'Açúcares livres'),
      'sodium_mg' => tr(c, 'Sodium', 'Sódio'),
      'iron_mg' => tr(c, 'Iron', 'Ferro'),
      'iodine_ug' => tr(c, 'Iodine', 'Iodo'),
      'calcium_mg' => tr(c, 'Calcium', 'Cálcio'),
      'vitamin_c_mg' => tr(c, 'Vitamin C', 'Vitamina C'),
      'vitamin_d_ug' => tr(c, 'Vitamin D', 'Vitamina D'),
      _ => key
    };
