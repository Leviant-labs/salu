import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Magic bytes `SALU1` identifying Salu encrypted archive format v1.
const List<int> archiveMagicBytes = <int>[83, 65, 76, 85, 49];

/// Salt length in bytes for PBKDF2-HMAC-SHA256.
const int archiveSaltBytes = 16;

/// Nonce length in bytes for AES-256-GCM.
const int archiveNonceBytes = 12;

/// Authentication tag length in bytes for AES-256-GCM.
const int archiveTagBytes = 16;

/// Authenticated header length (`magic || salt || nonce`).
const int archiveEnvelopeHeaderBytes = 5 + archiveSaltBytes + archiveNonceBytes;

/// Total envelope overhead (`magic || salt || nonce || tag`).
const int archiveEnvelopeOverheadBytes =
    archiveEnvelopeHeaderBytes + archiveTagBytes;

/// PBKDF2-HMAC-SHA256 iteration count (never weakened).
const int archivePbkdf2Iterations = 600000;

/// Derived symmetric key length in bytes (AES-256).
const int archiveKeyBytes = 32;

/// Minimum required backup password length in characters.
const int archiveMinPasswordLength = 12;

/// Maximum permitted compressed archive payload size (64 MiB).
const int maxEncryptedPayloadBytes = 64 * 1024 * 1024;

/// Maximum permitted encrypted envelope size (`64 MiB + 49 bytes`).
const int maxEncryptedEnvelopeBytes =
    maxEncryptedPayloadBytes + archiveEnvelopeOverheadBytes;

const String _safeDecryptFailureMessage =
    'Could not decrypt archive. Check the password or verify the file is intact.';

final AesGcm _aesGcm = AesGcm.with256bits();
final Pbkdf2 _pbkdf2 = Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: archivePbkdf2Iterations,
  bits: archiveKeyBytes * 8,
);

void _validatePassword(String password) {
  if (password.length < archiveMinPasswordLength) {
    throw const FormatException(
      'Backup password must be at least $archiveMinPasswordLength characters.',
    );
  }
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

bool _hasValidMagic(Uint8List bytes) {
  if (bytes.length < archiveMagicBytes.length) {
    return false;
  }
  for (var i = 0; i < archiveMagicBytes.length; i++) {
    if (bytes[i] != archiveMagicBytes[i]) {
      return false;
    }
  }
  return true;
}

Future<SecretKey> _deriveKey(String password, List<int> salt) {
  return _pbkdf2.deriveKeyFromPassword(
    password: password,
    nonce: salt,
  );
}

/// Encrypts a compressed ZIP archive payload using PBKDF2-HMAC-SHA256
/// (600,000 iterations) and AES-256-GCM with an authenticated `SALU1` header.
Future<Uint8List> encryptArchive(Uint8List zipBytes, String password) async {
  _validatePassword(password);
  if (zipBytes.length > maxEncryptedPayloadBytes) {
    throw const FormatException(
      'Archive exceeds the 64 MiB encrypted payload limit.',
    );
  }

  final salt = _randomBytes(archiveSaltBytes);
  final nonce = _randomBytes(archiveNonceBytes);

  final header = Uint8List(archiveEnvelopeHeaderBytes)
    ..setRange(0, 5, archiveMagicBytes)
    ..setRange(5, 5 + archiveSaltBytes, salt)
    ..setRange(5 + archiveSaltBytes, archiveEnvelopeHeaderBytes, nonce);

  final key = await _deriveKey(password, salt);
  final secretBox = await _aesGcm.encrypt(
    zipBytes,
    secretKey: key,
    nonce: nonce,
    aad: header,
  );

  final cipherText = secretBox.cipherText;
  final macBytes = secretBox.mac.bytes;
  final out = Uint8List(
    archiveEnvelopeHeaderBytes + cipherText.length + archiveTagBytes,
  )
    ..setRange(0, archiveEnvelopeHeaderBytes, header)
    ..setRange(
      archiveEnvelopeHeaderBytes,
      archiveEnvelopeHeaderBytes + cipherText.length,
      cipherText,
    )
    ..setRange(
      archiveEnvelopeHeaderBytes + cipherText.length,
      archiveEnvelopeHeaderBytes + cipherText.length + archiveTagBytes,
      macBytes,
    );
  return out;
}

/// Decrypts and authenticates a `SALU1` encrypted archive envelope.
Future<Uint8List> decryptArchive(Uint8List encrypted, String password) async {
  _validatePassword(password);
  if (encrypted.length < archiveEnvelopeOverheadBytes) {
    throw const FormatException(
      'Archive file is truncated or malformed.',
    );
  }
  if (encrypted.length > maxEncryptedEnvelopeBytes) {
    throw const FormatException(
      'Archive file exceeds the 64 MiB encrypted payload limit.',
    );
  }
  if (!_hasValidMagic(encrypted)) {
    throw const FormatException(
      'Unsupported archive format or invalid header.',
    );
  }

  final header =
      Uint8List.sublistView(encrypted, 0, archiveEnvelopeHeaderBytes);
  final salt = Uint8List.sublistView(encrypted, 5, 5 + archiveSaltBytes);
  final nonce = Uint8List.sublistView(
    encrypted,
    5 + archiveSaltBytes,
    archiveEnvelopeHeaderBytes,
  );
  final cipherEnd = encrypted.length - archiveTagBytes;
  final cipherText = Uint8List.sublistView(
    encrypted,
    archiveEnvelopeHeaderBytes,
    cipherEnd,
  );
  final mac = Mac(
    Uint8List.sublistView(encrypted, cipherEnd, encrypted.length),
  );

  final key = await _deriveKey(password, salt);
  try {
    final clearText = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
      aad: header,
    );
    return Uint8List.fromList(clearText);
  } on SecretBoxAuthenticationError {
    throw const FormatException(_safeDecryptFailureMessage);
  } catch (_) {
    throw const FormatException(_safeDecryptFailureMessage);
  }
}

/// File-backed encryption entry point for isolate-safe staging.
/// Validates size and password before reading the input file into memory.
Future<void> encryptFileToFile(
  File input,
  File output,
  String password,
) async {
  _validatePassword(password);
  final length = await input.length();
  if (length > maxEncryptedPayloadBytes) {
    throw const FormatException(
      'Archive exceeds the 64 MiB encrypted payload limit.',
    );
  }
  final plainBytes = await input.readAsBytes();
  final encrypted = await encryptArchive(plainBytes, password);
  await output.writeAsBytes(encrypted, flush: true);
}

/// File-backed decryption entry point for isolate-safe staging.
/// Validates envelope size and password before reading the input file into memory.
Future<void> decryptFileToFile(
  File input,
  File output,
  String password,
) async {
  _validatePassword(password);
  final length = await input.length();
  if (length < archiveEnvelopeOverheadBytes) {
    throw const FormatException(
      'Archive file is truncated or malformed.',
    );
  }
  if (length > maxEncryptedEnvelopeBytes) {
    throw const FormatException(
      'Archive file exceeds the 64 MiB encrypted payload limit.',
    );
  }
  final encryptedBytes = await input.readAsBytes();
  final plainBytes = await decryptArchive(encryptedBytes, password);
  await output.writeAsBytes(plainBytes, flush: true);
}
