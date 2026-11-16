import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import 'grocery_labels.dart';

final manualGroceryProvider = FutureProvider<Map<String,Map<String,Object?>>>(
  (ref) => GroceryService(ref.watch(databaseProvider)).manualGroceries());

class WeekGroceries extends ConsumerWidget {
  const WeekGroceries({super.key,required this.plan});
  final StoredPlan plan;
  String _name(BuildContext context, GroceryLineView row) =>
      row.entry.hasNameOverride ? row.name :
      groceryShoppingName(context, row.entry.foodId, row.name);
  Future<void> _generated(BuildContext context,WidgetRef ref,String key,
      Map<String,Object?> change) async {
    try {
      final db = ref.read(databaseProvider);
      final old = await LocalWorkspace(db).read('groceries',plan.documentId);
      final previous = GroceryService.normalizeItem(old?.data[key]);
      await GroceryService(db).saveGenerated(planDocumentId:plan.documentId,
        requestId:ref.read(idGeneratorProvider).next(),expectedRevision:old?.revision ?? 0,
        data:{...?old?.data,key:{...previous,...change}});
      ref.invalidate(groceryListProvider(plan.documentId));
    } catch(error) { if(context.mounted) showFailure(context,error); }
  }
  Future<void> _manual(BuildContext context,WidgetRef ref,String id,
      Map<String,Object?>? item) async {
    try {
      final db = ref.read(databaseProvider);
      final old = await LocalWorkspace(db).read('groceries','manual');
      final data = {...?old?.data};
      item == null ? data.remove(id) : data[id] = item;
      await GroceryService(db).saveManual(requestId:ref.read(idGeneratorProvider).next(),
        expectedRevision:old?.revision ?? 0,data:data);
      ref.invalidate(manualGroceryProvider);
    } catch(error) { if(context.mounted) showFailure(context,error); }
  }
  Future<void> _edit(BuildContext context,WidgetRef ref,GroceryLineView row) async {
    final name = TextEditingController(text:_name(context, row));
    final grams = TextEditingController(text:number(row.grams.toDouble()));
    final accepted = await showDialog<bool>(context:context,builder:(context) => AlertDialog(
      title:Text(tr(context,'Edit grocery item','Editar compra')),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:name,decoration:InputDecoration(labelText:tr(context,'Name','Nome'))),
        const SizedBox(height:12),TextField(controller:grams,
          keyboardType:const TextInputType.numberWithOptions(decimal:true),
          decoration:InputDecoration(labelText:tr(context,'Amount (g)','Quantidade (g)'))),
      ])),actions:[TextButton(onPressed:() => Navigator.pop(context,false),
        child:Text(tr(context,'Cancel','Cancelar'))),
        FilledButton(onPressed:() => Navigator.pop(context,true),child:Text(tr(context,'Save','Guardar')))]));
    if(accepted == true && context.mounted) {
      try {
        final quantity = Exact.parse(grams.text.replaceAll(',','.'));
        if(!quantity.positive) throw const FormatException('Invalid grocery quantity');
        await _generated(context,ref,row.entry.key,{
          if (row.entry.hasNameOverride || name.text.trim() != _name(context, row))
            'name':name.text.trim(),
          'grams':quantity.toJson(),
        });
      } catch(error) { if(context.mounted) showFailure(context,error); }
    }
    name.dispose(); grams.dispose();
  }
  @override
  Widget build(BuildContext context,WidgetRef ref) {
    final list = ref.watch(groceryListProvider(plan.documentId));
    final manual = ref.watch(manualGroceryProvider).valueOrNull ?? {};
    return list.when(loading:() => const Center(child:CircularProgressIndicator()),
      error:(error,stack) => TextButton(onPressed:() => ref.invalidate(groceryListProvider(plan.documentId)),
        child:Text(tr(context,'Retry groceries','Voltar a carregar compras'))),
      data:(groceries) => Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Text(tr(context,'Shopping for ${groceries.householdServings} person(s)',
            'Compras para ${groceries.householdServings} pessoa(s)'),
            style:Theme.of(context).textTheme.titleMedium),
        for(final row in groceries.visible) ListTile(
          leading:Checkbox(value:row.checked,onChanged:(value) =>
              _generated(context,ref,row.entry.key,{'checked':value == true})),
          title:Text(_name(context, row)),subtitle:Text('${number(row.grams.toDouble())} g'
            '${row.gramsOverrideValid ? '' : ' · ${tr(context,'Check amount override','Rever quantidade alterada')}'}'
            '${groceryPreparationNote(context, row.entry.foodId) == null ? '' : '\n${groceryPreparationNote(context, row.entry.foodId)}'}'),
          trailing:Wrap(children:[IconButton(tooltip:tr(context,'Edit item','Editar item'),
            icon:const Icon(Icons.edit_outlined),onPressed:() => _edit(context,ref,row)),
            IconButton(tooltip:tr(context,'Remove item','Remover item'),icon:const Icon(Icons.remove_circle_outline),
              onPressed:() => _generated(context,ref,row.entry.key,{'removed':true}))])),
        if(groceries.removed.isNotEmpty) ExpansionTile(title:Text(tr(context,'Removed items','Itens removidos')),
          children:[for(final row in groceries.removed) ListTile(title:Text(_name(context, row)),
            trailing:TextButton(onPressed:() => _generated(context,ref,row.entry.key,{'removed':false}),
              child:Text(tr(context,'Restore','Restaurar'))))]),
        const Divider(),Text(tr(context,'Your additions','As suas adições'),style:Theme.of(context).textTheme.titleMedium),
        for(final entry in manual.entries) ListTile(
          leading:Checkbox(value:entry.value['checked'] == true,onChanged:(value) =>
              _manual(context,ref,entry.key,{...entry.value,'checked':value == true})),
          title:Text(entry.value['name'] as String? ?? entry.key),
          trailing:IconButton(tooltip:tr(context,'Remove item','Remover item'),icon:const Icon(Icons.delete_outline),
            onPressed:() => _manual(context,ref,entry.key,null))),
        TextButton.icon(onPressed:() async {
          final input = TextEditingController();
          final accepted = await showDialog<bool>(context:context,builder:(context) => AlertDialog(
            title:Text(tr(context,'Add grocery item','Adicionar compra')),
            content:TextField(controller:input,autofocus:true,
              decoration:InputDecoration(labelText:tr(context,'Item','Item'))),
            actions:[TextButton(onPressed:() => Navigator.pop(context,false),child:Text(tr(context,'Cancel','Cancelar'))),
              FilledButton(onPressed:() => Navigator.pop(context,true),child:Text(tr(context,'Add','Adicionar')))]));
          if(accepted == true && input.text.trim().isNotEmpty && context.mounted) {
            await _manual(context,ref,ref.read(idGeneratorProvider).next(),{'name':input.text.trim(),'checked':false});
          }
          input.dispose();
        },icon:const Icon(Icons.add),label:Text(tr(context,'Add item','Adicionar item'))),
      ]));
  }
}
