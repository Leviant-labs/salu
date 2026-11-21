import 'dart:convert';

import 'assistant.dart';

/// Incremental Server-Sent Events decoder for OpenAI Responses streams.
///
/// Bounds total decoded UTF-8 bytes and completes immediately on a terminal
/// `response.completed` event without waiting for EOF.
final class SseDecoder {
  SseDecoder({this.maxBytes = defaultMaxBytes}) {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
    }
  }

  static const int defaultMaxBytes = 512 * 1024;

  final int maxBytes;
  final StringBuffer _lineBuffer = StringBuffer();
  final List<String> _dataLines = <String>[];
  int _totalBytes = 0;
  bool _pendingCr = false;
  bool _completed = false;

  /// Feeds a UTF-8 decoded [chunk], returning the `response` envelope if a
  /// terminal `response.completed` event completed in this chunk.
  Map<String, dynamic>? add(String chunk) {
    final chunkBytes = utf8.encode(chunk).length;
    if (chunkBytes > maxBytes - _totalBytes) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.invalidResponse,
      );
    }
    _totalBytes += chunkBytes;

    if (_completed) return null;

    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      final code = chunk.codeUnitAt(i);
      if (_pendingCr) {
        _pendingCr = false;
        if (code == 0x0A) {
          start = i + 1;
          continue;
        }
      }
      if (code == 0x0D || code == 0x0A) {
        if (i > start) {
          _lineBuffer.write(chunk.substring(start, i));
        }
        final line = _lineBuffer.toString();
        _lineBuffer.clear();
        start = i + 1;
        if (code == 0x0D) {
          _pendingCr = true;
        }
        final terminal = _handleLine(line);
        if (terminal != null) {
          return terminal;
        }
      }
    }
    if (start < chunk.length) {
      _lineBuffer.write(chunk.substring(start));
    }
    return null;
  }

  /// Verifies that a terminal `response.completed` event was observed before EOF.
  void finish() {
    if (!_completed) {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.incompleteResponse,
      );
    }
  }

  Map<String, dynamic>? _handleLine(String line) {
    if (line.isEmpty) {
      return _dispatchEvent();
    }
    if (line.startsWith(':')) {
      return null;
    }
    if (line.startsWith('data:')) {
      var value = line.substring(5);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
      _dataLines.add(value);
    }
    return null;
  }

  Map<String, dynamic>? _dispatchEvent() {
    if (_dataLines.isEmpty) return null;
    final data = _dataLines.join('\n');
    _dataLines.clear();
    if (data.isEmpty || data == '[DONE]') {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(data);
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

    final type = decoded['type'];
    if (type == 'response.completed') {
      final response = decoded['response'];
      if (response is! Map<String, dynamic>) {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.invalidResponse,
        );
      }
      _completed = true;
      return response;
    }
    if (type == 'response.failed' || type == 'error') {
      final response = decoded['response'];
      final error = response is Map ? response['error'] : decoded['error'];
      final code = error is Map ? error['code'] : null;
      if (code == 'subscription_sharing_usage_limit_exceeded' ||
          code == 'subscription_sharing_usage_unavailable') {
        throw const SaluAssistantException(
          SaluAssistantErrorCode.quotaExceeded,
        );
      }
      throw const SaluAssistantException(
        SaluAssistantErrorCode.requestRejected,
      );
    }
    if (type == 'response.incomplete') {
      throw const SaluAssistantException(
        SaluAssistantErrorCode.incompleteResponse,
      );
    }
    return null;
  }
}
