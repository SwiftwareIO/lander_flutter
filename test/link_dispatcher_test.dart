import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lander_flutter/lander_flutter.dart';
import 'package:lander_flutter/src/link_dispatcher.dart';

LanderLink link(String path) => LanderLink.unresolved(Uri.parse('https://acme.lndr.link$path'));

void main() {
  test('buffers links until the first listener, then replays them in order', () async {
    final d = LinkDispatcher();
    d.add(link('/a'));
    d.add(link('/b'));

    final got = <String>[];
    d.stream.listen((l) => got.add(l.uri.path));
    d.add(link('/c'));
    await pumpEventQueue();
    expect(got, ['/a', '/b', '/c']);
  });

  test('buffers again while nobody listens', () async {
    final d = LinkDispatcher();
    final first = <String>[];
    final sub = d.stream.listen((l) => first.add(l.uri.path));
    d.add(link('/a'));
    await pumpEventQueue();
    await sub.cancel();

    d.add(link('/b'));
    final second = <String>[];
    d.stream.listen((l) => second.add(l.uri.path));
    await pumpEventQueue();
    expect(first, ['/a']);
    expect(second, ['/b']);
  });

  test('launch link goes to the stream when getInitialLink is never called', () async {
    final d = LinkDispatcher();
    d.setInitialLink(link('/launch'));
    final got = <String>[];
    d.stream.listen((l) => got.add(l.uri.path));
    await pumpEventQueue();
    expect(got, ['/launch']);
    expect(await d.takeInitialLink(), isNull, reason: 'already delivered on the stream');
  });

  test('getInitialLink claims the launch link so the stream skips it', () async {
    final d = LinkDispatcher();
    final got = <String>[];
    final initial = d.takeInitialLink();
    d.stream.listen((l) => got.add(l.uri.path));
    d.setInitialLink(link('/launch'));
    d.add(link('/later'));
    expect((await initial)?.uri.path, '/launch');
    await pumpEventQueue();
    expect(got, ['/later']);
  });

  test('getInitialLink removes a buffered launch link', () async {
    final d = LinkDispatcher();
    d.setInitialLink(link('/launch'));
    d.add(link('/later'));
    expect((await d.takeInitialLink())?.uri.path, '/launch');
    expect((await d.takeInitialLink())?.uri.path, '/launch', reason: 'stable for repeated calls');

    final got = <String>[];
    d.stream.listen((l) => got.add(l.uri.path));
    await pumpEventQueue();
    expect(got, ['/later']);
  });

  test('getInitialLink waits until the launch link is known', () async {
    final d = LinkDispatcher();
    LanderLink? result;
    var done = false;
    unawaited(d.takeInitialLink().then((l) {
      result = l;
      done = true;
    }));
    await pumpEventQueue();
    expect(done, isFalse);
    d.setInitialLink(null);
    await pumpEventQueue();
    expect(done, isTrue);
    expect(result, isNull);
  });

  test('a second setInitialLink is delivered as a normal link', () async {
    final d = LinkDispatcher();
    d.setInitialLink(null);
    d.setInitialLink(link('/deferred'));
    final got = <String>[];
    d.stream.listen((l) => got.add(l.uri.path));
    await pumpEventQueue();
    expect(got, ['/deferred']);
  });

  test('multiple listeners all receive live links', () async {
    final d = LinkDispatcher();
    final a = <String>[];
    final b = <String>[];
    d.stream.listen((l) => a.add(l.uri.path));
    d.stream.listen((l) => b.add(l.uri.path));
    d.add(link('/x'));
    await pumpEventQueue();
    expect(a, ['/x']);
    expect(b, ['/x']);
  });
}
