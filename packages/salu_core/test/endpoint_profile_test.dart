import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('serialized connection contains a slot reference, never a key', () {
    final profile = EndpointProfile(
      id: 'home',
      name: 'Home server',
      protocol: EndpointProtocol.openaiChat,
      apiRoot: Uri.parse('https://inference.example/v1'),
      credentialRef: 'salu.endpoint.home.1',
      modelId: 'vision-test',
    );
    final json = jsonEncode(profile.toJson());
    expect(json, contains('salu.endpoint.home.1'));
    expect(jsonDecode(json), isNot(contains('apiKey')));
    expect(
      EndpointProfile.fromJson(jsonDecode(json) as Map<String, dynamic>)
          .apiRoot,
      profile.apiRoot,
    );
  });

  test('round-trips all fields and defaults safely', () {
    final profile = EndpointProfile(
      id: 'anthropic_main-1',
      name: '  Anthropic Proxy  ',
      protocol: EndpointProtocol.anthropicMessages,
      apiRoot: Uri.parse('http://localhost:8080/proxy/v1'),
      credentialRef: 'salu.endpoint.anthropic_main-1.2',
      modelId: 'claude-sonnet',
      discovery: ModelDiscoveryMode.catalogue,
      allowInsecureLocal: true,
      imageInput: true,
    );
    expect(profile.name, 'Anthropic Proxy');
    expect(profile.toString(), isNot(contains('salu.endpoint')));
    expect(profile.toString(), isNot(contains('sk-')));

    final decoded = EndpointProfile.fromJson(
      jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
    );
    expect(decoded, profile);
    expect(decoded.protocol, EndpointProtocol.anthropicMessages);
    expect(decoded.discovery, ModelDiscoveryMode.catalogue);
    expect(decoded.allowInsecureLocal, isTrue);
    expect(decoded.imageInput, isTrue);
    expect(decoded.modelId, 'claude-sonnet');
  });

  test('rejects invalid profile IDs', () {
    for (final badId in [
      '',
      ' ',
      'chatgpt-plan',
      'bad id',
      'bad/id',
      'bad.id',
      'bad\nid',
      'a' * 65,
    ]) {
      expect(
        () => EndpointProfile(
          id: badId,
          name: 'Valid',
          protocol: EndpointProtocol.openaiResponses,
          apiRoot: Uri.parse('https://inference.example/v1'),
          credentialRef: 'salu.endpoint.valid.1',
        ),
        throwsArgumentError,
        reason: 'expected rejection for id "$badId"',
      );
    }
  });

  test('rejects invalid names and model IDs', () {
    for (final badName in [
      '',
      '   ',
      'bad\nname',
      'bad\rname',
      'bad\x00name',
      'n' * 81,
    ]) {
      expect(
        () => EndpointProfile(
          id: 'p1',
          name: badName,
          protocol: EndpointProtocol.openaiChat,
          apiRoot: Uri.parse('https://inference.example/v1'),
          credentialRef: 'salu.endpoint.p1.1',
        ),
        throwsArgumentError,
        reason: 'expected rejection for name "$badName"',
      );
    }

    for (final badModel in [
      '',
      '   ',
      'bad\nmodel',
      'bad\rmodel',
      'bad\x7fmodel',
      'm' * 257,
    ]) {
      expect(
        () => EndpointProfile(
          id: 'p1',
          name: 'Server',
          protocol: EndpointProtocol.openaiChat,
          apiRoot: Uri.parse('https://inference.example/v1'),
          credentialRef: 'salu.endpoint.p1.1',
          modelId: badModel,
        ),
        throwsArgumentError,
        reason: 'expected rejection for modelId "$badModel"',
      );
    }
  });

  test('rejects malformed, non-HTTPS without opt-in, or oversized URLs', () {
    final longPath = '/${'a' * 2040}';
    final badUris = <Uri>[
      Uri.parse('http://localhost:11434/v1'),
      Uri.parse('ftp://inference.example/v1'),
      Uri.parse('file:///etc/passwd'),
      Uri.parse('https:///v1'),
      Uri.parse('https://user:pass@inference.example/v1'),
      Uri.parse('https://user@inference.example/v1'),
      Uri.parse('https://inference.example/v1?key=1'),
      Uri.parse('https://inference.example/v1?'),
      Uri.parse('https://inference.example/v1#frag'),
      Uri.parse('https://inference.example/v1#'),
      Uri.parse('https://inference.example$longPath'),
    ];
    for (final uri in badUris) {
      expect(
        () => EndpointProfile(
          id: 'p1',
          name: 'Server',
          protocol: EndpointProtocol.openaiChat,
          apiRoot: uri,
          credentialRef: 'salu.endpoint.p1.1',
        ),
        throwsArgumentError,
        reason: 'expected rejection for uri "$uri"',
      );
    }

    // Opt-in allows http://
    final local = EndpointProfile(
      id: 'local',
      name: 'Local',
      protocol: EndpointProtocol.openaiChat,
      apiRoot: Uri.parse('http://127.0.0.1:11434/v1'),
      credentialRef: 'salu.endpoint.local.1',
      allowInsecureLocal: true,
    );
    expect(local.allowInsecureLocal, isTrue);
  });

  test('rejects invalid credential references', () {
    for (final badRef in [
      '',
      'salu.',
      'openai.endpoint.1',
      'salu.endpoint.1\n',
      'salu.endpoint.1\r',
      'salu.endpoint.1\x00',
      'salu.endpoint. 1',
    ]) {
      expect(
        () => EndpointProfile(
          id: 'p1',
          name: 'Server',
          protocol: EndpointProtocol.openaiChat,
          apiRoot: Uri.parse('https://inference.example/v1'),
          credentialRef: badRef,
        ),
        throwsArgumentError,
        reason: 'expected rejection for credentialRef "$badRef"',
      );
    }
  });

  test('fromJson rejects malformed payloads', () {
    expect(
      () => EndpointProfile.fromJson({
        'id': 'p1',
        'name': 'Server',
        'protocol': 'unknownProtocol',
        'apiRoot': 'https://inference.example/v1',
        'credentialRef': 'salu.endpoint.p1.1',
      }),
      throwsFormatException,
    );
    expect(
      () => EndpointProfile.fromJson({
        'id': 'p1',
        'name': 'Server',
        'protocol': 'openaiChat',
        'apiRoot': 'http://[::1',
        'credentialRef': 'salu.endpoint.p1.1',
      }),
      throwsFormatException,
    );
    expect(
      () => EndpointProfile.fromJson({
        'id': 123,
        'name': 'Server',
        'protocol': 'openaiChat',
        'apiRoot': 'https://inference.example/v1',
        'credentialRef': 'salu.endpoint.p1.1',
      }),
      throwsFormatException,
    );
    expect(
      () => EndpointProfile.fromJson({
        'id': 'p1',
        'name': 'Server',
        'protocol': 'openaiChat',
        'apiRoot': 'https://inference.example/v1\r\n',
        'credentialRef': 'salu.endpoint.p1.1',
      }),
      throwsFormatException,
    );
  });

  test('hasSameDestination compares scheme, host, port, and protocol', () {
    final base = EndpointProfile(
      id: 'p1',
      name: 'One',
      protocol: EndpointProtocol.openaiChat,
      apiRoot: Uri.parse('https://api.example.com/v1'),
      credentialRef: 'salu.endpoint.p1.1',
    );

    expect(
      base.hasSameDestination(
        base.copyWith(
          name: 'Renamed',
          modelId: 'gpt-4o',
          apiRoot: Uri.parse('https://api.example.com:443/v2'),
        ),
      ),
      isTrue,
    );
    expect(
      base.hasSameDestination(
        base.copyWith(protocol: EndpointProtocol.openaiResponses),
      ),
      isFalse,
    );
    expect(
      base.hasSameDestination(
        base.copyWith(apiRoot: Uri.parse('https://other.example.com/v1')),
      ),
      isFalse,
    );
    expect(
      base.hasSameDestination(
        base.copyWith(apiRoot: Uri.parse('https://api.example.com:8443/v1')),
      ),
      isFalse,
    );
    expect(
      base.hasSameDestination(
        base.copyWith(
          apiRoot: Uri.parse('http://api.example.com/v1'),
          allowInsecureLocal: true,
        ),
      ),
      isFalse,
    );
  });
}
