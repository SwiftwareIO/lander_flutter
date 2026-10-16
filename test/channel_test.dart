import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lander_flutter/lander_flutter.dart';
import 'package:lander_flutter/src/platform.dart';

import 'fakes.dart';

/// Fakes the native plugin behind the real method and event channels: it
/// holds a launch link and buffers warm start links until Dart listens, like
/// the Kotlin and Swift code does.
class FakeNative {
  FakeNative({this.initialLink, List<String> queuedBeforeListen = const []})
      : _queued = [...queuedBeforeListen];

  String? initialLink;
  final List<String> _queued;
  final Map<String, String> storage = {};
  final List<MethodCall> calls = [];
  MockStreamHandlerEventSink? _sink;

  void install() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(MethodChannelLanderPlatform.methods, (call) async {
      calls.add(call);
      final args = (call.arguments as Map?)?.cast<String, Object?>();
      switch (call.method) {
        case 'getInitialLink':
          final link = initialLink;
          initialLink = null;
          return link;
        case 'getPlatformInfo':
          return {'platform': 'ios', 'appVersion': '1.0.0', 'osVersion': '18.1'};
        case 'getInstallReferrer':
          return null;
        case 'storageRead':
          return storage[args!['key']];
        case 'storageWrite':
          storage[args!['key'] as String] = args['value'] as String;
          return null;
        case 'storageDelete':
          storage.remove(args!['key']);
          return null;
      }
      throw MissingPluginException();
    });
    messenger.setMockStreamHandler(
      MethodChannelLanderPlatform.links,
      MockStreamHandler.inline(
        onListen: (args, sink) {
          _sink = sink;
          for (final link in _queued) {
            sink.success(link);
          }
          _queued.clear();
        },
        onCancel: (args) => _sink = null,
      ),
    );
  }

  /// A link arriving while the app runs (onNewIntent / continueUserActivity).
  void open(String link) {
    final sink = _sink;
    if (sink == null) {
      _queued.add(link);
    } else {
      sink.success(link);
    }
  }

  void uninstall() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(MethodChannelLanderPlatform.methods, null);
    messenger.setMockStreamHandler(MethodChannelLanderPlatform.links, null);
  }
}

FakeApi resolvingApi() => FakeApi(handlers: {
      '/v1/sdk/resolve': (r) {
        final uri = Uri.parse(r.body['url'] as String);
        if (uri.host != 'acme.golander.link') {
          return json({'error': {'code': 'link_not_found', 'message': ''}}, 404);
        }
        final id = uri.pathSegments.single.replaceFirst('p-', '');
        return json({...resolvedP123, 'path': '/product/$id', 'params': {'productId': id}});
      },
    });

/// Stand in for an app whose router subscribes some time after startup.
class LateRouterApp extends StatefulWidget {
  const LateRouterApp({super.key, required this.ready});

  final Future<void> ready;

  @override
  State<LateRouterApp> createState() => _LateRouterAppState();
}

class _LateRouterAppState extends State<LateRouterApp> {
  final List<String> routes = [];
  StreamSubscription<LanderLink>? sub;

  @override
  void initState() {
    super.initState();
    widget.ready.then((_) {
      sub = Lander.onDeepLink.listen((link) => setState(() => routes.add(link.route)));
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Column(children: [for (final r in routes) Text('route:$r')]),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNative native;

  tearDown(() async {
    Lander.debugReset();
    native.uninstall();
    LanderPlatform.instance = MethodChannelLanderPlatform();
  });

  group('MethodChannelLanderPlatform', () {
    test('talks to the native methods and storage', () async {
      native = FakeNative(initialLink: 'https://acme.golander.link/p-1')..install();
      final platform = MethodChannelLanderPlatform();

      expect(await platform.getInitialLink(), 'https://acme.golander.link/p-1');
      expect(await platform.getInitialLink(), isNull, reason: 'the native side hands it out once');
      final info = await platform.getPlatformInfo();
      expect(info.platform, 'ios');
      expect(info.appVersion, '1.0.0');
      await platform.write('install_id', 'abc');
      expect(await platform.read('install_id'), 'abc');
      await platform.delete('install_id');
      expect(await platform.read('install_id'), isNull);
      expect(native.calls.map((c) => c.method), contains('storageWrite'));
    });

    test('receives links the native side buffered before Dart listened', () async {
      native = FakeNative(queuedBeforeListen: ['https://acme.golander.link/p-1'])..install();
      final got = <String>[];
      final sub = MethodChannelLanderPlatform().linkStream.listen(got.add);
      native.open('https://acme.golander.link/p-2');
      await pumpEventQueue();
      expect(got, ['https://acme.golander.link/p-1', 'https://acme.golander.link/p-2']);
      await sub.cancel();
    });
  });

  group('Lander', () {
    testWidgets('links that arrive before the router subscribes are buffered, not lost', (tester) async {
      native = FakeNative(
        initialLink: 'https://acme.golander.link/p-1',
        queuedBeforeListen: ['https://acme.golander.link/p-2'],
      )..install();
      final api = resolvingApi();
      Lander.debugHttpClient = api.client;
      final routerReady = Completer<void>();

      await Lander.initialize(apiKey: 'pk_test_DemoPublishableKey000000000000', baseUrl: 'http://localhost:8787');
      await tester.pumpWidget(LateRouterApp(ready: routerReady.future));
      // Links resolve while nobody listens yet.
      await tester.pumpAndSettle();
      native.open('https://other.example/promo');
      await tester.pumpAndSettle();
      expect(find.textContaining('route:'), findsNothing);

      routerReady.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<Text>(find.textContaining('route:')).map((t) => t.data),
        ['route:/product/1', 'route:/product/2', 'route:/promo'],
      );

      native.open('acmeshop://product/3');
      await tester.pumpAndSettle();
      expect(find.text('route:/product/3'), findsOneWidget);
      expect(api.to('/v1/sdk/resolve'), hasLength(3), reason: 'custom scheme links are not resolved');
    });

    test('getInitialLink claims the launch link; the stream gets the rest', () async {
      native = FakeNative(initialLink: 'https://acme.golander.link/p-7')..install();
      Lander.debugHttpClient = resolvingApi().client;
      await Lander.initialize(apiKey: 'pk_test_DemoPublishableKey000000000000', baseUrl: 'http://localhost:8787');

      final initial = Lander.getInitialLink();
      final streamed = <String>[];
      final sub = Lander.onDeepLink.listen((l) => streamed.add(l.route));
      native.open('https://acme.golander.link/p-8');

      final link = await initial;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(link?.route, '/product/7');
      expect(link?.params, {'productId': '7'});
      expect(streamed, ['/product/8']);
      await sub.cancel();
    });

    test('onDeepLink can be listened to before initialize', () async {
      native = FakeNative(initialLink: 'https://acme.golander.link/p-5')..install();
      Lander.debugHttpClient = resolvingApi().client;
      final got = <String>[];
      final sub = Lander.onDeepLink.listen((l) => got.add(l.route));
      await Lander.initialize(apiKey: 'pk_test_DemoPublishableKey000000000000');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got, ['/product/5']);
      await sub.cancel();
    });

    test('rejects secret keys and calls before initialize, through the Future', () async {
      native = FakeNative()..install();
      // Calling never throws synchronously; the error is in the Future.
      final calls = [Lander.trackEvent('x'), Lander.claimHandoff('user_1'), Lander.getInitialLink(), Lander.createLink()];
      for (final call in calls) {
        await expectLater(call, throwsStateError);
      }
      await expectLater(Lander.initialize(apiKey: 'sk_test_DemoSecretKey00000000000000000'), throwsArgumentError);
      await expectLater(Lander.initialize(apiKey: 'nope'), throwsArgumentError);
    });

    test('a malformed key is rejected without echoing it', () async {
      native = FakeNative()..install();
      for (final key in [
        'Bearer sk_live_SecretSecretSecretSecret0000',
        ' sk_test_SecretSecretSecretSecret0000',
        'Bearer pk_live_DemoPublishableKey000000000000',
        'pk_live_Demo Publishable Key000000000000',
        'pk_prod_DemoPublishableKey000000000000',
      ]) {
        Object? error;
        try {
          await Lander.initialize(apiKey: key);
        } catch (e) {
          error = e;
        }
        expect(error, isArgumentError, reason: key);
        expect('$error', isNot(contains('Secret')), reason: key);
        expect('$error', isNot(contains('DemoPublishable')), reason: key);
      }
    });

    test('a key with surrounding whitespace is trimmed', () async {
      native = FakeNative()..install();
      final api = resolvingApi();
      Lander.debugHttpClient = api.client;
      await Lander.initialize(apiKey: ' pk_test_DemoPublishableKey000000000000\n');
      await Lander.debugClient!.initDone;
      expect(api.to('/v1/sdk/init').single.headers['Authorization'], 'Bearer pk_test_DemoPublishableKey000000000000');
    });

    test('createLink validates its arguments', () async {
      native = FakeNative()..install();
      Lander.debugHttpClient = resolvingApi().client;
      await Lander.initialize(apiKey: 'pk_test_DemoPublishableKey000000000000');
      await expectLater(Lander.createLink(path: 'no-slash'), throwsArgumentError);
      await expectLater(Lander.createLink(params: {'when': DateTime(2026)}), throwsArgumentError);
    });

    test('claimHandoff validates the user ID', () async {
      native = FakeNative()..install();
      Lander.debugHttpClient = resolvingApi().client;
      await Lander.initialize(apiKey: 'pk_test_DemoPublishableKey000000000000');
      await expectLater(Lander.claimHandoff('  '), throwsArgumentError);
      await expectLater(Lander.claimHandoff('x' * 257), throwsArgumentError);
    });
  });
}
