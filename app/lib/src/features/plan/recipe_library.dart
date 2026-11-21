import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:salu_data/salu_data.dart' as salu_data
    show decodeRecipe, encodeRecipe;

import '../../data_transfer/data_write_gate.dart';

/// App-layer wrapper around [RecipeLibraryRepository] with optional
/// [DataWriteGate] coordination.
class RecipeLibrary {
  const RecipeLibrary(this.foods, this.documents, {this.gate});
  final FoodRepository foods;
  final LocalDocumentStore documents;
  final DataWriteGate? gate;

  static const int currentVersion = RecipeLibraryRepository.currentVersion;

  RecipeLibraryRepository get _repository =>
      RecipeLibraryRepository(foods, documents);

  Future<T> _runWrite<T>(Future<T> Function() work) =>
      gate != null ? gate!.runWrite(work) : work();

  Future<List<RecipeVersion>> load() => _runWrite(() => _repository.load());

  Future<void> add(RecipeVersion recipe) =>
      _runWrite(() => _repository.add(recipe));

  static Map<String, Object?> encodeRecipe(RecipeVersion recipe) =>
      salu_data.encodeRecipe(recipe);

  static RecipeVersion decodeRecipe(Map<String, dynamic> row) =>
      salu_data.decodeRecipe(row);
}
