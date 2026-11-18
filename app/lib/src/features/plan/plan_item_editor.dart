import 'package:flutter/material.dart';

/// A result with a null name means delete. A null result means cancel.
typedef PlanItemEdit = ({String? name, String details});

Future<PlanItemEdit?> editPlanItem(
  BuildContext context, {
  required String title,
  required bool grocery,
  String name = '',
  String details = '',
  bool allowDelete = false,
}) =>
    showDialog<PlanItemEdit>(
      context: context,
      builder: (context) => _PlanItemEditor(
        title: title,
        grocery: grocery,
        name: name,
        details: details,
        allowDelete: allowDelete,
      ),
    );

class _PlanItemEditor extends StatefulWidget {
  const _PlanItemEditor({
    required this.title,
    required this.grocery,
    required this.name,
    required this.details,
    required this.allowDelete,
  });

  final String title;
  final bool grocery;
  final String name;
  final String details;
  final bool allowDelete;

  @override
  State<_PlanItemEditor> createState() => _PlanItemEditorState();
}

class _PlanItemEditorState extends State<_PlanItemEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.name);
  late final _details = TextEditingController(text: widget.details);

  @override
  void dispose() {
    _name.dispose();
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        scrollable: true,
        content: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: widget.name.isEmpty,
                maxLength: 120,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: widget.grocery ? 'Item name' : 'Meal name',
                  counterText: '',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a name.'
                    : null,
              ),
              TextFormField(
                controller: _details,
                minLines: 1,
                maxLines: widget.grocery ? 1 : 5,
                maxLength: widget.grocery ? 60 : 3000,
                decoration: InputDecoration(
                  labelText: widget.grocery
                      ? 'Amount (optional)'
                      : 'Ingredients or notes (optional)',
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (widget.allowDelete)
            TextButton(
              onPressed: () => Navigator.of(
                context,
              ).pop<PlanItemEdit>((name: null, details: '')),
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (!_form.currentState!.validate()) return;
              Navigator.of(context).pop<PlanItemEdit>((
                name: _name.text.trim(),
                details: _details.text.trim(),
              ));
            },
            child: const Text('Save'),
          ),
        ],
      );
}
