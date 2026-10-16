import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lander_flutter/src/platform.dart';

/// In memory stand in for the native side.
class FakePlatform extends LanderPlatform {
  FakePlatform({
    this.initialLink,
    this.platform = 'ios',
    this.installReferrer,
    this.appVersion = '2.4.0',
    this.osVersion = '18.1',
    Map<String, String>? storage,
  }) : storage = storage ?? {};

  String? initialLink;
  final String platform;
  final String? installReferrer;
  final String appVersion;
  final String osVersion;
  final Map<String, String> storage;
  final StreamController<String> links = StreamController<String>.broadcast();
  int installReferrerCalls = 0;

  /// Number of upcoming writes to each key that fail.
  final Map<String, int> writeFailures = {};

  @override
  Future<String?> getInitialLink() async {
    final link = initialLink;
    initialLink = null;
    return link;
  }

  @override
  Stream<String> get linkStream => links.stream;

  @override
  Future<LanderPlatformInfo> getPlatformInfo() async =>
      LanderPlatformInfo(platform: platform, appVersion: appVersion, osVersion: osVersion);

  @override
  Future<String?> getInstallReferrer() async {
    installReferrerCalls++;
    return installReferrer;
  }

  @override
  Future<String?> read(String key) async => storage[key];

  @override
  Future<void> write(String key, String value) async {
    final failures = writeFailures[key] ?? 0;
    if (failures > 0) {
      writeFailures[key] = failures - 1;
      throw Exception('disk full');
    }
    storage[key] = value;
  }

  @override
  Future<void> delete(String key) async => storage.remove(key);
}

/// A recorded request with its decoded JSON body.
class Recorded {
  Recorded(this.request) : body = jsonDecode(request.body) as Map<String, Object?>;

  final http.Request request;
  final Map<String, Object?> body;

  String get path => request.url.path;
  Map<String, String> get headers => request.headers;
}

typedef Handler = FutureOr<http.Response> Function(Recorded request);

/// A [MockClient] that records requests and answers per path.
class FakeApi {
  FakeApi({Map<String, Handler>? handlers}) : handlers = {...defaultHandlers, ...?handlers};

  static final Map<String, Handler> defaultHandlers = {
    '/v1/sdk/init': (r) => json({'installId': r.body['installId'], 'deferredLink': null}),
    '/v1/sdk/resolve': (r) => json({'error': {'code': 'link_not_found', 'message': 'Not found'}}, 404),
    '/v1/sdk/events': (r) => json({'accepted': (r.body['events'] as List).length, 'duplicates': 0}, 202),
  };

  final Map<String, Handler> handlers;
  final List<Recorded> requests = [];

  List<Recorded> to(String path) => requests.where((r) => r.path == path).toList();

  late final http.Client client = MockClient((request) async {
    final recorded = Recorded(request);
    requests.add(recorded);
    final handler = handlers[request.url.path];
    if (handler == null) return json({'error': {'code': 'not_found', 'message': 'no route'}}, 404);
    return handler(recorded);
  });
}

http.Response json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});

const resolvedP123 = {
  'linkId': '6f1c1f9e-8a2b-4c3d-9e4f-5a6b7c8d9e0f',
  'url': 'https://acme.golander.link/p-123',
  'path': '/product/123',
  'params': {'productId': '123', 'utm_source': 'x'},
  'campaign': null,
  'channel': 'share',
  'isDeferred': false,
  'confidence': 'deterministic',
  'method': 'universal_link',
};

/// What `/v1/sdk/init` returns on an Android first launch with a Play referrer token.
const deferredSpring = {
  'linkId': '9b1f3c2e-4d5a-4b6c-8d7e-0f1a2b3c4d5e',
  'url': 'https://acme.golander.link/spring-sale',
  'path': '/sale/spring',
  'params': {'discount': '15'},
  'campaign': 'spring_2027',
  'channel': null,
  'isDeferred': true,
  'confidence': 'deterministic',
  'method': 'install_referrer',
};
