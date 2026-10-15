import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'lander_client.dart';
import 'link_dispatcher.dart';
import 'models.dart';
import 'platform.dart';

/// Entry point of the Lander SDK.
///
/// ```dart
/// await Lander.initialize(apiKey: 'pk_live_...');
/// Lander.onDeepLink.listen((link) => router.go(link.route));
/// ```
abstract final class Lander {
  static LinkDispatcher _dispatcher = LinkDispatcher();
  static LanderClient? _client;
  static Future<void>? _started;

  /// Overrides the HTTP client used by the next [initialize]. Tests only.
  @visibleForTesting
  static http.Client? debugHttpClient;

  /// Starts the SDK. Call it once, as early as possible (before `runApp` is
  /// fine).
  ///
  /// Loads or creates the random install ID, starts listening for links and
  /// then reports the launch with `POST /v1/sdk/init` in the background, so
  /// awaiting this never waits on the network. On an Android first launch the
  /// Play Install Referrer is read and sent along. Network failures are logged
  /// (when [enableLogging] is on) and never thrown.
  ///
  /// [apiKey] must be a publishable key (`pk_test_...` or `pk_live_...`).
  /// Secret keys are rejected because anything shipped in an app is public.
  static Future<void> initialize({
    required String apiKey,
    String baseUrl = 'https://api.lndr.link',
    bool enableLogging = false,
  }) {
    if (_client != null) {
      if (enableLogging) debugPrint('[Lander] initialize called twice; ignoring the second call');
      return _started!;
    }
    if (apiKey.startsWith('sk_')) {
      throw ArgumentError.value('sk_...', 'apiKey', 'secret keys must never ship in an app; use a pk_ key');
    }
    if (!apiKey.startsWith('pk_')) {
      throw ArgumentError.value(apiKey, 'apiKey', 'expected a publishable key starting with pk_');
    }
    WidgetsFlutterBinding.ensureInitialized();
    final client = _client = LanderClient(
      apiKey: apiKey,
      baseUrl: baseUrl,
      dispatcher: _dispatcher,
      platform: LanderPlatform.instance,
      httpClient: debugHttpClient,
      enableLogging: enableLogging,
    );
    return _started = client.start();
  }

  /// Every deep link the app receives: Universal Links, App Links, custom
  /// scheme URLs and deferred links.
  ///
  /// Safe to listen to at any time, even before [initialize]. Links that
  /// arrive while nobody listens are buffered and replayed in order to the
  /// next listener, so nothing is lost while the app (or its router) starts.
  /// The launch link is included unless [getInitialLink] claimed it first.
  ///
  /// Unknown links (not created in Lander) and links that could not be
  /// resolved because of the network are still delivered, with
  /// [LanderLink.isResolved] false and only [LanderLink.uri] set.
  static Stream<LanderLink> get onDeepLink => _dispatcher.stream;

  /// The link that launched the app, or null.
  ///
  /// On a first launch this may be a deferred link (when the API recovers
  /// one), so it waits for the init request in that case. The launch link is
  /// delivered once: if [onDeepLink] already delivered it, this returns null,
  /// and once this has been called [onDeepLink] will not deliver it.
  static Future<LanderLink?> getInitialLink() => _require('getInitialLink').getInitialLink();

  /// Creates a short link from inside the app, for share and invite flows.
  ///
  /// [path] is the in app route the link opens. [params] values must be
  /// `String`, `num` or `bool`. The slug is always random and the domain is
  /// the project's default domain. Throws [LanderException] on failure.
  static Future<LanderShortLink> createLink({
    String path = '/',
    Map<String, Object> params = const {},
    String? title,
    String? campaign,
    String? channel,
    List<String> tags = const [],
    Uri? iosFallbackUrl,
    Uri? androidFallbackUrl,
    Uri? webFallbackUrl,
    String? ogTitle,
    String? ogDescription,
    Uri? ogImageUrl,
    DateTime? expiresAt,
  }) {
    final client = _require('createLink');
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', 'must start with /');
    }
    for (final MapEntry(:key, :value) in params.entries) {
      if (value is! String && value is! num && value is! bool) {
        throw ArgumentError.value(value, 'params[$key]', 'must be a String, num or bool');
      }
    }
    return client.createLink({
      'deepLinkPath': path,
      'params': params,
      'title': ?title,
      'campaign': ?campaign,
      'channel': ?channel,
      if (tags.isNotEmpty) 'tags': tags,
      'iosFallbackUrl': ?iosFallbackUrl?.toString(),
      'androidFallbackUrl': ?androidFallbackUrl?.toString(),
      'webFallbackUrl': ?webFallbackUrl?.toString(),
      'ogTitle': ?ogTitle,
      'ogDescription': ?ogDescription,
      'ogImageUrl': ?ogImageUrl?.toString(),
      'expiresAt': ?expiresAt?.toUtc().toIso8601String(),
    });
  }

  /// Records a custom event, for example a signup or a purchase.
  ///
  /// The event is stored on the device first and sent in batches, with
  /// retries, so it survives offline periods and app restarts. Each event has
  /// a client generated ID, so it is counted once even if it is sent twice.
  /// Pass [linkId] (from [LanderLink.linkId]) to attribute the event to the
  /// link that brought the user in.
  ///
  /// Throws [ArgumentError] for an empty or too long [name] (max 100), a
  /// [linkId] that is not a UUID, or properties that cannot be encoded as
  /// JSON; never throws for network errors.
  static Future<void> trackEvent(
    String name, {
    Map<String, Object?> properties = const {},
    String? linkId,
  }) =>
      _require('trackEvent').trackEvent(name, properties, linkId: linkId);

  /// The random ID Lander created for this install, once [initialize] has
  /// completed. Useful when asking for support; it is not tied to the device.
  static String? get installId => _client?.installId;

  static LanderClient _require(String method) {
    final client = _client;
    if (client == null) {
      throw StateError('Call Lander.initialize() before Lander.$method()');
    }
    return client;
  }

  /// The running client. Tests only.
  @visibleForTesting
  static LanderClient? get debugClient => _client;

  /// Tears the SDK down so tests can initialize it again.
  @visibleForTesting
  static void debugReset() {
    _client?.dispose();
    unawaited(_dispatcher.close());
    _client = null;
    _started = null;
    _dispatcher = LinkDispatcher();
    debugHttpClient = null;
  }
}
