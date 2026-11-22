import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/data_transfer/archive_crypto.dart';

void main() {
  test('archive authenticates password and randomizes repeated exports',
      () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    const password = 'test-only-password';
    final first = await encryptArchive(bytes, password);
    final second = await encryptArchive(bytes, password);
    expect(first, isNot(orderedEquals(second)));
    expect(await decryptArchive(first, password), orderedEquals(bytes));

    await expectLater(
      decryptArchive(first, 'wrong-test-password'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Could not decrypt archive'),
            isNot(contains(password)),
            isNot(contains('wrong-test-password')),
          ),
        ),
      ),
    );

    // Tampered tag byte.
    final tamperedTag = Uint8List.fromList(first);
    tamperedTag[tamperedTag.length - 1] ^= 1;
    await expectLater(
      decryptArchive(tamperedTag, password),
      throwsA(isA<FormatException>()),
    );

    // Tampered header AAD (salt byte).
    final tamperedHeader = Uint8List.fromList(first);
    tamperedHeader[6] ^= 1;
    await expectLater(
      decryptArchive(tamperedHeader, password),
      throwsA(isA<FormatException>()),
    );

    // Tampered ciphertext byte.
    final tamperedCiphertext = Uint8List.fromList(first);
    tamperedCiphertext[archiveEnvelopeHeaderBytes] ^= 1;
    await expectLater(
      decryptArchive(tamperedCiphertext, password),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects invalid inputs before running PBKDF2 KDF', () async {
    final sw = Stopwatch()..start();

    // Short password on encrypt & decrypt.
    await expectLater(
      encryptArchive(Uint8List.fromList([1, 2, 3]), 'short-pass'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      decryptArchive(Uint8List(64), 'short-pass'),
      throwsA(isA<FormatException>()),
    );

    // Truncated envelope (smaller than header + tag).
    await expectLater(
      decryptArchive(Uint8List.fromList([83, 65, 76, 85, 49, 0, 1]),
          'valid-long-password'),
      throwsA(isA<FormatException>()),
    );

    // Wrong magic.
    final badMagic = Uint8List(64);
    badMagic.setRange(0, 5, 'SALU9'.codeUnits);
    await expectLater(
      decryptArchive(badMagic, 'valid-long-password'),
      throwsA(isA<FormatException>()),
    );

    // Over-limit payload on encrypt.
    final overLimitPlain = Uint8List(maxEncryptedPayloadBytes + 1);
    await expectLater(
      encryptArchive(overLimitPlain, 'valid-long-password'),
      throwsA(isA<FormatException>()),
    );

    // Over-limit encrypted envelope on decrypt.
    final overLimitEnc = Uint8List(maxEncryptedEnvelopeBytes + 1);
    overLimitEnc.setRange(0, 5, archiveMagicBytes);
    await expectLater(
      decryptArchive(overLimitEnc, 'valid-long-password'),
      throwsA(isA<FormatException>()),
    );

    sw.stop();
    // All rejections happen before KDF, so total time should be well under 500ms.
    expect(sw.elapsedMilliseconds, lessThan(500));
  });

  test('file-to-file encrypt and decrypt round trip', () async {
    final tempDir = await Directory.systemTemp.createTemp('salu_crypto_test_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final input = File('${tempDir.path}/plain.zip');
    final encrypted = File('${tempDir.path}/archive.salu');
    final decrypted = File('${tempDir.path}/out.zip');
    final payload =
        Uint8List.fromList(List<int>.generate(2048, (i) => i % 251));
    await input.writeAsBytes(payload, flush: true);

    const password = 'file-roundtrip-password';
    await encryptFileToFile(input, encrypted, password);
    expect(await encrypted.exists(), isTrue);
    expect(await encrypted.length(),
        payload.length + archiveEnvelopeOverheadBytes);

    await decryptFileToFile(encrypted, decrypted, password);
    expect(await decrypted.readAsBytes(), orderedEquals(payload));
  });
}
