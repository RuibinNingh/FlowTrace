import 'dart:async';

import 'package:drift/drift.dart';

import 'connection.dart';
import 'write_gate.dart';

part 'app_database.g.dart';

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DataClassName('StoredSpace')
class LocalSpaces extends Table {
  TextColumn get id => text()();
  TextColumn get serverAddress => text()();
  TextColumn get serverInstanceId => text()();
  TextColumn get userId => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('StoredDraft')
class LocalDrafts extends Table {
  TextColumn get id => text()();
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get body => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, id};
}

@DataClassName('StoredEntity')
class LocalEntities extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get scopeId => text().withDefault(const Constant(''))();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get dataJson => text()();
  TextColumn get serverRevision => text().withDefault(const Constant('0'))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, entityType, entityId};
}

@DataClassName('StoredOperation')
class PendingOperations extends Table {
  IntColumn get sequence => integer().autoIncrement()();
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get operationId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operationJson => text()();
  TextColumn get frozenRequestJson => text().nullable()();
  TextColumn get state => text().withDefault(const Constant('queued'))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get predecessorId => text().nullable()();
  TextColumn get appliedRevision => text().nullable()();
  TextColumn get baseDataJson => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {spaceId, operationId},
  ];
}

@DataClassName('ConfirmedEntity')
class ServerShadows extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get scopeId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get revision => text()();
  TextColumn get dataJson => text()();
  BoolColumn get deleted => boolean()();

  @override
  Set<Column<Object>> get primaryKey => {
    spaceId,
    scopeId,
    entityType,
    entityId,
  };
}

@DataClassName('SpaceSyncState')
class SyncStates extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get clientId => text()();
  TextColumn get epoch => text()();
  TextColumn get cursorsJson => text().withDefault(const Constant('{}'))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get revokedScopesJson =>
      text().withDefault(const Constant('[]'))();

  @override
  Set<Column<Object>> get primaryKey => {spaceId};
}

@DataClassName('StoredConflict')
class SyncConflicts extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get operationId => text()();
  TextColumn get scopeId => text()();
  TextColumn get code => text()();
  TextColumn get baseJson => text().nullable()();
  TextColumn get localJson => text()();
  TextColumn get serverJson => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, operationId};
}

@DataClassName('RecoveryBackup')
class SyncRecoveryBackups extends Table {
  TextColumn get id => text()();
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get reason => text()();
  TextColumn get oldEpoch => text()();
  TextColumn get dataJson => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('StagedSnapshotPage')
class SnapshotPages extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get snapshotId => text()();
  IntColumn get pageIndex => integer()();
  TextColumn get itemsJson => text()();
  TextColumn get sha256 => text()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, snapshotId, pageIndex};
}

@DataClassName('StoredGroupPull')
class GroupPulls extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get requestId => text()();
  TextColumn get clientId => text()();
  TextColumn get epoch => text()();
  TextColumn get intentJson => text()();
  TextColumn get statusJson => text().nullable()();
  TextColumn get pullId => text().nullable()();
  TextColumn get nextToken => text().nullable()();
  TextColumn get receiveStateJson => text()();
  IntColumn get receivedPages => integer().withDefault(const Constant(0))();
  IntColumn get reservedBytes => integer().withDefault(const Constant(0))();
  IntColumn get installedUnits => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, requestId};
}

@DataClassName('StoredGroupPage')
class GroupPages extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get requestId => text()();
  IntColumn get ordinal => integer()();
  TextColumn get requestToken => text()();
  TextColumn get kind => text()();
  TextColumn get groupId => text()();
  IntColumn get pageIndex => integer()();
  TextColumn get bodyJson => text()();
  TextColumn get sha256 => text()();
  IntColumn get sizeBytes => integer()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, requestId, ordinal};
  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {spaceId, requestId, requestToken},
    {spaceId, requestId, kind, groupId, pageIndex},
  ];
}

@DataClassName('StoredGroupReceipt')
class GroupReceipts extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get requestId => text()();
  IntColumn get unitIndex => integer()();
  TextColumn get groupId => text()();
  TextColumn get manifestSha256 => text()();
  TextColumn get endCursorsJson => text()();
  IntColumn get sizeBytes => integer()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, requestId, unitIndex};
}

@DataClassName('StoredStageImportSource')
class StageImportSources extends Table {
  TextColumn get spaceId => text().references(LocalSpaces, #id)();
  TextColumn get stageId => text()();
  TextColumn get clientId => text()();
  TextColumn get epoch => text()();
  TextColumn get originSessionId => text()();
  TextColumn get format => text()();
  TextColumn get fileName => text()();
  TextColumn get sourceSha256 => text()();
  TextColumn get createBodyJson => text()();
  TextColumn get stateJson => text()();
  IntColumn get expectedBytes => integer()();
  IntColumn get reservedBytes => integer()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, stageId};
}

@DataClassName('StoredStageImportChunk')
class StageImportChunks extends Table {
  TextColumn get spaceId => text()();
  TextColumn get stageId => text()();
  IntColumn get chunkIndex => integer()();
  BlobColumn get body => blob()();
  TextColumn get sha256 => text()();
  IntColumn get sizeBytes => integer()();
  TextColumn get receiptJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, stageId, chunkIndex};
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (space_id, stage_id) REFERENCES stage_import_sources(space_id, stage_id)',
  ];
}

@DataClassName('StoredStageImportCommand')
class StageImportCommands extends Table {
  TextColumn get spaceId => text()();
  TextColumn get stageId => text()();
  TextColumn get commandId => text()();
  TextColumn get kind => text()();
  IntColumn get stageVersion => integer()();
  TextColumn get bodyJson => text()();
  TextColumn get responseJson => text().nullable()();
  TextColumn get phase => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {spaceId, stageId, commandId};
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (space_id, stage_id) REFERENCES stage_import_sources(space_id, stage_id)',
  ];
}

/// Independent source bytes for a recovery checkpoint. Active import source
/// cleanup cannot invalidate this backup, and JSON never contains large BLOBs.
@DataClassName('StoredStageImportRecoveryChunk')
class StageImportRecoveryChunks extends Table {
  TextColumn get backupId => text().references(SyncRecoveryBackups, #id)();
  TextColumn get stageId => text()();
  IntColumn get chunkIndex => integer()();
  BlobColumn get body => blob()();
  TextColumn get sha256 => text()();
  IntColumn get sizeBytes => integer()();

  @override
  Set<Column<Object>> get primaryKey => {backupId, stageId, chunkIndex};
}

@DriftDatabase(
  tables: [
    AppSettings,
    LocalSpaces,
    LocalDrafts,
    LocalEntities,
    PendingOperations,
    ServerShadows,
    SyncStates,
    SyncConflicts,
    SyncRecoveryBackups,
    SnapshotPages,
    GroupPulls,
    GroupPages,
    GroupReceipts,
    StageImportSources,
    StageImportChunks,
    StageImportCommands,
    StageImportRecoveryChunks,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : this._(
        executor ?? LazyDatabase(openPlatformConnection),
        DatabaseWriteGate(),
      );

  AppDatabase._(QueryExecutor executor, this.writeGate)
    : super(executor.interceptWith(writeGate));

  final DatabaseWriteGate writeGate;

  final Object _atomicZoneKey = Object();
  final Object _transactionZoneKey = Object();

  /// Track the public transaction callback without changing Drift's transaction
  /// or savepoint behavior. Helpers need no access to Drift's internal engine.
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) => super.transaction(() {
    final scope = _DatabaseTransactionScope();
    return runZoned(() async {
      try {
        return await action();
      } finally {
        scope.active = false;
      }
    }, zoneValues: {_transactionZoneKey: scope});
  }, requireNew: requireNew);

  /// Reuse a caller's consistent snapshot instead of creating a savepoint for
  /// a read. Outside a transaction, the complete read still has one snapshot.
  Future<T> readSnapshot<T>(Future<T> Function() action) {
    final scope =
        Zone.current[_transactionZoneKey] as _DatabaseTransactionScope?;
    if (scope != null) {
      if (!scope.active) {
        throw StateError('本地事务已结束，不能继续读取该快照。');
      }
      return action();
    }
    return writeGate.readSnapshot(() => transaction(action));
  }

  /// One transaction owns a complete application write. Nested helpers join
  /// it without remote savepoints. Any failed helper makes the whole write
  /// rollback-only, even when its caller catches that failure.
  ///
  /// Raw Drift transactions retain their original semantics. A write cannot
  /// join one implicitly: its caller must use this method as the outer owner.
  Future<T> atomicWrite<T>(Future<T> Function() action) async {
    final transactionScope =
        Zone.current[_transactionZoneKey] as _DatabaseTransactionScope?;
    final inherited = Zone.current[_atomicZoneKey] as _AtomicWriteScope?;
    if (inherited != null) {
      if (!inherited.active) {
        throw StateError('本地写入事务已结束，不能继续异步写入。');
      }
      try {
        if (!identical(inherited.transaction, transactionScope) ||
            transactionScope?.active != true) {
          throw StateError('本地写入不能嵌套到另一个原始事务。');
        }
        return await action();
      } catch (error, trace) {
        inherited.failure ??= error;
        inherited.failureTrace ??= trace;
        rethrow;
      }
    }
    if (transactionScope != null) {
      throw StateError('完整本地写入必须由atomicWrite事务持有。');
    }
    return transaction(() async {
      final scope = _AtomicWriteScope(
        Zone.current[_transactionZoneKey] as _DatabaseTransactionScope,
      );
      return runZoned(() async {
        try {
          final result = await action();
          if (scope.failure != null) {
            Error.throwWithStackTrace(scope.failure!, scope.failureTrace!);
          }
          return result;
        } finally {
          scope.active = false;
        }
      }, zoneValues: {_atomicZoneKey: scope});
    });
  }

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // Schema 1 is the isolated settings-only predecessor used by migration
      // fixtures. No destructive table rebuild or user-data reset is needed.
      if (from < 2) {
        await m.createTable(localSpaces);
        await m.createTable(localDrafts);
        await m.createTable(localEntities);
        await m.createTable(pendingOperations);
      }
      if (from >= 2 && from < 3) {
        await m.addColumn(localEntities, localEntities.scopeId);
        await m.addColumn(pendingOperations, pendingOperations.predecessorId);
        await m.addColumn(pendingOperations, pendingOperations.appliedRevision);
        await m.addColumn(pendingOperations, pendingOperations.baseDataJson);
      }
      if (from < 3) {
        await m.createTable(serverShadows);
        await m.createTable(syncStates);
        await m.createTable(syncConflicts);
        await m.createTable(syncRecoveryBackups);
        await m.createTable(snapshotPages);
        // V2 had no scope column. Recover it only from that entity's own
        // persisted command; unmatched legacy rows stay isolated (empty scope).
        await customStatement('''
          UPDATE local_entities SET scope_id = COALESCE((
            SELECT json_extract(operation_json, '\$.scope_id')
            FROM pending_operations p
            WHERE p.space_id = local_entities.space_id
              AND p.entity_type = local_entities.entity_type
              AND p.entity_id = local_entities.entity_id
            ORDER BY p.sequence DESC LIMIT 1
          ), '')
        ''');
      }
      if (from < 4) {
        await m.createTable(groupPulls);
        await m.createTable(groupPages);
        await m.createTable(groupReceipts);
      }
      if (from < 5) {
        await m.createTable(stageImportSources);
        await m.createTable(stageImportChunks);
        await m.createTable(stageImportCommands);
        await m.createTable(stageImportRecoveryChunks);
      }
    },
    beforeOpen: (_) => customStatement('PRAGMA foreign_keys = ON'),
  );
}

final class _AtomicWriteScope {
  _AtomicWriteScope(this.transaction);
  final _DatabaseTransactionScope transaction;
  bool active = true;
  Object? failure;
  StackTrace? failureTrace;
}

final class _DatabaseTransactionScope {
  bool active = true;
}
