import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lander_flutter/lander_flutter.dart';
import 'package:lander_flutter/src/api_client.dart';
import 'package:lander_flutter/src/event_queue.dart';
import 'package:lander_flutter/src/lander_client.dart';
import 'package:lander_flutter/src/link_dispatcher.dart';
import 'package:uuid/uuid.dart';

import 'fakes.dart';

final _clients = <LanderClient>[];

LanderClient client(FakePlatform platform, FakeApi api, {LinkDispatcher? dispatcher}) {
  final c = LanderClient(
    apiKey: 'pk_test_DemoPublishableKey000000000000',
    baseUrl: 'http://localhost:8787',
    dispatcher: dispatcher ?? LinkDispatcher(),
    platform: platform,
    httpClient: api.client,
    flushDelay: Duration.zero,
    requestBackoff: const Backoff(base: Duration(milliseconds: 1), jitter: 0),
    eventBackoff: const Backoff(base: Duration(milliseconds: 1), jitter: 0),
  );
  _clients.add(c);
  return c;
}

Future<void> started(LanderClient c) async {
  await c.start();
  await c.initDone;
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    for (final c in _clients) {
      c.dispose();
    }
    _clients.clear();
  });

  group('init', () {
    test('first launch creates and persists a random install ID and reports isFirstLaunch', () async {
      final platform = FakePlatform();
      final api = FakeApi();
      final c = client(platform, api);
      await started(c);

      final id = platform.storage[LanderClient.installIdKey];
      expect(Uuid.isValidUUID(fromString: id!), isTrue);
      expect(c.installId, id);

      final init = api.to('/v1/sdk/init').single;
      expect(init.body, {
        'installId': id,
        'platform': 'ios',
        'appVersion': '2.4.0',
        'sdkVersion': landerSdkVersion,
        'osVersion': '18.1',
        'isFirstLaunch': true,
      });
      expect(init.headers['Idempotency-Key'], isNotNull);
      expect(platform.storage[LanderClient.firstLaunchReportedKey], '1');
      expect(platform.installReferrerCalls, 0, reason: 'iOS has no install referrer');
    });

    test('later launches reuse the install ID and report isFirstLaunch false', () async {
      final platform = FakePlatform();
      await started(client(platform, FakeApi()));
      final id = platform.storage[LanderClient.installIdKey];

      final api = FakeApi();
      await started(client(platform, api));
      final init = api.to('/v1/sdk/init').single;
      expect(init.body['installId'], id);
      expect(init.body['isFirstLaunch'], false);
    });

    test('a failed first launch report is retried on the next launch with the same key', () async {
      final platform = FakePlatform();
      final down = FakeApi(handlers: {'/v1/sdk/init': (r) => json({'error': {'code': 'internal', 'message': ''}}, 500)});
      await started(client(platform, down));
      expect(down.to('/v1/sdk/init'), hasLength(3), reason: 'first launch init is retried');
      expect(platform.storage[LanderClient.firstLaunchReportedKey], isNull);

      final up = FakeApi();
      await started(client(platform, up));
      final init = up.to('/v1/sdk/init').single;
      expect(init.body['isFirstLaunch'], true);
      expect(init.headers['Idempotency-Key'], down.requests.first.headers['Idempotency-Key']);
    });

    test('Android first launch sends the Play Install Referrer, only once', () async {
      final platform = FakePlatform(platform: 'android', installReferrer: 'utm_source=google-play&lander_token=abc');
      final api = FakeApi();
      await started(client(platform, api));
      expect(api.to('/v1/sdk/init').single.body['installReferrer'], 'utm_source=google-play&lander_token=abc');

      final api2 = FakeApi();
      await started(client(platform, api2));
      expect(api2.to('/v1/sdk/init').single.body.containsKey('installReferrer'), isFalse);
      expect(platform.installReferrerCalls, 1);
    });

    test('never throws when the network is down', () async {
      final api = FakeApi(handlers: {'/v1/sdk/init': (r) => throw http.ClientException('offline')});
      final c = client(FakePlatform(), api);
      await expectLater(started(c), completes);
      expect(await c.getInitialLink(), isNull);
    });

    test('a deferred link from init becomes the initial link', () async {
      final api = FakeApi(handlers: {
        '/v1/sdk/init': (r) => json({
              'installId': r.body['installId'],
              'deferredLink': {...resolvedP123, 'isDeferred': true, 'confidence': 'probabilistic'},
            }),
      });
      final c = client(FakePlatform(platform: 'android'), api);
      await started(c);
      final link = await c.getInitialLink();
      expect(link?.isDeferred, isTrue);
      expect(link?.path, '/product/123');
      expect(link?.confidence, LanderConfidence.probabilistic);
      expect(link?.uri.toString(), 'https://acme.lndr.link/p-123');
    });
  });

  group('resolve', () {
    test('a known link resolves to a LanderLink with its params', () async {
      final api = FakeApi(handlers: {'/v1/sdk/resolve': (r) => json(resolvedP123)});
      final c = client(FakePlatform(initialLink: 'https://acme.lndr.link/p-123?utm_source=x'), api);
      await started(c);

      final link = await c.getInitialLink();
      expect(link, isNotNull);
      expect(link!.isResolved, isTrue);
      expect(link.linkId, resolvedP123['linkId']);
      expect(link.path, '/product/123');
      expect(link.route, '/product/123');
      expect(link.params, {'productId': '123', 'utm_source': 'x'});
      expect(link.channel, 'share');
      expect(link.campaign, isNull);
      expect(link.isDeferred, isFalse);
      expect(link.confidence, LanderConfidence.deterministic);
      expect(link.uri.toString(), 'https://acme.lndr.link/p-123?utm_source=x');

      final resolve = api.to('/v1/sdk/resolve').single;
      expect(resolve.body, {'installId': c.installId, 'url': 'https://acme.lndr.link/p-123?utm_source=x'});
      expect(resolve.headers['Idempotency-Key'], isNotNull);
      expect(api.requests.first.path, '/v1/sdk/init', reason: 'init registers the install before resolve');
    });

    test('an unknown link (404) is still delivered with the raw Uri', () async {
      final api = FakeApi();
      final c = client(FakePlatform(initialLink: 'https://acme.example/products/9?ref=mail'), api);
      await started(c);

      final link = await c.getInitialLink();
      expect(link!.isResolved, isFalse);
      expect(link.uri.toString(), 'https://acme.example/products/9?ref=mail');
      expect(link.route, '/products/9?ref=mail');
      expect(link.params, isEmpty);
      expect(api.to('/v1/sdk/resolve'), hasLength(1), reason: '404 is not retried');
    });

    test('a network failure delivers the raw Uri instead of losing the link', () async {
      final api = FakeApi(handlers: {'/v1/sdk/resolve': (r) => throw http.ClientException('offline')});
      final c = client(FakePlatform(initialLink: 'https://acme.lndr.link/p-123'), api);
      await started(c);
      final link = await c.getInitialLink();
      expect(link!.isResolved, isFalse);
      expect(link.uri.path, '/p-123');
    });

    test('custom scheme URLs are delivered without a network call', () async {
      final api = FakeApi();
      final c = client(FakePlatform(initialLink: 'acmeshop://product/123?ref=qr'), api);
      await started(c);
      final link = await c.getInitialLink();
      expect(link!.route, '/product/123?ref=qr');
      expect(api.to('/v1/sdk/resolve'), isEmpty);
    });

    test('warm start links are resolved and delivered in arrival order', () async {
      final api = FakeApi(handlers: {
        '/v1/sdk/resolve': (r) async {
          final url = r.body['url'] as String;
          // The first link resolves slowly; order must still hold.
          if (url.endsWith('slow')) await Future<void>.delayed(const Duration(milliseconds: 20));
          return json({...resolvedP123, 'path': Uri.parse(url).path});
        },
      });
      final platform = FakePlatform();
      final c = client(platform, api);
      await started(c);

      final got = <String?>[];
      c.dispatcher.stream.listen((l) => got.add(l.path));
      platform.links.add('https://acme.lndr.link/slow');
      platform.links.add('https://acme.lndr.link/fast');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got, ['/slow', '/fast']);
    });

    test('the same URL reported twice in a row counts once', () async {
      final api = FakeApi();
      final platform = FakePlatform(initialLink: 'https://acme.lndr.link/p-123');
      final c = client(platform, api);
      await started(c);
      final got = <LanderLink>[];
      c.dispatcher.stream.listen(got.add);
      platform.links.add('https://acme.lndr.link/p-123');
      await pumpEventQueue();
      expect(got, hasLength(1), reason: 'the launch link, delivered once');
      expect(api.to('/v1/sdk/resolve'), hasLength(1));
    });
  });

  group('events', () {
    test('trackEvent queues, persists and sends a batch with client ids', () async {
      final platform = FakePlatform();
      final api = FakeApi();
      final c = client(platform, api);
      await started(c);

      await c.trackEvent('purchase', {'amount': 49.99, 'currency': 'USD'}, linkId: resolvedP123['linkId'] as String);
      await c.trackEvent('signup', {});
      await c.events.flush();

      final batches = api.to('/v1/sdk/events');
      expect(batches, isNotEmpty);
      final sent = [for (final b in batches) ...(b.body['events'] as List).cast<Map<String, Object?>>()];
      expect(sent.map((e) => e['name']), ['purchase', 'signup']);
      final e = sent.first;
      expect(e['type'], 'custom');
      expect(e['properties'], {'amount': 49.99, 'currency': 'USD'});
      expect(e['linkId'], resolvedP123['linkId']);
      expect(sent.last.containsKey('linkId'), isFalse);
      expect(Uuid.isValidUUID(fromString: e['id'] as String), isTrue);
      expect(DateTime.parse(e['occurredAt'] as String).isUtc, isTrue);
      expect(e['occurredAt'], matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$')));
      expect(batches.first.body['installId'], c.installId);
      expect(batches.first.headers['Idempotency-Key'], isNotNull);
      expect(jsonDecode(platform.storage[EventQueue.storageKey]!), isEmpty);
    });

    test('events tracked offline are sent on the next launch', () async {
      final platform = FakePlatform();
      final offline = FakeApi(handlers: {'/v1/sdk/events': (r) => throw http.ClientException('offline')});
      final c1 = client(platform, offline);
      await started(c1);
      await c1.trackEvent('purchase', {'amount': 1});
      await c1.events.flush();
      c1.dispose();
      expect(c1.events.pending, hasLength(1));
      final id = c1.events.pending.single['id'];

      final online = FakeApi();
      final c2 = client(platform, online);
      await started(c2);
      await c2.events.flush();
      final sent = online.to('/v1/sdk/events').expand((b) => b.body['events'] as List).toList();
      expect(sent.map((e) => (e as Map)['id']), [id]);
    });

    test('retries a failed batch with the same idempotency key', () async {
      var calls = 0;
      final api = FakeApi(handlers: {
        '/v1/sdk/events': (r) => ++calls == 1
            ? json({'error': {'code': 'internal', 'message': ''}}, 503)
            : json({'accepted': 1, 'duplicates': 0}, 202),
      });
      final c = client(FakePlatform(), api);
      await started(c);
      await c.trackEvent('purchase', {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sends = api.to('/v1/sdk/events');
      expect(sends, hasLength(2));
      expect(sends[0].headers['Idempotency-Key'], sends[1].headers['Idempotency-Key']);
      expect(sends[0].body['events'], sends[1].body['events']);
      expect(c.events.pending, isEmpty);
    });

    test('rejects invalid names and properties', () async {
      final c = client(FakePlatform(), FakeApi());
      await started(c);
      expect(() => c.trackEvent('', {}), throwsArgumentError);
      expect(() => c.trackEvent('x' * 101, {}), throwsArgumentError);
      expect(() => c.trackEvent('ok', {'when': DateTime(2026)}), throwsArgumentError);
      expect(() => c.trackEvent('ok', {}, linkId: 'p-123'), throwsArgumentError);
    });
  });

  group('registration', () {
    test('install_id_conflict creates a new install ID and reports a first launch', () async {
      final platform = FakePlatform(storage: {
        LanderClient.installIdKey: '11111111-2222-4333-8444-555555555555',
        LanderClient.firstLaunchReportedKey: '1',
      });
      final api = FakeApi(handlers: {
        '/v1/sdk/init': (r) => r.body['installId'] == '11111111-2222-4333-8444-555555555555'
            ? json({'error': {'code': 'install_id_conflict', 'message': 'Taken'}}, 409)
            : json({'installId': r.body['installId'], 'deferredLink': null}),
      });
      final c = client(platform, api);
      await started(c);
      await pumpEventQueue();

      final inits = api.to('/v1/sdk/init');
      expect(inits, hasLength(2));
      expect(inits[1].body['isFirstLaunch'], true);
      expect(c.installId, isNot('11111111-2222-4333-8444-555555555555'));
      expect(platform.storage[LanderClient.installIdKey], c.installId);
      expect(platform.storage[LanderClient.firstLaunchReportedKey], '1');
    });

    test('events wait for a successful init instead of being dropped', () async {
      var initUp = false;
      final api = FakeApi(handlers: {
        '/v1/sdk/init': (r) => initUp
            ? json({'installId': r.body['installId'], 'deferredLink': null})
            : json({'error': {'code': 'internal_error', 'message': ''}}, 500),
      });
      final platform = FakePlatform();
      final c1 = client(platform, api);
      await started(c1);
      await c1.trackEvent('purchase', {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(api.to('/v1/sdk/events'), isEmpty, reason: 'install not registered yet');
      expect(c1.events.pending, hasLength(1));
      c1.dispose();

      initUp = true;
      final c2 = client(platform, api);
      await started(c2);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(api.to('/v1/sdk/events'), hasLength(1));
      expect(c2.events.pending, isEmpty);
    });

    test('install_not_found on events registers the install again and keeps the events', () async {
      var known = false;
      final api = FakeApi(handlers: {
        '/v1/sdk/init': (r) {
          known = r.body['isFirstLaunch'] == true;
          return json({'installId': r.body['installId'], 'deferredLink': null});
        },
        '/v1/sdk/events': (r) => known
            ? json({'accepted': 1, 'duplicates': 0}, 202)
            : json({'error': {'code': 'install_not_found', 'message': ''}}, 404),
      });
      // Looks registered locally, but the API forgot it (database reset).
      final platform = FakePlatform(storage: {LanderClient.firstLaunchReportedKey: '1'});
      final c = client(platform, api);
      await started(c);
      await c.trackEvent('purchase', {});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(api.to('/v1/sdk/init').last.body['isFirstLaunch'], true);
      expect(api.to('/v1/sdk/events').length, greaterThanOrEqualTo(2));
      expect(c.events.pending, isEmpty);
    });
  });

  group('createLink', () {
    test('posts to /v1/sdk/links and parses the link', () async {
      final api = FakeApi(handlers: {
        '/v1/sdk/links': (r) => json({
              'id': '0d6f1a7e-1111-4222-8333-944445555666',
              'url': 'https://acme.lndr.link/x7Kp2Qa',
              'domain': 'acme.lndr.link',
              'slug': 'x7Kp2Qa',
              'title': null,
              'deepLinkPath': r.body['deepLinkPath'],
              'params': r.body['params'],
              'campaign': null,
              'channel': 'share',
              'tags': <String>[],
              'expiresAt': null,
              'enabled': true,
              'createdAt': '2026-10-15T10:00:00Z',
              'updatedAt': '2026-10-15T10:00:00Z',
            }, 201),
      });
      final c = client(FakePlatform(), api);
      await started(c);
      final link = await c.createLink({'deepLinkPath': '/product/123', 'params': {'productId': '123'}, 'channel': 'share'});

      expect(link.url.toString(), 'https://acme.lndr.link/x7Kp2Qa');
      expect(link.path, '/product/123');
      expect(link.params, {'productId': '123'});
      expect(link.createdAt, DateTime.utc(2026, 10, 15, 10));
      final req = api.to('/v1/sdk/links').single;
      expect(req.headers['Idempotency-Key'], isNotNull);
      expect(req.body['installId'], c.installId);
    });

    test('throws LanderException on failure after retrying with one key', () async {
      final api = FakeApi(handlers: {'/v1/sdk/links': (r) => json({'error': {'code': 'internal', 'message': 'x'}}, 500)});
      final c = client(FakePlatform(), api);
      await started(c);
      await expectLater(c.createLink({'deepLinkPath': '/'}), throwsA(isA<LanderException>()));
      final reqs = api.to('/v1/sdk/links');
      expect(reqs, hasLength(3));
      expect(reqs.map((r) => r.headers['Idempotency-Key']).toSet(), hasLength(1));
    });
  });

  test('flushes events when the app goes to the background', () async {
    final api = FakeApi(handlers: {'/v1/sdk/events': (r) => json({'accepted': 1, 'duplicates': 0}, 202)});
    final c = LanderClient(
      apiKey: 'pk_test_x',
      baseUrl: 'http://localhost:8787',
      dispatcher: LinkDispatcher(),
      platform: FakePlatform(),
      httpClient: api.client,
      flushDelay: const Duration(hours: 1),
    );
    _clients.add(c);
    await started(c);
    await c.trackEvent('purchase', {});
    await pumpEventQueue();
    expect(api.to('/v1/sdk/events'), isEmpty);

    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    await pumpEventQueue();
    expect(api.to('/v1/sdk/events'), hasLength(1));
  });
}
