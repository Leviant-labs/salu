import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/chatgpt_session.dart';

void main() {
  test('verified identity must match the pending transaction and registration',
      () {
    final claims = <String, dynamic>{
      'iss': 'https://auth.openai.com',
      'aud': ['client'],
      'nonce': 'nonce',
      'sub': 'subject',
      'iat': 900,
      'exp': 1100,
    };
    void validate(Map<String, dynamic> value, {String? previous = 'subject'}) =>
        ChatGptSession.validateClaims(value, 'client', 'nonce', 1000, previous);
    validate(claims);
    for (final invalid in [
      {...claims, 'iss': 'https://other.example'},
      {...claims, 'aud': 'other-client'},
      {...claims, 'nonce': 'other-nonce'},
      {...claims, 'sub': ''},
      {...claims, 'exp': 1000},
      {...claims, 'iat': 1061},
    ]) {
      expect(() => validate(invalid), throwsStateError);
    }
    expect(
        () => validate(claims, previous: 'another-subject'), throwsStateError);
  });
}
