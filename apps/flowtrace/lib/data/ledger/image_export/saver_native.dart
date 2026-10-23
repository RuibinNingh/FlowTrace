import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'target.dart';

const _channel = MethodChannel('flowtrace/image_export');

LedgerImageExportSaver openSaver() => Platform.isAndroid
    ? const AndroidLedgerImageExportSaver()
    : Platform.isWindows
    ? const WindowsLedgerImageExportSaver()
    : throw UnsupportedError('当前平台尚不支持图片导出。');

/// Separate choose/stage/commit calls let Dart revalidate a captured lease after
/// the system dialog and immediately before publishing the complete archive.
final class AndroidLedgerImageExportSaver implements LedgerImageExportSaver {
  const AndroidLedgerImageExportSaver({this.channel = _channel});
  final MethodChannel channel;
  @override
  Future<LedgerImageExportDestination?> choose() async {
    final token = await channel.invokeMethod<String>('choose');
    if (token == null) return null;
    if (!RegExp(
      r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    ).hasMatch(token)) {
      throw const FormatException('Invalid export destination');
    }
    return _AndroidDestination(channel, token);
  }
}

final class _AndroidDestination implements LedgerNamedImageExportDestination {
  _AndroidDestination(this.channel, this.token);
  final MethodChannel channel;
  final String token;
  @override
  String get fileName => 'flowtrace-images-${token.substring(0, 8)}.zip';
  bool committed = false;
  bool used = false;
  @override
  Future<LedgerImageExportStatus> write(
    Uint8List bytes, {
    required Future<void> Function() guard,
  }) async {
    if (used || bytes.isEmpty || bytes.length > imageExportMaxZipBytes) {
      throw StateError('Invalid export destination');
    }
    used = true;
    await guard();
    await channel.invokeMethod<void>('stage', {'token': token, 'bytes': bytes});
    await guard();
    await channel.invokeMethod<void>('commit', {'token': token});
    committed = true;
    return LedgerImageExportStatus.saved;
  }

  @override
  Future<void> discard() async {
    if (!committed) {
      await channel.invokeMethod<void>('discard', {'token': token});
    }
  }
}

final class WindowsLedgerImageExportSaver implements LedgerImageExportSaver {
  const WindowsLedgerImageExportSaver({this.chooseLocation});
  final Future<FileSaveLocation?> Function()? chooseLocation;
  @override
  Future<LedgerImageExportDestination?> choose() async {
    final location =
        await (chooseLocation?.call() ??
            getSaveLocation(
              acceptedTypeGroups: const [
                XTypeGroup(label: 'ZIP', extensions: ['zip']),
              ],
              suggestedName: imageExportFileName,
            ));
    return location == null ? null : _WindowsDestination(location.path);
  }
}

final class _WindowsDestination implements LedgerNamedImageExportDestination {
  _WindowsDestination(this.path);
  final String path;
  @override
  String get fileName => File(path).uri.pathSegments.last;
  File? temporary;
  bool used = false;
  @override
  Future<LedgerImageExportStatus> write(
    Uint8List bytes, {
    required Future<void> Function() guard,
  }) async {
    if (used || bytes.isEmpty || bytes.length > imageExportMaxZipBytes) {
      throw StateError('Invalid export destination');
    }
    used = true;
    await guard();
    final file = File('$path.flowtrace-${const Uuid().v4()}.part');
    await file.create(exclusive: true);
    temporary = file;
    final handle = await file.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await guard();
    await file.rename(path);
    temporary = null;
    return LedgerImageExportStatus.saved;
  }

  @override
  Future<void> discard() async {
    final file = temporary;
    if (file != null && await file.exists()) await file.delete();
    temporary = null;
  }
}
