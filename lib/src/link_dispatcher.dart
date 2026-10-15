import 'dart:async';

import 'models.dart';

/// Delivers links to the app without losing or doubling any.
///
/// * Links that arrive while nobody listens to [stream] are buffered and
///   replayed, in order, to the next listener. This covers cold starts and
///   links that arrive before the router is ready.
/// * The link that launched the app is delivered exactly once: through
///   [takeInitialLink] when the app asks for it before the stream delivered it,
///   otherwise through [stream].
class LinkDispatcher {
  LinkDispatcher() {
    _controller = StreamController<LanderLink>.broadcast(onListen: _drain);
  }

  late final StreamController<LanderLink> _controller;
  final List<_Pending> _buffer = [];
  final Completer<LanderLink?> _initial = Completer();
  bool _initialRequested = false;
  bool _initialOnStream = false;

  Stream<LanderLink> get stream => _controller.stream;

  /// Whether the launch link is known (it may be null).
  bool get initialSettled => _initial.isCompleted;

  /// Sets the link that launched the app. Only the first call counts.
  void setInitialLink(LanderLink? link) {
    if (_initial.isCompleted) {
      if (link != null) add(link);
      return;
    }
    _initial.complete(link);
    if (link == null || _initialRequested) return;
    _emit(_Pending(link, initial: true));
  }

  /// Delivers a link that arrived while the app was running.
  void add(LanderLink link) => _emit(_Pending(link));

  /// Returns the launch link unless the stream already delivered it.
  Future<LanderLink?> takeInitialLink() async {
    _initialRequested = true;
    final link = await _initial.future;
    if (_initialOnStream) return null;
    _buffer.removeWhere((p) => p.initial);
    return link;
  }

  void _emit(_Pending pending) {
    if (_controller.hasListener && _buffer.isEmpty) {
      _deliver(pending);
    } else {
      _buffer.add(pending);
      if (_controller.hasListener) _drain();
    }
  }

  void _drain() {
    while (_buffer.isNotEmpty && _controller.hasListener) {
      _deliver(_buffer.removeAt(0));
    }
  }

  void _deliver(_Pending pending) {
    if (pending.initial) {
      if (_initialRequested) return;
      _initialOnStream = true;
    }
    _controller.add(pending.link);
  }

  Future<void> close() => _controller.close();
}

class _Pending {
  _Pending(this.link, {this.initial = false});

  final LanderLink link;
  final bool initial;
}
