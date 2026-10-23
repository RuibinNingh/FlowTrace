import 'dart:typed_data';

const attachmentMaxBytes = 10 * 1024 * 1024;

final class AttachmentStorageFailure implements Exception {
  const AttachmentStorageFailure();
  @override
  String toString() => '附件未能写入本机存储，请释放空间后重试。';
}

void validateBlobKey(String key) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
    throw const FormatException('Invalid attachment storage key');
  }
}

/// Bytes survive a new store instance. There is no in-memory fallback.
abstract interface class AttachmentByteStore {
  Future<void> write(String key, Uint8List bytes);
  Future<Uint8List?> read(String key);
  Future<void> delete(String key);
  Future<void> close();
}
