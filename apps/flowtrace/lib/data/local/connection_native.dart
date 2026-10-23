import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../platform/windows/windows_runtime.dart';

Future<QueryExecutor> openConnection() async {
  final folder = Platform.isWindows
      ? await WindowsRuntime.dataDirectory()
      : Directory(
          p.join((await getApplicationSupportDirectory()).path, 'flowtrace'),
        );
  await folder.create(recursive: true);
  sqlite3.tempDirectory = (await getTemporaryDirectory()).path;
  return NativeDatabase.createInBackground(
    File(p.join(folder.path, 'flowtrace.sqlite')),
  );
}
