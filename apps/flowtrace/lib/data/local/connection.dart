import 'package:drift/drift.dart';

import 'connection_unsupported.dart'
    if (dart.library.io) 'connection_native.dart'
    if (dart.library.js_interop) 'connection_web.dart'
    as platform;

Future<QueryExecutor> openPlatformConnection() => platform.openConnection();
