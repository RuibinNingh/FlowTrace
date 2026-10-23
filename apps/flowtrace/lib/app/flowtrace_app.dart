import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/semantics.dart' show SemanticsHandle;
import 'package:flutter_localizations/flutter_localizations.dart';

import '../features/drafts/drafts_page.dart';
import '../features/home/home_page.dart';
import '../features/settings/settings_page.dart';
import '../features/data_tools/app_data_tools_page.dart';
import '../features/identity/account_page.dart';
import '../features/diagnostics/client_diagnostics_page.dart';
import '../features/sync/sync_page.dart';
import '../platform/web/update_bridge.dart';
import '../data/preferences/preferences_scope.dart';
import '../features/protection/protection_gate.dart';
import 'app_controller.dart';
import 'app_theme.dart';

class FlowTraceApp extends StatefulWidget {
  const FlowTraceApp({required this.controller, super.key});
  final AppController controller;

  @override
  State<FlowTraceApp> createState() => _FlowTraceAppState();
}

class _FlowTraceAppState extends State<FlowTraceApp> {
  SemanticsHandle? _webSemantics;
  void Function()? _removeUpdateBridge;
  final _navigation = _UpdateNavigation();
  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // Keep Web semantics enabled from the first frame so accessible controls
    // and DOM text editing use a consistent mode through identity changes and
    // route transitions. The app owns and releases this request explicitly.
    if (kIsWeb) {
      _webSemantics = WidgetsBinding.instance.ensureSemantics();
      _removeUpdateBridge = registerShellUpdateBarrier(
        prepare: () {
          FocusManager.instance.primaryFocus?.unfocus();
          final revision = _navigation.revision;
          return controller.prepareForUpdate(
            _navigation.routes,
            navigationCurrent: () => _navigation.revision == revision,
          );
        },
        resume: () => controller.resumeAfterUpdate(),
      );
    }
  }

  @override
  void dispose() {
    _removeUpdateBridge?.call();
    controller.resumeAfterUpdate();
    _webSemantics?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPreferencesScope(
    controller: controller.preferences,
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        title: '流迹 FlowTrace',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: controller.themeMode,
        navigatorObservers: [_navigation],
        builder: (context, child) => AppProtectionGate(
          controller: controller.protection,
          child: Stack(
            children: [
              AbsorbPointer(
                absorbing: controller.preparingUpdate,
                child: ExcludeFocus(
                  excluding: controller.preparingUpdate,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
              if (controller.preparingUpdate) ...[
                const ModalBarrier(dismissible: false, color: Colors.black54),
                const Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('正在保存草稿并准备更新…'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => controller.loading
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : controller.startupError != null
              ? Scaffold(
                  appBar: AppBar(title: const Text('流迹')),
                  body: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            controller.startupError!,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: controller.initialize,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : controller.space!.verified
              ? HomePage(
                  key: ValueKey(controller.space!.id),
                  app: controller,
                  space: controller.space!,
                )
              : DraftsPage(controller: controller),
        ),
        routes: {
          '/diagnostics': (_) {
            final captured = controller.space;
            return AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                if (captured == null ||
                    !captured.verified ||
                    controller.space?.id != captured.id) {
                  return Scaffold(
                    appBar: AppBar(title: const Text('本机诊断')),
                    body: const Center(child: Text('登录账号后查看对应的本机诊断记录。')),
                  );
                }
                return ClientDiagnosticsPage(
                  diagnostics: controller.diagnostics,
                  space: captured,
                  isCurrent: () => controller.space?.id == captured.id,
                );
              },
            );
          },
          '/settings': (_) => SettingsPage(
            controller: controller,
            preferences: controller.preferences,
            protection: controller.protection,
          ),
          if (controller.identity != null)
            '/data-tools': (_) => AppDataToolsPage(app: controller),
          if (controller.identity != null)
            '/account': (_) => AccountPage(app: controller),
          if (controller.identity != null)
            '/sync': (_) =>
                SyncPage(app: controller, engine: controller.syncEngine),
        },
      ),
    ),
  );
}

final class _UpdateNavigation extends NavigatorObserver {
  final routes = <Route<dynamic>>[];
  int revision = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    ++revision;
    routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    ++revision;
    routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    ++revision;
    routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    ++revision;
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        routes.removeAt(index);
      } else {
        routes[index] = newRoute;
      }
    }
  }
}
