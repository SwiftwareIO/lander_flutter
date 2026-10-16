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
      uri: Uri.parse('https://acme.golander.link/p-123'),
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

  testWidgets('a probabilistic link opens the screen as a suggestion and shows its method', (tester) async {
    final link = LanderLink(
      uri: Uri.parse('https://acme.golander.link/p-456'),
      linkId: '6f1c1f9e-8a2b-4c3d-9e4f-5a6b7c8d9e0f',
      path: '/product/456',
      isDeferred: true,
      confidence: LanderConfidence.probabilistic,
      method: 'probabilistic_match',
    );
    final router = buildRouter(initialLocation: '/');
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go(link.route, extra: link);
    await tester.pumpAndSettle();
    expect(find.textContaining('may have tapped before installing'), findsOneWidget);
    expect(find.textContaining('probabilistic_match', findRichText: true), findsOneWidget);
  });

  testWidgets('the install ID updates once Lander has started', (tester) async {
    await tester.pumpWidget(const ShopApp());
    expect(find.textContaining('(loading)', findRichText: true), findsOneWidget);
    installId.value = '0d6f1a7e-1111-4222-8333-944445555666';
    await tester.pump();
    expect(find.textContaining('0d6f1a7e-1111-4222-8333-944445555666', findRichText: true), findsOneWidget);
    installId.value = null;
  });

  testWidgets('home offers sign in for authenticated handoff', (tester) async {
    await tester.pumpWidget(const ShopApp());
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('an unknown route shows the not found screen', (tester) async {
    await tester.pumpWidget(const ShopApp(initialLocation: '/nope'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No screen for /nope'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}
