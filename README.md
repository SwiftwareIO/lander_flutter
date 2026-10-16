# lander_flutter

Deep linking without the fuss. The Flutter SDK for [Lander](https://lander.link): receive Universal Links, App Links and custom scheme URLs, resolve them to the link you created in Lander, create short links from inside the app, and report conversions.

- One stream for every link: cold start, warm start, deferred (after install).
- Every link says how sure Lander is: `deterministic`, `probabilistic` or `unattributed`.
- Links are buffered until your router listens, so nothing is lost during startup.
- Unknown links still reach your app with the raw URL.
- Offline event queue with batching, retries and deduplication.
- Privacy first: a random install ID, no fingerprinting, no IDFA, no pasteboard reads.

Requires Flutter 3.38 or newer, iOS 15+, Android API 24+.

## Install

The package is not on pub.dev yet. Depend on it from git or a path:

```yaml
dependencies:
  lander_flutter:
    git:
      url: https://github.com/lander/lander.git
      path: sdk/lander_flutter
```

## Usage

### Initialize

Call `initialize` once, before `runApp`. It loads (or creates) the install ID and starts listening for links; the launch report (`POST /v1/sdk/init`) runs in the background, so it never blocks startup on the network.

```dart
import 'package:lander_flutter/lander_flutter.dart';

Future<void> main() async {
  await Lander.initialize(
    apiKey: 'pk_live_...', // publishable key from the dashboard
    enableLogging: kDebugMode,
  );
  runApp(const MyApp());
}
```

Only publishable keys (`pk_test_...`, `pk_live_...`) are accepted. Secret keys (`sk_...`) are rejected, because anything shipped in an app is public.

### Receive links

```dart
final router = GoRouter(routes: [...]);

// In initState of your root widget, after the router exists:
_sub = Lander.onDeepLink.listen((link) {
  router.go(link.route, extra: link);
});
```

`LanderLink` mirrors the API's `ResolvedLink`:

| Field | Meaning |
|---|---|
| `uri` | The URL that opened the app, exactly as the OS delivered it |
| `linkId` | Lander link ID, or `null` when the link is unknown to Lander |
| `url` | Canonical short link, for example `https://acme.lander.link/p-123` |
| `path` | The in app route set on the link, for example `/product/123` |
| `params` | Link params, with the opened URL's query parameters merged over them |
| `campaign`, `channel` | Attribution labels set on the link |
| `isDeferred` | True when the link was recovered after an install or handed off after sign in |
| `confidence` | `deterministic`, `probabilistic` or `unattributed` |
| `method` | How the link was tied to the open: `universal_link`, `app_link`, `install_referrer`, `landing_page`, `authenticated_handoff` or `probabilistic_match` |
| `isResolved` | Whether Lander recognized the link |
| `route` | `path` when resolved, otherwise the raw URL's path and query |

How delivery works:

- **Buffered.** Links that arrive while nothing listens to `onDeepLink` (cold start, or before your router is ready) are kept and replayed, in order, to the next listener. You can even listen before `initialize`.
- **The launch link is delivered once.** Either listen to `onDeepLink` only (simplest), or call `getInitialLink()` for the launch link, for example to pick the router's `initialLocation`. Whichever gets it first wins; the other does not see it again, so navigation never happens twice.
- **Unknown links still arrive.** When the API answers 404 (not a Lander link, for example a page on your own site), or the network is down, you get a `LanderLink` with `isResolved == false` and only `uri` set.
- **Custom scheme URLs** (`acmeshop://product/123`) are delivered as is, without a network call. `route` treats the host as the first path segment, so this one routes to `/product/123`. The exception is a scheme URL carrying a short link in `lander_link` (the iOS "Continue in app" page builds these): that link is resolved, and `uri` stays the scheme URL.
- The same URL reported twice within two seconds (some OS versions do this at launch) counts as one open.

```dart
// Option: decide the first screen from the launch link.
final initial = await Lander.getInitialLink(); // waits for the resolve call
final router = GoRouter(initialLocation: initial?.route ?? '/', routes: [...]);
```

`getInitialLink` waits for the resolve request when the app was opened by a link, and on a first launch for the init request (a deferred link may come back). Each request has a 10 second timeout, so on a slow network this can take a while; listening to `onDeepLink` never blocks anything.

Opens are reported by the API when the SDK resolves the link, so you do not need to track them yourself.

### Deferred deep links

A deferred deep link is a link someone tapped before the app was installed. Lander brings them to the right screen after install wherever that can be done honestly, and labels every result. The full picture, per platform, is in [`docs/DEFERRED.md`](../../docs/DEFERRED.md).

- **Android, automatic and deterministic.** The redirector sends the click to the Play Store with a single use token in the install referrer. On first launch the SDK sends the referrer to `POST /v1/sdk/init`, and the link comes back through `getInitialLink` / `onDeepLink` with `isDeferred: true`, `confidence: deterministic` and `method: install_referrer`. Nothing to code.
- **iOS "Continue in app" page (deterministic).** When the project turns it on, iOS clicks see a small page with an App Store button and an "I already have the app, open it" button. After installing, the user comes back and taps the second button; the app opens on the link's screen with `method: landing_page` (and `isDeferred: true` when the app was installed after the click). If your iOS app has a custom URL scheme, the button uses it, so add the scheme to `Info.plist` (see iOS setup).
- **Authenticated handoff (deterministic, both platforms).** Your server binds a link to a user, the app claims it after sign in:

  ```dart
  final user = await auth.signIn();
  final link = await Lander.claimHandoff(user.id); // null when nothing is pending
  if (link != null) router.go(link.route, extra: link);
  ```

  `claimHandoff` returns the link and never also emits it on `onDeepLink`, so navigation happens once. Use an ID that cannot be guessed (your auth system's user UUID, not an email address or a counter).
- **iOS probabilistic matching (opt in, off by default).** Projects that turn it on get a deferred link on iOS first launch when the recent clicks (default 2 hours) that match the install's OS major version and country all point at one link. Projects that also turn on IP matching match clicks from the same network first, which finds far more installs. It arrives with `confidence: probabilistic`, so treat it as a suggestion: for example land on the product page, never sign the user in or apply a credit on the strength of it.
- **Everything else is `unattributed`:** no deferred link is delivered, and the install is reported as unattributed.

```dart
Lander.onDeepLink.listen((link) {
  if (link.isDeferred && link.confidence == LanderConfidence.probabilistic) {
    // Show it, but do not act on it as if the user had tapped it in the app.
  }
  router.go(link.route, extra: link);
});
```

### Create links

```dart
try {
  final link = await Lander.createLink(
    path: '/product/123',
    params: {'productId': '123'},
    title: 'Trail runner',
    channel: 'share',
  );
  Share.share(link.url.toString());
} on LanderException catch (e) {
  // e.code, e.statusCode, e.message
}
```

The slug is random and the domain is the project's default domain. The install ID is sent along so the API rate limits per install (20 links per minute). Requests are retried on network and server errors with the same `Idempotency-Key`, so a retry never creates two links.

### Track events

```dart
await Lander.trackEvent(
  'purchase',
  properties: {'amount': 49.99, 'currency': 'USD'},
  linkId: link?.linkId, // optional: attribute to the link that opened the app
);
```

Events are written to a queue on the device first and sent in batches of up to 100 to `POST /v1/sdk/events`:

- They survive offline periods and app restarts (up to 1000 queued events; the oldest are dropped beyond that).
- They wait until the API knows the install (the first successful init), since it rejects events from unknown installs.
- Failed batches are retried with exponential backoff (1 s doubling up to 5 min, with jitter, honoring `Retry-After`).
- Every event carries a client generated UUID, so a batch sent twice (for example after a lost response) is counted once.
- The queue is flushed shortly after each event and when the app goes to the background.
- A batch the API rejects as invalid is dropped so it cannot block the queue; an auth error pauses sending until the next launch, keeping the events.

`trackEvent` throws `ArgumentError` for programming errors (empty name, name over 100 characters, non JSON properties, a `linkId` that is not a UUID) and never throws for network errors.

### Install ID

`Lander.installId` is the random UUID v4 created on first launch. It identifies this install only: it is stored in a file excluded from iCloud and Android backups, so it is never restored onto another device, and it is gone when the app is uninstalled. If the API reports that the ID belongs to another project or environment (for example after switching from a `pk_test_` to a `pk_live_` key), the SDK creates a new one and reports a first launch.

## Android setup

In `android/app/src/main/AndroidManifest.xml`, inside your main `<activity>`:

```xml
<!-- Let Lander deliver links instead of Flutter's built in handler. -->
<meta-data android:name="flutter_deeplinking_enabled" android:value="false" />

<!-- App Links for your Lander domain. autoVerify makes Android check
     https://<domain>/.well-known/assetlinks.json, which Lander serves. -->
<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="https" android:host="acme.lander.link" />
</intent-filter>

<!-- Optional: custom scheme -->
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="acmeshop" />
</intent-filter>
```

Keep the activity's `android:launchMode="singleTop"` (the Flutter default), so links that arrive while the app runs go to `onNewIntent` instead of starting a second activity.

In the Lander dashboard, add your package name and the SHA-256 fingerprints of every signing key (debug, upload and the Play App Signing key) so `assetlinks.json` verifies. Check verification with:

```bash
adb shell pm get-app-links com.acme.shop
```

On first launch the SDK reads the [Play Install Referrer](https://developer.android.com/google/play/installreferrer) once and sends it to the API for deferred deep linking. The plugin adds the `com.android.installreferrer:installreferrer` dependency for you.

## iOS setup

1. **Associated Domains.** In Xcode, add the Associated Domains capability to the Runner target with `applinks:acme.lander.link`. This creates `Runner/Runner.entitlements`:

   ```xml
   <key>com.apple.developer.associated-domains</key>
   <array>
       <string>applinks:acme.lander.link</string>
   </array>
   ```

   In the Lander dashboard, add your Team ID and bundle ID; Lander serves `/.well-known/apple-app-site-association` for your domain.

2. **Disable Flutter's built in deep linking** in `ios/Runner/Info.plist`, so navigation does not happen twice:

   ```xml
   <key>FlutterDeepLinkingEnabled</key>
   <false/>
   ```

3. **Optional custom scheme** in `Info.plist`:

   ```xml
   <key>CFBundleURLTypes</key>
   <array>
       <dict>
           <key>CFBundleURLName</key>
           <string>com.acme.shop</string>
           <key>CFBundleURLSchemes</key>
           <array><string>acmeshop</string></array>
       </dict>
   </array>
   ```

Both app lifecycles are supported with no code changes: apps using a `FlutterSceneDelegate` (the default for new Flutter apps) and older apps using only `FlutterAppDelegate`. The plugin registers for scene and app delegate callbacks and handles Universal Links (`NSUserActivity`) and URL opens on cold and warm start. If you use multiple scenes with a custom root view controller, register your engine with the scene lifecycle as described in Flutter's `FlutterSceneLifeCycleEngineRegistration` docs.

The plugin returns `false` from every URL callback so other plugins (for example sign in redirects) still receive their URLs. Those URLs also reach `onDeepLink` when they come through Lander's callbacks; ignore routes you do not handle.

## Privacy

- **Install ID only.** A random UUID v4 per install. No device model, no advertising ID (IDFA or GAID), no device fingerprint, no pasteboard access.
- **What is sent:** the install ID, platform, app version, OS version, SDK version, the URLs that opened the app, the events you track, on Android first launch the Play Install Referrer string, and the user ID you pass to `claimHandoff` (the API stores only a hash of it).
- **Deferred links never use device fingerprints.** Android uses the Play Install Referrer; iOS uses an explicit tap on the "Continue in app" page or your own sign in. Opt in probabilistic matching compares only OS major version, country and click time, plus, if you also opt in to IP matching, a keyed hash of the network (never the IP address, deleted within 7 hours). The SDK itself sends nothing extra for this.
- **Storage** lives in Application Support (iOS) and `noBackupFilesDir` (Android), excluded from backups.
- The iOS privacy manifest (`PrivacyInfo.xcprivacy`) declares a device ID and product interaction data, both for analytics, not linked to the user and not used for tracking. No required reason APIs are used.

## Local development

With the Lander monorepo running (`pnpm dev`), the API listens on port 8787. Use the seeded test key:

```dart
await Lander.initialize(
  apiKey: 'pk_test_DemoPublishableKey000000000000',
  baseUrl: Platform.isAndroid ? 'http://10.0.2.2:8787' : 'http://localhost:8787',
  enableLogging: true,
);
```

Plain HTTP needs `android:usesCleartextTraffic="true"` in your debug manifest on Android and `NSAllowsLocalNetworking` under `NSAppTransportSecurity` on iOS. The example app has both.

Open a link without tapping one:

```bash
xcrun simctl openurl booted "https://acme.lander.link/p-123"
```

```bash
adb shell am start -a android.intent.action.VIEW -d "https://acme.lander.link/p-123" com.acme.shop
```

On the iOS simulator a Universal Link only opens the app when the domain's apple-app-site-association file is reachable; use the custom scheme (`acmeshop://product/123`) to test routing locally.

## Example

[`example/`](example) is "Acme Shop", a go_router app with a product screen at `/product/:id`. The seeded link `https://acme.lander.link/p-123` resolves to `/product/123`. It shows what Lander resolved for each link, creates share links and tracks purchases.

```bash
cd example
flutter run
```

## API

The SDK only talks to the public API documented in `docs/API.md` (`/v1/sdk/init`, `/v1/sdk/resolve`, `/v1/sdk/events`, `/v1/sdk/links`, `/v1/sdk/handoffs/claim`), never to the database. Every request has a 10 second timeout; every write carries an `Idempotency-Key` that stays the same across retries.
