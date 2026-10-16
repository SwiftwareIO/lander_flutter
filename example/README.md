# Acme Shop (lander_flutter example)

A go_router app that opens a product screen from a Lander link. The seeded link `https://acme.golander.link/p-123` resolves to `/product/123` with `{"productId": "123"}`.

Bundle ID and package name: `com.acme.shop`, matching `supabase/seed.sql`. Custom scheme: `acmeshop`.

## Run against the local API

Start the monorepo (`pnpm dev` at the repo root), then:

```bash
flutter run
```

The app uses the seeded key `pk_test_DemoPublishableKey000000000000` and `http://10.0.2.2:8787` on the Android emulator or `http://localhost:8787` on the iOS simulator. Point it elsewhere with `--dart-define=LANDER_BASE_URL=https://api.golander.link`.

## Open a link

```bash
xcrun simctl openurl booted "acmeshop://product/123"
```

```bash
adb shell am start -a android.intent.action.VIEW -d "https://acme.golander.link/p-123" com.acme.shop
```

On Android an unverified App Link opens a chooser or the browser; `adb shell pm set-app-links --package com.acme.shop 2 all` marks the domain as verified on a test device. On iOS, Universal Links need the domain's apple-app-site-association file to be reachable, so test with the custom scheme locally.

The home screen shows the install ID and what Lander resolved for the last link. On a product screen, Share creates a short link with `Lander.createLink` and Buy tracks a `purchase` event attributed to the link that opened the screen.
