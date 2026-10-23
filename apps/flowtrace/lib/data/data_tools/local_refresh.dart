import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'data_tools_models.dart';
import 'data_tools_repository.dart';

/// Server acknowledgment and local materialization have separate durability.
/// Retrying this coordinator never reissues an import/undo or financial write.
class DataToolsLocalRefresh {
  DataToolsLocalRefresh(this.repository);
  final DataToolsRepository repository;

  String _key(DataToolsLease lease, String batch) =>
      'data_tools.local_refresh.v1.${lease.space.id}.$batch';
  String _marker(StoredDataImport record) => jsonEncode({
    'version': 1,
    'phase': record.phase,
    'receipt_hash': sha256
        .convert(utf8.encode(jsonEncode(record.result!.toJson())))
        .toString(),
  });

  Future<void> _finish(
    DataToolsLease lease,
    StoredDataImport record,
    Future<void> Function(DataImportApplied receipt, bool undo) adopt,
  ) async {
    lease.check();
    await adopt(record.result!, record.phase == 'undone');
    lease.check();
    await repository.local.database.atomicWrite(() async {
      lease.check();
      final current = await repository.read(lease.space, record.batchId);
      if (current == null ||
          current.phase != record.phase ||
          current.result == null ||
          _marker(current) != _marker(record)) {
        throw StateError('Data import changed during local refresh');
      }
      await repository.local.writeSetting(
        _key(lease, record.batchId),
        _marker(record),
      );
      lease.check();
    });
  }

  Future<void> acknowledge(
    DataToolsLease lease,
    DataImportApplied receipt, {
    required bool undo,
    required Future<void> Function(DataImportApplied receipt, bool undo) adopt,
  }) async {
    lease.check();
    final current = await repository.read(lease.space, receipt.batchId);
    lease.check();
    if (current == null ||
        current.epoch != lease.epoch ||
        current.clientId != lease.clientId ||
        current.phase != (undo ? 'undone' : 'applied') ||
        current.result == null ||
        jsonEncode(current.result!.toJson()) != jsonEncode(receipt.toJson())) {
      throw StateError('Data import acknowledgment is unavailable');
    }
    await _finish(lease, current, adopt);
  }

  /// Call only after a fresh authorized server pull. Failed items remain pending
  /// across process restarts; bounded work avoids blocking all UI on old errors.
  Future<int> reconcile(
    DataToolsLease lease, {
    required Future<void> Function(DataImportApplied receipt, bool undo) adopt,
  }) async {
    lease.check();
    final records = await repository.list(lease.space);
    var remaining = 0, processed = 0;
    for (final record in records) {
      if (!{'applied', 'undone'}.contains(record.phase) ||
          record.result == null ||
          record.epoch != lease.epoch ||
          record.clientId != lease.clientId) {
        continue;
      }
      lease.check();
      final prior = await repository.local.readSetting(
        _key(lease, record.batchId),
      );
      lease.check();
      if (prior == _marker(record)) continue;
      if (processed++ >= 50) {
        remaining++;
        continue;
      }
      try {
        await _finish(lease, record, adopt);
      } catch (_) {
        lease
            .check(); // Identity changes are never reduced to a benign warning.
        remaining++;
      }
    }
    return remaining;
  }
}
