export 'byte_store_unsupported.dart'
    if (dart.library.io) 'byte_store_native.dart'
    if (dart.library.js_interop) 'byte_store_web.dart';
