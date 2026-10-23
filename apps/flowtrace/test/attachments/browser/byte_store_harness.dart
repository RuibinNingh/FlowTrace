import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flowtrace/data/attachments/byte_store.dart';
import 'package:flowtrace/data/attachments/byte_store_web.dart';
import 'package:web/web.dart' as web;

void main() {
  final button = web.document.querySelector('#run') as web.HTMLButtonElement;
  final status = web.document.querySelector('#status')!;
  button.onclick = ((web.Event _) {
    button.disabled = true;
    status.textContent = '正在验证真实 IndexedDB…';
    run().then(
      (receipt) {
        status.textContent = '通过：原件字节持久化、重开读取、禁止覆盖与受控删除';
        web.document.querySelector('#receipt')!.textContent = jsonEncode(
          receipt,
        );
      },
      onError: (Object _) {
        status.textContent = '未通过：本机存储测试失败';
      },
    );
  }).toJS;
}

Future<Map<String, Object?>> run() async {
  final name =
      'flowtrace-attachment-e2e-${DateTime.now().microsecondsSinceEpoch}';
  final key = 'a' * 64;
  final first = WebAttachmentBytes(databaseName: name);
  final original = Uint8List.fromList([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    1,
    2,
    3,
    4,
  ]);
  final frozen = Uint8List.fromList(original);
  final pending = first.write(key, original);
  original[0] = 0;
  await pending;
  await first.close();
  final second = WebAttachmentBytes(databaseName: name);
  try {
    final after = await second.read(key);
    if (after == null || base64Encode(after) != base64Encode(frozen)) {
      throw StateError('Persistence mismatch');
    }
    var refused = false;
    try {
      await second.write(key, Uint8List.fromList([9]));
    } on AttachmentStorageFailure {
      refused = true;
    }
    if (!refused ||
        base64Encode((await second.read(key))!) != base64Encode(frozen)) {
      throw StateError('Immutable write mismatch');
    }
    await second.delete(key);
    if (await second.read(key) != null) throw StateError('Deletion mismatch');
    return {
      'kind': 'real-browser-indexeddb',
      'checks': 4,
      'passed': true,
      'durable_bytes': frozen.length,
      'in_memory_fallback': false,
    };
  } finally {
    await second.close();
    web.window.indexedDB.deleteDatabase(name);
  }
}
