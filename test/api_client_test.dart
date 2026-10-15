import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lander_flutter/lander_flutter.dart';
import 'package:lander_flutter/src/api_client.dart';
import 'package:lander_flutter/src/logger.dart';

import 'fakes.dart';

LanderApi api(http.Client client, {Duration timeout = const Duration(seconds: 10)}) => LanderApi(
      apiKey: 'pk_test_DemoPublishableKey000000000000',
      baseUrl: 'http://localhost:8787/',
      client: client,
      logger: LanderLogger(enabled: false),
      timeout: timeout,
      backoff: const Backoff(base: Duration(milliseconds: 100), jitter: 0),
    );

void main() {
  test('sends auth, JSON and idempotency headers to the joined URL', () async {
    final fake = FakeApi(handlers: {'/v1/sdk/init': (r) => json({'ok': true})});
    final res = await api(fake.client).post('/v1/sdk/init', {'a': 1}, idempotencyKey: 'key-1');

    expect(res, {'ok': true});
    final r = fake.requests.single;
    expect(r.request.url.toString(), 'http://localhost:8787/v1/sdk/init');
    expect(r.headers['Authorization'], 'Bearer pk_test_DemoPublishableKey000000000000');
    expect(r.headers['Content-Type'], startsWith('application/json'));
    expect(r.headers['Idempotency-Key'], 'key-1');
    expect(r.headers['X-Lander-Sdk'], 'flutter/$landerSdkVersion');
    expect(r.body, {'a': 1});
  });

  test('omits the Idempotency-Key header when none is given', () async {
    final fake = FakeApi(handlers: {'/x': (r) => json({})});
    await api(fake.client).post('/x', {});
    expect(fake.requests.single.headers.containsKey('Idempotency-Key'), isFalse);
  });

  test('maps API errors to LanderException', () async {
    final fake = FakeApi(handlers: {
      '/x': (r) => json({'error': {'code': 'rate_limited', 'message': 'Slow down'}}, 429, {'retry-after': '7'}),
    });
    await expectLater(
      api(fake.client).post('/x', {}),
      throwsA(isA<LanderException>()
          .having((e) => e.code, 'code', 'rate_limited')
          .having((e) => e.statusCode, 'statusCode', 429)
          .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 7))
          .having((e) => e.isRetryable, 'isRetryable', isTrue)),
    );
  });

  test('a 404 is not retryable and keeps the API error code', () async {
    final fake = FakeApi();
    await expectLater(
      api(fake.client).post('/v1/sdk/resolve', {'url': 'x'}, maxAttempts: 3),
      throwsA(isA<LanderException>()
          .having((e) => e.code, 'code', 'link_not_found')
          .having((e) => e.isRetryable, 'isRetryable', isFalse)),
    );
    expect(fake.requests, hasLength(1));
  });

  test('network errors become network_error, never a raw exception', () async {
    final client = MockClient((_) => throw http.ClientException('offline'));
    await expectLater(
      api(client).post('/x', {}),
      throwsA(isA<LanderException>().having((e) => e.code, 'code', 'network_error')),
    );
  });

  test('times out slow requests', () {
    fakeAsync((async) {
      final client = MockClient((_) => Completer<http.Response>().future);
      Object? error;
      api(client, timeout: const Duration(seconds: 3)).post('/x', {}).catchError((Object e) {
        error = e;
        return <String, Object?>{};
      });
      async.elapse(const Duration(seconds: 2));
      expect(error, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(error, isA<LanderException>().having((e) => e.code, 'code', 'timeout'));
    });
  });

  test('retries retryable failures with the same idempotency key', () {
    fakeAsync((async) {
      var calls = 0;
      final fake = FakeApi(handlers: {
        '/x': (r) => ++calls < 3 ? json({'error': {'code': 'internal', 'message': 'boom'}}, 503) : json({'ok': 1}),
      });
      Map<String, Object?>? result;
      api(fake.client).post('/x', {}, idempotencyKey: 'same', maxAttempts: 3).then((r) => result = r);
      async.flushMicrotasks();
      expect(fake.requests, hasLength(1));
      async.elapse(const Duration(milliseconds: 100)); // backoff 0
      expect(fake.requests, hasLength(2));
      async.elapse(const Duration(milliseconds: 200)); // backoff 1
      expect(result, {'ok': 1});
      expect(fake.requests.map((r) => r.headers['Idempotency-Key']), everyElement('same'));
    });
  });

  group('Backoff', () {
    test('doubles and caps', () {
      const b = Backoff(base: Duration(seconds: 1), max: Duration(seconds: 10), jitter: 0);
      expect([for (var i = 0; i < 6; i++) b.delay(i).inSeconds], [1, 2, 4, 8, 10, 10]);
    });

    test('jitter stays within bounds', () {
      const b = Backoff(base: Duration(seconds: 10), jitter: 0.5);
      for (var i = 0; i < 50; i++) {
        final d = b.delay(0).inMilliseconds;
        expect(d, inInclusiveRange(5000, 10000));
      }
    });
  });
}
