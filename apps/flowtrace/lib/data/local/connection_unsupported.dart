import 'package:drift/drift.dart';

Future<QueryExecutor> openConnection() async =>
    throw UnsupportedError('当前平台没有可用的持久化存储。');
