import 'package:http/http.dart' as http;

http.Client createPlatformClient() => http.Client();
String? browserCsrfToken() => null;
Future<void> withBrowserRefreshLock(
  String name,
  Future<void> Function() action,
) => action();
