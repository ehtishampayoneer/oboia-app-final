# OBOIA — Flutter Mobile App

This is the customer + craftsman mobile app for the OBOIA wallpaper platform.
It connects to the **same Firebase project** (`oboia-server`) that your Next.js
dashboard already uses, so everything syncs in real time.

> **You do not need to be a developer to follow this guide.** Just go line by
> line. Every command is copy-paste. If something breaks, read the _"If it
> breaks"_ note under that step.

---

## What you'll end up with

-   A working mobile app on your phone showing real shops from your dashboard
-   AR that lets customers preview wallpapers on their walls
-   A cart + order flow that shows up in your dashboard **instantly**
-   A separate craftsman mode (for users with `role = craftsman` in Firestore)

---

## Step 1 — Install the tools (one time only)

You only do this the first time you ever build a Flutter app on your
computer. If you already have Flutter, skip to Step 2.

### 1a. Install Flutter

Go to https://docs.flutter.dev/get-started/install and follow the
instructions **for your operating system**. You want the **stable**
channel, version **3.19 or newer**.

When done, open a terminal and run:

```bash
flutter --version
```

You should see a version number. If you don't, Flutter is not on your PATH —
revisit the install guide.

Then run:

```bash
flutter doctor
```

This checks your setup. Follow any instructions it gives you. For our app
you need:

-   ✅ Flutter
-   ✅ Android toolchain (install Android Studio → inside it, install the
    Android SDK)
-   ✅ Xcode (only if you're on a Mac and want to build for iPhone)
-   ✅ A device (physical phone plugged in with USB debugging, or an
    emulator)

### 1b. Install the Firebase CLI + FlutterFire CLI

Open a terminal and run:

```bash
npm install -g firebase-tools
dart pub global activate flutterfire_cli
```

If `dart pub global` prints a warning about PATH, follow its instructions
(usually adding `~/.pub-cache/bin` to your PATH).

### 1c. Log in to Firebase

```bash
firebase login
```

This opens a browser — log in with **the Google account that owns the
`oboia-server` Firebase project**.

---

## Step 2 — Put this project on your computer

1. Unzip `oboia.zip` wherever you like. For example: `~/Projects/oboia`.
2. Open a terminal and `cd` into that folder:
    ```bash
    cd ~/Projects/oboia
    ```
3. Pull the Flutter dependencies:
    ```bash
    flutter pub get
    ```
    This downloads all the packages listed in `pubspec.yaml`. It takes 1–2
    minutes the first time.

> **If it breaks:** most errors here are because Flutter isn't installed
> correctly. Go back to Step 1a and run `flutter doctor` again.

---

## Step 3 — Connect this app to your Firebase project (very important)

The file `lib/firebase_options.dart` already has your Firebase keys baked in,
**but** Android and iOS need platform-specific app IDs. We get those in one
command.

From inside the `oboia` folder, run:

```bash
flutterfire configure
```

When it asks:

-   **Which Firebase project?** → pick **`oboia-server`**.
-   **Which platforms?** → press space on **android** and **ios**, then enter.
-   **Bundle ID for iOS?** → type `com.oboia.app` and press enter.
-   **Package name for Android?** → type `com.oboia.app` and press enter.

This will:

-   **Overwrite** `lib/firebase_options.dart` with the correct per-platform
    IDs (this is what we want — it replaces the `REPLACE_AFTER_FLUTTERFIRE_CONFIGURE`
    placeholders).
-   Drop `android/app/google-services.json` into place.
-   Drop `ios/Runner/GoogleService-Info.plist` into place.
-   Register the app inside your Firebase project.

> **If it breaks:** make sure you ran `firebase login` first (Step 1c), and
> that the Google account you logged in with actually owns `oboia-server`.

---

## Step 4 — Enable the Firebase features we need

Go to https://console.firebase.google.com/project/oboia-server

### 4a. Enable Email/Password sign-in

1. Left sidebar → **Authentication** → **Get started** (if not already).
2. **Sign-in method** tab.
3. Click **Email/Password** → toggle **Enable** → Save.

### 4b. Enable Google sign-in

1. Same **Sign-in method** tab.
2. Click **Google** → toggle **Enable**.
3. Pick a **support email** → Save.

### 4c. Enable Firebase Storage (needed for profile photos)

The spec says Storage was not enabled yet — we enable it now.

1. Left sidebar → **Storage** → **Get started**.
2. Pick **Start in production mode** (we'll add rules in Step 4d).
3. Location: **europe-west3** (same as your Firestore — Frankfurt).
4. Done.

### 4d. Set Storage rules (so app can upload avatars)

Still in Storage → **Rules** tab → paste this → **Publish**:

```
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    // Each user can only write their own avatar.
    match /users/{uid}/{filename} {
      allow read: if true;
      allow write: if request.auth != null && request.auth.uid == uid;
    }
    // Wallpaper textures are public read.
    match /wallpapers/{all=**} {
      allow read: if true;
      allow write: if false;  // only admin from dashboard writes these
    }
  }
}
```

### 4e. Confirm Firestore is still in test mode

Left sidebar → **Firestore** → **Rules** — your existing test-mode rules are
fine for now. Before you go to production you'll want real rules, but for
development + launch this app will work.

---

## Step 5 — iOS-only: complete the Google Sign-In setup

**Only if you care about iPhone.** If you're only testing on Android,
skip this step.

1. Open `ios/Runner/GoogleService-Info.plist` (it was created by Step 3).
2. Find the key called `REVERSED_CLIENT_ID`. Copy its value — it looks like
   `com.googleusercontent.apps.223722007359-abcdef...`.
3. Open `ios/Runner/Info.plist`.
4. Find the line that says
   `<string>com.googleusercontent.apps.YOUR-REVERSED-CLIENT-ID</string>`.
5. Replace the whole string with the real reversed client id you copied.
6. Save the file.

---

## Step 6 — Plug in your phone and run it

### On Android

1. Enable **Developer options → USB debugging** on your phone.
2. Plug the phone into your computer with a USB cable.
3. Accept the "Allow USB debugging" popup on the phone.
4. From the `oboia` folder:
    ```bash
    flutter devices
    ```
    You should see your phone listed. If not, the phone isn't in
    developer/USB-debugging mode yet.
5. Run:
    ```bash
    flutter run
    ```
    First build takes 3–5 minutes. After that, changes rebuild in seconds.

### On iPhone (Mac only)

1. In the `oboia/ios` folder, run once:
    ```bash
    cd ios && pod install && cd ..
    ```
2. Open `ios/Runner.xcworkspace` in Xcode.
3. Select Runner → **Signing & Capabilities** → pick your **Team** (your
   Apple ID).
4. Plug in your iPhone, unlock it, trust the computer.
5. Close Xcode. Back in terminal:
    ```bash
    flutter run
    ```

> **If the app installs but AR doesn't open:** your device isn't ARCore /
> ARKit compatible, OR you installed on an emulator (AR only works on real
> phones). Check the ARCore-supported list at
> https://developers.google.com/ar/devices for Android.

---

## Step 7 — Make sure it talks to your dashboard

1. Open the app on your phone → create an account with email OR Google.
2. Go to your Next.js dashboard on Vercel, log in as a shop admin.
3. Create a new wallpaper with a thumbnail (or approve an existing one).
4. **Watch your phone** — the wallpaper should appear in the shop's
   wallpaper grid within 1–2 seconds, **no refresh needed**.
5. Add the wallpaper to cart → place order.
6. Switch back to the dashboard — the order appears in real time.

If any of this doesn't work, see **Troubleshooting** below.

---

## Step 8 — (Optional) Build release APK / IPA

### Android APK (for sharing or Play Store)

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

### Android App Bundle (recommended for Play Store)

```bash
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`

### iPhone (Mac only, App Store)

```bash
flutter build ipa
```

Then upload to App Store Connect with Xcode or Transporter.

---

## Folder layout (for reference)

```
oboia/
├── lib/
│   ├── main.dart                     → Firebase init + router
│   ├── firebase_options.dart         → generated by flutterfire configure
│   ├── models/                       → Dart types matching Firestore docs
│   ├── services/                     → Firebase + AR integration
│   ├── providers/                    → state management
│   ├── screens/                      → all 9+ screens
│   │   ├── auth/                     → welcome / login / signup
│   │   ├── home/                     → shop listing
│   │   ├── shop/                     → single shop + wallpapers
│   │   ├── ar/                       → AR camera + wall preview
│   │   ├── cart/                     → cart + order confirm
│   │   ├── orders/                   → order list + detail
│   │   ├── profile/                  → customer profile
│   │   └── craftsman/                → craftsman mode
│   ├── widgets/                      → reusable UI pieces
│   ├── theme/                        → dark + gold theme
│   └── utils/                        → calculations, formatters
├── android/                          → Android native config
├── ios/                              → iOS native config
└── pubspec.yaml                      → Flutter dependencies
```

---

## Troubleshooting

### "Google sign-in fails on Android"

This is almost always because a SHA-1 fingerprint isn't registered in
Firebase. Run:

```bash
cd android && ./gradlew signingReport
```

Copy the `SHA1:` line under the `debug` variant, then go to Firebase →
Project settings → **Your apps** → Android app → **Add fingerprint**.
Paste it, save, then re-run `flutterfire configure`.

### "AR screen crashes or shows black"

-   You're on an emulator. AR needs a real phone.
-   You're on an older phone — check the supported list:
    https://developers.google.com/ar/devices
-   Camera permission was denied — uninstall the app, reinstall, tap
    Allow when it asks for camera access.

### "Wallpapers don't appear"

In the dashboard, make sure the wallpaper has:

-   `isApproved: true`
-   A valid `shopId` (matching a shop with `isActive: true`)
-   A `thumbnailUrl` (otherwise the card shows a placeholder icon)

### "Profile photo upload fails"

You forgot Step 4c — enable Firebase Storage.

### "Orders don't show up in the dashboard"

Check the Firestore console → `orders` collection. If the order is there
but doesn't render in the dashboard, the dashboard is filtering wrong; if
the order isn't there, the app couldn't write (check app logs for a
permission error → tighten or loosen Firestore rules).

### "I get a 'minSdkVersion 21 is not enough' error"

That's because ARCore needs minSdk 24. It's already set to 24 in
`android/app/build.gradle`, but if you edited it, change it back.

---

## A note on PBR AR rendering

The app currently uses the **albedo** texture (`pbr.albedoUrl` or
`thumbnailUrl`) to preview the wallpaper in AR. True physically-based
rendering with **normal + roughness + AO** maps needs a native Swift /
Kotlin module and a renderer like SceneKit/Filament — that's out of scope
for a Flutter plugin today.

The code is structured so you can drop that in later: the `PbrMaps` model
already carries all four URLs, and `ar_service.dart` has a hook at the node
placement step where you'd wire in the native PBR renderer.

---

## Business rules baked into the app

Because these were in your spec and must never be broken, they're enforced
in code:

-   **Scanner ≠ Sale.** Using AR and adding to cart does not create a sale.
-   **Order ≠ Sale.** Placing an order creates an order doc with status
    `pending`, nothing more.
-   **Closed receipt = sale.** Craftsman bonuses only count sales with
    `status: closed`. This is enforced in
    `FirestoreService.confirmedBonusForCraftsman`.
-   **All queries filter by `shopId`.** See every method in
    `firestore_service.dart`.
-   **Roll math rounds up.** `Calc.rollsNeeded` uses `.ceil()` always.

---

That's it. Welcome to OBOIA Mobile. 🎨
