## 0.2.0

- Added multi-source support: new `source` parameter on `Logpane.init()` to tag events by app/platform (e.g. "flutter-mobile", "flutter-admin")
- Source field included in all analytics and error event payloads
- Fully backward compatible (defaults to empty string)

## 0.1.4

- Fixed init crashes when called before Flutter bindings are ready
- Hardened all public methods with null safety and error handling
- Improved device info collection reliability

## 0.1.3

- Added automatic environment tagging (debug vs production based on `kDebugMode`)
- Events are always sent regardless of build mode

## 0.1.2

- Added AI agent integration link to README

## 0.1.1

- Added proper unit tests
- Removed manual endpoint configuration (uses API key prefix routing)
- Added development notice to README

## 0.1.0

- Initial release
- Event tracking with offline SQLite queue
- Automatic error capture (FlutterError, PlatformDispatcher, runZonedGuarded)
- Automatic screen tracking via NavigatorObserver
- Session management with 30-minute background timeout
- Device metadata collection
- Gzip-compressed event batching
- User identification and anonymous tracking
