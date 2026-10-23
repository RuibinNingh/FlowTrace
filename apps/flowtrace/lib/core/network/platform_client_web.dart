import 'dart:js_interop';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

http.Client createPlatformClient() => BrowserClient()..withCredentials = true;

String? browserCsrfToken() {
  for (final part in web.document.cookie.split(';')) {
    final pair = part.trim();
    if (pair.startsWith('flowtrace_web_csrf=')) {
      return Uri.decodeComponent(pair.substring('flowtrace_web_csrf='.length));
    }
  }
  return null;
}

Future<void> withBrowserRefreshLock(
  String name,
  Future<void> Function() action,
) async {
  await web.window.navigator.locks
      .request(
        name,
        ((web.Lock? lock) {
          return (() async {
            await action();
            return null as JSAny?;
          })().toJS;
        }).toJS,
      )
      .toDart;
}
