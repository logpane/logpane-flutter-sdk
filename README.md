# Logpane Flutter SDK

Lightweight analytics and error tracking SDK for Flutter. Self-hosted, privacy-friendly.

## Installation

```yaml
dependencies:
  logpane: ^0.1.0
```

```bash
flutter pub get
```

## Quick Start

```dart
import 'package:logpane/logpane.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await Logpane.init(
      endpoint: 'https://api.yourdomain.com',
      apiKey: 'your-api-key',
    );

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      Logpane.instance.captureFlutterError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      Logpane.instance.captureError(error, stack);
      return true;
    };

    runApp(const MyApp());
  }, (error, stack) {
    Logpane.instance.captureError(error, stack);
  });
}
```

## Screen Tracking

```dart
MaterialApp(
  navigatorObservers: [Logpane.instance.navigatorObserver],
);
```

## Custom Events

```dart
Logpane.instance.track('purchase', {
  'item': 'sword',
  'price': 9.99,
});
```

## Error Capture

```dart
try {
  await riskyOperation();
} catch (e, stack) {
  Logpane.instance.captureError(e, stack,
    context: 'riskyOperation',
  );
}
```

## User Identification

```dart
Logpane.instance.identify(userId: user.id, traits: {
  'username': user.name,
});

// On logout
Logpane.instance.reset();
```

## Features

- Offline event queue (SQLite-backed, events sent when connectivity returns)
- Automatic error capture across all three Dart error layers
- Automatic screen tracking via NavigatorObserver
- Session management with 30-minute background timeout
- Device metadata (platform, model, OS, app version)
- Gzip-compressed event batching
- Privacy-friendly (no fingerprinting, opt-out toggle)

## Configuration

```dart
await Logpane.init(
  endpoint: 'https://api.yourdomain.com',
  apiKey: 'your-api-key',
  flushIntervalSeconds: 30,    // How often to send batched events
  maxBatchSize: 50,            // Max events per batch
  maxQueueSize: 1000,          // Max events in offline queue
  enableInDebug: false,        // Disable in debug mode
);
```

## License

MIT
