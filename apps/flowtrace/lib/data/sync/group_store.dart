import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/config/data_space.dart';
import '../local/app_database.dart';
import 'group_protocol.dart';
import 'group_progress.dart';
import 'snapshot_protocol.dart';
import 'sync_store.dart';

Map<String, Object?> _object(String value) => syncObject(jsonDecode(value));

final class GroupCleanupBinding {
  GroupCleanupBinding(this.requestId, this.clientId, this.epoch, this.pullId);
  final String requestId;
  final String clientId;
  final String epoch;
  final String pullId;
}

/// Group pages are controlled cache. Receipt and cursor installation share one
/// atomicWrite with the existing projection writer; receiving never calls it.
final class GroupPullStore {
  GroupPullStore(this.sync, {this.maxBytes = groupSessionBytes}) {
    if (maxBytes < 1024 || maxBytes > groupSessionBytes) {
      throw ArgumentError('Invalid trusted group storage budget');
    }
  }
  final SyncStore sync;
  final int maxBytes;
  AppDatabase get db => sync.db;
  final _manifestCache = <String, GroupManifest>{};
  final _unitCache = <String, GroupUnit>{};
  final _metadataCache =
      <
        String,
        ({List<GroupCommit> commits, List<GroupPageDescriptor> pages})
      >{};

  T _remember<T>(Map<String, T> cache, String key, T value) {
    cache.remove(key);
    cache[key] = value;
    while (cache.length > 2) {
      cache.remove(cache.keys.first);
    }
    return value;
  }

  Future<StoredGroupPull?> read(DataSpace space, String requestId) =>
      (db.select(db.groupPulls)..where(
            (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
          ))
          .getSingleOrNull();

  String _cleanupPrefix(DataSpace space) =>
      'sync.group-cleanup.v1.${space.id}.';

  /// Non-financial handoff survives a scope-driven clearGroupCache. Its closed
  /// UUID-only metadata can only collect an exact previously bound remote cache.
  Future<List<GroupCleanupBinding>> listCleanup(DataSpace space) async {
    final prefix = _cleanupPrefix(space);
    final rows = await (db.select(
      db.appSettings,
    )..where((t) => t.key.like('$prefix%'))).get();
    if (rows.length > 32 ||
        rows.fold<int>(0, (sum, row) => sum + utf8.encode(row.value).length) >
            32768) {
      throw StateError('Group cleanup marker budget exceeded');
    }
    return rows.map((row) {
      final value = _object(row.value);
      const fields = {
        'space_id',
        'request_id',
        'client_id',
        'sync_epoch',
        'pull_id',
      };
      if (utf8.encode(row.value).length > 1024 ||
          value.length != fields.length ||
          !value.keys.toSet().containsAll(fields) ||
          value['space_id'] != space.id) {
        throw const FormatException('Invalid group cleanup binding');
      }
      final requestId = syncIdentifier(value['request_id']);
      if (row.key != '$prefix$requestId') {
        throw const FormatException('Invalid group cleanup key');
      }
      return GroupCleanupBinding(
        requestId,
        syncIdentifier(value['client_id']),
        syncIdentifier(value['sync_epoch']),
        syncIdentifier(value['pull_id']),
      );
    }).toList();
  }

  Future<void> stageCleanup(
    DataSpace space,
    StoredGroupPull pull, {
    required bool Function() isCurrent,
  }) => db.atomicWrite(() async {
    await _current(space, pull, isCurrent, allowAbandoned: true);
    if (pull.spaceId != space.id || pull.pullId == null) {
      throw StateError('Group cleanup requires a bound local handle');
    }
    final value = canonicalSyncJson({
      'space_id': space.id,
      'request_id': syncIdentifier(pull.requestId),
      'client_id': syncIdentifier(pull.clientId),
      'sync_epoch': syncIdentifier(pull.epoch),
      'pull_id': syncIdentifier(pull.pullId),
    });
    final key = '${_cleanupPrefix(space)}${pull.requestId}';
    final old = await (db.select(
      db.appSettings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    if (old != null) {
      if (old.value != value) throw StateError('Group cleanup binding changed');
      return;
    }
    final bindings = await listCleanup(space);
    if (bindings.length >= 32 || utf8.encode(value).length > 1024) {
      throw StateError('Group cleanup marker budget exceeded');
    }
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(key: key, value: value));
    if (!isCurrent()) {
      throw StateError('Group identity changed before cleanup handoff');
    }
  });

  Future<void> finishCleanup(
    DataSpace space,
    String requestId,
    String pullId, {
    required bool Function() isCurrent,
  }) => db.atomicWrite(() async {
    if (!isCurrent()) throw StateError('Group cleanup identity changed');
    final key = '${_cleanupPrefix(space)}${syncIdentifier(requestId)}';
    final old = await (db.select(
      db.appSettings,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    if (old != null) {
      if (_object(old.value)['pull_id'] != syncIdentifier(pullId)) {
        throw StateError('Group cleanup receipt handle mismatch');
      }
      await (db.delete(db.appSettings)..where((t) => t.key.equals(key))).go();
    }
    if (!isCurrent()) {
      throw StateError('Group identity changed before cleanup receipt commit');
    }
  });

  /// Includes terminal local rows whose remote cache still needs collection.
  /// Already collected history is not scanned back into a new network run.
  Future<List<StoredGroupPull>> listActive(
    DataSpace space, {
    required String clientId,
    required String epoch,
  }) =>
      (db.select(db.groupPulls)
            ..where(
              (t) =>
                  t.spaceId.equals(space.id) &
                  t.clientId.equals(clientId) &
                  t.epoch.equals(epoch) &
                  const CustomExpression<bool>(
                    "COALESCE(json_extract(receive_state_json,'\$.server_collected'),0)=0",
                  ),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.createdAt),
              (t) => OrderingTerm.asc(t.requestId),
            ])
            ..limit(3))
          .get();

  /// Only a safe list summary matched to the persisted original request can
  /// recover a lost create handle. No synthetic progress or token is invented.
  Future<void> rememberHandle(
    DataSpace space,
    String requestId, {
    required String pullId,
    required String clientId,
    required String epoch,
    required bool Function() isCurrent,
  }) => db.atomicWrite(() async {
    syncIdentifier(pullId);
    final pull = await read(space, requestId);
    if (pull == null) throw StateError('Missing persisted group request');
    await _current(space, pull, isCurrent, allowAbandoned: true);
    if (pull.clientId != clientId ||
        pull.epoch != epoch ||
        (pull.pullId != null && pull.pullId != pullId)) {
      throw const FormatException('Group recovered handle mismatch');
    }
    final duplicate =
        await (db.select(db.groupPulls)..where(
              (t) => t.spaceId.equals(space.id) & t.pullId.equals(pullId),
            ))
            .getSingleOrNull();
    if (duplicate != null && duplicate.requestId != requestId) {
      throw const FormatException('Group handle belongs to another request');
    }
    await (db.update(db.groupPulls)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .write(GroupPullsCompanion(pullId: Value(pullId)));
    if (!isCurrent()) {
      throw StateError('Group identity changed before handle commit');
    }
  });

  /// Keep the original manifest/receipt or abandoned request tombstone. Only a
  /// confirmed remote discard (or a safe absent-list result) closes cleanup.
  Future<void> markServerCollected(
    DataSpace space,
    String requestId, {
    required bool Function() isCurrent,
  }) => db.atomicWrite(() async {
    final pull = await read(space, requestId);
    if (pull == null) return;
    await _current(space, pull, isCurrent, allowAbandoned: true);
    final receive = _object(pull.receiveStateJson);
    if (!{'done', 'abandoned'}.contains(receive['phase'])) {
      throw StateError(
        'Group cache cannot be collected before local completion or discard',
      );
    }
    receive['server_collected'] = true;
    await (db.update(db.groupPulls)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .write(
          GroupPullsCompanion(
            receiveStateJson: Value(canonicalSyncJson(receive)),
          ),
        );
    if (!isCurrent()) {
      throw StateError('Group identity changed before collection commit');
    }
  });

  Future<void> _current(
    DataSpace space,
    StoredGroupPull pull,
    bool Function() isCurrent, {
    bool allowAbandoned = false,
  }) async {
    final state = await sync.state(space);
    if (!isCurrent() ||
        state == null ||
        state.status != 'active' ||
        state.clientId != pull.clientId ||
        state.epoch != pull.epoch ||
        (!allowAbandoned &&
            _object(pull.receiveStateJson)['phase'] == 'abandoned')) {
      throw StateError('Group synchronization identity changed');
    }
  }

  Future<void> _budget(DataSpace space, int additional) async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(SUM(reserved_bytes),0) AS bytes FROM group_pulls WHERE space_id=?',
          variables: [Variable.withString(space.id)],
          readsFrom: {db.groupPulls},
        )
        .getSingle();
    if (additional < 0 || row.read<int>('bytes') + additional > maxBytes) {
      throw StateError('Group staging storage budget exceeded');
    }
  }

  /// Call before POST: request identity and exact cursors survive a lost reply.
  Future<StoredGroupPull> begin(
    DataSpace space,
    String requestId, {
    required String clientId,
    required String epoch,
    required Map<String, String> cursors,
    required bool Function() isCurrent,
  }) => db.atomicWrite(() async {
    final intent = canonicalSyncJson({
      'protocol_version': 1,
      'request_id': syncIdentifier(requestId),
      'client_id': syncIdentifier(clientId),
      'sync_epoch': syncIdentifier(epoch),
      'cursors': syncVector(cursors),
    });
    if (cursors.length > 1000 || utf8.encode(intent).length > groupPageBytes) {
      throw const FormatException('Group intent exceeds bounds');
    }
    final old = await read(space, requestId);
    if (old != null) {
      await _current(space, old, isCurrent);
      if (old.intentJson != intent) {
        throw StateError('Group request identity reused');
      }
      return old;
    }
    final state = await sync.state(space);
    if (!isCurrent() ||
        state == null ||
        state.status != 'active' ||
        state.clientId != clientId ||
        state.epoch != epoch ||
        canonicalSyncJson(jsonDecode(state.cursorsJson)) !=
            canonicalSyncJson(cursors)) {
      throw StateError('Group base cursors changed');
    }
    final count = await db
        .customSelect(
          "SELECT COUNT(*) AS retained FROM group_pulls WHERE space_id=? "
          "AND json_extract(receive_state_json,'\$.phase') NOT IN ('done','abandoned')",
          variables: [Variable.withString(space.id)],
          readsFrom: {db.groupPulls},
        )
        .getSingle();
    if (count.read<int>('retained') >= 2) {
      throw StateError('Too many retained group pulls');
    }
    final bytes = utf8.encode(intent).length;
    await _budget(space, bytes);
    await db
        .into(db.groupPulls)
        .insert(
          GroupPullsCompanion.insert(
            spaceId: space.id,
            requestId: requestId,
            clientId: clientId,
            epoch: epoch,
            intentJson: intent,
            receiveStateJson: '{"phase":"creating"}',
            reservedBytes: Value(bytes),
            createdAt: DateTime.now().toUtc(),
          ),
        );
    if (!isCurrent()) throw StateError('Group identity changed before commit');
    return (await read(space, requestId))!;
  });

  GroupManifest _manifest(StoredGroupPull pull) {
    if (pull.statusJson == null) {
      throw StateError('Group manifest not received');
    }
    return _manifestCache[pull.statusJson!] ??
        _remember(
          _manifestCache,
          pull.statusJson!,
          GroupManifest.fromStatus(_object(pull.statusJson!)),
        );
  }

  Future<void> rememberProgress(
    DataSpace space,
    String requestId,
    GroupProgress progress, {
    required bool Function() isCurrent,
  }) => db.atomicWrite(() async {
    if (progress.status == 'ready') {
      await acceptReady(space, requestId, progress.body, isCurrent: isCurrent);
      return;
    }
    final pull = await read(space, requestId);
    if (pull == null) {
      throw StateError('Persist group request before receiving progress');
    }
    await _current(space, pull, isCurrent);
    if (progress.requestId != requestId ||
        progress.epoch != pull.epoch ||
        (pull.pullId != null && pull.pullId != progress.id) ||
        pull.statusJson != null ||
        pull.receivedPages != 0) {
      throw const FormatException('Group progress identity or state mismatch');
    }
    await (db.update(db.groupPulls)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .write(
          GroupPullsCompanion(
            pullId: Value(progress.id),
            receiveStateJson: Value(
              canonicalSyncJson({
                'phase': progress.status,
                'step_token': progress.stepToken,
              }),
            ),
          ),
        );
    if (!isCurrent()) {
      throw StateError('Group identity changed before progress commit');
    }
  });

  Future<void> acceptReady(
    DataSpace space,
    String requestId,
    Map<String, Object?> status, {
    required bool Function() isCurrent,
    DateTime? now,
  }) => db.atomicWrite(() async {
    final pull = await read(space, requestId);
    if (pull == null) throw StateError('Persist the group request before POST');
    await _current(space, pull, isCurrent);
    final manifest = GroupManifest.fromStatus(status);
    manifest.checkIdentity(
      space.serverInstanceId,
      space.userId,
      pull.clientId,
      pull.epoch,
      now: now,
    );
    if (manifest.requestId != requestId ||
        (pull.pullId != null && pull.pullId != manifest.id) ||
        canonicalSyncJson(manifest.base) !=
            canonicalSyncJson(_object(pull.intentJson)['cursors'])) {
      throw const FormatException('Group intent response mismatch');
    }
    final encoded = canonicalSyncJson(status);
    if (pull.statusJson != null) {
      if (pull.statusJson != encoded) {
        throw StateError('Immutable group manifest changed');
      }
      return;
    }
    final state = (await sync.state(space))!;
    if (canonicalSyncJson(jsonDecode(state.cursorsJson)) !=
        canonicalSyncJson(manifest.base)) {
      throw StateError('Group base cursors changed');
    }
    final duplicate =
        await (db.select(db.groupPulls)..where(
              (t) => t.spaceId.equals(space.id) & t.pullId.equals(manifest.id),
            ))
            .getSingleOrNull();
    if (duplicate != null && duplicate.requestId != requestId) {
      throw StateError('Group pull belongs to another request');
    }
    final bytes = utf8.encode(encoded).length;
    await _budget(space, bytes);
    await (db.update(db.groupPulls)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .write(
          GroupPullsCompanion(
            statusJson: Value(encoded),
            pullId: Value(manifest.id),
            nextToken: Value(groupToken(status['first_page_token'])),
            receiveStateJson: Value(
              canonicalSyncJson({
                'phase': manifest.unitCount == 0 ? 'complete' : 'index',
                'unit': 0,
                'page': 0,
              }),
            ),
            reservedBytes: Value(pull.reservedBytes + bytes),
          ),
        );
    if (!isCurrent()) throw StateError('Group identity changed before commit');
  });

  Future<GroupWirePage> _page(
    StoredGroupPull pull,
    String kind,
    String group,
    int index,
  ) async {
    final row =
        await (db.select(db.groupPages)..where(
              (t) =>
                  t.spaceId.equals(pull.spaceId) &
                  t.requestId.equals(pull.requestId) &
                  t.kind.equals(kind) &
                  t.groupId.equals(group) &
                  t.pageIndex.equals(index),
            ))
            .getSingleOrNull();
    if (row == null) throw StateError('Missing group staging page');
    final page = GroupWirePage.parse(_object(row.bodyJson));
    if (page.pullId != pull.pullId ||
        page.kind != kind ||
        (page.groupId ?? '') != group ||
        page.index != index ||
        page.hash != row.sha256 ||
        page.byteCount != row.sizeBytes) {
      throw const FormatException('Corrupt group staging page');
    }
    return page;
  }

  Future<GroupUnit> _unit(
    StoredGroupPull pull,
    GroupManifest manifest,
    int index, {
    bool fresh = false,
  }) async {
    if (index < 0 || index >= manifest.unitCount) {
      throw StateError('Invalid group unit');
    }
    final key = '${manifest.id}:$index:${manifest.digest}';
    if (!fresh && _unitCache.containsKey(key)) return _unitCache[key]!;
    var first = 0;
    for (final descriptor in manifest.indexPages) {
      if (index >= first + descriptor.count) {
        first += descriptor.count;
        continue;
      }
      final page = await _page(pull, 'index', '', descriptor.index);
      page.checkDescriptor(descriptor);
      final unit = GroupUnit.parse(
        manifest.id,
        (page.body['units'] as List)[index - first],
      );
      if (unit.index != index) {
        throw const FormatException('Group index position mismatch');
      }
      return fresh ? unit : _remember(_unitCache, key, unit);
    }
    throw const FormatException('Group unit absent from index');
  }

  Future<({List<GroupCommit> commits, List<GroupPageDescriptor> pages})>
  _metadata(StoredGroupPull pull, GroupUnit unit, {bool fresh = false}) async {
    final key = '${pull.pullId}:${unit.id}:${unit.hash}';
    if (!fresh && _metadataCache.containsKey(key)) return _metadataCache[key]!;
    final commits = <GroupCommit>[];
    final pages = <GroupPageDescriptor>[];
    final identifiers = <String>{};
    for (final descriptor in unit.parts) {
      final page = await _page(pull, 'manifest', unit.id, descriptor.index);
      page.checkDescriptor(descriptor);
      for (final raw in page.body['commits'] as List) {
        final commit = GroupCommit.parse(raw);
        if (commit.index != commits.length || !identifiers.add(commit.id)) {
          throw const FormatException('Group commit descriptor order mismatch');
        }
        commits.add(commit);
        if (commits.length > 2000) {
          throw const FormatException('Too many group commits');
        }
      }
      for (final raw in page.body['data_pages'] as List) {
        final descriptor = GroupPageDescriptor.parse(raw);
        if (descriptor.index != pages.length || descriptor.count == 0) {
          throw const FormatException('Group data descriptor order mismatch');
        }
        pages.add(descriptor);
        if (pages.length > 8192) {
          throw const FormatException('Too many group data pages');
        }
      }
    }
    if (commits.length != unit.commitCount ||
        pages.isEmpty ||
        commits.fold<int>(0, (sum, c) => sum + c.eventCount) !=
            unit.eventCount ||
        pages.fold<int>(0, (sum, p) => sum + p.count) != unit.eventCount) {
      throw const FormatException('Incomplete group metadata');
    }
    final result = (
      commits: List<GroupCommit>.unmodifiable(commits),
      pages: List<GroupPageDescriptor>.unmodifiable(pages),
    );
    return fresh ? result : _remember(_metadataCache, key, result);
  }

  Future<void> receive(
    DataSpace space,
    String requestId,
    String requestToken,
    Map<String, Object?> raw, {
    required bool Function() isCurrent,
    DateTime? now,
  }) => db.atomicWrite(() async {
    final pull = await read(space, requestId);
    if (pull == null) throw StateError('Missing group pull');
    await _current(space, pull, isCurrent);
    final manifest = _manifest(pull);
    manifest.checkIdentity(
      space.serverInstanceId,
      space.userId,
      pull.clientId,
      pull.epoch,
      now: now,
    );
    final page = GroupWirePage.parse(raw);
    if (page.pullId != manifest.id) {
      throw const FormatException('Page belongs to another pull');
    }
    final old =
        await (db.select(db.groupPages)..where(
              (t) =>
                  t.spaceId.equals(space.id) &
                  t.requestId.equals(requestId) &
                  t.requestToken.equals(requestToken),
            ))
            .getSingleOrNull();
    if (old != null) {
      if (old.bodyJson != page.encoded) {
        throw const FormatException('Immutable group page changed');
      }
      return;
    }
    if (groupToken(requestToken) != pull.nextToken ||
        pull.receivedPages >= 8192) {
      throw StateError('Group page token or count mismatch');
    }
    final state = _object(pull.receiveStateJson);
    if (state['phase'] != page.kind || state['page'] != page.index) {
      throw const FormatException('Group page sequence mismatch');
    }
    final unitIndex = state['unit'] as int;
    GroupUnit? unit;
    if (page.kind == 'index') {
      page.checkDescriptor(manifest.indexPages[page.index]);
      final start = manifest.indexPages
          .take(page.index)
          .fold<int>(0, (n, p) => n + p.count);
      final units = (page.body['units'] as List)
          .map((u) => GroupUnit.parse(manifest.id, u))
          .toList();
      if (units.first.index != start) {
        throw const FormatException('Group index has gaps');
      }
    } else {
      unit = await _unit(pull, manifest, unitIndex);
      if (page.groupId != unit.id) {
        throw const FormatException('Page belongs to another group');
      }
      if (page.kind == 'manifest') {
        page.checkDescriptor(unit.parts[page.index]);
      } else {
        final metadata = await _metadata(pull, unit);
        page.checkDescriptor(metadata.pages[page.index]);
      }
    }
    await _budget(space, page.byteCount);
    await db
        .into(db.groupPages)
        .insert(
          GroupPagesCompanion.insert(
            spaceId: space.id,
            requestId: requestId,
            ordinal: pull.receivedPages,
            requestToken: requestToken,
            kind: page.kind,
            groupId: page.groupId ?? '',
            pageIndex: page.index,
            bodyJson: page.encoded,
            sha256: page.hash,
            sizeBytes: page.byteCount,
          ),
        );
    Map<String, Object?> next;
    if (page.kind == 'index') {
      next = page.index + 1 == manifest.indexPages.length
          ? {'phase': 'manifest', 'unit': 0, 'page': 0}
          : {'phase': 'index', 'unit': 0, 'page': page.index + 1};
    } else if (page.kind == 'manifest') {
      if (page.index + 1 == unit!.parts.length) {
        await _metadata(pull, unit);
        next = {'phase': 'data', 'unit': unitIndex, 'page': 0};
      } else {
        next = {'phase': 'manifest', 'unit': unitIndex, 'page': page.index + 1};
      }
    } else {
      final metadata = await _metadata(pull, unit!);
      next = page.index + 1 < metadata.pages.length
          ? {'phase': 'data', 'unit': unitIndex, 'page': page.index + 1}
          : unitIndex + 1 < manifest.unitCount
          ? {'phase': 'manifest', 'unit': unitIndex + 1, 'page': 0}
          : {'phase': 'complete', 'unit': manifest.unitCount, 'page': 0};
    }
    if ((next['phase'] == 'complete') != (page.nextToken == null)) {
      throw const FormatException('Group token chain ends at wrong page');
    }
    if (page.nextToken != null) {
      final seen =
          await (db.select(db.groupPages)..where(
                (t) =>
                    t.spaceId.equals(space.id) &
                    t.requestId.equals(requestId) &
                    t.requestToken.equals(page.nextToken!),
              ))
              .getSingleOrNull();
      if (seen != null) throw const FormatException('Group token cycle');
    }
    await (db.update(db.groupPulls)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .write(
          GroupPullsCompanion(
            nextToken: Value(page.nextToken),
            receiveStateJson: Value(canonicalSyncJson(next)),
            receivedPages: Value(pull.receivedPages + 1),
            reservedBytes: Value(pull.reservedBytes + page.byteCount),
          ),
        );
    if (!isCurrent()) {
      throw StateError('Group identity changed before page commit');
    }
  });

  /// A fresh authorized status GET and permission response precede this call.
  /// Only one <=200-event commit is buffered; all unit writes join this one
  /// outer transaction, including its final cursor and durable receipt.
  Future<void> installNext(
    DataSpace space,
    String requestId, {
    required GroupManifest authorizedManifest,
    required Map<String, String> permissionVersions,
    required bool Function() isCurrent,
    DateTime? now,
  }) => db.atomicWrite(() async {
    final pull = await read(space, requestId);
    if (pull == null) throw StateError('Missing group pull');
    await _current(space, pull, isCurrent);
    final manifest = _manifest(pull);
    manifest.checkIdentity(
      space.serverInstanceId,
      space.userId,
      pull.clientId,
      pull.epoch,
      now: now,
    );
    if (authorizedManifest.encoded != manifest.encoded ||
        canonicalSyncJson(permissionVersions) !=
            canonicalSyncJson(manifest.permissions)) {
      throw StateError('Group authorization changed');
    }
    final current = (await sync.state(space))!;
    if ((jsonDecode(current.revokedScopesJson) as List).any(
      manifest.permissions.containsKey,
    )) {
      throw StateError('Group contains a revoked scope');
    }
    final index = pull.installedUnits;
    if (_object(pull.receiveStateJson)['phase'] == 'done') {
      if (index != manifest.unitCount) {
        throw StateError('Incomplete group receipt');
      }
      return;
    }
    final previous = index == 0
        ? manifest.base
        : _object(
            (await (db.select(db.groupReceipts)..where(
                      (t) =>
                          t.spaceId.equals(space.id) &
                          t.requestId.equals(requestId) &
                          t.unitIndex.equals(index - 1),
                    ))
                    .getSingle())
                .endCursorsJson,
          ).cast<String, String>();
    if (canonicalSyncJson(jsonDecode(current.cursorsJson)) !=
        canonicalSyncJson(previous)) {
      throw StateError('Group cursor compare-and-swap failed');
    }
    if (manifest.unitCount == 0) {
      if (_object(pull.receiveStateJson)['phase'] != 'complete') {
        throw StateError('Group incomplete');
      }
      if (manifest.checkpoint.entries.any(
        (e) => e.value != (manifest.base[e.key] ?? '0'),
      )) {
        throw const FormatException('Empty group skips a changed scope');
      }
      await sync.applyPullPage(
        space,
        pull.epoch,
        [],
        finalPage: true,
        checkpoint: manifest.checkpoint,
      );
      await _done(space, pull);
      if (!isCurrent()) {
        throw StateError('Group identity changed before commit');
      }
      return;
    }
    if (index >= manifest.unitCount) return;
    final receive = _object(pull.receiveStateJson);
    if (receive['phase'] != 'complete' && (receive['unit'] as int) <= index) {
      throw StateError('Group data has not all arrived');
    }
    final unit = await _unit(pull, manifest, index, fresh: true);
    final end = unit.endCursors;
    if (!end.keys.toSet().containsAll(previous.keys) ||
        !manifest.checkpoint.keys.toSet().containsAll(end.keys) ||
        end.entries.any(
          (e) =>
              BigInt.parse(e.value) < BigInt.parse(previous[e.key] ?? '0') ||
              BigInt.parse(e.value) > BigInt.parse(manifest.checkpoint[e.key]!),
        )) {
      throw const FormatException('Group unit cursor is not a safe prefix');
    }
    final metadata = await _metadata(pull, unit, fresh: true);
    final receiptBytes = utf8
        .encode(
          canonicalSyncJson({
            'unit_index': index,
            'group_id': unit.id,
            'manifest_sha256': unit.hash,
            'end_cursors': end,
          }),
        )
        .length;
    var commitIndex = 0;
    var total = 0;
    var events = <Object?>[];
    final identities = <String>{};
    final observedEnd = <String, String>{
      for (final scope in manifest.checkpoint.keys)
        scope: previous[scope] ?? '0',
    };
    for (final descriptor in metadata.pages) {
      final page = await _page(pull, 'data', unit.id, descriptor.index);
      page.checkDescriptor(descriptor);
      for (final raw in page.body['fragments'] as List) {
        final fragment = syncObject(raw);
        if (commitIndex >= metadata.commits.length ||
            fragment['commit_index'] != commitIndex ||
            fragment['event_offset'] != events.length) {
          throw const FormatException(
            'Group fragment is missing or duplicated',
          );
        }
        final commit = metadata.commits[commitIndex];
        for (final rawEvent in fragment['events'] as List) {
          final event = syncObject(rawEvent);
          final scope = syncIdentifier(event['scope_id']);
          final revision = syncRevision(event['scope_revision']);
          if (!manifest.permissions.containsKey(scope) ||
              !end.containsKey(scope) ||
              BigInt.parse(revision) > BigInt.parse(end[scope]!) ||
              !identities.add('$scope:$revision:${event['event_index']}')) {
            throw const FormatException(
              'Group event is outside its authorized cursor',
            );
          }
          if (BigInt.parse(revision) > BigInt.parse(observedEnd[scope]!)) {
            observedEnd[scope] = revision;
          }
          events.add(event);
          if (events.length > commit.eventCount) {
            throw const FormatException('Group commit overflow');
          }
        }
        if (events.length == commit.eventCount) {
          if (syncContentHash(events) != commit.hash) {
            throw const FormatException('Group commit hash mismatch');
          }
          if (!isCurrent()) {
            throw StateError('Group identity changed during installation');
          }
          await sync.applyPullPage(space, pull.epoch, [
            events.map(decodeSyncEvent).toList(),
          ], finalPage: false);
          total += events.length;
          events = [];
          identities.clear();
          commitIndex++;
        }
      }
    }
    if (events.isNotEmpty ||
        commitIndex != metadata.commits.length ||
        total != unit.eventCount) {
      throw const FormatException('Incomplete group commit stream');
    }
    if (canonicalSyncJson(end) != canonicalSyncJson(observedEnd)) {
      throw const FormatException(
        'Group cursor exceeds its actual event prefix',
      );
    }
    final finalUnit = index + 1 == manifest.unitCount;
    if (finalUnit &&
        canonicalSyncJson(end) != canonicalSyncJson(manifest.checkpoint)) {
      throw const FormatException(
        'Final group cursor does not reach checkpoint',
      );
    }
    final released = await db
        .customSelect(
          "SELECT COALESCE(SUM(size_bytes),0) AS bytes FROM group_pages "
          "WHERE space_id=? AND request_id=? AND group_id=? AND kind IN ('manifest','data')",
          variables: [
            Variable.withString(space.id),
            Variable.withString(requestId),
            Variable.withString(unit.id),
          ],
          readsFrom: {db.groupPages},
        )
        .getSingle();
    final freedBytes = released.read<int>('bytes');
    final increase = receiptBytes - freedBytes;
    if (increase > 0) await _budget(space, increase);
    await _current(space, pull, isCurrent);
    await sync.applyPullPage(
      space,
      pull.epoch,
      [],
      finalPage: true,
      checkpoint: end,
    );
    await db
        .into(db.groupReceipts)
        .insert(
          GroupReceiptsCompanion.insert(
            spaceId: space.id,
            requestId: requestId,
            unitIndex: index,
            groupId: unit.id,
            manifestSha256: unit.hash,
            endCursorsJson: canonicalSyncJson(end),
            sizeBytes: receiptBytes,
          ),
        );
    await (db.delete(db.groupPages)..where(
          (t) =>
              t.spaceId.equals(space.id) &
              t.requestId.equals(requestId) &
              t.groupId.equals(unit.id) &
              t.kind.isIn(['manifest', 'data']),
        ))
        .go();
    await (db.update(db.groupPulls)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .write(
          GroupPullsCompanion(
            installedUnits: Value(index + 1),
            reservedBytes: Value(
              pull.reservedBytes + receiptBytes - freedBytes,
            ),
          ),
        );
    if (finalUnit) await _done(space, pull);
    if (!isCurrent()) throw StateError('Group identity changed before commit');
  });

  /// Explicitly discard resumable controlled cache, including expired pulls.
  /// The original request tombstone remains and cannot be repopulated. Existing
  /// business projections/cursors and original user commands are untouched.
  Future<void> abandon(
    DataSpace space,
    String requestId, {
    required bool Function() isCurrent,
  }) => db.atomicWrite(() async {
    final pull = await read(space, requestId);
    if (pull == null) throw StateError('Missing group pull');
    await _current(space, pull, isCurrent, allowAbandoned: true);
    if (_object(pull.receiveStateJson)['phase'] == 'abandoned') return;
    await (db.delete(db.groupPages)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .go();
    await (db.delete(db.groupReceipts)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .go();
    await (db.update(db.groupPulls)..where(
          (t) => t.spaceId.equals(space.id) & t.requestId.equals(requestId),
        ))
        .write(
          GroupPullsCompanion(
            statusJson: const Value(null),
            nextToken: const Value(null),
            receiveStateJson: const Value('{"phase":"abandoned"}'),
            reservedBytes: Value(utf8.encode(pull.intentJson).length),
          ),
        );
    _manifestCache.clear();
    _unitCache.clear();
    _metadataCache.clear();
    if (!isCurrent()) throw StateError('Group identity changed before discard');
  });

  Future<void> _done(DataSpace space, StoredGroupPull pull) async {
    // The request, manifest and small installation receipts remain immutable.
    // Only already installed projection pages are removed, with real accounting.
    await (db.delete(db.groupPages)..where(
          (t) =>
              t.spaceId.equals(space.id) & t.requestId.equals(pull.requestId),
        ))
        .go();
    final receipts = await db
        .customSelect(
          'SELECT COALESCE(SUM(size_bytes),0) AS bytes FROM group_receipts WHERE space_id=? AND request_id=?',
          variables: [
            Variable.withString(space.id),
            Variable.withString(pull.requestId),
          ],
          readsFrom: {db.groupReceipts},
        )
        .getSingle();
    final retained =
        utf8.encode(pull.intentJson).length +
        utf8.encode(pull.statusJson!).length +
        receipts.read<int>('bytes');
    await (db.update(db.groupPulls)..where(
          (t) =>
              t.spaceId.equals(space.id) & t.requestId.equals(pull.requestId),
        ))
        .write(
          GroupPullsCompanion(
            receiveStateJson: const Value('{"phase":"done"}'),
            reservedBytes: Value(retained),
          ),
        );
  }
}
