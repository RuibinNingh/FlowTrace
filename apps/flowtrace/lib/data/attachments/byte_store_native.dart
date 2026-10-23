import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../platform/windows/windows_runtime.dart';

import 'byte_store.dart';

Future<AttachmentByteStore> openAttachmentBytes() async {
  final root = Platform.isWindows
      ? await WindowsRuntime.dataDirectory()
      : Directory(
          p.join((await getApplicationSupportDirectory()).path, 'flowtrace'),
        );
  return NativeAttachmentBytes(Directory(p.join(root.path, 'attachments')));
}

final class NativeAttachmentBytes implements AttachmentByteStore {
  NativeAttachmentBytes(this.directory);
  final Directory directory;
  static const _uuid = Uuid();

  Future<void> _directory() async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const AttachmentStorageFailure();
    }
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const AttachmentStorageFailure();
    }
  }

  File _file(String key) {
    validateBlobKey(key);
    return File(p.join(directory.path, '$key.blob'));
  }

  Future<void> _ordinary(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const AttachmentStorageFailure();
    }
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    validateBlobKey(key);
    final frozen = Uint8List.fromList(bytes);
    if (frozen.isEmpty || frozen.length > attachmentMaxBytes) {
      throw const AttachmentStorageFailure();
    }
    File? temporary;
    try {
      await _directory();
      final original = await read(key);
      if (original != null) {
        if (sha256.convert(original) != sha256.convert(frozen)) {
          throw const AttachmentStorageFailure();
        }
        return;
      }
      temporary = File(p.join(directory.path, '.${_uuid.v4()}.part'));
      await temporary.create(exclusive: true);
      await temporary.writeAsBytes(frozen, flush: true);
      await temporary.rename(_file(key).path);
    } catch (_) {
      throw const AttachmentStorageFailure();
    } finally {
      if (temporary != null) {
        try {
          if (await temporary.exists()) {
            await temporary.delete();
          }
        } catch (_) {
          /* Orphan remains private. */
        }
      }
    }
  }

  @override
  Future<Uint8List?> read(String key) async {
    final file = _file(key);
    try {
      await _directory();
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      await _ordinary(file);
      if (await file.length() > attachmentMaxBytes) {
        throw const AttachmentStorageFailure();
      }
      final output = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (output.length + chunk.length > attachmentMaxBytes) {
          throw const AttachmentStorageFailure();
        }
        output.add(chunk);
      }
      return output.takeBytes();
    } catch (_) {
      throw const AttachmentStorageFailure();
    }
  }

  @override
  Future<void> delete(String key) async {
    final file = _file(key);
    try {
      await _directory();
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return;
      }
      await _ordinary(file);
      await file.delete();
    } catch (_) {
      throw const AttachmentStorageFailure();
    }
  }

  @override
  Future<void> close() async {}
}
