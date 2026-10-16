## 0.2.1

Fixes.

* Android: the plugin now declares the `INTERNET` permission, so release builds reach the Lander API even when the app's own manifest does not ask for it (Flutter only adds it to debug and profile builds).
* A failed first launch report (offline at first launch) is retried in the same session: when the app returns to the foreground, before `claimHandoff`, and before queued events are sent. Concurrent retries share one request. A deferred link that comes back then arrives on `onDeepLink`.
* A deferred or handed off link with a field of an unexpected type no longer throws inside the SDK and loses the link: the field is treated as missing. `claimHandoff` throws `LanderException` (`invalid_response`) instead of a `TypeError` for a response it cannot use.
* `getInitialLink()` returns the launch link once; later calls return `null`, as documented.
* Interactive calls (`createLink`, `claimHandoff`, launch report, link resolve) wait at most 10 seconds in total between retries. A longer `Retry-After` ends the retries and the `LanderException` carries `retryAfter`. `link_quota_exceeded` is no longer retried.
* Responses are decoded as UTF-8 whatever the `Content-Type` says, so non-ASCII titles and params are no longer garbled with older `http` versions.
* A 2xx response that is not a JSON object (for example a captive portal page) is an `invalid_response` error instead of a success. Before, it marked the first launch as reported and lost a deferred link.
* `appVersion` and `osVersion` are cut to the 50 characters the API accepts, so a long build name no longer makes every launch report fail.
* Android: a new activity on a cached Flutter engine gets its own launch link.
* iOS: the privacy manifest declares User ID (linked to the user, App Functionality), sent by `claimHandoff`.
* `sdkVersion` reported as `0.2.1`.

## 0.2.0

Deferred deep linking.

* Deferred links from `POST /v1/sdk/init` arrive through `getInitialLink` and `onDeepLink` as before, now with `isDeferred`, `confidence` (`deterministic`, `probabilistic` or `unattributed`) and the new `LanderLink.method` (`install_referrer`, `probabilistic_match`, `landing_page`, `authenticated_handoff`, `universal_link`, `app_link`). Still delivered exactly once, and a link that opened the app wins over a deferred one.
* Android: installs from a Lander link land on that link's screen. The redirector now puts a single use `lander_token` in the Play Store referrer, which the SDK already sends on first launch (deterministic, `install_referrer`).
* `Lander.claimHandoff(userId)`: after sign in, returns the link your backend bound to that user with `POST /v1/handoffs` (deterministic, `authenticated_handoff`), or null. Returned only, never emitted on `onDeepLink`. Retries reuse one `Idempotency-Key`, so a lost response does not lose the link.
* Custom scheme URLs that carry a short link in `lander_link` (the iOS "Continue in app" page's open button) are resolved like the link itself; `uri` stays the scheme URL, and if resolving fails the scheme URL's path still routes.
* `sdkVersion` reported as `0.2.0`.

## 0.1.0

First release: the installed app path.

* `Lander.initialize`: random install ID (UUID v4, stored outside backups), `POST /v1/sdk/init` on every launch with `isFirstLaunch`, Play Install Referrer on Android first launch. Never throws on network errors; a failed first launch report is retried on the next launch with the same idempotency key, and an `install_id_conflict` gets a fresh install ID.
* `Lander.onDeepLink` and `Lander.getInitialLink`: Universal Links, App Links and custom scheme URLs on cold and warm start, resolved through `POST /v1/sdk/resolve`. Links are buffered until the app listens, the launch link is delivered exactly once, and unknown links (404) or network failures still deliver the raw URL.
* `Lander.createLink`: short links from inside the app via `POST /v1/sdk/links`.
* `Lander.trackEvent`: persistent offline queue, batches of up to 100, exponential backoff with jitter and `Retry-After`, deduplication by client generated event ID, flush on app background, held until the install is registered. Optional `linkId` for attribution.
* Request timeouts (10 s) and an `Idempotency-Key` on every write, reused across retries.
* Android (Kotlin): launch intent and `onNewIntent` delivery, Recents replay ignored, Play Install Referrer.
* iOS (Swift): app delegate and `UIScene` based apps, `NSUserActivity` Universal Links and URL opens, privacy manifest.
* Example app: Acme Shop with go_router.
