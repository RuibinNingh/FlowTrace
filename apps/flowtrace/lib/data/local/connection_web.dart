import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

Future<QueryExecutor> openConnection() async {
  final opened = await WasmDatabase.open(
    databaseName: 'flowtrace',
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
  );
  if (opened.chosenImplementation == WasmStorageImplementation.inMemory ||
      opened.chosenImplementation ==
          WasmStorageImplementation.unsafeIndexedDb) {
    await opened.resolvedExecutor.close();
    throw UnsupportedError('浏览器未提供安全的多标签页持久化存储，不能将草稿标为已保存。');
  }
  return opened.resolvedExecutor;
}
