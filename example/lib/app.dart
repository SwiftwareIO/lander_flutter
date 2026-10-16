import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lander_flutter/lander_flutter.dart';

import 'screens.dart';

/// The most recent link, shown on the home screen for debugging.
final lastLink = ValueNotifier<LanderLink?>(null);

/// Lander's install ID, set once `Lander.initialize` completes.
final installId = ValueNotifier<String?>(null);

GoRouter buildRouter({String initialLocation = '/'}) => GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const HomeScreen(),
          routes: [
            GoRoute(
              // https://acme.golander.link/p-123 resolves to /product/123.
              path: 'product/:id',
              builder: (context, state) => ProductScreen(
                id: state.pathParameters['id']!,
                link: state.extra is LanderLink ? state.extra as LanderLink : null,
              ),
            ),
          ],
        ),
      ],
      errorBuilder: (context, state) => NotFoundScreen(uri: state.uri),
    );

class ShopApp extends StatefulWidget {
  const ShopApp({super.key, this.initialLocation = '/'});

  final String initialLocation;

  @override
  State<ShopApp> createState() => _ShopAppState();
}

class _ShopAppState extends State<ShopApp> {
  late final GoRouter _router = buildRouter(initialLocation: widget.initialLocation);
  StreamSubscription<LanderLink>? _links;

  @override
  void initState() {
    super.initState();
    // Subscribing once the router exists is enough: Lander buffers links
    // (including the one that launched the app) until someone listens.
    _links = Lander.onDeepLink.listen((link) {
      lastLink.value = link;
      // Probabilistic links are a good guess, not proof: open the screen, but
      // the product screen does not act on them (see isSuggestion there).
      _router.go(link.route, extra: link);
    });
  }

  @override
  void dispose() {
    _links?.cancel();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'Acme Shop',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        routerConfig: _router,
      );
}
