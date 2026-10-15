import 'dart:async';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

/// Facts about the host app sent with `POST /v1/sdk/init`. Deliberately small:
/// no device model, no locale, no advertising identifiers.
@immutable
class LanderPlatformInfo {
  const LanderPlatformInfo({required this.platform, required this.appVersion, this.osVersion});

  /// `ios` or `android`.
  final String platform;
  final String appVersion;
  final String? osVersion;
}

/// The native side of the plugin. Replace [instance] with a fake in tests.
abstract class LanderPlatform {
  static LanderPlatform instance = MethodChannelLanderPlatform();

  /// The URL that launched the app, if any. The native side hands it out once.
  Future<String?> getInitialLink();

  /// URLs that arrive while the app is running (warm start). The native side
  /// buffers URLs until this stream is listened to.
  Stream<String> get linkStream;

  Future<LanderPlatformInfo> getPlatformInfo();

  /// Raw Play Install Referrer string. Android only; null elsewhere or when
  /// the Play Store is unavailable.
  Future<String?> getInstallReferrer();

  /// Small key value storage kept out of device backups, so the install ID and
  /// event queue never move to another device.
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MethodChannelLanderPlatform extends LanderPlatform {
  @visibleForTesting
  static const methods = MethodChannel('lander_flutter/methods');

  @visibleForTesting
  static const links = EventChannel('lander_flutter/links');

  Stream<String>? _linkStream;

  @override
  Future<String?> getInitialLink() => methods.invokeMethod<String>('getInitialLink');

  @override
  Stream<String> get linkStream =>
      _linkStream ??= links.receiveBroadcastStream().where((e) => e is String).cast<String>();

  @override
  Future<LanderPlatformInfo> getPlatformInfo() async {
    final info = await methods.invokeMapMethod<String, Object?>('getPlatformInfo') ?? const {};
    return LanderPlatformInfo(
      platform: info['platform'] as String? ?? 'unknown',
      appVersion: info['appVersion'] as String? ?? '0.0.0',
      osVersion: info['osVersion'] as String?,
    );
  }

  @override
  Future<String?> getInstallReferrer() => methods.invokeMethod<String>('getInstallReferrer');

  @override
  Future<String?> read(String key) => methods.invokeMethod<String>('storageRead', {'key': key});

  @override
  Future<void> write(String key, String value) =>
      methods.invokeMethod<void>('storageWrite', {'key': key, 'value': value});

  @override
  Future<void> delete(String key) => methods.invokeMethod<void>('storageDelete', {'key': key});
}
