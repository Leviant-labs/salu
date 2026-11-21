import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'assistant.dart';
import 'operation_fence.dart';
import 'sse_decoder.dart';

/// Bounded, fence-aware HTTP transport for inference and auth endpoints.
final class EndpointTransport {
  EndpointTransport({
    HttpClient Function()? clientFactory,
    Duration timeout = const Duration(seconds: 45),
    Future<List<InternetAddress>> Function(String host)? dnsLookup,
  })  : _clientFactory = clientFactory ?? HttpClient.new,
        _timeout = timeout,
        _dnsLookup = dnsLookup ?? InternetAddress.lookup;

  static const int defaultMaxBytes = 512 * 1024;
  static const Duration _maxConnectTimeout = Duration(seconds: 10);
  static final RegExp _headerNameControl = RegExp(r'[\x00-\x20\x7F:]');
  static final RegExp _headerValueControl = RegExp(r'[\x00-\x08\x0A-\x1F\x7F]');

  final HttpClient Function() _clientFactory;
  final Duration _timeout;
  final Future<List<InternetAddress>> Function(String host) _dnsLookup;

  /// Sends a JSON HTTP request and parses a JSON object response.
  Future<Map<String, dynamic>> send({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    Map<String, Object?>? body,
    required bool allowInsecureLocal,
    required OperationFence fence,
    int maxBytes = defaultMaxBytes,
    Duration? deadline,
    int? epoch,
  }) {
    final encodedBody = body == null ? null : utf8.encode(jsonEncode(body));
    return _execute(
      uri: uri,
      method: method,
      headers: headers,
      bodyBytes: encodedBody,
      contentType: body == null ? null : ContentType.json,
      defaultAccept: 'application/json',
      allowInsecureLocal: allowInsecureLocal,
      fence: fence,
      maxBytes: maxBytes,
      deadline: deadline,
      epoch: epoch,
      streamSse: false,
      allowEmptyResponse: false,
    );
  }

  /// Sends a JSON HTTP request and streams an SSE `response.completed` envelope.
  Future<Map<String, dynamic>> sendSse({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    Map<String, Object?>? body,
    required bool allowInsecureLocal,
    required OperationFence fence,
    int maxBytes = defaultMaxBytes,
    Duration? deadline,
    int? epoch,
  }) {
    final encodedBody = body == null ? null : utf8.encode(jsonEncode(body));
    return _execute(
      uri: uri,
      method: method,
      headers: headers,
      bodyBytes: encodedBody,
      contentType: body == null ? null : ContentType.json,
      defaultAccept: 'text/event-stream',
      allowInsecureLocal: allowInsecureLocal,
      fence: fence,
      maxBytes: maxBytes,
      deadline: deadline,
      epoch: epoch,
      streamSse: true,
      allowEmptyResponse: false,
    );
  }

  /// Sends an `application/x-www-form-urlencoded` POST and parses JSON.
  Future<Map<String, dynamic>> postForm({
    required Uri uri,
    required Map<String, String> form,
    required OperationFence fence,
    Map<String, String> headers = const <String, String>{},
    bool allowEmptyResponse = false,
    bool allowInsecureLocal = false,
    int maxBytes = defaultMaxBytes,
    Duration? deadline,
    int? epoch,
  }) {
    final encodedForm = utf8.encode(
      form.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&'),
    );
    return _execute(
      uri: uri,
      method: 'POST',
      headers: headers,
      bodyBytes: encodedForm,
      contentType:
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8'),
      defaultAccept: 'application/json',
      allowInsecureLocal: allowInsecureLocal,
      fence: fence,
      maxBytes: maxBytes,
      deadline: deadline,
      epoch: epoch,
      streamSse: false,
      allowEmptyResponse: allowEmptyResponse,
    );
  }

  @visibleForTesting
  static bool isAllowedLocalUriForTesting(
    Uri uri,
    List<InternetAddress> resolvedAddresses,
  ) {
    if (uri.scheme.toLowerCase() != 'http' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@')) {
      return false;
    }
    if (resolvedAddresses.isEmpty) return false;
    return resolvedAddresses.every(isAllowedLocalAddress);
  }

  @visibleForTesting
  static bool isAllowedLocalAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return _isAllowedLocalIpv4(bytes[0], bytes[1]);
    }
    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      // Check IPv4-mapped IPv6 ::ffff:a.b.c.d
      var isMappedIpv4 = bytes[10] == 0xff && bytes[11] == 0xff;
      if (isMappedIpv4) {
        for (var i = 0; i < 10; i++) {
          if (bytes[i] != 0) {
            isMappedIpv4 = false;
            break;
          }
        }
      }
      if (isMappedIpv4) {
        return _isAllowedLocalIpv4(bytes[12], bytes[13]);
      }

      // Loopback ::1
      var isLoopback = bytes[15] == 1;
      if (isLoopback) {
        for (var i = 0; i < 15; i++) {
          if (bytes[i] != 0) {
            isLoopback = false;
            break;
          }
        }
      }
      if (isLoopback) return true;

      // Unique Local Address fc00::/7
      if ((bytes[0] & 0xfe) == 0xfc) return true;

      // Link-local fe80::/10
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true;

      return false;
    }
    return false;
  }

  static bool _isAllowedLocalIpv4(int b0, int b1) {
    if (b0 == 127) return true; // 127.0.0.0/8 loopback
    if (b0 == 10) return true; // 10.0.0.0/8 private
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return true; // 172.16.0.0/12 private
    if (b0 == 192 && b1 == 168) return true; // 192.168.0.0/16 private
    return false;
  }

  Future<Map<String, dynamic>> _execute({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int>? bodyBytes,
    required ContentType? contentType,
    required String defaultAccept,
    required bool allowInsecureLocal,
    required OperationFence fence,
    required int maxBytes,
    required Duration? deadline,
    required int? epoch,
    required bool streamSse,
    required bool allowEmptyResponse,
  }) async {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
    }
    final activeEpoch = epoch ?? fence.capture();
    if (!fence.isCurrent(activeEpoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    final totalDeadline = deadline ?? _timeout;
    if (totalDeadline <= Duration.zero) {
      throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
    }
    final stopwatch = Stopwatch()..start();
    Duration remaining() {
      final left = totalDeadline - stopwatch.elapsed;
      return left.isNegative ? Duration.zero : left;
    }

    _validateHeadersLocally(headers);
    final isLocalHttp = await _validateDestination(
      uri: uri,
      allowInsecureLocal: allowInsecureLocal,
      remaining: remaining,
    );

    if (!fence.isCurrent(activeEpoch)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.connectionChanged,
      );
    }

    final client = _clientFactory();
    var closed = false;
    void Function()? abortActiveRead;

    void closeClient() {
      if (closed) return;
      closed = true;
      abortActiveRead?.call();
      client.close(force: true);
    }

    final unregister = fence.onInvalidate(closeClient);

    try {
      final remBeforeConnect = remaining();
      if (remBeforeConnect <= Duration.zero) {
        throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
      }
      final connectTimeout = remBeforeConnect < _maxConnectTimeout
          ? remBeforeConnect
          : _maxConnectTimeout;
      try {
        client.connectionTimeout = connectTimeout;
      } on NoSuchMethodError {
        // Test fakes may not implement connectionTimeout.
      }
      if (isLocalHttp) {
        try {
          client.findProxy = (_) => 'DIRECT';
        } on NoSuchMethodError {
          // Test fakes may not implement findProxy.
        }
      }

      final request =
          await _openRequest(client, method, uri).timeout(remaining());
      if (!fence.isCurrent(activeEpoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }

      request.followRedirects = false;
      if (contentType != null) {
        request.headers.contentType = contentType;
      }
      var hasAcceptHeader = false;
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == HttpHeaders.acceptHeader) {
          hasAcceptHeader = true;
        }
        request.headers.set(entry.key, entry.value);
      }
      if (!hasAcceptHeader) {
        request.headers.set(HttpHeaders.acceptHeader, defaultAccept);
      }
      if (bodyBytes != null) {
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
      }

      final remBeforeClose = remaining();
      if (remBeforeClose <= Duration.zero) {
        throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
      }
      final response = await request.close().timeout(remBeforeClose);
      if (!fence.isCurrent(activeEpoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }

      final status = response.statusCode;
      if (status == HttpStatus.tooManyRequests) {
        final code = await _readQuotaError(
          response,
          maxBytes: maxBytes,
          remaining: remaining,
          setAbort: (cb) => abortActiveRead = cb,
          closeClient: closeClient,
        );
        throw SaluAssistantException(code);
      }
      if (status != HttpStatus.ok) {
        throw SaluAssistantException(_mapErrorStatus(status));
      }

      if (streamSse) {
        final result = await _readSseBody(
          response,
          maxBytes: maxBytes,
          remaining: remaining,
          setAbort: (cb) => abortActiveRead = cb,
          closeClient: closeClient,
        );
        if (!fence.isCurrent(activeEpoch)) {
          throw const SaluAssistantException(
            SaluAssistantErrorCode.connectionChanged,
          );
        }
        return result;
      }

      final responseBody = await _readTextBody(
        response,
        maxBytes: maxBytes,
        remaining: remaining,
        setAbort: (cb) => abortActiveRead = cb,
        closeClient: closeClient,
      );
      if (!fence.isCurrent(activeEpoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      if (allowEmptyResponse && responseBody.isEmpty) {
        return <String, dynamic>{};
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(responseBody);
      } on FormatException {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.invalidResponse,
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.invalidResponse,
        );
      }
      return decoded;
    } on SaluAssistantException {
      if (!fence.isCurrent(activeEpoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      rethrow;
    } on TimeoutException {
      if (!fence.isCurrent(activeEpoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
    } on Object {
      if (!fence.isCurrent(activeEpoch)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        );
      }
      throw const SaluAssistantException(SaluAssistantErrorCode.networkError);
    } finally {
      unregister();
      closeClient();
    }
  }

  static void _validateHeadersLocally(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.isEmpty ||
          _headerNameControl.hasMatch(entry.key) ||
          _headerValueControl.hasMatch(entry.value)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.requestRejected,
        );
      }
    }
  }

  Future<bool> _validateDestination({
    required Uri uri,
    required bool allowInsecureLocal,
    required Duration Function() remaining,
  }) async {
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@')) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.requestRejected,
      );
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'https') return false;
    if (scheme != 'http' || !allowInsecureLocal) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.requestRejected,
      );
    }

    final host = uri.host;
    final literal = _tryParseHostLiteral(host);
    if (literal != null) {
      if (!isAllowedLocalAddress(literal)) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.requestRejected,
        );
      }
      return true;
    }

    final rem = remaining();
    if (rem <= Duration.zero) {
      throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
    }
    final List<InternetAddress> addresses;
    try {
      addresses = await _dnsLookup(host).timeout(rem);
    } on TimeoutException {
      throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
    } on Object {
      throw const SaluAssistantException(SaluAssistantErrorCode.networkError);
    }

    if (addresses.isEmpty) {
      throw const SaluAssistantException(SaluAssistantErrorCode.networkError);
    }
    if (!addresses.every(isAllowedLocalAddress)) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.requestRejected,
      );
    }
    return true;
  }

  static InternetAddress? _tryParseHostLiteral(String host) {
    final zoneIndex = host.indexOf('%');
    final stripped = zoneIndex == -1 ? host : host.substring(0, zoneIndex);
    return InternetAddress.tryParse(stripped);
  }

  static Future<HttpClientRequest> _openRequest(
    HttpClient client,
    String method,
    Uri uri,
  ) {
    final upper = method.toUpperCase();
    return switch (upper) {
      'POST' => client.postUrl(uri),
      'GET' => client.getUrl(uri),
      _ => client.openUrl(upper, uri),
    };
  }

  static SaluAssistantErrorCode _mapErrorStatus(int status) => switch (status) {
        HttpStatus.unauthorized => SaluAssistantErrorCode.authenticationFailed,
        HttpStatus.forbidden => SaluAssistantErrorCode.accessDenied,
        HttpStatus.requestTimeout ||
        HttpStatus.gatewayTimeout =>
          SaluAssistantErrorCode.timeout,
        >= 500 && < 600 => SaluAssistantErrorCode.serviceUnavailable,
        _ => SaluAssistantErrorCode.requestRejected,
      };

  static Future<SaluAssistantErrorCode> _readQuotaError(
    HttpClientResponse response, {
    required int maxBytes,
    required Duration Function() remaining,
    required void Function(void Function()? cb) setAbort,
    required void Function() closeClient,
  }) async {
    try {
      final text = await _readTextBody(
        response,
        maxBytes: maxBytes,
        remaining: remaining,
        setAbort: setAbort,
        closeClient: closeClient,
      );
      final Object? body = jsonDecode(text);
      if (body
          case {
            'error': {
              'code': 'insufficient_quota' ||
                  'subscription_sharing_usage_limit_exceeded' ||
                  'subscription_sharing_usage_unavailable'
            }
          }) {
        return SaluAssistantErrorCode.quotaExceeded;
      }
    } on FormatException {
      // An unreadable body does not change the meaning of HTTP 429.
    } on SaluAssistantException catch (e) {
      if (e.code == SaluAssistantErrorCode.connectionChanged ||
          e.code == SaluAssistantErrorCode.timeout) {
        return e.code;
      }
      // An oversized body does not change the meaning of HTTP 429 either.
    }
    return SaluAssistantErrorCode.rateLimited;
  }

  static Future<String> _readTextBody(
    HttpClientResponse response, {
    required int maxBytes,
    required Duration Function() remaining,
    required void Function(void Function()? cb) setAbort,
    required void Function() closeClient,
  }) async {
    if (response.contentLength > maxBytes) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.invalidResponse,
      );
    }
    final rem = remaining();
    if (rem <= Duration.zero) {
      throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
    }

    final completer = Completer<String>();
    final buffer = StringBuffer();
    final utf8Sink = utf8.decoder.startChunkedConversion(
      _StringChunkSink(buffer.write),
    );
    var totalBytes = 0;

    void fail(Object error, [StackTrace? stackTrace]) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }

    setAbort(() => fail(const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        )));

    final timer = Timer(rem, () {
      fail(const SaluAssistantException(SaluAssistantErrorCode.timeout));
      closeClient();
    });

    late final StreamSubscription<List<int>> sub;
    sub = response.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (chunk.length > maxBytes - totalBytes) {
          fail(const SaluAssistantException(
            SaluAssistantErrorCode.invalidResponse,
          ));
          unawaited(sub.cancel());
          return;
        }
        totalBytes += chunk.length;
        try {
          utf8Sink.add(chunk);
        } on FormatException {
          fail(const SaluAssistantException(
            SaluAssistantErrorCode.invalidResponse,
          ));
          unawaited(sub.cancel());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        fail(error, stackTrace);
      },
      onDone: () {
        if (completer.isCompleted) return;
        try {
          utf8Sink.close();
        } on FormatException {
          fail(const SaluAssistantException(
            SaluAssistantErrorCode.invalidResponse,
          ));
          return;
        }
        completer.complete(buffer.toString());
      },
      cancelOnError: true,
    );

    try {
      return await completer.future;
    } finally {
      timer.cancel();
      setAbort(null);
      closeClient();
      unawaited(sub.cancel());
    }
  }

  static Future<Map<String, dynamic>> _readSseBody(
    HttpClientResponse response, {
    required int maxBytes,
    required Duration Function() remaining,
    required void Function(void Function()? cb) setAbort,
    required void Function() closeClient,
  }) async {
    if (response.contentLength > maxBytes) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.invalidResponse,
      );
    }
    final rem = remaining();
    if (rem <= Duration.zero) {
      throw const SaluAssistantException(SaluAssistantErrorCode.timeout);
    }

    final completer = Completer<Map<String, dynamic>>();
    final decoder = SseDecoder(maxBytes: maxBytes);
    var totalBytes = 0;

    void fail(Object error, [StackTrace? stackTrace]) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }

    setAbort(() => fail(const SaluAssistantException(
          SaluAssistantErrorCode.connectionChanged,
        )));

    final timer = Timer(rem, () {
      fail(const SaluAssistantException(SaluAssistantErrorCode.timeout));
      closeClient();
    });

    late final StreamSubscription<List<int>> sub;
    final utf8Sink = utf8.decoder.startChunkedConversion(
      _StringChunkSink((text) {
        if (completer.isCompleted) return;
        final result = decoder.add(text);
        if (result != null && !completer.isCompleted) {
          completer.complete(result);
          unawaited(sub.cancel());
        }
      }),
    );

    sub = response.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (chunk.length > maxBytes - totalBytes) {
          fail(const SaluAssistantException(
            SaluAssistantErrorCode.invalidResponse,
          ));
          unawaited(sub.cancel());
          return;
        }
        totalBytes += chunk.length;
        try {
          utf8Sink.add(chunk);
        } on SaluAssistantException catch (e, st) {
          fail(e, st);
          unawaited(sub.cancel());
        } on FormatException {
          fail(const SaluAssistantException(
            SaluAssistantErrorCode.invalidResponse,
          ));
          unawaited(sub.cancel());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        fail(error, stackTrace);
      },
      onDone: () {
        if (completer.isCompleted) return;
        try {
          utf8Sink.close();
          if (completer.isCompleted) return;
          decoder.finish();
        } on SaluAssistantException catch (e, st) {
          fail(e, st);
        } on FormatException {
          fail(const SaluAssistantException(
            SaluAssistantErrorCode.invalidResponse,
          ));
        }
      },
      cancelOnError: true,
    );

    try {
      return await completer.future;
    } finally {
      timer.cancel();
      setAbort(null);
      closeClient();
      unawaited(sub.cancel());
    }
  }
}

final class _StringChunkSink implements Sink<String> {
  _StringChunkSink(this._onData);

  final void Function(String data) _onData;

  @override
  void add(String data) {
    if (data.isNotEmpty) {
      _onData(data);
    }
  }

  @override
  void close() {}
}
