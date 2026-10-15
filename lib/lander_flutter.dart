/// Lander for Flutter: deep linking without the fuss.
///
/// Receive Universal Links, App Links and custom scheme URLs, resolve them to
/// Lander links, create short links and report conversions.
library;

export 'src/lander.dart' show Lander;
export 'src/models.dart' show LanderConfidence, LanderException, LanderLink, LanderShortLink;
export 'src/version.dart' show landerSdkVersion;
