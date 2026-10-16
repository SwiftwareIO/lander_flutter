import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'lander_client.dart';
import 'link_dispatcher.dart';
import 'models.dart';
import 'platform.dart';

/// Entry point of the Lander SDK.
///
/// Every method that returns a Future reports its errors (including
/// [ArgumentError] and [StateError]) through that Future, never by throwing
/// synchronously.
///
/// ```dart
/// await Lander.initialize(apiKey: 'pk_live_...');
/// Lander.onDeepLink.listen((link) => router.go(link.route));
/// ```
abstract final class Lander {
  /// The format of a publishable key, as in `packages/shared/src/keys.ts`.
  static final RegExp _publishableKey = RegExp(r'^pk_(test|live)_[A-Za-z0-9]{24,}$');

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
  /// Surrounding whitespace is ignored. Secret keys are rejected because
  /// anything shipped in an app is public. Errors, including the
  /// [ArgumentError] for a bad key, arrive through the returned Future; the
  /// key itself is never included in an error message.
  static Future<void> initialize({
    required String apiKey,
    String baseUrl = 'https://api.golander.link',
    bool enableLogging = false,
  }) async {
    if (_client != null) {
      if (enableLogging) debugPrint('[Lander] initialize called twice; ignoring the second call');
      return _started!;
    }
    final key = apiKey.trim();
    if (key.contains('sk_')) {
      throw ArgumentError('secret keys must never ship in an app; use a pk_ key', 'apiKey');
    }
    if (!_publishableKey.hasMatch(key)) {
      throw ArgumentError(
        'expected a publishable key such as pk_live_..., with no "Bearer" prefix or spaces',
        'apiKey',
      );
    }
    WidgetsFlutterBinding.ensureInitialized();
    final client = _client = LanderClient(
      apiKey: key,
      baseUrl: baseUrl,
      dispatcher: _dispatcher,
      platform: LanderPlatform.instance,
      httpClient: debugHttpClient,
      enableLogging: enableLogging,
    );
    return _started = client.start();
  }

  /// Every deep link the app receives: Universal Links, App Links, custom
  /// scheme URLs and deferred links (recovered on first launch, with
  /// [LanderLink.isDeferred] true and their [LanderLink.confidence]).
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
  /// delivered once: if [onDeepLink] or an earlier call already delivered it,
  /// this returns null, and once this has been called [onDeepLink] will not
  /// deliver it.
  ///
  /// Throws [StateError] (through the Future) before [initialize].
  static Future<LanderLink?> getInitialLink() async => _require('getInitialLink').getInitialLink();

  /// Creates a short link from inside the app, for share and invite flows.
  ///
  /// [path] is the in app route the link opens. [params] values must be
  /// `String`, `num` or `bool`. The slug is always random and the domain is
  /// the project's default domain. Throws [LanderException] on failure.
  /// Retries wait at most 10 seconds in total, so a long `Retry-After` comes
  /// back as an exception with [LanderException.retryAfter] instead.
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
  }) async {
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

  /// Claims the link your backend handed off to this user, after sign in.
  ///
  /// Your server binds a link to one of its users with `POST /v1/handoffs`
  /// (secret key), for example when someone signs up on your website from a
  /// campaign link. After that user signs in to the app, call this with the
  /// same [userId] to get that link (`isDeferred` true, `confidence`
  /// deterministic, `method` `authenticated_handoff`), or null when nothing is
  /// pending. The newest pending handoff wins and every pending one for the
  /// user is cleared, so a second call returns null.
  ///
  /// The link is only returned, never also emitted on [onDeepLink], so
  /// navigate with it yourself. Use an ID that cannot be guessed (your auth
  /// system's user UUID, not an email address or a counter). Throws
  /// [LanderException] when the request fails after retries, or when the
  /// install could not be registered yet (`install_not_registered`; the
  /// registration is retried first).
  static Future<LanderLink?> claimHandoff(String userId) async {
    final client = _require('claimHandoff');
    final id = userId.trim();
    if (id.isEmpty || id.length > 256) {
      throw ArgumentError.value(userId, 'userId', 'must be 1 to 256 characters');
    }
    return client.claimHandoff(id);
  }

  /// Ties the events and link opens recorded from now on to one of your users,
  /// so you can see who converted in the dashboard and in webhooks.
  ///
  /// Call it after sign in (and on launch when a user is already signed in),
  /// and with null on sign out. The ID is remembered across launches, and each
  /// event keeps the user that was set when it was tracked. Lander stores the
  /// ID as you send it, so use an ID that does not identify the person on its
  /// own (your auth system's user UUID, not an email address). Throws
  /// [ArgumentError] for an ID that is empty or longer than 256 characters
  /// after trimming.
  static Future<void> setUserId(String? userId) async {
    final client = _require('setUserId');
    final id = userId?.trim();
    if (id != null && (id.isEmpty || id.length > 256)) {
      throw ArgumentError.value(userId, 'userId', 'must be 1 to 256 characters');
    }
    return client.setUserId(id);
  }

  /// The user ID from [setUserId], or null when no user is set.
  static String? get userId => _client?.userId;

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
  }) async =>
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
