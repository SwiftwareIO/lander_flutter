import 'package:flutter/foundation.dart';

/// Prints SDK diagnostics when logging is enabled. Never logs API keys.
class LanderLogger {
  LanderLogger({required this.enabled});

  final bool enabled;

  void log(String message) {
    if (enabled) debugPrint('[Lander] $message');
  }
}
