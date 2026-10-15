import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lander_flutter/lander_flutter.dart';
import 'package:lander_flutter/src/api_client.dart';
import 'package:lander_flutter/src/event_queue.dart';
import 'package:lander_flutter/src/logger.dart';

Map<String, Object?> event(String id) => {
      'id': id,
      'type': 'custom',
      'name': 'purchase',
      'properties': <String, Object?>{},
      'occurredAt': '2026-10-15T10:00:00.000Z',
    };

class Harness {
  Harness({Map<String, String>? storage, this.failWith}) : storage = storage ?? {};

  final Map<String, String> storage;
  final List<List<String>> batches = [];
  LanderException? Function(int call)? failWith;

  EventQueue queue({int batchSize = 100, int maxQueueSize = 1000}) => EventQueue(
        read: (k) async => storage[k],
        write: (k, v) async => storage[k] = v,
        sender: (events) async {
          batches.add([for (final e in events) e['id'] as String]);
          final error = failWith?.call(batches.length);
          if (error != null) throw error;
        },
        logger: LanderLogger(enabled: false),
        batchSize: batchSize,
        maxQueueSize: maxQueueSize,
        flushDelay: const Duration(seconds: 2),
        backoff: const Backoff(base: Duration(seconds: 1), max: Duration(seconds: 30), jitter: 0),
      );

  List<String> get persistedIds => storage[EventQueue.storageKey] == null
      ? []
      : [for (final e in jsonDecode(storage[EventQueue.storageKey]!) as List) (e as Map)['id'] as String];
}

const serverError = LanderException(code: 'internal', message: 'boom', statusCode: 503);

void main() {
  test('batches queued events after the flush delay', () {
    fakeAsync((async) {
      final h = Harness();
      final q = h.queue(batchSize: 100);
      for (var i = 0; i < 250; i++) {
        q.add(event('e$i'));
      }
      async.flushMicrotasks();
      expect(h.batches, isEmpty, reason: 'waits for the flush delay');
      expect(h.persistedIds, hasLength(250), reason: 'persisted before sending');

      async.elapse(const Duration(seconds: 2));
      expect(h.batches.map((b) => b.length), [100, 100, 50]);
      expect(h.batches.expand((b) => b), [for (var i = 0; i < 250; i++) 'e$i']);
      expect(q.pending, isEmpty);
      expect(h.persistedIds, isEmpty);
    });
  });

  test('deduplicates events by id', () {
    fakeAsync((async) {
      final h = Harness();
      final q = h.queue();
      q.add(event('a'));
      q.add(event('a'));
      q.add(event('b'));
      async.flushMicrotasks();
      expect(q.pending.map((e) => e['id']), ['a', 'b']);
      async.elapse(const Duration(seconds: 2));
      expect(h.batches, [
        ['a', 'b'],
      ]);
    });
  });

  test('retries with exponential backoff and keeps events until accepted', () {
    fakeAsync((async) {
      final h = Harness(failWith: (call) => call <= 3 ? serverError : null);
      final q = h.queue();
      q.add(event('a'));
      async.elapse(const Duration(seconds: 2));
      expect(h.batches, hasLength(1));
      expect(h.persistedIds, ['a'], reason: 'kept after a failure');

      async.elapse(const Duration(milliseconds: 999));
      expect(h.batches, hasLength(1));
      async.elapse(const Duration(milliseconds: 1)); // 1s
      expect(h.batches, hasLength(2));
      async.elapse(const Duration(seconds: 2)); // 2s
      expect(h.batches, hasLength(3));

      // A new event during backoff does not cut the backoff short.
      q.add(event('b'));
      async.elapse(const Duration(seconds: 3));
      expect(h.batches, hasLength(3));
      async.elapse(const Duration(seconds: 1)); // 4s
      expect(h.batches, hasLength(4));
      expect(h.batches.last, ['a', 'b']);
      expect(h.batches.map((b) => b.first), everyElement('a'), reason: 'same ids on every retry');
      expect(q.pending, isEmpty);
      expect(h.persistedIds, isEmpty);
    });
  });

  test('honors Retry-After when it is longer than the backoff', () {
    fakeAsync((async) {
      final h = Harness(
        failWith: (call) => call == 1
            ? const LanderException(code: 'rate_limited', message: '', statusCode: 429, retryAfter: Duration(seconds: 20))
            : null,
      );
      h.queue().add(event('a'));
      async.elapse(const Duration(seconds: 2));
      async.elapse(const Duration(seconds: 19));
      expect(h.batches, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(h.batches, hasLength(2));
    });
  });

  test('drops a batch the API rejects as invalid instead of blocking the queue', () {
    fakeAsync((async) {
      final h = Harness(
        failWith: (call) => call == 1 ? const LanderException(code: 'validation_error', message: '', statusCode: 400) : null,
      );
      final q = h.queue(batchSize: 1);
      q.add(event('bad'));
      q.add(event('good'));
      async.elapse(const Duration(seconds: 2));
      expect(h.batches, [
        ['bad'],
        ['good'],
      ]);
      expect(q.pending, isEmpty);
    });
  });

  test('pauses on an auth error and keeps events for the next launch', () {
    fakeAsync((async) {
      final h = Harness(failWith: (_) => const LanderException(code: 'invalid_key', message: '', statusCode: 401));
      final q = h.queue();
      q.add(event('a'));
      async.elapse(const Duration(minutes: 10));
      expect(h.batches, hasLength(1));
      expect(h.persistedIds, ['a']);
    });
  });

  test('persists across restarts and does not resend accepted events', () {
    fakeAsync((async) {
      final storage = <String, String>{};
      final offline = Harness(storage: storage, failWith: (_) => serverError);
      final q1 = offline.queue();
      q1.add(event('a'));
      q1.add(event('b'));
      async.elapse(const Duration(seconds: 2));
      q1.dispose();
      expect(offline.persistedIds, ['a', 'b']);

      // Next launch, back online.
      final online = Harness(storage: storage);
      final q2 = online.queue();
      q2.load();
      async.flushMicrotasks();
      expect(q2.pending.map((e) => e['id']), ['a', 'b']);
      q2.add(event('a')); // already queued: ignored
      q2.add(event('c'));
      q2.flush();
      async.flushMicrotasks();
      expect(online.batches, [
        ['a', 'b', 'c'],
      ]);
      expect(online.persistedIds, isEmpty);
    });
  });

  test('drops the oldest events beyond maxQueueSize', () {
    fakeAsync((async) {
      final h = Harness(failWith: (_) => serverError);
      final q = h.queue(maxQueueSize: 3);
      for (final id in ['a', 'b', 'c', 'd', 'e']) {
        q.add(event(id));
      }
      async.flushMicrotasks();
      expect(q.pending.map((e) => e['id']), ['c', 'd', 'e']);
    });
  });

  test('concurrent flushes share one request', () {
    fakeAsync((async) {
      final h = Harness();
      final q = h.queue();
      q.add(event('a'));
      async.flushMicrotasks();
      q.flush();
      q.flush();
      async.flushMicrotasks();
      expect(h.batches, hasLength(1));
    });
  });

  test('survives corrupt persisted data', () {
    fakeAsync((async) {
      final h = Harness(storage: {EventQueue.storageKey: '{not json'});
      final q = h.queue();
      q.add(event('a'));
      async.flushMicrotasks();
      expect(q.pending.map((e) => e['id']), ['a']);
    });
  });
}
