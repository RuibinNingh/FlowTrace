import 'saver_unsupported.dart'
    if (dart.library.io) 'saver_native.dart'
    if (dart.library.js_interop) 'saver_web.dart'
    as platform;
import 'target.dart';

LedgerImageExportSaver openLedgerImageExportSaver() => platform.openSaver();
