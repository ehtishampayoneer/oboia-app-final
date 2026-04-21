// File generated for OBOIA — connects Flutter to the oboia-server Firebase project.
// Values pulled from the configuration you provided.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyA19aEUkdcbph_SiWeELXPlDLL0GtsHc-w',
    appId: '1:223722007359:web:b656ced819740134c0418a',
    messagingSenderId: '223722007359',
    projectId: 'oboia-server',
    authDomain: 'oboia-server.firebaseapp.com',
    storageBucket: 'oboia-server.firebasestorage.app',
  );

  // IMPORTANT: After running `flutterfire configure` you will get proper
  // per-platform appIds. For now we fall back to the web appId so the app
  // can initialize. Replace these when you run flutterfire configure.
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyA19aEUkdcbph_SiWeELXPlDLL0GtsHc-w',
    appId: '1:223722007359:android:REPLACE_AFTER_FLUTTERFIRE_CONFIGURE',
    messagingSenderId: '223722007359',
    projectId: 'oboia-server',
    storageBucket: 'oboia-server.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyA19aEUkdcbph_SiWeELXPlDLL0GtsHc-w',
    appId: '1:223722007359:ios:REPLACE_AFTER_FLUTTERFIRE_CONFIGURE',
    messagingSenderId: '223722007359',
    projectId: 'oboia-server',
    storageBucket: 'oboia-server.firebasestorage.app',
    iosBundleId: 'com.oboia.app',
  );
}
