/// Nonsecret metadata for user-configured inference endpoints.
///
/// Credentials never live in [EndpointProfile]; only an opaque secure-storage
/// slot reference ([credentialRef]) is persisted alongside the profile.
library;

/// Wire protocol spoken by an endpoint profile.
enum EndpointProtocol {
  openaiChat,
  openaiResponses,
  anthropicMessages,
}

/// How available models are obtained for a profile.
enum ModelDiscoveryMode {
  models,
  catalogue,
  manual,
}

/// Validated nonsecret metadata for a single configured AI endpoint.
final class EndpointProfile {
  /// Creates and validates an endpoint profile.
  EndpointProfile({
    required this.id,
    required String name,
    required this.protocol,
    required this.apiRoot,
    required this.credentialRef,
    String? modelId,
    this.discovery = ModelDiscoveryMode.models,
    this.allowInsecureLocal = false,
    this.imageInput,
  })  : name = _validateName(name),
        modelId = _validateModelId(modelId) {
    _validateId(id);
    _validateApiRoot(apiRoot, allowInsecureLocal: allowInsecureLocal);
    _validateCredentialRef(credentialRef);
  }

  /// Parses an [EndpointProfile] from JSON.
  factory EndpointProfile.fromJson(Map<String, dynamic> json) {
    final id = _requireString(json, 'id');
    final name = _requireString(json, 'name');
    final protocol = _parseEnum(
      EndpointProtocol.values,
      _requireString(json, 'protocol'),
      'protocol',
    );
    final rawApiRoot = _requireString(json, 'apiRoot');
    if (_controlChars.hasMatch(rawApiRoot)) {
      throw FormatException(
        'apiRoot cannot contain control characters',
        rawApiRoot,
      );
    }
    final Uri apiRoot;
    try {
      apiRoot = Uri.parse(rawApiRoot);
    } on FormatException catch (error) {
      throw FormatException(
          'Invalid apiRoot URI: ${error.message}', rawApiRoot);
    }
    final credentialRef = _requireString(json, 'credentialRef');
    final rawModelId = json['modelId'];
    if (rawModelId != null && rawModelId is! String) {
      throw FormatException('Expected string for modelId', rawModelId);
    }
    final rawDiscovery = json['discovery'];
    final discovery = switch (rawDiscovery) {
      null => ModelDiscoveryMode.models,
      final String value =>
        _parseEnum(ModelDiscoveryMode.values, value, 'discovery'),
      _ => throw FormatException('Expected string for discovery', rawDiscovery),
    };
    final rawAllowInsecureLocal = json['allowInsecureLocal'];
    final allowInsecureLocal = switch (rawAllowInsecureLocal) {
      null => false,
      final bool value => value,
      _ => throw FormatException(
          'Expected bool for allowInsecureLocal',
          rawAllowInsecureLocal,
        ),
    };
    final rawImageInput = json['imageInput'];
    if (rawImageInput != null && rawImageInput is! bool) {
      throw FormatException('Expected bool for imageInput', rawImageInput);
    }

    return EndpointProfile(
      id: id,
      name: name,
      protocol: protocol,
      apiRoot: apiRoot,
      credentialRef: credentialRef,
      modelId: rawModelId as String?,
      discovery: discovery,
      allowInsecureLocal: allowInsecureLocal,
      imageInput: rawImageInput as bool?,
    );
  }

  static const int maxNameLength = 80;
  static const int maxApiRootLength = 2048;
  static const int maxModelIdLength = 256;
  static const int maxCredentialRefLength = 256;
  static const String reservedChatGptId = 'chatgpt-plan';
  static const String credentialRefPrefix = 'salu.';

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');
  static final RegExp _whitespace = RegExp(r'\s');

  /// Opaque profile identifier, never derived from a secret key.
  final String id;

  /// Human-readable display name.
  final String name;

  /// Wire protocol spoken by the endpoint.
  final EndpointProtocol protocol;

  /// Base API URL without userinfo, query string, or fragment.
  final Uri apiRoot;

  /// Secure-storage slot reference starting with `salu.`.
  final String credentialRef;

  /// Selected model identifier, if chosen.
  final String? modelId;

  /// How models are discovered for this endpoint.
  final ModelDiscoveryMode discovery;

  /// Whether plain `http://` is explicitly permitted for local endpoints.
  final bool allowInsecureLocal;

  /// Whether the selected model is known to accept image input, if declared.
  final bool? imageInput;

  /// Whether [other] points to the same scheme, host, port, and protocol.
  bool hasSameDestination(EndpointProfile other) =>
      protocol == other.protocol &&
      apiRoot.scheme == other.apiRoot.scheme &&
      apiRoot.host == other.apiRoot.host &&
      apiRoot.port == other.apiRoot.port;

  /// Returns a validated copy with updated fields.
  EndpointProfile copyWith({
    String? id,
    String? name,
    EndpointProtocol? protocol,
    Uri? apiRoot,
    String? credentialRef,
    String? modelId,
    ModelDiscoveryMode? discovery,
    bool? allowInsecureLocal,
    bool? imageInput,
  }) =>
      EndpointProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        apiRoot: apiRoot ?? this.apiRoot,
        credentialRef: credentialRef ?? this.credentialRef,
        modelId: modelId ?? this.modelId,
        discovery: discovery ?? this.discovery,
        allowInsecureLocal: allowInsecureLocal ?? this.allowInsecureLocal,
        imageInput: imageInput ?? this.imageInput,
      );

  /// Serializes only nonsecret profile metadata; never includes API keys.
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'apiRoot': apiRoot.toString(),
        'credentialRef': credentialRef,
        if (modelId != null) 'modelId': modelId,
        'discovery': discovery.name,
        'allowInsecureLocal': allowInsecureLocal,
        if (imageInput != null) 'imageInput': imageInput,
      };

  @override
  bool operator ==(Object other) =>
      other is EndpointProfile &&
      other.id == id &&
      other.name == name &&
      other.protocol == protocol &&
      other.apiRoot == apiRoot &&
      other.credentialRef == credentialRef &&
      other.modelId == modelId &&
      other.discovery == discovery &&
      other.allowInsecureLocal == allowInsecureLocal &&
      other.imageInput == imageInput;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        protocol,
        apiRoot,
        credentialRef,
        modelId,
        discovery,
        allowInsecureLocal,
        imageInput,
      );

  @override
  String toString() =>
      'EndpointProfile(id: $id, name: $name, protocol: ${protocol.name}, '
      'apiRoot: $apiRoot, modelId: $modelId)';

  static void _validateId(String id) {
    if (id == reservedChatGptId || !_idPattern.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'must be 1..64 ASCII [A-Za-z0-9_-] characters and not $reservedChatGptId',
      );
    }
  }

  static String _validateName(String name) {
    if (_controlChars.hasMatch(name)) {
      throw ArgumentError('Endpoint name cannot contain control characters');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > maxNameLength) {
      throw ArgumentError.value(
        trimmed,
        'name',
        'must be 1..$maxNameLength characters after trimming',
      );
    }
    return trimmed;
  }

  static String? _validateModelId(String? modelId) {
    if (modelId == null) return null;
    if (_controlChars.hasMatch(modelId)) {
      throw ArgumentError('Model ID cannot contain control characters');
    }
    final trimmed = modelId.trim();
    if (trimmed.isEmpty || trimmed.length > maxModelIdLength) {
      throw ArgumentError.value(
        trimmed,
        'modelId',
        'must be 1..$maxModelIdLength characters after trimming',
      );
    }
    return trimmed;
  }

  static void _validateApiRoot(Uri apiRoot,
      {required bool allowInsecureLocal}) {
    final text = apiRoot.toString();
    if (text.length > maxApiRootLength || _controlChars.hasMatch(text)) {
      throw ArgumentError.value(
        text,
        'apiRoot',
        'must be at most $maxApiRootLength characters with no control characters',
      );
    }
    if (!apiRoot.hasAuthority || apiRoot.host.isEmpty) {
      throw ArgumentError.value(text, 'apiRoot', 'must include a host');
    }
    if (apiRoot.userInfo.isNotEmpty || apiRoot.authority.contains('@')) {
      throw ArgumentError.value(text, 'apiRoot', 'must not contain userinfo');
    }
    if (apiRoot.hasQuery || apiRoot.hasFragment) {
      throw ArgumentError.value(
        text,
        'apiRoot',
        'must not contain query parameters or fragments',
      );
    }
    if (apiRoot.hasPort && (apiRoot.port < 1 || apiRoot.port > 65535)) {
      throw ArgumentError.value(text, 'apiRoot', 'port out of range');
    }
    final scheme = apiRoot.scheme;
    if (scheme == 'https') return;
    if (scheme == 'http' && allowInsecureLocal) return;
    throw ArgumentError.value(
      text,
      'apiRoot',
      'must use https unless allowInsecureLocal is true',
    );
  }

  static void _validateCredentialRef(String ref) {
    if (!ref.startsWith(credentialRefPrefix) ||
        ref.length <= credentialRefPrefix.length ||
        ref.length > maxCredentialRefLength ||
        _controlChars.hasMatch(ref) ||
        _whitespace.hasMatch(ref)) {
      throw ArgumentError(
        'credentialRef must start with "$credentialRefPrefix" without spaces or control characters',
      );
    }
  }

  static String _requireString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Expected string for $key', value);
    }
    return value;
  }

  static T _parseEnum<T extends Enum>(
    List<T> values,
    String raw,
    String field,
  ) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    throw FormatException('Invalid $field: $raw', raw);
  }
}
