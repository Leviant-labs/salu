import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

/// User-held password, no escrow/recovery. Passwords never enter SQLite.
final class EncryptedArchive {
  static const iterations = 210000;
  static final _cipher = AesGcm.with256bits();
  static final _kdf =
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
  static List<int> _random(int n) {
    final random = Random.secure();
    return List.generate(n, (_) => random.nextInt(256));
  }

  static Future<String> seal(String plaintext, String password) async {
    if (password.length < 12) {
      throw ArgumentError('Use a passphrase of at least 12 characters');
    }
    final salt = _random(16);
    final key =
        await _kdf.deriveKeyFromPassword(password: password, nonce: salt);
    final box = await _cipher.encrypt(utf8.encode(plaintext),
        secretKey: key,
        nonce: _random(12),
        aad: utf8.encode('salu-encrypted-archive-v1'));
    return jsonEncode({
      'format': 'salu-encrypted-archive',
      'version': 1,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': iterations,
      'cipher': 'AES-256-GCM',
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'tag': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText)
    });
  }

  static Future<String> open(String archive, String password) async {
    if (archive.length > 75 * 1024 * 1024) {
      throw const FormatException('Archive too large');
    }
    final j = Map<String, Object?>.from(jsonDecode(archive) as Map);
    if (j['format'] != 'salu-encrypted-archive' ||
        j['version'] != 1 ||
        j['iterations'] != iterations ||
        j['kdf'] != 'PBKDF2-HMAC-SHA256' ||
        j['cipher'] != 'AES-256-GCM') {
      throw const FormatException('Unsupported encrypted archive');
    }
    final salt = base64Decode(j['salt']! as String),
        nonce = base64Decode(j['nonce']! as String),
        tag = base64Decode(j['tag']! as String);
    if (salt.length != 16 || nonce.length != 12 || tag.length != 16) {
      throw const FormatException('Invalid encryption parameters');
    }
    final key =
        await _kdf.deriveKeyFromPassword(password: password, nonce: salt);
    final result = await _cipher.decrypt(
        SecretBox(base64Decode(j['ciphertext']! as String),
            nonce: nonce, mac: Mac(tag)),
        secretKey: key,
        aad: utf8.encode('salu-encrypted-archive-v1'));
    return utf8.decode(result);
  }
}
