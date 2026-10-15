import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'event_queue.dart';
import 'link_dispatcher.dart';
import 'logger.dart';
import 'models.dart';
import 'platform.dart';
import 'version.dart';

/// The SDK engine behind the static `Lander` facade. One per app.
class LanderClient with WidgetsBindingObserver {
  LanderClient({
    required String apiKey,
    required String baseUrl,
    required this.dispatcher,
    required this.platform,
    http.Client? httpClient,
    bool enableLogging = false,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration flushDelay = const Duration(seconds: 2),
    Backoff eventBackoff = const Backoff(),
    Backoff requestBackoff = const Backoff(base: Duration(milliseconds: 500), max: Duration(seconds: 4)),
  }) : logger = LanderLogger(enabled: enableLogging) {
    api = LanderApi(
      apiKey: apiKey,
      baseUrl: baseUrl,
      client: httpClient ?? http.Client(),
      logger: logger,
      timeout: requestTimeout,
      backoff: requestBackoff,
    );
    events = EventQueue(
      read: _read,
      write: _write,
      sender: _sendEvents,
      logger: logger,
      flushDelay: flushDelay,
      backoff: eventBackoff,
    );
  }

  static const installIdKey = 'install_id';

  /// Query parameter of a custom scheme URL carrying the Lander link it
  /// stands for.
  static const landerLinkParam = 'lander_link';
  static const firstLaunchReportedKey = 'first_launch_reported';

  /// Repeated identical URLs inside this window count as one open. iOS and
  /// Android can report the same launch URL through more than one callback.
  static const duplicateLinkWindow = Duration(seconds: 2);

  final LinkDispatcher dispatcher;
  final LanderPlatform platform;
  final LanderLogger logger;
  late final LanderApi api;
  late final EventQueue events;

  static const _uuid = Uuid();
  late final Future<void> _ready = _loadInstall();
  final Completer<void> _initDone = Completer();
  Future<void> _linkChain = Future.value();
  StreamSubscription<String>? _linkSub;
  String? _installId;
  bool _isFirstLaunch = false;

  /// Whether the API knows this install (an init succeeded, now or on an
  /// earlier launch). Events wait for it: the API rejects events from
  /// unknown installs.
  bool _registered = false;
  bool _reRegisterTried = false;
  bool _conflictRetried = false;
  String? _lastRawLink;
  DateTime? _lastRawLinkAt;
  bool _observing = false;

  /// The random install ID, once loaded.
  String? get installId => _installId;

  /// Completes when `POST /v1/sdk/init` has finished (or failed).
  Future<void> get initDone => _initDone.future;

  /// Loads local state and hooks up link delivery, then starts the network
  /// init in the background. Never throws.
  Future<void> start() async {
    await _ready;

    final initialRaw = await _safe(platform.getInitialLink, 'getInitialLink');
    final hasInitial = initialRaw != null && initialRaw.isNotEmpty;
    if (hasInitial) {
      _onRawLink(initialRaw, initial: true);
    } else if (!_isFirstLaunch) {
      // Only a first launch can produce a deferred link, so do not make
      // getInitialLink wait for the network otherwise.
      dispatcher.setInitialLink(null);
    }

    try {
      _linkSub = platform.linkStream.listen(
        _onRawLink,
        onError: (Object e) => logger.log('Link stream error: $e'),
      );
    } catch (e) {
      logger.log('Link stream unavailable: $e');
    }

    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _observing = true;

    unawaited(_init(hasInitialLink: hasInitial));
    unawaited(events.load().then((_) => events.flush()));
  }

  Future<void> _loadInstall() async {
    var id = await _safe(() => _read(installIdKey), 'read install id');
    if (id == null || !Uuid.isValidUUID(fromString: id)) {
      id = _uuid.v4();
      await _write(installIdKey, id);
      logger.log('Created install ID $id');
    }
    _installId = id;
    _isFirstLaunch = await _safe(() => _read(firstLaunchReportedKey), 'read first launch') != '1';
    _registered = !_isFirstLaunch;
  }

  /// Starts over with a new install ID, reported as a first launch.
  Future<void> _resetInstall() async {
    _installId = _uuid.v4();
    await _write(installIdKey, _installId!);
    try {
      await platform.delete(firstLaunchReportedKey);
    } catch (e) {
      logger.log('Storage delete failed: $e');
    }
    _isFirstLaunch = true;
    _registered = false;
    logger.log('Created install ID $_installId');
  }

  Future<void> _init({required bool hasInitialLink}) async {
    try {
      final json = await _register();
      final deferred = json?['deferredLink'];
      if (deferred is Map<String, Object?> && !hasInitialLink) {
        final link = LanderLink.fromJson(deferred);
        logger.log('Deferred link: $link');
        dispatcher.setInitialLink(link);
      }
    } finally {
      if (!hasInitialLink && !dispatcher.initialSettled) dispatcher.setInitialLink(null);
      if (!_initDone.isCompleted) _initDone.complete();
    }
  }

  /// `POST /v1/sdk/init`. Returns the response, or null on failure. Never throws.
  Future<Map<String, Object?>?> _register() async {
    try {
      final info = await _safe(platform.getPlatformInfo, 'getPlatformInfo');
      if (info == null || (info.platform != 'ios' && info.platform != 'android')) {
        logger.log('Unsupported platform, skipping init. Links and events still work locally.');
        return null;
      }

      String? referrer;
      if (_isFirstLaunch && info.platform == 'android') {
        referrer = await _safe(
          () => platform.getInstallReferrer().timeout(const Duration(seconds: 5)),
          'getInstallReferrer',
        );
        if (referrer != null && referrer.length > 2048) referrer = referrer.substring(0, 2048);
      }

      final json = await api.post(
        '/v1/sdk/init',
        {
          'installId': _installId,
          'platform': info.platform,
          'appVersion': info.appVersion,
          'sdkVersion': landerSdkVersion,
          'osVersion': ?info.osVersion,
          'isFirstLaunch': _isFirstLaunch,
          if (referrer != null && referrer.isNotEmpty) 'installReferrer': referrer,
        },
        // A stable key for the install report, so a retry after a lost
        // response (even on the next launch) records one install, not two.
        idempotencyKey: _isFirstLaunch ? _uuid.v5(Namespace.url.value, 'lander:install:$_installId') : _uuid.v4(),
        maxAttempts: _isFirstLaunch ? 3 : 1,
      );
      if (_isFirstLaunch) {
        await _write(firstLaunchReportedKey, '1');
        _isFirstLaunch = false;
      }
      _registered = true;
      logger.log('Init ok');
      // Send events that waited for the install to be known.
      unawaited(events.flush());
      return json;
    } on LanderException catch (e) {
      if (e.code == 'install_id_conflict' && !_conflictRetried) {
        // The ID belongs to another project or environment, for example after
        // switching from a test key to a live key. Start over with a new one.
        _conflictRetried = true;
        logger.log('Install ID belongs to another project, creating a new one');
        await _resetInstall();
        return _register();
      }
      logger.log('Init failed: $e');
      return null;
    } catch (e) {
      logger.log('Init failed unexpectedly: $e');
      return null;
    }
  }

  void _onRawLink(String raw, {bool initial = false}) {
    final now = DateTime.now();
    if (!initial && raw == _lastRawLink && now.difference(_lastRawLinkAt!) < duplicateLinkWindow) {
      logger.log('Ignoring duplicate link $raw');
      return;
    }
    _lastRawLink = raw;
    _lastRawLinkAt = now;
    _linkChain = _linkChain.then((_) async {
      final link = await _resolve(raw);
      if (initial) {
        dispatcher.setInitialLink(link);
      } else if (link != null) {
        dispatcher.add(link);
      }
    }).catchError((Object e) {
      logger.log('Link delivery failed for $raw: $e');
      if (initial && !dispatcher.initialSettled) dispatcher.setInitialLink(null);
    });
  }

  /// Resolves [raw] through the API. Never throws: unknown links and network
  /// failures produce an unresolved link carrying the raw URL.
  Future<LanderLink?> _resolve(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      logger.log('Ignoring unparsable link $raw');
      return null;
    }
    var target = raw;
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      // Custom scheme URLs are not Lander short links, unless they carry one in
      // `lander_link` (the "Continue in app" page's open button does).
      final carried = Uri.tryParse(uri.queryParameters[landerLinkParam] ?? '');
      if (carried == null || (carried.scheme != 'https' && carried.scheme != 'http')) {
        return LanderLink.unresolved(uri);
      }
      target = carried.toString();
    }
    // Let init register this install first, but never hold a link for long.
    await initDone.timeout(api.timeout, onTimeout: () {});
    try {
      final json = await api.post(
        '/v1/sdk/resolve',
        {'installId': _installId, 'url': target},
        idempotencyKey: _uuid.v4(),
        maxAttempts: 2,
      );
      final link = LanderLink.fromJson(json, uri: uri);
      logger.log('Resolved $link');
      return link;
    } on LanderException catch (e) {
      logger.log(e.statusCode == 404 ? 'Not a Lander link: $raw' : 'Resolve failed for $raw: $e');
      return LanderLink.unresolved(uri);
    } catch (e) {
      logger.log('Resolve returned an unexpected response for $raw: $e');
      return LanderLink.unresolved(uri);
    }
  }

  Future<LanderLink?> getInitialLink() => dispatcher.takeInitialLink();

  /// `POST /v1/sdk/handoffs/claim`. Returns the link the customer's backend
  /// bound to [userId], or null. The link is returned only, never also sent to
  /// `onDeepLink`, so the app navigates once.
  Future<LanderLink?> claimHandoff(String userId) async {
    await _ready;
    // The API only knows installs that went through init.
    await initDone;
    if (!_registered) {
      throw const LanderException(
        code: 'install_not_registered',
        message: 'Lander could not register this install yet (offline?); try again later',
      );
    }
    final json = await api.post(
      '/v1/sdk/handoffs/claim',
      {'installId': _installId, 'userId': userId},
      // One key per call, reused across its retries: a retry after a lost
      // response gets the same link instead of nothing.
      idempotencyKey: _uuid.v4(),
      maxAttempts: 3,
    );
    final deferred = json['deferredLink'];
    if (deferred == null) {
      logger.log('No pending handoff');
      return null;
    }
    if (deferred is! Map<String, Object?>) {
      throw const LanderException(code: 'invalid_response', message: 'Unexpected claimHandoff response');
    }
    final link = LanderLink.fromJson(deferred);
    logger.log('Handoff: $link');
    return link;
  }

  Future<LanderShortLink> createLink(Map<String, Object?> body) async {
    await _ready;
    final json = await api.post(
      '/v1/sdk/links',
      // installId lets the API rate limit per install instead of per IP.
      {...body, 'installId': _installId},
      idempotencyKey: _uuid.v4(),
      maxAttempts: 3,
    );
    try {
      return LanderShortLink.fromJson(json);
    } catch (e) {
      throw LanderException(code: 'invalid_response', message: 'Unexpected createLink response: $e');
    }
  }

  Future<void> trackEvent(String name, Map<String, Object?> properties, {String? linkId}) async {
    if (name.isEmpty || name.length > 100) {
      throw ArgumentError.value(name, 'name', 'must be 1 to 100 characters');
    }
    // Validate here: one bad event would make the API reject its whole batch.
    if (linkId != null && !Uuid.isValidUUID(fromString: linkId)) {
      throw ArgumentError.value(linkId, 'linkId', 'must be a Lander link ID (UUID)');
    }
    final Map<String, Object?> props;
    try {
      // Round trip to fail fast on values that cannot be sent as JSON.
      props = (jsonDecode(jsonEncode(properties)) as Map).cast<String, Object?>();
    } on JsonUnsupportedObjectError catch (e) {
      throw ArgumentError.value(properties, 'properties', 'must be JSON encodable: ${e.unsupportedObject}');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await events.add({
      'id': _uuid.v4(),
      'type': 'custom',
      'name': name,
      'linkId': ?linkId,
      'properties': props,
      'occurredAt': DateTime.fromMillisecondsSinceEpoch(now, isUtc: true).toIso8601String(),
    });
  }

  Future<void> _sendEvents(List<Map<String, Object?>> batch) async {
    await _ready;
    if (!_registered) {
      // Retried with backoff, and flushed as soon as init succeeds.
      throw const LanderException(code: 'install_not_registered', message: 'Waiting for init to succeed');
    }
    final ids = [for (final e in batch) e['id']]..sort((a, b) => '$a'.compareTo('$b'));
    try {
      await api.post(
        '/v1/sdk/events',
        {'installId': _installId, 'events': batch},
        idempotencyKey: _uuid.v5(Namespace.url.value, 'lander:events:${ids.join(',')}'),
      );
    } on LanderException catch (e) {
      if (e.code != 'install_not_found' || _reRegisterTried) rethrow;
      // The API lost this install (for example a reset local database).
      // Register it again once, and keep the events meanwhile.
      _reRegisterTried = true;
      _registered = false;
      _isFirstLaunch = true;
      logger.log('API does not know this install, registering it again');
      unawaited(_register());
      throw LanderException(code: e.code, message: e.message);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      unawaited(events.flush());
    }
  }

  Future<String?> _read(String key) => platform.read(key);

  Future<void> _write(String key, String value) async {
    try {
      await platform.write(key, value);
    } catch (e) {
      logger.log('Storage write failed for $key: $e');
    }
  }

  Future<T?> _safe<T>(Future<T?> Function() call, String what) async {
    try {
      return await call();
    } catch (e) {
      logger.log('$what failed: $e');
      return null;
    }
  }

  /// Stops listening and cancels timers. Does not wait for the platform side
  /// to acknowledge the cancellation.
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
    events.dispose();
    unawaited(_linkSub?.cancel());
    _linkSub = null;
  }
}
