import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import 'app_database.dart';

final class QueuedCommand {
  QueuedCommand({
    required this.operationId,
    required this.scopeId,
    required this.entityType,
    required this.entityId,
    required this.action,
    required this.baseRevision,
    required Map<String, Object?> payload,
    Map<String, Object?>? move,
    this.dependsOn,
  }) : _payloadJson = _encodePayload(payload),
       _moveJson = move == null ? null : _encodePayload(move) {
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    );
    if (!uuid.hasMatch(operationId) ||
        !uuid.hasMatch(scopeId) ||
        !uuid.hasMatch(entityId) ||
        (dependsOn != null && !uuid.hasMatch(dependsOn!))) {
      throw ArgumentError('同步命令标识必须为规范UUID。');
    }
    if (!{
          'book',
          'account',
          'category',
          'tag',
          'bill',
          'budget',
        }.contains(entityType) ||
        !{'create', 'update', 'delete'}.contains(action) ||
        !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(baseRevision)) {
      throw ArgumentError('无效同步命令。');
    }
    if (move != null) {
      final target = move['target_scope_id'];
      final replacements = move['attachment_replacements'];
      if (entityType != 'bill' ||
          action != 'update' ||
          BigInt.parse(baseRevision) <= BigInt.zero ||
          move.length != 2 ||
          target is! String ||
          !uuid.hasMatch(target) ||
          target == scopeId ||
          payload['book_id'] != target ||
          payload['preserve_hidden_financial_links'] == true ||
          replacements is! List ||
          replacements.length > 20) {
        throw ArgumentError('无效账本移动命令。');
      }
      final sources = <String>{}, targets = <String>{};
      for (final row in replacements) {
        if (row is! Map<String, Object?> ||
            row.length != 2 ||
            row['source_id'] is! String ||
            !uuid.hasMatch(row['source_id'] as String) ||
            row['target_id'] is! String ||
            !uuid.hasMatch(row['target_id'] as String) ||
            row['source_id'] == row['target_id'] ||
            !sources.add(row['source_id'] as String) ||
            !targets.add(row['target_id'] as String)) {
          throw ArgumentError('无效移动附件映射。');
        }
      }
      final ids = payload['attachment_ids'] ?? const <String>[];
      if (sources.intersection(targets).isNotEmpty) {
        throw ArgumentError('来源和目标附件不能交叉复用。');
      }
      if (ids is! List ||
          jsonEncode(ids) !=
              jsonEncode([
                for (final row in replacements) (row as Map)['target_id'],
              ])) {
        throw ArgumentError('移动附件顺序与目标正文不符。');
      }
    }
  }

  final String operationId;
  final String scopeId;
  final String entityType;
  final String entityId;
  final String action;
  final String baseRevision;
  final String _payloadJson;
  final String? _moveJson;
  Map<String, Object?> get payload =>
      (jsonDecode(_payloadJson) as Map<String, dynamic>)
          .cast<String, Object?>();
  final String? dependsOn;
  Map<String, Object?>? get move => _moveJson == null
      ? null
      : (jsonDecode(_moveJson) as Map).cast<String, Object?>();
  String get destinationScopeId =>
      move?['target_scope_id'] as String? ?? scopeId;

  Map<String, Object?> get body => {
    'operation_id': operationId,
    'scope_id': scopeId,
    'entity_type': entityType,
    'entity_id': entityId,
    'action': action,
    'base_revision': baseRevision,
    'depends_on': dependsOn,
    'payload': payload,
    if (_moveJson != null) 'move': move,
  };

  String get serialized => jsonEncode(body);

  static String _encodePayload(Map<String, Object?> payload) {
    _validateExactJson(payload);
    Object? sorted(Object? value) {
      if (value is Map<String, Object?>) {
        final keys = value.keys.toList()..sort();
        return {for (final key in keys) key: sorted(value[key])};
      }
      if (value is List) return value.map(sorted).toList();
      return value;
    }

    return jsonEncode(sorted(payload));
  }

  static void _validateExactJson(Object? value) {
    if (value == null || value is String || value is bool) return;
    if (value is int && value >= 0 && value <= 2147483647) return;
    if (value is List) {
      for (final item in value) {
        _validateExactJson(item);
      }
      return;
    }
    if (value is Map<String, Object?>) {
      for (final item in value.values) {
        _validateExactJson(item);
      }
      return;
    }
    throw ArgumentError('金额/修订必须为字符串；命令不能含浮点或超范围控制数。');
  }
}

final class LocalRepository {
  LocalRepository(this.database);

  final AppDatabase database;
  static const _uuid = Uuid();

  Future<void> registerSpace(DataSpace space) => database
      .into(database.localSpaces)
      .insertOnConflictUpdate(
        LocalSpacesCompanion.insert(
          id: space.id,
          serverAddress: space.server.toString(),
          serverInstanceId: space.serverInstanceId,
          userId: space.userId,
          createdAt: DateTime.now().toUtc(),
        ),
      );

  Future<String?> readSetting(String key) async => (await (database.select(
    database.appSettings,
  )..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> writeSetting(String key, String value) => database
      .into(database.appSettings)
      .insertOnConflictUpdate(
        AppSettingsCompanion.insert(key: key, value: value),
      );

  Future<List<StoredDraft>> drafts(DataSpace space) =>
      (database.select(database.localDrafts)
            ..where((t) => t.spaceId.equals(space.id))
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .get();

  Future<String> saveDraft(
    DataSpace space,
    String body, {
    String? draftId,
  }) async {
    final value = body.trim();
    if (value.isEmpty || value.length > 2000) {
      throw ArgumentError('草稿需要1至2000个字符。');
    }
    final id = draftId ?? _uuid.v4();
    final previous =
        await (database.select(database.localDrafts)
              ..where((t) => t.spaceId.equals(space.id) & t.id.equals(id)))
            .getSingleOrNull();
    final now = DateTime.now().toUtc();
    await database
        .into(database.localDrafts)
        .insertOnConflictUpdate(
          LocalDraftsCompanion.insert(
            id: id,
            spaceId: space.id,
            body: value,
            createdAt: previous?.createdAt ?? now,
            updatedAt: now,
          ),
        );
    return id;
  }

  Future<void> deleteDraft(DataSpace space, String id) async {
    await (database.delete(
      database.localDrafts,
    )..where((t) => t.spaceId.equals(space.id) & t.id.equals(id))).go();
  }

  Future<List<StoredOperation>> pending(DataSpace space) =>
      (database.select(database.pendingOperations)
            ..where(
              (t) =>
                  t.spaceId.equals(space.id) &
                  t.state.isNotIn(['applied', 'discarded']),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.sequence)]))
          .get();

  /// Save every user intent; its predecessor supplies the revision only when
  /// the sync coordinator freezes the first network request.
  Future<void> saveEntityAndQueue(
    DataSpace space,
    QueuedCommand command,
  ) async {
    if (!space.verified) {
      throw StateError('登录并确认服务器实例前只保存本地草稿，不能发送正式同步操作。');
    }
    await database.atomicWrite(() async {
      final syncState = await (database.select(
        database.syncStates,
      )..where((t) => t.spaceId.equals(space.id))).getSingleOrNull();
      if (syncState != null && syncState.status != 'active') {
        throw StateError('同步资料需要恢复，请先处理恢复；可以继续保存本地草稿。');
      }
      final existing = await _operation(space.id, command.operationId);
      if (existing != null) {
        if (existing.operationJson != command.serialized) {
          throw StateError('operation_id已固定，不能更改正文。');
        }
        return;
      }
      final prior =
          await (database.select(database.pendingOperations)
                ..where(
                  (t) =>
                      t.spaceId.equals(space.id) &
                      t.entityType.equals(command.entityType) &
                      t.entityId.equals(command.entityId) &
                      t.state.isNotIn(['applied', 'discarded']),
                )
                ..orderBy([(t) => OrderingTerm.asc(t.sequence)]))
              .get();
      final predecessor = prior.isEmpty ? null : prior.last.operationId;
      if (predecessor != null &&
          command.dependsOn != null &&
          command.dependsOn != predecessor) {
        throw StateError('同实体操作必须先等待自己的前序回执。');
      }
      final shadow =
          await (database.select(database.serverShadows)..where(
                (t) =>
                    t.spaceId.equals(space.id) &
                    t.scopeId.equals(command.scopeId) &
                    t.entityType.equals(command.entityType) &
                    t.entityId.equals(command.entityId),
              ))
              .getSingleOrNull();
      final now = DateTime.now().toUtc();
      await database
          .into(database.localEntities)
          .insertOnConflictUpdate(
            LocalEntitiesCompanion.insert(
              spaceId: space.id,
              scopeId: Value(command.destinationScopeId),
              entityType: command.entityType,
              entityId: command.entityId,
              dataJson: jsonEncode(command.payload),
              serverRevision: Value(command.baseRevision),
              deleted: Value(command.action == 'delete'),
              updatedAt: now,
            ),
          );
      await database
          .into(database.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              spaceId: space.id,
              operationId: command.operationId,
              entityType: command.entityType,
              entityId: command.entityId,
              operationJson: command.serialized,
              predecessorId: Value(predecessor),
              baseDataJson: Value(shadow?.dataJson),
              createdAt: now,
            ),
          );
      // A conflict may stay open while the person continues editing. Its
      // local side always represents the newest intent in this entity chain.
      for (final operation in prior) {
        await (database.update(database.syncConflicts)..where(
              (t) =>
                  t.spaceId.equals(space.id) &
                  t.operationId.equals(operation.operationId),
            ))
            .write(
              SyncConflictsCompanion(
                localJson: Value(jsonEncode(command.payload)),
              ),
            );
      }
    });
  }

  Future<void> markAttempted(
    DataSpace space,
    String operationId,
    String serializedRequest,
  ) => database.atomicWrite(() async {
    final operation = await _operation(space.id, operationId);
    if (operation == null) throw StateError('待传操作不存在。');
    if (operation.frozenRequestJson != null &&
        operation.frozenRequestJson != serializedRequest) {
      throw StateError('首次发送后的请求正文不可变。');
    }
    await (database.update(database.pendingOperations)..where(
          (t) => t.spaceId.equals(space.id) & t.operationId.equals(operationId),
        ))
        .write(
          PendingOperationsCompanion(
            frozenRequestJson: Value(serializedRequest),
            state: const Value('sending'),
            attemptCount: Value(operation.attemptCount + 1),
          ),
        );
  });

  Future<StoredOperation?> _operation(String spaceId, String operationId) =>
      (database.select(database.pendingOperations)..where(
            (t) =>
                t.spaceId.equals(spaceId) & t.operationId.equals(operationId),
          ))
          .getSingleOrNull();
}
