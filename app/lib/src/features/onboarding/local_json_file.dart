import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Versioned feature documents in the app's private support directory.
class LocalJsonFile {
  LocalJsonFile(
    this.filename, {
    this.directory = getApplicationSupportDirectory,
  });

  final String filename;
  final Future<Directory> Function() directory;
  Future<void> _pending = Future<void>.value();

  Future<File> _file() async =>
      File('${(await directory()).path}${Platform.pathSeparator}$filename');

  Future<Map<String, dynamic>?> read() async {
    await _pending;
    return _read(await _file());
  }

  Future<Map<String, dynamic>?> _read(File file) async {
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const FormatException('Unsupported local document');
    }
    return value;
  }

  /// Serialize read-modify-write operations and never overwrite a bad read.
  Future<void> update(
    Map<String, Object?> Function(Map<String, dynamic>? saved) change,
  ) {
    final result = _pending.then((_) async {
      final file = await _file();
      final next = change(await _read(file));
      await file.parent.create(recursive: true);
      final staging = File('${file.path}.tmp');
      await staging.writeAsString(
        jsonEncode({...next, 'version': 1}),
        flush: true,
      );
      await staging.rename(file.path);
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
