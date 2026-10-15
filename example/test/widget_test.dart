import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lander_flutter/lander_flutter.dart';
import 'package:lander_flutter_example/app.dart';

void main() {
  testWidgets('home lists products', (tester) async {
    await tester.pumpWidget(const ShopApp());
    expect(find.text('Acme Shop'), findsOneWidget);
    expect(find.text('Trail runner'), findsOneWidget);
  });

  testWidgets('a resolved link route opens the product screen', (tester) async {
    final link = LanderLink(
      uri: Uri.parse('https://acme.lander.link/p-123'),
      linkId: '6f1c1f9e-8a2b-4c3d-9e4f-5a6b7c8d9e0f',
      path: '/product/123',
      params: {'productId': '123'},
      channel: 'share',
      confidence: LanderConfidence.deterministic,
    );
    await tester.pumpWidget(ShopApp(initialLocation: link.route));
    await tester.pumpAndSettle();
    expect(find.text('Product 123'), findsOneWidget);
  });

  testWidgets('an unknown route shows the not found screen', (tester) async {
    await tester.pumpWidget(const ShopApp(initialLocation: '/nope'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No screen for /nope'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}
