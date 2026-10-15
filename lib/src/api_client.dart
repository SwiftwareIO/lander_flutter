import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'logger.dart';
import 'models.dart';
import 'version.dart';

/// Exponential backoff with jitter: `base * 2^attempt`, capped at [max].
class Backoff {
  const Backoff({
    this.base = const Duration(seconds: 1),
    this.max = const Duration(minutes: 5),
    this.jitter = 0.2,
  });

  final Duration base;
  final Duration max;

  /// Fraction of the delay that is randomized, between 0 and 1.
  final double jitter;

  /// Delay before retry number [attempt] (0 based).
  Duration delay(int attempt, {Random? random}) {
    final exp = base.inMilliseconds * pow(2, min(attempt, 20));
    final capped = min(exp, max.inMilliseconds).toDouble();
    if (jitter <= 0) return Duration(milliseconds: capped.round());
    final r = (random ?? Random()).nextDouble();
    // Spread over [capped * (1 - jitter), capped].
    return Duration(milliseconds: (capped * (1 - jitter * r)).round());
  }
}

/// Thin JSON client for the `/v1/sdk/*` endpoints in docs/API.md.
class LanderApi {
  LanderApi({
    required String apiKey,
    required String baseUrl,
    required http.Client client,
    required LanderLogger logger,
    this.timeout = const Duration(seconds: 10),
    this.backoff = const Backoff(base: Duration(milliseconds: 500), max: Duration(seconds: 4)),
  })  : _apiKey = apiKey,
        _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _client = client,
        _logger = logger;

  final String _apiKey;
  final String _baseUrl;
  final http.Client _client;
  final LanderLogger _logger;

  /// Per attempt request timeout.
  final Duration timeout;

  /// Backoff between attempts of [post] when `maxAttempts > 1`.
  final Backoff backoff;

  /// POSTs [body] as JSON and returns the decoded response object.
  ///
  /// Retries retryable failures (network errors, timeouts, 408, 429, 5xx) up to
  /// [maxAttempts] times, reusing the same [idempotencyKey] so the server can
  /// drop duplicates. Throws [LanderException] on failure.
  Future<Map<String, Object?>> post(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
    Map<String, String> headers = const {},
    int maxAttempts = 1,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await _postOnce(path, body, idempotencyKey: idempotencyKey, headers: headers);
      } on LanderException catch (e) {
        attempt++;
        if (!e.isRetryable || attempt >= maxAttempts) rethrow;
        var wait = backoff.delay(attempt - 1);
        final retryAfter = e.retryAfter;
        if (retryAfter != null && retryAfter > wait) wait = retryAfter;
        _logger.log('POST $path failed (${e.code}), retrying in ${wait.inMilliseconds} ms');
        await Future<void>.delayed(wait);
      }
    }
  }

  Future<Map<String, Object?>> _postOnce(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final http.Response res;
    try {
      res = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'X-Lander-Sdk': 'flutter/$landerSdkVersion',
              'Idempotency-Key': ?idempotencyKey,
              ...headers,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw LanderException(code: 'timeout', message: 'POST $path timed out after ${timeout.inSeconds}s');
    } catch (e) {
      throw LanderException(code: 'network_error', message: 'POST $path failed: $e');
    }

    final json = _decode(res.body);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return json ?? const {};
    }
    final error = json?['error'];
    throw LanderException(
      statusCode: res.statusCode,
      code: error is Map && error['code'] is String ? error['code'] as String : 'http_${res.statusCode}',
      message: error is Map && error['message'] is String
          ? error['message'] as String
          : 'POST $path returned ${res.statusCode}',
      retryAfter: _retryAfter(res.headers['retry-after']),
    );
  }

  static Map<String, Object?>? _decode(String body) {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static Duration? _retryAfter(String? header) {
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 3600));
    return null;
  }
}
