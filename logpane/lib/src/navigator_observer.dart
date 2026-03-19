import 'package:flutter/widgets.dart';

/// A [NavigatorObserver] that automatically tracks screen views.
///
/// Add this to your MaterialApp to enable automatic screen tracking:
/// ```dart
/// MaterialApp(
///   navigatorObservers: [Logpane.instance.navigatorObserver],
/// );
/// ```
///
/// Screen names are derived from the route settings name. Routes without
/// a name are tracked as 'Unknown'.
class LogpaneNavigatorObserver extends NavigatorObserver {
  final void Function(String screenName) _onScreenView;

  LogpaneNavigatorObserver({
    required void Function(String screenName) onScreenView,
  }) : _onScreenView = onScreenView;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _trackScreenFromRoute(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) {
      _trackScreenFromRoute(newRoute);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) {
      _trackScreenFromRoute(previousRoute);
    }
  }

  void _trackScreenFromRoute(Route<dynamic> route) {
    final screenName = _extractScreenName(route);
    if (screenName != null) {
      _onScreenView(screenName);
    }
  }

  String? _extractScreenName(Route<dynamic> route) {
    // Use the route settings name if available.
    final name = route.settings.name;
    if (name != null && name.isNotEmpty && name != '/') {
      return name;
    }

    // For the root route ('/'), use a descriptive name.
    if (name == '/') {
      return 'root';
    }

    // Skip routes without names (e.g., dialogs, bottom sheets).
    return null;
  }
}
