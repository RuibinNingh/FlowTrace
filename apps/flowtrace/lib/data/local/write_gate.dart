import 'dart:async';
import 'dart:collection';

import 'package:drift/drift.dart';

/// Fences all SQLite writers, including direct statements and raw transactions.
/// Existing transactions retain their permit until commit or rollback finishes.
final class DatabaseWriteGate extends QueryInterceptor {
  bool _paused = false;
  int _active = 0;
  Completer<void>? _drained;
  final Set<TransactionExecutor> _transactions = HashSet.identity();
  final Set<TransactionExecutor> _readTransactions = HashSet.identity();
  final Object _readZone = Object();

  bool get paused => _paused;

  void _enter() {
    if (_paused) throw StateError('正在准备更新，请稍后再保存。');
    ++_active;
  }

  void _leave() {
    --_active;
    if (_active == 0) {
      _drained?.complete();
      _drained = null;
    }
  }

  Future<bool> pauseAndDrain({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _paused = true;
    if (_active == 0) return true;
    _drained ??= Completer<void>();
    try {
      await _drained!.future.timeout(timeout);
      return _paused && _active == 0;
    } on TimeoutException {
      return false;
    }
  }

  void resume() => _paused = false;

  Future<T> readSnapshot<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_readZone: true});

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    if (Zone.current[_readZone] == true && !_transactions.contains(parent)) {
      final transaction = parent.beginTransaction();
      _readTransactions.add(transaction);
      return transaction;
    }
    // A nested savepoint may finish an already admitted transaction while the
    // gate is closed. A new root transaction cannot enter that window.
    if (_transactions.contains(parent)) {
      ++_active;
    } else {
      _enter();
    }
    try {
      final transaction = parent.beginTransaction();
      _transactions.add(transaction);
      return transaction;
    } catch (_) {
      _leave();
      rethrow;
    }
  }

  Future<void> _finish(
    TransactionExecutor inner,
    Future<void> Function() action,
  ) async {
    await action();
    _readTransactions.remove(inner);
    if (_transactions.remove(inner)) _leave();
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    // On commit failure Drift still has to roll back. Keep the permit until
    // that rollback settles, rather than allowing an update in between.
    await inner.send();
    _readTransactions.remove(inner);
    if (_transactions.remove(inner)) _leave();
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) =>
      _finish(inner, inner.rollback);

  Future<T> _write<T>(
    QueryExecutor executor,
    Future<T> Function() action,
  ) async {
    if (_readTransactions.contains(executor)) {
      throw StateError('只读快照不能写入本地资料。');
    }
    if (_transactions.contains(executor)) return action();
    _enter();
    try {
      return await action();
    } finally {
      _leave();
    }
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => _write(executor, () => executor.runBatched(statements));

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _write(executor, () => executor.runCustom(statement, args));

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _write(executor, () => executor.runInsert(statement, args));

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _write(executor, () => executor.runDelete(statement, args));

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _write(executor, () => executor.runUpdate(statement, args));
}
