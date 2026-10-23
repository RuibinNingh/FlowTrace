import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:uuid/uuid.dart';

import 'export_saver.dart';

Future<DataToolsExportDestination?> chooseExport(String format) async {
  if (!Platform.isWindows) throw UnsupportedError('当前原生导出入口支持Windows。');
  final location = await getSaveLocation(
    suggestedName: 'flowtrace-export.$format',
    acceptedTypeGroups: [
      XTypeGroup(label: format.toUpperCase(), extensions: [format]),
    ],
  );
  return location == null ? null : _Destination(location.path);
}

final class _Destination implements DataToolsExportDestination {
  _Destination(this.path);
  final String path;
  File? pending;
  bool used = false;
  @override
  Future<DataToolsExportStatus> write(
    Uint8List bytes, {
    required void Function() guard,
  }) async {
    if (used || bytes.isEmpty || bytes.length > 25 * 1024 * 1024) {
      throw StateError('导出文件无效。');
    }
    used = true;
    guard();
    final temporary = File('$path.flowtrace-${const Uuid().v4()}.part');
    await temporary.create(exclusive: true);
    pending = temporary;
    final output = await temporary.open(mode: FileMode.writeOnly);
    try {
      await output.writeFrom(bytes);
      await output.flush();
    } finally {
      await output.close();
    }
    guard();
    await temporary.rename(path);
    pending = null;
    return DataToolsExportStatus.saved;
  }

  @override
  Future<void> discard() async {
    final temporary = pending;
    if (temporary != null && await temporary.exists()) await temporary.delete();
    pending = null;
  }
}
