import 'package:flutter/foundation.dart';

/// How sure Lander is that a link caused this open or install.
enum LanderConfidence {
  /// Matched by an exact identifier, for example a Universal Link or App Link
  /// open, or an Android install referrer token.
  deterministic,

  /// Matched by a heuristic. Only used for opt in deferred links on iOS.
  probabilistic,

  /// No link could be tied to this open.
  unattributed;

  static LanderConfidence parse(Object? value) {
    for (final c in values) {
      if (c.name == value) return c;
    }
    return unattributed;
  }
}

/// A deep link delivered to the app.
///
/// When Lander knows the link, the fields mirror the `ResolvedLink` returned by
/// `POST /v1/sdk/resolve`. When it does not (unknown link, custom scheme URL,
/// or the network was unavailable) only [uri] is set, [isResolved] is false and
/// the app can still route on the raw URL.
@immutable
class LanderLink {
  const LanderLink({
    required this.uri,
    this.linkId,
    this.url,
    this.path,
    this.params = const {},
    this.campaign,
    this.channel,
    this.isDeferred = false,
    this.confidence = LanderConfidence.unattributed,
  });

  /// A link Lander could not resolve. Only the raw [uri] is available.
  const LanderLink.unresolved(this.uri)
      : linkId = null,
        url = null,
        path = null,
        params = const {},
        campaign = null,
        channel = null,
        isDeferred = false,
        confidence = LanderConfidence.unattributed;

  /// Builds a link from a `ResolvedLink` JSON object. [uri] is the URL that
  /// opened the app; for deferred links it falls back to the link's own URL.
  factory LanderLink.fromJson(Map<String, Object?> json, {Uri? uri}) {
    final url = json['url'] as String?;
    final params = json['params'];
    return LanderLink(
      uri: uri ?? Uri.parse(url ?? ''),
      linkId: json['linkId'] as String?,
      url: url,
      path: json['path'] as String?,
      params: params is Map
          ? Map.unmodifiable(<String, Object>{
              for (final e in params.entries)
                if (e.value != null) '${e.key}': e.value as Object,
            })
          : const {},
      campaign: json['campaign'] as String?,
      channel: json['channel'] as String?,
      isDeferred: json['isDeferred'] == true,
      confidence: LanderConfidence.parse(json['confidence']),
    );
  }

  /// The URL that opened the app, exactly as the OS delivered it.
  final Uri uri;

  /// Lander link ID, or null when the link is not known to Lander.
  final String? linkId;

  /// The canonical short link, for example `https://acme.lndr.link/p-123`.
  final String? url;

  /// The in app route configured on the link, for example `/product/123`.
  final String? path;

  /// The link's stored params with the opened URL's query parameters merged
  /// over them. Values are `String`, `num` or `bool`.
  final Map<String, Object> params;

  final String? campaign;
  final String? channel;

  /// True when the link was recovered after an install (deferred deep link).
  final bool isDeferred;

  final LanderConfidence confidence;

  /// Whether Lander recognized this link.
  bool get isResolved => linkId != null;

  /// The route to navigate to: the link's [path] when resolved, otherwise the
  /// raw URL's path and query. For custom scheme URLs the host counts as the
  /// first path segment, so `acmeshop://product/123` gives `/product/123`.
  String get route {
    if (path != null) return path!;
    final isWeb = uri.scheme == 'http' || uri.scheme == 'https';
    var raw = !isWeb && uri.host.isNotEmpty ? '/${uri.host}${uri.path}' : uri.path;
    if (raw.isEmpty) raw = '/';
    return uri.hasQuery ? '$raw?${uri.query}' : raw;
  }

  @override
  bool operator ==(Object other) =>
      other is LanderLink &&
      other.uri == uri &&
      other.linkId == linkId &&
      other.url == url &&
      other.path == path &&
      mapEquals(other.params, params) &&
      other.campaign == campaign &&
      other.channel == channel &&
      other.isDeferred == isDeferred &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(uri, linkId, path, isDeferred, confidence);

  @override
  String toString() => isResolved
      ? 'LanderLink($linkId, path: $path, params: $params, uri: $uri)'
      : 'LanderLink(unresolved, uri: $uri)';
}

/// A short link created with `Lander.createLink`.
@immutable
class LanderShortLink {
  const LanderShortLink({
    required this.id,
    required this.url,
    required this.domain,
    required this.slug,
    required this.path,
    this.params = const {},
    this.title,
    this.campaign,
    this.channel,
    this.tags = const [],
    this.expiresAt,
    this.createdAt,
  });

  factory LanderShortLink.fromJson(Map<String, Object?> json) {
    final params = json['params'];
    final tags = json['tags'];
    return LanderShortLink(
      id: json['id'] as String,
      url: Uri.parse(json['url'] as String),
      domain: json['domain'] as String? ?? '',
      slug: json['slug'] as String? ?? '',
      path: json['deepLinkPath'] as String? ?? '/',
      params: params is Map
          ? Map.unmodifiable(<String, Object>{
              for (final e in params.entries)
                if (e.value != null) '${e.key}': e.value as Object,
            })
          : const {},
      title: json['title'] as String?,
      campaign: json['campaign'] as String?,
      channel: json['channel'] as String?,
      tags: tags is List ? List.unmodifiable(tags.map((t) => '$t')) : const [],
      expiresAt: _date(json['expiresAt']),
      createdAt: _date(json['createdAt']),
    );
  }

  final String id;

  /// The shareable URL, for example `https://acme.lndr.link/x7Kp2Qa`.
  final Uri url;
  final String domain;
  final String slug;

  /// The in app route the link opens.
  final String path;
  final Map<String, Object> params;
  final String? title;
  final String? campaign;
  final String? channel;
  final List<String> tags;
  final DateTime? expiresAt;
  final DateTime? createdAt;

  @override
  bool operator ==(Object other) =>
      other is LanderShortLink && other.id == id && other.url == url;

  @override
  int get hashCode => Object.hash(id, url);

  @override
  String toString() => url.toString();
}

/// Thrown by [Lander] calls that need an answer from the API, such as
/// `createLink`. Fire and forget calls (`initialize`, `trackEvent`) never throw
/// on network or server errors.
class LanderException implements Exception {
  const LanderException({
    required this.code,
    required this.message,
    this.statusCode,
    this.retryAfter,
  });

  /// The API's error code (for example `rate_limited`), or `network_error`,
  /// `timeout` or `invalid_response` for client side failures.
  final String code;
  final String message;

  /// HTTP status, or null when no response was received.
  final int? statusCode;

  /// Server requested delay before retrying, from the `Retry-After` header.
  final Duration? retryAfter;

  /// Whether retrying the same request later may succeed.
  bool get isRetryable {
    final s = statusCode;
    return s == null || s == 408 || s == 429 || s >= 500;
  }

  @override
  String toString() =>
      'LanderException($code${statusCode == null ? '' : ', $statusCode'}): $message';
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
