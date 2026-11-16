/// Strict, bounded XML tokenizer for the SpreadsheetML parts of an XLSX file.
///
/// The INSA workbook is parsed without adding an XML dependency, so the
/// committed lockfiles stay unchanged. The reader accepts the simple element
/// and attribute grammar used by SpreadsheetML and deliberately rejects
/// anything that would need a general XML processor:
///
/// * DTD, entity and other `<!...>` declarations (no external entity access).
/// * CDATA sections.
/// * processing instructions other than the leading XML declaration.
/// * unknown or external entity references; only XML's five predefined
///   entities and numeric character references are decoded.
/// * excessive element nesting or document event counts.
///
/// It never reads from the filesystem or a network and never resolves a URI.
library;

/// One token emitted by [InsaXmlReader].
sealed class InsaXmlEvent {
  const InsaXmlEvent();
}

/// A start tag. Self-closing tags emit a matching [InsaXmlEnd] immediately.
final class InsaXmlStart extends InsaXmlEvent {
  const InsaXmlStart(this.name, this.attributes, this.depth);

  final String name;
  final Map<String, String> attributes;
  final int depth;
}

/// An end tag. [depth] is the depth of the element that ended.
final class InsaXmlEnd extends InsaXmlEvent {
  const InsaXmlEnd(this.name, this.depth);

  final String name;
  final int depth;
}

/// Character data between tags.
final class InsaXmlText extends InsaXmlEvent {
  const InsaXmlText(this.text, this.depth);

  final String text;
  final int depth;
}

/// Local part of a possibly namespace-qualified XML name.
String insaXmlLocalName(String name) {
  final colon = name.lastIndexOf(':');
  return colon < 0 ? name : name.substring(colon + 1);
}

final RegExp _hexDigits = RegExp(r'^[0-9A-Fa-f]+$');
final RegExp _decimalDigits = RegExp(r'^[0-9]+$');

/// Streaming, bounded XML reader.
///
/// The caller receives every start, end and text event in document order. The
/// input [entry] name is only used to build a precise error message.
final class InsaXmlReader {
  InsaXmlReader(
    this._xml, {
    required this.entry,
    this.maxDepth = 64,
    this.maxEvents = 5000000,
  });

  final String _xml;
  final String entry;
  final int maxDepth;
  final int maxEvents;

  Never _fail(String message) =>
      throw FormatException('INSA workbook XML entry "$entry" $message');

  /// Parses the document and invokes [onEvent] for each token.
  void read(void Function(InsaXmlEvent event) onEvent) {
    final xml = _xml;
    var index = 0;
    if (xml.isNotEmpty && xml.codeUnitAt(0) == 0xFEFF) index = 1;

    var eventCount = 0;
    void emit(InsaXmlEvent event) {
      eventCount++;
      if (eventCount > maxEvents) {
        _fail('exceeds the XML event limit of $maxEvents');
      }
      onEvent(event);
    }

    // An XML declaration is optional, but when present it must be first.
    if (xml.startsWith('<?xml', index) &&
        index + 5 < xml.length &&
        _isWhitespace(xml.codeUnitAt(index + 5))) {
      final end = xml.indexOf('?>', index + 5);
      if (end < 0) _fail('is malformed: unterminated XML declaration');
      _validateDeclaration(xml.substring(index + 5, end));
      index = end + 2;
    }

    final stack = <String>[];
    var rootSeen = false;

    while (index < xml.length) {
      if (xml.codeUnitAt(index) != 0x3C) {
        final next = xml.indexOf('<', index);
        final end = next < 0 ? xml.length : next;
        final raw = xml.substring(index, end);
        index = end;
        if (raw.isEmpty) continue;
        final text = _decodeEntities(raw);
        _validateTextChars(text);
        if (stack.isEmpty) {
          if (text.trim().isNotEmpty) {
            _fail('is malformed: text outside the root element');
          }
        } else {
          emit(InsaXmlText(text, stack.length));
        }
        continue;
      }

      if (xml.startsWith('<!--', index)) {
        final end = xml.indexOf('-->', index + 4);
        if (end < 0) _fail('is malformed: unterminated comment');
        final body = xml.substring(index + 4, end);
        if (body.contains('--') || body.endsWith('-')) {
          _fail('is malformed: invalid comment');
        }
        index = end + 3;
        continue;
      }

      if (xml.startsWith('<![CDATA[', index)) {
        _fail('is malformed: CDATA sections are not supported');
      }
      final declarationEnd =
          index + 10 > xml.length ? xml.length : index + 10;
      final declarationPrefix = xml.substring(index, declarationEnd).toUpperCase();
      if (declarationPrefix.startsWith('<!DOCTYPE') ||
          declarationPrefix.startsWith('<!ENTITY')) {
        _fail('contains a DTD or entity declaration');
      }
      if (xml.startsWith('<!', index)) {
        _fail('is malformed: unsupported markup declaration');
      }
      if (xml.startsWith('<?', index)) {
        _fail('is malformed: processing instructions are not supported');
      }

      if (xml.startsWith('</', index)) {
        index += 2;
        final parsed = _readName(xml, index, 'closing tag');
        final name = parsed.$1;
        index = parsed.$2;
        while (index < xml.length && _isWhitespace(xml.codeUnitAt(index))) {
          index++;
        }
        if (index >= xml.length || xml.codeUnitAt(index) != 0x3E) {
          _fail('is malformed: expected ">" in closing tag');
        }
        index++;
        if (stack.isEmpty) {
          _fail('is malformed: unexpected closing tag "$name"');
        }
        final open = stack.removeLast();
        if (open != name) {
          _fail('is malformed: closing tag "$name" does not match "$open"');
        }
        emit(InsaXmlEnd(name, stack.length + 1));
        continue;
      }

      index++;
      final parsed = _readName(xml, index, 'start tag');
      final name = parsed.$1;
      index = parsed.$2;
      final attributes = <String, String>{};
      var selfClosing = false;

      while (true) {
        while (index < xml.length && _isWhitespace(xml.codeUnitAt(index))) {
          index++;
        }
        if (index >= xml.length) {
          _fail('is malformed: unterminated start tag');
        }
        final code = xml.codeUnitAt(index);
        if (code == 0x3E) {
          index++;
          break;
        }
        if (code == 0x2F) {
          if (index + 1 >= xml.length ||
              xml.codeUnitAt(index + 1) != 0x3E) {
            _fail('is malformed: expected ">" after "/"');
          }
          index += 2;
          selfClosing = true;
          break;
        }

        final attribute = _readName(xml, index, 'attribute');
        final attributeName = attribute.$1;
        index = attribute.$2;
        while (index < xml.length && _isWhitespace(xml.codeUnitAt(index))) {
          index++;
        }
        if (index >= xml.length || xml.codeUnitAt(index) != 0x3D) {
          _fail('is malformed: expected "=" after "$attributeName"');
        }
        index++;
        while (index < xml.length && _isWhitespace(xml.codeUnitAt(index))) {
          index++;
        }
        if (index >= xml.length) {
          _fail('is malformed: missing value for "$attributeName"');
        }
        final quote = xml.codeUnitAt(index);
        if (quote != 0x22 && quote != 0x27) {
          _fail('is malformed: expected a quoted value for "$attributeName"');
        }
        index++;
        final valueStart = index;
        while (index < xml.length && xml.codeUnitAt(index) != quote) {
          if (xml.codeUnitAt(index) == 0x3C) {
            _fail('is malformed: "<" in attribute value');
          }
          index++;
        }
        if (index >= xml.length) {
          _fail('is malformed: unterminated value for "$attributeName"');
        }
        final rawValue = xml.substring(valueStart, index);
        index++;
        if (attributes.containsKey(attributeName)) {
          _fail('is malformed: duplicate attribute "$attributeName"');
        }
        final value = _decodeEntities(rawValue);
        _validateTextChars(value);
        attributes[attributeName] = value;
      }

      final depth = stack.length + 1;
      if (depth > maxDepth) {
        _fail('exceeds the maximum XML nesting depth of $maxDepth');
      }
      if (stack.isEmpty) {
        if (rootSeen) _fail('is malformed: multiple root elements');
        rootSeen = true;
      }
      emit(InsaXmlStart(name, Map<String, String>.unmodifiable(attributes), depth));
      if (selfClosing) {
        emit(InsaXmlEnd(name, depth));
      } else {
        stack.add(name);
      }
    }

    if (!rootSeen) _fail('is malformed: document has no root element');
    if (stack.isNotEmpty) {
      _fail('is malformed: unclosed element "${stack.last}"');
    }
  }

  void _validateDeclaration(String declaration) {
    final attributes =
        _parseDeclarationAttributes(declaration);
    for (final key in attributes.keys) {
      if (key != 'version' && key != 'encoding' && key != 'standalone') {
        _fail('is malformed: unexpected XML declaration attribute "$key"');
      }
    }
    if (attributes['version'] != '1.0') {
      _fail('is malformed: unsupported XML version');
    }
    final encoding = attributes['encoding'];
    if (encoding != null && encoding.toLowerCase() != 'utf-8') {
      _fail('is malformed: unsupported XML encoding "$encoding"');
    }
    final standalone = attributes['standalone'];
    if (standalone != null && standalone != 'yes' && standalone != 'no') {
      _fail('is malformed: invalid XML standalone value');
    }
  }

  Map<String, String> _parseDeclarationAttributes(String source) {
    final attributes = <String, String>{};
    var index = 0;
    while (true) {
      while (index < source.length && _isWhitespace(source.codeUnitAt(index))) {
        index++;
      }
      if (index >= source.length) return attributes;
      final parsed = _readName(source, index, 'XML declaration');
      final name = parsed.$1;
      index = parsed.$2;
      while (index < source.length && _isWhitespace(source.codeUnitAt(index))) {
        index++;
      }
      if (index >= source.length || source.codeUnitAt(index) != 0x3D) {
        _fail('is malformed: expected "=" in XML declaration');
      }
      index++;
      while (index < source.length && _isWhitespace(source.codeUnitAt(index))) {
        index++;
      }
      if (index >= source.length) {
        _fail('is malformed: missing XML declaration value');
      }
      final quote = source.codeUnitAt(index);
      if (quote != 0x22 && quote != 0x27) {
        _fail('is malformed: expected a quoted XML declaration value');
      }
      index++;
      final start = index;
      while (index < source.length && source.codeUnitAt(index) != quote) {
        if (source.codeUnitAt(index) == 0x26) {
          _fail('is malformed: entity references are not allowed in the '
              'XML declaration');
        }
        index++;
      }
      if (index >= source.length) {
        _fail('is malformed: unterminated XML declaration value');
      }
      final value = source.substring(start, index);
      index++;
      if (attributes.containsKey(name)) {
        _fail('is malformed: duplicate XML declaration attribute "$name"');
      }
      attributes[name] = value;
    }
  }

  (String, int) _readName(String source, int index, String context) {
    final start = index;
    if (index >= source.length || !_isNameStart(source.codeUnitAt(index))) {
      _fail('is malformed: expected a name in $context');
    }
    index++;
    while (index < source.length && _isNamePart(source.codeUnitAt(index))) {
      index++;
    }
    return (source.substring(start, index), index);
  }

  String _decodeEntities(String raw) {
    if (!raw.contains('&')) return raw;
    final out = StringBuffer();
    var index = 0;
    while (index < raw.length) {
      final code = raw.codeUnitAt(index);
      if (code != 0x26) {
        out.writeCharCode(code);
        index++;
        continue;
      }
      final end = raw.indexOf(';', index + 1);
      if (end < 0) {
        _fail('is malformed: unterminated entity reference');
      }
      final name = raw.substring(index + 1, end);
      switch (name) {
        case 'amp':
          out.write('&');
          break;
        case 'lt':
          out.write('<');
          break;
        case 'gt':
          out.write('>');
          break;
        case 'quot':
          out.write('"');
          break;
        case 'apos':
          out.write("'");
          break;
        default:
          if (name.startsWith('#x') || name.startsWith('#X')) {
            final digits = name.substring(2);
            if (digits.isEmpty ||
                digits.length > 8 ||
                !_hexDigits.hasMatch(digits)) {
              _fail('is malformed: invalid hexadecimal character reference');
            }
            final value = int.tryParse(digits, radix: 16);
            if (value == null) {
              _fail('is malformed: invalid hexadecimal character reference');
            }
            _writeCodePoint(out, value);
          } else if (name.startsWith('#')) {
            final digits = name.substring(1);
            if (digits.isEmpty ||
                digits.length > 8 ||
                !_decimalDigits.hasMatch(digits)) {
              _fail('is malformed: invalid decimal character reference');
            }
            final value = int.tryParse(digits);
            if (value == null) {
              _fail('is malformed: invalid decimal character reference');
            }
            _writeCodePoint(out, value);
          } else {
            _fail('is malformed: unknown entity "&$name;"');
          }
      }
      index = end + 1;
    }
    return out.toString();
  }

  void _writeCodePoint(StringBuffer out, int value) {
    if (!_isValidXmlCodePoint(value)) {
      _fail('is malformed: invalid XML character reference');
    }
    out.write(String.fromCharCode(value));
  }

  void _validateTextChars(String text) {
    for (var index = 0; index < text.length; index++) {
      final code = text.codeUnitAt(index);
      if (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D) {
        _fail('is malformed: invalid control character');
      }
      if (code == 0xFFFE || code == 0xFFFF) {
        _fail('is malformed: invalid XML character');
      }
    }
  }
}

bool _isWhitespace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

bool _isNameStart(int code) =>
    (code >= 0x41 && code <= 0x5A) ||
    (code >= 0x61 && code <= 0x7A) ||
    code == 0x5F ||
    code == 0x3A;

bool _isNamePart(int code) =>
    _isNameStart(code) ||
    (code >= 0x30 && code <= 0x39) ||
    code == 0x2D ||
    code == 0x2E;

bool _isValidXmlCodePoint(int value) =>
    value == 0x09 ||
    value == 0x0A ||
    value == 0x0D ||
    (value >= 0x20 && value <= 0xD7FF) ||
    (value >= 0xE000 && value <= 0xFFFD) ||
    (value >= 0x10000 && value <= 0x10FFFF);
