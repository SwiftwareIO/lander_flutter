import 'package:flutter_test/flutter_test.dart';
import 'package:lander_flutter/lander_flutter.dart';

import 'fakes.dart';

void main() {
  group('LanderLink.fromJson', () {
    test('reads a well formed ResolvedLink', () {
      final link = LanderLink.fromJson(resolvedP123);
      expect(link.isResolved, isTrue);
      expect(link.uri.toString(), 'https://acme.golander.link/p-123');
      expect(link.params, {'productId': '123', 'utm_source': 'x'});
    });

    test('treats fields of the wrong type as missing instead of throwing', () {
      final link = LanderLink.fromJson({
        'linkId': resolvedP123['linkId'],
        'url': 42,
        'path': '/product/123',
        'params': {'ok': '1', 'n': 2, 'nested': {'a': 1}, 'list': [1], 'gone': null},
        'campaign': false,
        'channel': ['share'],
        'isDeferred': 'yes',
        'confidence': 7,
        'method': {'x': 1},
      });
      expect(link.linkId, resolvedP123['linkId']);
      expect(link.url, isNull);
      expect(link.uri, Uri());
      expect(link.route, '/product/123');
      expect(link.params, {'ok': '1', 'n': 2});
      expect(link.campaign, isNull);
      expect(link.channel, isNull);
      expect(link.isDeferred, isFalse);
      expect(link.confidence, LanderConfidence.unattributed);
      expect(link.method, isNull);
    });

    test('an unparsable url keeps the rest of the link', () {
      final link = LanderLink.fromJson({...deferredSpring, 'url': 'https://[not a host'});
      expect(link.uri, Uri());
      expect(link.url, 'https://[not a host');
      expect(link.path, '/sale/spring');
      expect(link.isDeferred, isTrue);
    });

    test('params that are not a map are ignored', () {
      expect(LanderLink.fromJson({...resolvedP123, 'params': 'discount=15'}).params, isEmpty);
    });
  });
}
