import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'export_saver.dart';

Future<DataToolsExportDestination?> chooseExport(String format) async {
  final location = await getSaveLocation(
    suggestedName: 'flowtrace-export.$format',
    acceptedTypeGroups: [
      XTypeGroup(label: format.toUpperCase(), extensions: [format]),
    ],
  );
  return location == null ? null : _Destination(location.path, format);
}

final class _Destination implements DataToolsExportDestination {
  _Destination(this.path, this.format);
  final String path, format;
  bool used = false;
  @override
  Future<DataToolsExportStatus> write(
    Uint8List bytes, {
    required void Function() guard,
  }) async {
    if (used || bytes.isEmpty || bytes.length > 25 * 1024 * 1024) {
      throw StateError('导出文件无效。');
    }
    guard();
    used = true;
    await XFile.fromData(
      bytes,
      name: 'flowtrace-export.$format',
      mimeType: format == 'json'
          ? 'application/json'
          : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ).saveTo(path);
    return DataToolsExportStatus.downloadStarted;
  }

  @override
  Future<void> discard() async {}
}
