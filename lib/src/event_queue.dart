import 'dart:async';
import 'dart:convert';

import 'api_client.dart';
import 'logger.dart';
import 'models.dart';

/// Sends one batch. Throws [LanderException] on failure.
typedef EventBatchSender = Future<void> Function(List<Map<String, Object?>> events);

/// Persistent, deduplicating event queue.
///
/// Events are stored before they are sent, sent in batches of up to
/// [batchSize], and removed only after the API accepts them. Retryable failures
/// back off exponentially; events keep their client generated `id`, so a batch
/// that is re-sent after a lost response is deduplicated by the API.
class EventQueue {
  EventQueue({
    required this.read,
    required this.write,
    required this.sender,
    required this.logger,
    this.batchSize = 100,
    this.maxQueueSize = 1000,
    this.flushDelay = const Duration(seconds: 2),
    this.backoff = const Backoff(),
  });

  static const storageKey = 'event_queue';

  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String value) write;
  final EventBatchSender sender;
  final LanderLogger logger;
  final int batchSize;

  /// Oldest events are dropped beyond this size so a long offline period
  /// cannot grow storage without bound.
  final int maxQueueSize;

  /// Delay between an [add] and the flush it schedules, so bursts of events
  /// go out as one batch.
  final Duration flushDelay;
  final Backoff backoff;

  final List<Map<String, Object?>> _events = [];
  final Set<String> _ids = {};
  late final Future<void> _loaded = _load();
  Future<void> _writeChain = Future.value();
  Future<void>? _flushing;
  Timer? _timer;
  int _failures = 0;
  bool _halted = false;
  bool _disposed = false;

  /// Events waiting to be sent, oldest first.
  List<Map<String, Object?>> get pending => List.unmodifiable(_events);

  /// Loads the persisted queue. Safe to call more than once.
  Future<void> load() => _loaded;

  Future<void> _load() async {
    try {
      final raw = await read(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final e in decoded) {
        if (e is Map<String, Object?> && e['id'] is String) _insert(e);
      }
      logger.log('Loaded ${_events.length} queued events');
    } catch (e) {
      logger.log('Could not load the event queue, starting empty: $e');
    }
  }

  /// Adds [event] (which must have a unique `id`) and schedules a flush.
  /// Events with an `id` that is already queued are ignored.
  Future<void> add(Map<String, Object?> event) async {
    await _loaded;
    if (!_insert(event)) return;
    while (_events.length > maxQueueSize) {
      _ids.remove(_events.removeAt(0)['id']);
    }
    await _persist();
    _schedule(flushDelay);
  }

  bool _insert(Map<String, Object?> event) {
    final id = event['id'] as String;
    if (!_ids.add(id)) return false;
    _events.add(event);
    return true;
  }

  /// Sends everything that is queued now. Concurrent calls share one flush.
  Future<void> flush() => _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<void> _flush() async {
    await _loaded;
    _timer?.cancel();
    _timer = null;
    while (_events.isNotEmpty && !_halted && !_disposed) {
      final batch = _events.take(batchSize).toList();
      try {
        await sender(batch);
        _failures = 0;
        _remove(batch);
        logger.log('Sent ${batch.length} events');
      } on LanderException catch (e) {
        if (e.isRetryable) {
          var wait = backoff.delay(_failures++);
          final retryAfter = e.retryAfter;
          if (retryAfter != null && retryAfter > wait) wait = retryAfter;
          logger.log('Event batch failed (${e.code}), retrying in ${wait.inSeconds}s');
          _schedule(wait, retry: true);
          return;
        }
        if (e.statusCode == 401 || e.statusCode == 403) {
          // A bad key will not fix itself. Keep the events for the next launch.
          logger.log('Event batch rejected (${e.code}): check the API key. Pausing until next launch.');
          _halted = true;
          return;
        }
        // Validation errors: the batch will never be accepted, drop it so it
        // does not block the queue forever.
        logger.log('Dropping ${batch.length} events rejected by the API (${e.code}): ${e.message}');
        _remove(batch);
      } catch (e) {
        logger.log('Event batch failed unexpectedly: $e');
        _schedule(backoff.delay(_failures++), retry: true);
        return;
      } finally {
        await _persist();
      }
    }
  }

  void _remove(List<Map<String, Object?>> batch) {
    final sent = {for (final e in batch) e['id']};
    _events.removeWhere((e) => sent.contains(e['id']));
    _ids.removeAll(sent);
  }

  /// Schedules a flush. A pending timer (a scheduled flush or a backoff) is
  /// kept, so new events never cut a backoff short; a [retry] replaces it.
  void _schedule(Duration delay, {bool retry = false}) {
    if (_disposed || _halted) return;
    if (_timer != null && !retry) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  Future<void> _persist() {
    final snapshot = jsonEncode(_events);
    return _writeChain = _writeChain.then((_) => write(storageKey, snapshot)).catchError((Object e) {
      logger.log('Could not persist the event queue: $e');
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
