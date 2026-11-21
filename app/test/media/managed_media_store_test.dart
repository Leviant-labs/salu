import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:salu/src/media/managed_media_store.dart';

void main() {
  test('collector never removes a referenced image', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final input = File('${root.path}/input.png');
    await input.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'test-photo',
    );
    final ref = await media.importImage(XFile(input.path));
    expect(ref, 'media:test-photo');
    await media.collect({ref}, olderThanUtc: DateTime.utc(2100));
    expect(await (await media.resolve(ref))!.exists(), isTrue);
    expect(await input.exists(), isTrue);
  });

  test('collector removes unreferenced old managed files only', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final input = File('${root.path}/input.png');
    await input.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
    var next = 0;
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'photo-${++next}',
    );
    final keptRef = await media.importImage(XFile(input.path));
    final orphanRef = await media.importImage(XFile(input.path));

    // Newer than cutoff: nothing removed.
    await media.collect({keptRef}, olderThanUtc: DateTime.utc(2000));
    expect(await media.resolve(orphanRef), isNotNull);

    // Older than cutoff: orphan removed, kept preserved.
    await media.collect({keptRef}, olderThanUtc: DateTime.utc(2100));
    expect(await media.resolve(keptRef), isNotNull);
    expect(await media.resolve(orphanRef), isNull);
  });

  test('rejects traversal, invalid IDs, and out-of-root paths', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final outside = File('${root.path}/secret.png');
    await outside.writeAsBytes([1, 2, 3, 4]);
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'valid-id',
    );

    expect(await media.resolve('media:../secret'), isNull);
    expect(await media.resolve('media:foo/bar'), isNull);
    expect(await media.resolve(r'media:foo\bar'), isNull);
    expect(await media.resolve('media:'), isNull);
    expect(await media.resolve('media:${'a' * 129}'), isNull);
    expect(await media.resolve(outside.path), isNull);
    expect(
      await media.resolve('${root.path}/owned/meal-images/../secret.png'),
      isNull,
    );

    // removeUnreferenced must never touch out-of-root files.
    await media.removeUnreferenced(outside.path, const {});
    expect(await outside.exists(), isTrue);
  });

  test('nonexistent managed ref resolves to null', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'missing',
    );
    expect(await media.resolve('media:does-not-exist'), isNull);
  });

  test('collision does not overwrite existing managed file', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final first = File('${root.path}/first.png');
    final second = File('${root.path}/second.png');
    await first.writeAsBytes([1, 1, 1, 1]);
    await second.writeAsBytes([2, 2, 2, 2]);
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'same-id',
    );

    final ref = await media.importImage(XFile(first.path));
    await expectLater(
      () => media.importImage(XFile(second.path)),
      throwsA(isA<FileSystemException>()),
    );
    final stored = await media.resolve(ref);
    expect(stored, isNotNull);
    expect(await stored!.readAsBytes(), [1, 1, 1, 1]);
    expect(await second.exists(), isTrue);
  });

  test('failed copy cleans only staging file and preserves source', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'failed-copy',
    );

    await expectLater(
      () => media.importImage(XFile('${root.path}/nonexistent-source.png')),
      throwsA(isA<Object>()),
    );
    final mediaDir = Directory('${root.path}/owned/meal-images');
    if (await mediaDir.exists()) {
      expect(await mediaDir.list().toList(), isEmpty);
    }
    expect(await media.resolve('media:failed-copy'), isNull);
  });

  test('resolves recognized legacy app-owned absolute path', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final mediaDir = await Directory('${root.path}/owned/meal-images')
        .create(recursive: true);
    final legacyFile = File('${mediaDir.path}/photo-legacy.image');
    await legacyFile.writeAsBytes([9, 8, 7, 6]);
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'unused',
    );

    final resolved = await media.resolve(legacyFile.path);
    expect(resolved, isNotNull);
    expect(await resolved!.readAsBytes(), [9, 8, 7, 6]);

    // Legacy path is also protected when referenced in collect().
    await media.collect({legacyFile.path}, olderThanUtc: DateTime.utc(2100));
    expect(await legacyFile.exists(), isTrue);
  });

  test('removeUnreferenced deletes only when not in referenced set', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final input = File('${root.path}/input.png');
    await input.writeAsBytes([137, 80, 78, 71]);
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'removable',
    );
    final ref = await media.importImage(XFile(input.path));

    await media.removeUnreferenced(ref, {ref});
    expect(await media.resolve(ref), isNotNull);

    await media.removeUnreferenced(ref, const {});
    expect(await media.resolve(ref), isNull);
  });

  test('recoverLostPickerImages returns injected lost files', () async {
    final root = await Directory.systemTemp.createTemp('salu-media-');
    addTearDown(() => root.delete(recursive: true));
    final lost = File('${root.path}/lost.png');
    await lost.writeAsBytes([137, 80, 78, 71]);
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'recovered',
      lostDataRetriever: () async => [XFile(lost.path)],
    );

    final files = await media.recoverLostPickerImages();
    expect(files.map((file) => file.path), [lost.path]);
  });

  testWidgets('ManagedMediaImage shows unavailable state for missing file',
      (tester) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('salu-media-'),
    );
    addTearDown(() async {
      await root?.delete(recursive: true);
    });
    final media = ManagedMediaStore(
      directory: () async => Directory('${root!.path}/owned'),
      newId: () => 'unused',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManagedMediaImage(
            reference: 'media:missing-file',
            media: media,
            unavailableText: 'Meal photo unavailable.',
          ),
        ),
      ),
    );
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.text('Meal photo unavailable.'), findsOneWidget);
  });
}
