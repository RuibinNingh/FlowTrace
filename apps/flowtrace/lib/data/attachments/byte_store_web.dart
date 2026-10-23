import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web/web.dart' as web;

import 'byte_store.dart';

Future<AttachmentByteStore> openAttachmentBytes() async => WebAttachmentBytes();

final class WebAttachmentBytes implements AttachmentByteStore {
  WebAttachmentBytes({this.databaseName = 'flowtrace-attachments'});
  final String databaseName;
  Future<web.IDBDatabase>? _database;

  Future<web.IDBDatabase> _open() => _database ??= _connect();

  Future<web.IDBDatabase> _connect() async {
    final done = Completer<web.IDBDatabase>();
    var expired = false;
    try {
      final request = web.window.indexedDB.open(databaseName, 1);
      request.onupgradeneeded = ((web.Event event) {
        final database = request.result as web.IDBDatabase;
        database.createObjectStore('bytes');
      }).toJS;
      request.onsuccess = ((web.Event event) {
        final database = request.result as web.IDBDatabase;
        database.onversionchange = ((web.Event _) {
          database.close();
        }).toJS;
        if (done.isCompleted || expired) {
          database.close();
        } else {
          done.complete(database);
        }
      }).toJS;
      void failed(web.Event _) {
        if (!done.isCompleted) {
          done.completeError(const AttachmentStorageFailure());
        }
      }

      request.onerror = failed.toJS;
      request.onblocked = failed.toJS;
      return await done.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          expired = true;
          throw const AttachmentStorageFailure();
        },
      );
    } catch (_) {
      _database = null;
      throw const AttachmentStorageFailure();
    }
  }

  Future<T> _transaction<T>(
    String key,
    bool write,
    T Function(JSAny?) read, {
    Uint8List? bytes,
  }) async {
    validateBlobKey(key);
    try {
      final database = await _open();
      final transaction = database.transaction(
        'bytes'.toJS,
        write ? 'readwrite' : 'readonly',
        web.IDBTransactionOptions(durability: 'strict'),
      );
      final store = transaction.objectStore('bytes');
      final done = Completer<T>();
      T? result;
      void failed(web.Event _) {
        if (!done.isCompleted) {
          done.completeError(const AttachmentStorageFailure());
        }
      }

      transaction.onerror = failed.toJS;
      transaction.onabort = failed.toJS;
      transaction.oncomplete = ((web.Event event) {
        if (!done.isCompleted) done.complete(result as T);
      }).toJS;
      final request = store.get(key.toJS);
      request.onsuccess = ((web.Event event) {
        try {
          final raw = request.result;
          result = read(raw);
          if (write) {
            if (bytes == null) {
              store.delete(key.toJS);
            } else if (raw == null) {
              store.add(bytes.toJS, key.toJS);
            } else {
              final previous = (raw as JSUint8Array).toDart;
              if (sha256.convert(previous) != sha256.convert(bytes)) {
                transaction.abort();
                if (!done.isCompleted) {
                  done.completeError(const AttachmentStorageFailure());
                }
              }
            }
          }
        } catch (_) {
          transaction.abort();
          if (!done.isCompleted) {
            done.completeError(const AttachmentStorageFailure());
          }
        }
      }).toJS;
      return await done.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          transaction.abort();
          throw const AttachmentStorageFailure();
        },
      );
    } catch (_) {
      throw const AttachmentStorageFailure();
    }
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    final frozen = Uint8List.fromList(bytes);
    if (frozen.isEmpty || frozen.length > attachmentMaxBytes) {
      throw const AttachmentStorageFailure();
    }
    await _transaction<bool>(key, true, (_) => true, bytes: frozen);
  }

  @override
  Future<Uint8List?> read(String key) =>
      _transaction<Uint8List?>(key, false, (raw) {
        if (raw == null) return null;
        final bytes = Uint8List.fromList((raw as JSUint8Array).toDart);
        if (bytes.length > attachmentMaxBytes) {
          throw const AttachmentStorageFailure();
        }
        return bytes;
      });

  @override
  Future<void> delete(String key) async {
    await _transaction<bool>(key, true, (_) => true);
  }

  @override
  Future<void> close() async {
    final current = _database;
    _database = null;
    if (current != null) (await current).close();
  }
}
