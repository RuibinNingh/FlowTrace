import 'dart:typed_data';

const imageExportMaxOriginalBytes = 20 * 1024 * 1024;
const imageExportMaxZipBytes = 21 * 1024 * 1024;
const imageExportFileName = 'flowtrace-images.zip';

enum LedgerImageExportStatus { saved, downloadStarted, cancelled }

/// A user selected destination, never an application supplied arbitrary URI.
abstract interface class LedgerImageExportDestination {
  Future<LedgerImageExportStatus> write(
    Uint8List bytes, {
    required Future<void> Function() guard,
  });

  /// Releases an unfinished selection; never removes a completed export.
  Future<void> discard();
}

/// Optional actual display name; platform paths and document URIs stay private.
abstract interface class LedgerNamedImageExportDestination
    implements LedgerImageExportDestination {
  String get fileName;
}

abstract interface class LedgerImageExportSaver {
  Future<LedgerImageExportDestination?> choose();
}
