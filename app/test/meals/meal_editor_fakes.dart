import 'dart:async';
import 'dart:convert';
import 'dart:io';

// The plugins expose their test seams through these transitive dependencies.
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:salu/src/assistant/assistant.dart';
import 'package:salu_core/salu_core.dart';

final class MemoryPhotoMeals implements PhotoMealRepository {
  final meals = <String, PhotoMeal>{};
  final insertions = <PhotoMeal>[];
  final replacements = <({PhotoMeal meal, int expectedRevision})>[];

  @override
  Future<List<PhotoMeal>> listFor(DiaryDate date) async => [
        for (final meal in meals.values)
          if (meal.date == date) meal,
      ];

  @override
  Future<bool> saveNew(PhotoMeal meal) async {
    insertions.add(meal);
    if (meals.containsKey(meal.id)) return false;
    meals[meal.id] = meal;
    return true;
  }

  @override
  Future<bool> replace(PhotoMeal meal, int expectedRevision) async {
    replacements.add((meal: meal, expectedRevision: expectedRevision));
    if (meals[meal.id]?.revision != expectedRevision) return false;
    meals[meal.id] = meal.copyWith(revision: expectedRevision + 1);
    return true;
  }
}

final class EmptyCatalogue implements FoodRepository {
  const EmptyCatalogue();

  @override
  Future<Food?> findById(String id) async => null;

  @override
  Future<List<Food>> search(String query, {int limit = 20}) async => [];
}

final class FixturePicker extends ImagePickerPlatform {
  FixturePicker(this.path);

  final String path;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async =>
      XFile(path);
}

final class TestPhotoDirectory extends PathProviderPlatform {
  TestPhotoDirectory(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

final class FakeOpenAi implements SaluAssistantKeyStore {
  FakeOpenAi({bool connected = true, this.reply = const {}, this.waitForReply})
      : _key = connected ? 'test-key-for-meal-editor' : null;

  final Map<String, Object?> reply;
  final Future<void>? waitForReply;
  final requests = <Map<String, Object?>>[];
  int clientsCreated = 0;
  String? _key;

  late final assistant = SaluAssistant(
    keyStore: this,
    httpClientFactory: () {
      clientsCreated++;
      return _Client(this);
    },
  );

  @override
  Future<String?> read() async => _key;

  @override
  Future<void> write(String key) async => _key = key;

  @override
  Future<void> delete() async => _key = null;
}

/// Reads the actual Responses API input emitted by SaluAssistant.
List<Map<String, Object?>> userContent(Map<String, Object?> request) {
  final messages =
      (request['input'] as List<Object?>).cast<Map<String, Object?>>();
  final user = messages.singleWhere((message) => message['role'] == 'user');
  return (user['content'] as List<Object?>).cast<Map<String, Object?>>();
}

final class _Client implements HttpClient {
  _Client(this.api);

  final FakeOpenAi api;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _Request(api);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  _Request(this.api);

  final FakeOpenAi api;
  final _body = <int>[];

  @override
  final HttpHeaders headers = _Headers();

  @override
  int contentLength = -1;

  @override
  bool followRedirects = true;

  @override
  void add(List<int> data) => _body.addAll(data);

  @override
  Future<HttpClientResponse> close() async {
    api.requests.add(jsonDecode(utf8.decode(_body)) as Map<String, Object?>);
    await api.waitForReply;
    return _Response(utf8.encode(jsonEncode({
      'status': 'completed',
      'output': [
        {
          'type': 'message',
          'role': 'assistant',
          'status': 'completed',
          'content': [
            {'type': 'output_text', 'text': jsonEncode(api.reply)},
          ],
        },
      ],
    })));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Headers implements HttpHeaders {
  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response extends StreamView<List<int>>
    implements HttpClientResponse {
  _Response(List<int> body)
      : contentLength = body.length,
        super(Stream<List<int>>.value(body));

  @override
  final int contentLength;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
