{{flutter_js}}
{{flutter_build_config}}

// FlowTraceShell loads this only after the complete, verified release is active.
// Service worker registration belongs to that shell, never to Flutter's loader.
_flutter.loader.load({config: {canvasKitBaseUrl: "canvaskit/"}});
