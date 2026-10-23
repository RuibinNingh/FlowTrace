import 'package:flutter/widgets.dart';

import 'app_preferences.dart';
import 'preferences_controller.dart';

class AppPreferencesScope extends InheritedNotifier<PreferencesController> {
  const AppPreferencesScope({
    required PreferencesController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static AppPreferences of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppPreferencesScope>()
          ?.notifier
          ?.value ??
      const AppPreferences();
}
