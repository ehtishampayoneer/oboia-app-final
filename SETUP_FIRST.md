# ⚡ READ THIS BEFORE ANYTHING ELSE

Before running any of the steps in `README.md`, do this **one command** first.
It takes 30 seconds and fills in parts of the Android/iOS native scaffolding
that can't be shipped inside a zip file (Xcode project files, Gradle wrapper
binaries, platform icons, etc).

## Run this once, right after unzipping

```bash
cd oboia

# Regenerates the native project scaffolding around our custom files.
# IMPORTANT: use --project-name oboia so the Dart package name stays "oboia".
flutter create --project-name oboia --org com.oboia --platforms=android,ios .
```

Flutter will say things like `"Would you like to overwrite..."` for a couple
of files. Answer **`n` (No)** when it asks about any of these:

-   `android/app/src/main/AndroidManifest.xml`  ← **keep ours** (has camera + ARCore)
-   `android/app/build.gradle`                   ← **keep ours** (has minSdk 24)
-   `android/build.gradle`                       ← **keep ours**
-   `android/settings.gradle`                    ← **keep ours**
-   `android/gradle.properties`                  ← **keep ours**
-   `ios/Runner/Info.plist`                      ← **keep ours** (has camera + ARKit)
-   `ios/Podfile`                                ← **keep ours** (iOS 12 target)
-   `lib/main.dart`                              ← **keep ours** (the whole app!)
-   `pubspec.yaml`                               ← **keep ours** (all deps)
-   `README.md`                                  ← **keep ours**
-   `analysis_options.yaml`                      ← **keep ours**

Answer **`y` (Yes)** for anything else — those are Flutter's stock native
files (launcher icons, Xcode project structure, Gradle wrapper jar, etc.)
that I couldn't ship in the zip.

## Then continue with README.md from Step 2 onward

Open `README.md` and follow it. Start at **Step 2 — Put this project on your
computer**, but skip substep 1 (unzipping) since you've already done that.

---

### Why this step exists

A Flutter project has two layers:

1. **The Dart app code** (lives in `lib/`) — that's what OBOIA actually is.
   Every single file in `lib/` is custom-written for your platform.
2. **The native scaffolding** (the rest of `android/` and `ios/`) — most of
   it is boilerplate that Flutter generates identically for every project.
   I shipped you only the files that needed customization (permissions,
   minSdk, bundle ID, etc). Running `flutter create` fills in the
   boilerplate around them.

This is the cleanest, most reliable way to start a Flutter project.
