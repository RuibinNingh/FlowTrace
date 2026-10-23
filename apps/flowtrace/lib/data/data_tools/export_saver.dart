import 'dart:typed_data';

import 'export_saver_unsupported.dart'
    if (dart.library.io) 'export_saver_native.dart'
    if (dart.library.js_interop) 'export_saver_web.dart'
    as platform;

enum DataToolsExportStatus { saved, downloadStarted }

abstract interface class DataToolsExportDestination {
  Future<DataToolsExportStatus> write(
    Uint8List bytes, {
    required void Function() guard,
  });
  Future<void> discard();
}

Future<DataToolsExportDestination?> chooseDataToolsExport(String format) {
  if (!{'json', 'xlsx'}.contains(format)) throw ArgumentError('无效导出格式。');
  return platform.chooseExport(format);
}
