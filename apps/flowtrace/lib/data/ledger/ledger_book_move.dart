import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/money/money.dart';
import '../../core/network/api_failure.dart';
import '../../domain/ledger/postings.dart';
import '../../features/attachments/attachment_models.dart';
import '../attachments/attachment_repository.dart';
import '../attachments/attachment_transfer.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import '../sync/snapshot_protocol.dart';
import '../sync/tombstone_proof.dart';
import 'ledger_projection.dart';
import 'ledger_repository.dart';

/// Null categories and empty tags are explicit clearing decisions, not defaults.
final class BillBookMoveMapping {
  BillBookMoveMapping({
    required this.categoryId,
    required List<String> tagIds,
    required this.feeCategoryId,
  }) : tagIds = List.unmodifiable(tagIds);
  final String? categoryId, feeCategoryId;
  final List<String> tagIds;
}

final class BillBookMoveItem {
  const BillBookMoveItem({
    required this.billId,
    required this.sourceBookId,
    required this.targetBookId,
    required this.billType,
    required this.imageCount,
    this.money,
    this.issue,
  });
  final String billId, sourceBookId, targetBookId, billType;
  final int imageCount;
  final Money? money;
  final String? issue;
}

final class LedgerBookMoveException implements Exception {
  LedgerBookMoveException(Map<String, String> issues)
    : issues = Map.unmodifiable(issues);
  final Map<String, String> issues;
  @override
  String toString() =>
      'LedgerBookMoveException(${issues.values.toSet().join(', ')})';
}

final class LedgerBookMovePreview {
  LedgerBookMovePreview._({
    required this.spaceId,
    required this.epoch,
    required this.clientId,
    required this.generation,
    required this.targetBookId,
    required this.permissionHash,
    required List<BillBookMoveItem> items,
    required Map<String, String> issues,
    required Map<String, BillBookMoveMapping> mappings,
    required List<_MovePlan> plans,
    required Map<String, String> cloneIds,
    required Object owner,
  }) : items = List.unmodifiable(items),
       issues = Map.unmodifiable(issues),
       mappings = Map.unmodifiable(mappings),
       _plans = List.unmodifiable(plans),
       _cloneIds = Map.unmodifiable(cloneIds),
       _owner = owner;
  final String spaceId, epoch, clientId, targetBookId, permissionHash;
  final int generation;
  final List<BillBookMoveItem> items;
  final Map<String, String> issues;
  final Map<String, BillBookMoveMapping> mappings;
  final List<_MovePlan> _plans;
  final Map<String, String> _cloneIds;
  final Object _owner;
  int get imageCount => _cloneIds.length;
  bool get canPrepare => issues.isEmpty && _plans.isNotEmpty;
}

final class LedgerBookMovePrepared {
  LedgerBookMovePrepared._(this.preview, this._owner);
  final LedgerBookMovePreview preview;
  final Object _owner;
  int get imageCount => preview.imageCount;
}

final class LedgerBookMoveResult {
  LedgerBookMoveResult(
    Map<String, String> operationIds, {
    this.alreadyQueued = false,
  }) : operationIds = Map.unmodifiable(operationIds);
  final Map<String, String> operationIds;
  final bool alreadyQueued;
}

final class _MovePlan {
  _MovePlan({
    required this.id,
    required this.source,
    required this.revision,
    required this.operationId,
    required Map<String, Object?> original,
    required Map<String, Object?> target,
    required List<FinancialPosting> postings,
    required this.sourceProjectionHash,
    required this.fingerprint,
  }) : _original = jsonEncode(original),
       _target = jsonEncode(target),
       _postings = jsonEncode(postings.map(postingJson).toList());
  final String id,
      source,
      revision,
      operationId,
      sourceProjectionHash,
      fingerprint;
  final String _original, _target, _postings;
  Map<String, Object?> get original => ledgerObject(jsonDecode(_original));
  Map<String, Object?> get target => ledgerObject(jsonDecode(_target));
  List<FinancialPosting> get postings =>
      (jsonDecode(_postings) as List).map(postingFromJson).toList();
}

/// Preparation uploads unreferenced target clones. Confirmation only queues
/// immutable commands; each server move remains one independent transaction.
final class LedgerBookMoveService {
  LedgerBookMoveService(
    this.ledger,
    this.attachments, {
    required this.refreshPermissions,
    AttachmentTransfer? transfer,
  }) : transfer = transfer ?? AttachmentTransfer(attachments) {
    if (!identical(ledger.repository.database, attachments.local.database)) {
      throw ArgumentError('账务和附件必须使用同一本机资料库。');
    }
  }
  final LedgerRepository ledger;
  final AttachmentRepository attachments;
  final AttachmentTransfer transfer;
  final Future<void> Function(AttachmentLease lease) refreshPermissions;
  final Object _owner = Object();
  final Set<Object> _running = {};
  static const _uuid = Uuid();
  AppDatabase get _db => ledger.repository.database;

  Future<LedgerProjection> _projection(DataSpace space) =>
      _db.readSnapshot(() async {
        final entities = await (_db.select(
          _db.localEntities,
        )..where((t) => t.spaceId.equals(space.id))).get();
        final shadows = await (_db.select(
          _db.serverShadows,
        )..where((t) => t.spaceId.equals(space.id))).get();
        final operations =
            await (_db.select(_db.pendingOperations)
                  ..where((t) => t.spaceId.equals(space.id))
                  ..orderBy([(t) => OrderingTerm.asc(t.sequence)]))
                .get();
        final state = await (_db.select(
          _db.syncStates,
        )..where((t) => t.spaceId.equals(space.id))).getSingleOrNull();
        final settings =
            await (_db.select(_db.appSettings)..where(
                  (t) =>
                      t.key.equals('sync.scope-details.${space.id}') |
                      t.key.like('ledger.postings.v1.${space.id}.%') |
                      t.key.like('${tombstoneProofPrefix(space)}%'),
                ))
                .get();
        return LedgerProjection(
          space,
          LedgerRows(
            entities: entities,
            shadows: shadows,
            operations: operations,
            syncState: state,
            settings: {
              for (final setting in settings) setting.key: setting.value,
            },
          ),
        );
      });

  String _permissionHash(LedgerProjection p) => syncContentHash({
    'epoch': p.rows.syncState?.epoch,
    'client': p.rows.syncState?.clientId,
    'status': p.rows.syncState?.status,
    'revoked': p.rows.syncState?.revokedScopesJson,
    'details': p.rows.settings['sync.scope-details.${p.space.id}'],
  });

  Map<String, Object?> _body(Map<String, Object?> value) =>
      normalizeLedgerPayload('bill', value)
        ..remove('preserve_hidden_financial_links');

  bool _pending(LedgerProjection p, String id) =>
      p.operations(id).any((op) => mutableIntentStates.contains(op.state));
  Never _fail(String code) => throw DomainError(code);

  String _fingerprint(
    LedgerProjection p,
    LedgerEntity bill,
    Map<String, Object?> target,
  ) {
    final references = <String>{
      bill.scopeId,
      target['book_id'] as String,
      ...accountIds(target),
      if (target['category_id'] is String) target['category_id'] as String,
      ...(target['tag_ids'] as List).cast<String>(),
      if ((target['fee'] as Map?)?['category_id'] is String)
        ((target['fee'] as Map)['category_id']) as String,
    };
    return syncContentHash({
      'bill': {
        'scope': bill.scopeId,
        'revision': bill.revision,
        'deleted': bill.deleted,
        'payload': bill.payload,
        'editable': bill.editablePayload,
        'projection': bill.projection,
      },
      'refs': [
        for (final id in references.toList()..sort())
          {
            'id': id,
            'scope': p.local[id]?.scopeId,
            'revision': p.local[id]?.serverRevision,
            'deleted': p.local[id]?.deleted,
            'data': p.payloads[id],
          },
      ],
      'postings': p.currentPostings(bill.id)?.map(postingJson).toList(),
      'ops': [
        for (final op in p.rows.operations)
          if (op.entityId == bill.id || references.contains(op.entityId))
            {'id': op.operationId, 'state': op.state, 'body': op.operationJson},
      ],
      'receipt_intents': [
        for (final row in p.local.values)
          if (row.entityType == 'bill' &&
              _pending(p, row.entityId) &&
              (p.payloads[row.entityId]?['allocations'] as List? ?? []).any(
                (raw) => ledgerObject(raw)['source_bill_id'] == bill.id,
              ))
            {
              'id': row.entityId,
              'deleted': row.deleted,
              'payload': p.payloads[row.entityId],
            },
      ],
    });
  }

  LedgerEntity _definition(
    LedgerProjection p,
    LedgerView view,
    String id,
    String type,
    String scope,
  ) {
    final value = view.find(type, id), shadow = p.shadow(scope, type, id);
    if (value == null ||
        value.deleted ||
        value.scopeId != scope ||
        _pending(p, id) ||
        shadow == null ||
        shadow.deleted ||
        shadow.revision != value.revision ||
        ledgerObject(jsonDecode(shadow.dataJson))['projection_kind'] != type ||
        canonicalSyncJson(
              normalizeLedgerPayload(
                type,
                ledgerObject(jsonDecode(shadow.dataJson)),
              ),
            ) !=
            canonicalSyncJson(value.payload)) {
      _fail('move.sync_definitions_first');
    }
    return value;
  }

  _MovePlan _plan(
    LedgerProjection p,
    LedgerView view,
    String id,
    String targetBook,
    BillBookMoveMapping mapping,
    Map<String, String> cloneIds, {
    String? operationId,
  }) {
    final bill = view.find('bill', id);
    if (bill == null || bill.deleted) _fail('move.bill_unavailable');
    if (!p.writable ||
        !p.canWrite('bill', bill.scopeId) ||
        !p.canWrite('bill', targetBook)) {
      _fail('move.scope_readonly');
    }
    if (bill.scopeId == targetBook) _fail('move.same_book');
    if (bill.pending ||
        bill.conflicted ||
        BigInt.parse(bill.revision) <= BigInt.zero) {
      _fail('move.sync_bill_first');
    }
    final full = bill.editablePayload;
    if (full == null || !bill.canEdit) {
      _fail('move.financial_links_unavailable');
    }
    final original = _body(full), source = bill.scopeId;
    final fromBook = _definition(p, view, source, 'book', source),
        toBook = _definition(p, view, targetBook, 'book', targetBook);
    if (fromBook.payload['currency'] != toBook.payload['currency']) {
      _fail('move.currency_mismatch');
    }
    if ({'refund', 'reimbursement'}.contains(original['bill_type']) ||
        (original['allocations'] as List).isNotEmpty) {
      _fail('move.has_allocations');
    }
    final canonical = p.shadow(source, 'bill', id);
    if (canonical == null ||
        canonical.deleted ||
        canonical.revision != bill.revision) {
      _fail('move.canonical_unavailable');
    }
    final sourceProjection = ledgerObject(jsonDecode(canonical.dataJson));
    if (sourceProjection['projection_kind'] != 'bill_public') {
      _fail('move.canonical_unavailable');
    }
    if (original['bill_type'] == 'expense' &&
        sourceProjection['remaining_allocatable_minor'] !=
            ledgerObject(original['money'])['amount_minor']) {
      _fail('move.has_allocations');
    }
    for (final row in p.local.values) {
      if (row.entityType == 'bill' &&
          !row.deleted &&
          (p.payloads[row.entityId]?['allocations'] as List? ?? []).any(
            (raw) => ledgerObject(raw)['source_bill_id'] == id,
          )) {
        _fail('move.has_allocations');
      }
    }
    for (final accountId in accountIds(original)) {
      final known = view.find('account', accountId);
      if (known != null && known.scopeId != p.space.userId) {
        _fail('move.shared_account');
      }
      final account = _definition(
        p,
        view,
        accountId,
        'account',
        p.space.userId,
      );
      if (account.scopeId != p.space.userId) _fail('move.shared_account');
    }
    void category(String? category, {required String? kind}) {
      if (category == null) return;
      final definition = _definition(p, view, category, 'category', targetBook);
      if (definition.effectiveArchived ||
          kind != null && definition.payload['kind'] != kind) {
        _fail('move.category_invalid');
      }
    }

    category(
      mapping.categoryId,
      kind: {'income', 'expense'}.contains(original['bill_type'])
          ? original['bill_type'] as String
          : null,
    );
    category(mapping.feeCategoryId, kind: 'expense');
    if (mapping.tagIds.toSet().length != mapping.tagIds.length ||
        mapping.tagIds.length > 100) {
      _fail('move.tag_invalid');
    }
    for (final tagId in mapping.tagIds) {
      final tag = _definition(p, view, tagId, 'tag', targetBook);
      if (tag.effectiveArchived || tag.payload['kind'] != 'tag') {
        _fail('move.tag_invalid');
      }
    }
    final target = ledgerCopy(original)
      ..['book_id'] = targetBook
      ..['category_id'] = mapping.categoryId
      ..['tag_ids'] = mapping.tagIds;
    if (target['fee'] != null) {
      target['fee'] = {
        ...ledgerObject(target['fee']),
        'category_id': mapping.feeCategoryId,
      };
    }
    final imageIds = (original['attachment_ids'] as List).cast<String>();
    target['attachment_ids'] = [
      for (final image in imageIds) cloneIds.putIfAbsent(image, _uuid.v4),
    ];
    final postings = p.currentPostings(id);
    if (postings == null) _fail('move.postings_unavailable');
    return _MovePlan(
      id: id,
      source: source,
      revision: bill.revision,
      operationId: operationId ?? _uuid.v4(),
      original: original,
      target: target,
      postings: postings,
      sourceProjectionHash: syncContentHash(sourceProjection),
      fingerprint: _fingerprint(p, bill, target),
    );
  }

  Future<void> _capability(AttachmentLease lease) async {
    lease.check();
    final info = await lease.request('GET', '/server-info');
    lease.check();
    if (info['instance_id'] != lease.space.serverInstanceId ||
        info['sync_epoch'] != lease.epoch) {
      throw const ApiFailure('move_identity_changed', '服务器资料版本已变化，请先核对恢复。');
    }
    if (info['minimum_protocol'] != 1 ||
        info['capabilities'] is! List ||
        !(info['capabilities'] as List).contains('bill-move-v1')) {
      throw const ApiFailure('bill_move_unsupported', '当前服务器不支持跨账本移动，请先升级服务端。');
    }
  }

  Future<LedgerBookMovePreview> preview(
    AttachmentLease lease, {
    required Iterable<String> ids,
    required String targetBookId,
    required Map<String, BillBookMoveMapping> mappings,
  }) async {
    lease.check();
    await refreshPermissions(lease);
    lease.check();
    await _capability(lease);
    attachmentIdentifier(targetBookId);
    final inputs = ids.take(1001).toList();
    if (inputs.isEmpty || inputs.length > 1000) {
      throw LedgerBookMoveException({'selection': 'move.selection_limit'});
    }
    final selected = inputs.toSet().toList()..sort();
    final p = await _projection(lease.space),
        view = p.view(
          const LedgerQuery(includeArchived: true, includeDeleted: true),
        );
    if (p.rows.syncState?.epoch != lease.epoch ||
        p.rows.syncState?.clientId != lease.clientId ||
        !p.writable) {
      throw LedgerBookMoveException({'selection': 'move.recovery_required'});
    }
    final issues = <String, String>{},
        plans = <_MovePlan>[],
        items = <BillBookMoveItem>[],
        cloneIds = <String, String>{};
    for (final id in selected) {
      attachmentIdentifier(id);
      String? issue;
      final bill = view.find('bill', id), mapping = mappings[id];
      try {
        if (mapping == null) _fail('move.mapping_required');
        plans.add(_plan(p, view, id, targetBookId, mapping, cloneIds));
      } on DomainError catch (error) {
        issue = error.code;
        issues[id] = issue;
      }
      items.add(
        BillBookMoveItem(
          billId: id,
          sourceBookId: bill?.scopeId ?? '',
          targetBookId: targetBookId,
          billType: bill?.payload['bill_type'] as String? ?? '',
          imageCount: (bill?.payload['attachment_ids'] as List? ?? []).length,
          money: bill == null ? null : Money.fromJson(bill.payload['money']),
          issue: issue,
        ),
      );
    }
    lease.check();
    return LedgerBookMovePreview._(
      spaceId: lease.space.id,
      epoch: lease.epoch,
      clientId: lease.clientId,
      generation: lease.generation,
      targetBookId: targetBookId,
      permissionHash: _permissionHash(p),
      items: items,
      issues: issues,
      mappings: mappings,
      plans: plans,
      cloneIds: cloneIds,
      owner: _owner,
    );
  }

  void _lease(AttachmentLease lease, LedgerBookMovePreview preview) {
    lease.check();
    if (!identical(preview._owner, _owner) ||
        !preview.canPrepare ||
        lease.space.id != preview.spaceId ||
        lease.epoch != preview.epoch ||
        lease.clientId != preview.clientId ||
        lease.generation != preview.generation) {
      throw LedgerBookMoveException({'selection': 'move.preview_stale'});
    }
  }

  Future<void> _remotePermissions(
    AttachmentLease lease,
    LedgerBookMovePreview preview,
  ) async {
    _lease(lease, preview);
    await refreshPermissions(lease);
    _lease(lease, preview);
    final p = await _projection(lease.space);
    _lease(lease, preview);
    if (p.rows.syncState?.epoch != lease.epoch || !p.writable) {
      throw LedgerBookMoveException({'selection': 'move.recovery_required'});
    }
    for (final id in {
      preview.targetBookId,
      ...preview._plans.map((p) => p.source),
      lease.space.userId,
    }) {
      if (p.revoked.contains(id) ||
          !{'owner', 'editor'}.contains(p.roles[id])) {
        throw LedgerBookMoveException({'selection': 'move.scope_readonly'});
      }
    }
  }

  Future<LedgerProjection> _recheck(
    AttachmentLease lease,
    LedgerBookMovePreview preview,
  ) async {
    _lease(lease, preview);
    final p = await _projection(lease.space),
        view = p.view(
          const LedgerQuery(includeArchived: true, includeDeleted: true),
        );
    if (_permissionHash(p) != preview.permissionHash) {
      throw LedgerBookMoveException({'selection': 'move.preview_stale'});
    }
    for (final plan in preview._plans) {
      final _MovePlan current;
      try {
        current = _plan(
          p,
          view,
          plan.id,
          preview.targetBookId,
          preview.mappings[plan.id]!,
          {...preview._cloneIds},
          operationId: plan.operationId,
        );
      } on DomainError {
        throw LedgerBookMoveException({plan.id: 'move.preview_stale'});
      }
      if (current.fingerprint != plan.fingerprint ||
          canonicalSyncJson(current.target) != canonicalSyncJson(plan.target)) {
        throw LedgerBookMoveException({plan.id: 'move.preview_stale'});
      }
    }
    _lease(lease, preview);
    return p;
  }

  Future<void> _remoteBills(
    AttachmentLease lease,
    LedgerBookMovePreview preview,
  ) async {
    for (final plan in preview._plans) {
      final result = await lease.request(
        'GET',
        '/sync/entities/bill/${plan.id}?scope_id=${plan.source}',
      );
      _lease(lease, preview);
      final event = ledgerObject(result['event']);
      if (event['scope_id'] != plan.source ||
          event['entity_id'] != plan.id ||
          event['entity_type'] != 'bill' ||
          event['revision'] != plan.revision ||
          event['deleted'] != false ||
          result['editable_payload'] == null ||
          canonicalSyncJson(_body(ledgerObject(result['editable_payload']))) !=
              canonicalSyncJson(plan.original)) {
        throw LedgerBookMoveException({plan.id: 'move.server_changed'});
      }
      if (plan.original['bill_type'] == 'expense' &&
          ledgerObject(event['data'])['remaining_allocatable_minor'] !=
              ledgerObject(plan.original['money'])['amount_minor']) {
        throw LedgerBookMoveException({plan.id: 'move.has_allocations'});
      }
    }
  }

  Map<String, Object?> _metadata(
    Map<String, Object?> info,
    String id,
    String scope,
  ) {
    if (info['attachment_id'] != id ||
        info['scope_id'] != scope ||
        info['status'] != 'ready' ||
        !attachmentMediaTypes.contains(info['media_type']) ||
        info['size_bytes'] is! int ||
        (info['size_bytes'] as int) < 1 ||
        (info['size_bytes'] as int) > 10 * 1024 * 1024) {
      throw const ApiFailure(
        'move_attachment_unavailable',
        '移动所需的原图尚不可用，请先同步。',
      );
    }
    attachmentChecksum(info['sha256']);
    return info;
  }

  Future<LedgerBookMovePrepared> prepare(
    AttachmentLease lease,
    LedgerBookMovePreview preview, {
    void Function(int complete, int total)? onProgress,
  }) async {
    _lease(lease, preview);
    if (!_running.add(preview)) {
      throw LedgerBookMoveException({'selection': 'move.busy'});
    }
    try {
      await _remotePermissions(lease, preview);
      await _capability(lease);
      await _recheck(lease, preview);
      await _remoteBills(lease, preview);
      var complete = 0;
      for (final image in preview._cloneIds.entries) {
        await _recheck(lease, preview);
        final plan = preview._plans.firstWhere(
          (p) => (p.original['attachment_ids'] as List).contains(image.key),
        );
        final meta = _metadata(
          await lease.request('GET', '/attachments/${image.key}'),
          image.key,
          plan.source,
        );
        _lease(lease, preview);
        final local = await attachments.get(lease.space, image.key);
        final original = local == null
            ? await transfer.downloadOriginal(lease, plan.source, image.key)
            : await attachments.original(lease.space, local);
        _lease(lease, preview);
        if (original.length != meta['size_bytes'] ||
            sha256.convert(original).toString() != meta['sha256'] ||
            local != null &&
                (local.scopeId != plan.source || local.epoch != lease.epoch)) {
          throw const ApiFailure('move_attachment_mismatch', '原图校验失败，未移动账单。');
        }
        await _remotePermissions(lease, preview);
        await _recheck(lease, preview);
        await attachments.stage(
          lease.space,
          lease.epoch,
          preview.targetBookId,
          original,
          mediaType: meta['media_type'] as String,
          attachmentId: image.value,
        );
        await transfer.upload(lease, image.value);
        _lease(lease, preview);
        final ready = _metadata(
          await lease.request('GET', '/attachments/${image.value}'),
          image.value,
          preview.targetBookId,
        );
        if ([
          'sha256',
          'size_bytes',
          'media_type',
        ].any((key) => ready[key] != meta[key])) {
          throw const ApiFailure(
            'move_attachment_mismatch',
            '目标图片与原件不一致，未移动账单。',
          );
        }
        onProgress?.call(++complete, preview.imageCount);
      }
      await _recheck(lease, preview);
      await _remotePermissions(lease, preview);
      await _remoteBills(lease, preview);
      return LedgerBookMovePrepared._(preview, _owner);
    } finally {
      _running.remove(preview);
    }
  }

  QueuedCommand _command(LedgerBookMovePreview preview, _MovePlan plan) =>
      QueuedCommand(
        operationId: plan.operationId,
        scopeId: plan.source,
        entityType: 'bill',
        entityId: plan.id,
        action: 'update',
        baseRevision: plan.revision,
        payload: plan.target,
        move: {
          'target_scope_id': preview.targetBookId,
          'attachment_replacements': [
            for (final image
                in (plan.original['attachment_ids'] as List).cast<String>())
              {'source_id': image, 'target_id': preview._cloneIds[image]},
          ],
        },
      );

  Future<LedgerBookMoveResult?> _existing(
    AttachmentLease lease,
    LedgerBookMovePreview preview,
  ) async {
    final p = await _projection(lease.space);
    _lease(lease, preview);
    if (_permissionHash(p) != preview.permissionHash) {
      throw LedgerBookMoveException({'selection': 'move.preview_stale'});
    }
    final existing = {for (final op in p.rows.operations) op.operationId: op};
    final found = preview._plans
        .where((plan) => existing.containsKey(plan.operationId))
        .toList();
    if (found.isEmpty) return null;
    if (found.length != preview._plans.length ||
        found.any((plan) {
          final op = existing[plan.operationId]!;
          return op.operationJson != _command(preview, plan).serialized ||
              !{'queued', 'sending', 'retry', 'applied'}.contains(op.state);
        })) {
      throw LedgerBookMoveException({'selection': 'move.review_required'});
    }
    return LedgerBookMoveResult({
      for (final plan in preview._plans) plan.id: plan.operationId,
    }, alreadyQueued: true);
  }

  Future<LedgerBookMoveResult> confirm(
    AttachmentLease lease,
    LedgerBookMovePrepared prepared,
  ) async {
    final preview = prepared.preview;
    _lease(lease, preview);
    if (!identical(prepared._owner, _owner)) {
      throw LedgerBookMoveException({'selection': 'move.preview_stale'});
    }
    await _remotePermissions(lease, preview);
    await _capability(lease);
    final prior = await _existing(lease, preview);
    if (prior != null) {
      _lease(lease, preview);
      return prior;
    }
    await _remoteBills(lease, preview);
    return _db.atomicWrite(() async {
      final existing = await _existing(lease, preview);
      if (existing != null) {
        _lease(lease, preview);
        return existing;
      }
      await _recheck(lease, preview);
      for (final clone in preview._cloneIds.values) {
        final record = await attachments.get(lease.space, clone);
        if (record == null ||
            record.phase != AttachmentPhase.ready ||
            record.scopeId != preview.targetBookId ||
            record.epoch != lease.epoch) {
          throw LedgerBookMoveException({'selection': 'move.images_not_ready'});
        }
      }
      for (final plan in preview._plans) {
        _lease(lease, preview);
        await ledger.repository.saveEntityAndQueue(
          lease.space,
          _command(preview, plan),
        );
        final entries = plan.postings.map(postingJson).toList();
        await ledger.repository.writeSetting(
          'ledger.postings.v1.${lease.space.id}.${plan.operationId}',
          jsonEncode({
            'version': 1,
            'bill_id': plan.id,
            'fingerprint': financialFingerprint(plan.target),
            'old_entries': entries,
            'new_entries': entries,
            'move_source_scope_id': plan.source,
            'move_source_revision': plan.revision,
            'move_source_projection_hash': plan.sourceProjectionHash,
          }),
        );
      }
      _lease(lease, preview);
      return LedgerBookMoveResult({
        for (final plan in preview._plans) plan.id: plan.operationId,
      });
    });
  }
}
