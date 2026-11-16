/// The optional inference provider boundary.
///
/// Nothing in the core depends on a provider being reachable: this file declares
/// a capability interface only. Concrete providers (ChatGPT plan authorization,
/// user-owned keys) live in the app package, and their output is untrusted input
/// that must be validated into typed commands before it can change anything.
library;

import 'dart:typed_data';

/// What the app may ask a provider to do.
enum InferenceTask {
  /// Read printed nutrition values from a photo of a label.
  labelOcr,

  /// Propose visible foods and approximate portions from a meal photo.
  mealPhoto,

  /// Turn a sentence such as "two eggs and a coffee" into structured items.
  naturalLanguageLog,

  /// Explain an app-computed finding in plain language.
  explainFinding,

  /// Turn a typed plan-assistance suggestion into a reviewable proposal.
  /// The suggestion is schema-constrained `salu-plan-assistance-v1` output;
  /// the provider never writes meals, targets, or diary entries directly.
  planAssistance,
}

/// Optional provider features. Advertised support is a hint, never a guarantee.
enum InferenceCapability {
  /// Accepts image input.
  imageInput,

  /// Can return schema-constrained output.
  structuredOutput,

  /// Can call app tools through validated commands.
  toolCalls,

  /// Can stream partial output.
  streaming,

  /// Can cancel an in-flight request.
  cancellation,
}

/// An image sent to a provider, already stripped of unnecessary metadata.
final class ImageAttachment {
  /// Wraps encoded image [bytes] with their [mimeType].
  const ImageAttachment({required this.bytes, required this.mimeType});

  /// Encoded image data.
  final Uint8List bytes;

  /// MIME type such as `image/jpeg`.
  final String mimeType;
}

/// A single request to a provider.
final class InferenceRequest {
  /// Creates a request. [requestId] correlates retries, logs, and drafts.
  const InferenceRequest({
    required this.requestId,
    required this.task,
    required this.prompt,
    this.images = const <ImageAttachment>[],
    this.expectedSchema,
  });

  /// Correlation id, stable across retries.
  final String requestId;

  /// The task this request represents.
  final InferenceTask task;

  /// Instruction text. Never contains data the user did not agree to share.
  final String prompt;

  /// Images attached to the request.
  final List<ImageAttachment> images;

  /// JSON-schema text the caller would like honoured, when supported.
  final String? expectedSchema;
}

/// Provider output, still untrusted.
final class InferenceResponse {
  /// Creates a response.
  const InferenceResponse({
    required this.requestId,
    required this.text,
    this.structured,
  });

  /// Correlation id echoed from the request.
  final String requestId;

  /// Free-form output.
  final String text;

  /// Schema-shaped output when the provider returned any.
  final Map<String, Object?>? structured;
}

/// A provider the user may enable. Implementing this is not authorization to
/// send data: the app gates every transfer on an explicit consent scope.
abstract interface class InferenceProvider {
  /// Stable provider id, e.g. `chatgpt-plan`.
  String get providerId;

  /// Features the provider claims.
  Set<InferenceCapability> get capabilities;

  /// Whether the provider accepts [task]. Callers still validate the result.
  bool supports(InferenceTask task);

  /// Runs [request]. Implementations enforce their own timeouts and retry limits.
  Future<InferenceResponse> infer(InferenceRequest request);

  /// Releases credentials and any queued work.
  Future<void> disconnect();
}
