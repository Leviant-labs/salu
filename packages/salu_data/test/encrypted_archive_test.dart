import 'dart:convert';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test(
      'archive encrypts, authenticates and rejects wrong passwords or tampering',
      () async {
    const password = 'a user held long passphrase';
    final sealed = await EncryptedArchive.seal('{"diary":"private"}', password);
    expect(sealed, isNot(contains('private')));
    expect(
        await EncryptedArchive.open(sealed, password), '{"diary":"private"}');
    await expectLater(
        EncryptedArchive.open(sealed, 'wrong password'), throwsA(anything));
    final j = jsonDecode(sealed) as Map<String, dynamic>;
    final cipher = base64Decode(j['ciphertext'] as String);
    cipher[0] ^= 1;
    j['ciphertext'] = base64Encode(cipher);
    await expectLater(
        EncryptedArchive.open(jsonEncode(j), password), throwsA(anything));
  });
}
