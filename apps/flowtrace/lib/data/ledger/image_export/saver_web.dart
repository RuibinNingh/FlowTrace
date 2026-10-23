import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'target.dart';

LedgerImageExportSaver openSaver() => const _WebSaver();

final class _WebSaver implements LedgerImageExportSaver {
  const _WebSaver();
  @override
  Future<LedgerImageExportDestination?> choose() async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ZIP', extensions: ['zip']),
      ],
      suggestedName: imageExportFileName,
    );
    return location == null ? null : _WebDestination(location.path);
  }
}

final class _WebDestination implements LedgerImageExportDestination {
  _WebDestination(this.path);
  final String path;
  bool used = false;
  @override
  Future<LedgerImageExportStatus> write(
    Uint8List bytes, {
    required Future<void> Function() guard,
  }) async {
    if (used || bytes.isEmpty || bytes.length > imageExportMaxZipBytes) {
      throw StateError('Invalid export destination');
    }
    await guard();
    used = true;
    await XFile.fromData(
      bytes,
      name: imageExportFileName,
      mimeType: 'application/zip',
    ).saveTo(path);
    return LedgerImageExportStatus.downloadStarted;
  }

  @override
  Future<void> discard() async {}
}
