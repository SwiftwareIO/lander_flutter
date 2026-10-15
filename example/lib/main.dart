import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lander_flutter/lander_flutter.dart';

import 'app.dart';

/// Seeded local test key from supabase/seed.sql. Publishable keys are safe to
/// ship in apps.
const landerApiKey = 'pk_test_DemoPublishableKey000000000000';

/// The local API from `pnpm dev`. The Android emulator reaches the host at
/// 10.0.2.2; the iOS simulator shares the host's localhost. Override with
/// `--dart-define=LANDER_BASE_URL=https://api.lndr.link`.
String get landerBaseUrl {
  const override = String.fromEnvironment('LANDER_BASE_URL');
  if (override.isNotEmpty) return override;
  return defaultTargetPlatform == TargetPlatform.android ? 'http://10.0.2.2:8787' : 'http://localhost:8787';
}

Future<void> main() async {
  // Returns quickly: the network init runs in the background.
  await Lander.initialize(apiKey: landerApiKey, baseUrl: landerBaseUrl, enableLogging: kDebugMode);
  runApp(const ShopApp());
}
