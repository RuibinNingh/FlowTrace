import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'protection_notifications_api.dart';

ProtectionNotifications createProtectionNotifications() =>
    _BrowserNotifications();

class _BrowserNotifications implements ProtectionNotifications {
  _BrowserNotifications() {
    try {
      _channel = web.BroadcastChannel('flowtrace.app-protection.v1');
      _listener = ((web.Event event) {
        if ((event as web.MessageEvent).data.dartify() == 'changed') {
          _changes.add(null);
        }
      }).toJS;
      _channel!.addEventListener('message', _listener);
    } catch (_) {
      _channel = null;
    }
  }
  web.BroadcastChannel? _channel;
  JSFunction? _listener;
  final _changes = StreamController<void>.broadcast();
  @override
  bool get available => _channel != null;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  void publish() => _channel?.postMessage('changed'.toJS);
  @override
  void close() {
    if (_listener != null) _channel?.removeEventListener('message', _listener);
    _channel?.close();
    _channel = null;
    unawaited(_changes.close());
  }
}
