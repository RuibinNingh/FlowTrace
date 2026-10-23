import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/attachments/attachment_repository.dart';
import 'package:flowtrace/data/attachments/attachment_transfer.dart';
import 'package:flowtrace/data/attachments/byte_store_native.dart';
import 'package:flowtrace/data/ledger/ledger_book_move.dart';
import 'package:flowtrace/data/ledger/ledger_models.dart';
import 'package:flowtrace/data/ledger/ledger_projection.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';

import 'query_fixtures.dart';

final targetExpense = qid(60), targetIncome = qid(61), targetTag = qid(62);

final class _DelayedRead extends QueryInterceptor {
  bool active = false;
  int count = 0;
  final started = Completer<void>(), resume = Completer<void>();
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(statement, args);
    if (active && statement.contains('local_entities') && ++count == 2) {
      started.complete();
      await resume.future;
    }
    return rows;
  }
}

BillBookMoveMapping clearMapping() =>
    BillBookMoveMapping(categoryId: null, tagIds: [], feeCategoryId: null);
Uint8List picture() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII=',
);

final class _Remote {
  _Remote(this.f);
  final QueryFixture f;
  bool current = true,
      supportsMove = true,
      staleBill = false,
      requiresRebuild = false;
  final roles = {qUser: 'owner', qBook: 'owner', qOtherBook: 'owner'};
  final originals = <String, Map<String, Object?>>{};
  final public = <String, Map<String, Object?>>{};
  final revisions = <String, String>{};
  final images = <String, Uint8List>{};
  final scopes = <String, String>{};
  final declarations = <String, Map<String, Object?>>{};
  final uploads = <String, String>{};
  int nextUpload = 500, downloads = 0;
  Future<void> capture(Iterable<String> ids) async {
    for (final id in ids) {
      final bill = await f.entity(id);
      originals[id] = bill.editablePayload!;
      public[id] = bill.projection;
      revisions[id] = bill.revision;
    }
  }

  Map<String, Object?> metadata(String id) => {
    'attachment_id': id,
    'scope_id': scopes[id],
    'status': 'ready',
    'sha256': sha256.convert(images[id]!).toString(),
    'size_bytes': images[id]!.length,
    'media_type': 'image/png',
    'width': 3,
    'height': 2,
  };
  AttachmentLease get lease => AttachmentLease(
    space: f.space,
    epoch: qEpoch,
    clientId: qid(5),
    generation: 1,
    isCurrent: () => current,
    request: (method, path, {body, bodyBytes, contentType}) async {
      if (path == '/server-info') {
        return {
          'instance_id': f.space.serverInstanceId,
          'sync_epoch': qEpoch,
          'minimum_protocol': 1,
          'capabilities': [if (supportsMove) 'bill-move-v1'],
        };
      }
      if (path == '/sync/scopes') {
        return {
          'sync_epoch': qEpoch,
          'requires_rebuild': requiresRebuild,
          'revoked_scope_ids': [
            for (final id in [qUser, qBook, qOtherBook])
              if (!roles.containsKey(id)) id,
          ],
          'scopes': [
            for (final entry in roles.entries)
              {
                'scope_id': entry.key,
                'role': entry.value,
                'kind': entry.key == qUser ? 'user' : 'book',
                'permission_version': '1',
                'revision': '1',
              },
          ],
        };
      }
      if (path.startsWith('/sync/entities/bill/')) {
        final id = Uri.parse(path).pathSegments.last;
        return {
          'event': {
            'scope_id': qBook,
            'entity_type': 'bill',
            'entity_id': id,
            'revision': staleBill
                ? (BigInt.parse(revisions[id]!) + BigInt.one).toString()
                : revisions[id],
            'deleted': false,
            'data': public[id],
          },
          'editable_payload': originals[id],
        };
      }
      if (path == '/attachments/uploads' && method == 'POST') {
        final id = body!['attachment_id'] as String;
        final upload = qid(nextUpload++);
        declarations[id] = body;
        uploads[upload] = id;
        scopes[id] = body['scope_id'] as String;
        return {'attachment_id': id, 'upload_id': upload, 'status': 'pending'};
      }
      if (path.startsWith('/attachments/uploads/')) {
        final upload = Uri.parse(path).pathSegments[2],
            id = uploads[Uri.parse(path).pathSegments[2]]!;
        if (method == 'PUT') {
          images[id] = Uint8List.fromList(bodyBytes!);
          return {
            'attachment_id': id,
            'upload_id': upload,
            'status': 'uploaded',
          };
        }
        return metadata(id);
      }
      if (path.startsWith('/attachments/')) {
        return metadata(path.split('/').last);
      }
      throw StateError('Unexpected synthetic request $method $path');
    },
    download: (path, {maxBytes = 10 * 1024 * 1024}) async {
      downloads++;
      return Uint8List.fromList(images[Uri.parse(path).pathSegments[1]]!);
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late QueryFixture f;
  late Directory directory;
  late NativeAttachmentBytes bytes;
  late AttachmentRepository attachments;
  late LedgerBookMoveService service;
  late _Remote remote;
  late _DelayedRead delayed;
  setUp(() async {
    delayed = _DelayedRead();
    f = QueryFixture(executor: NativeDatabase.memory().interceptWith(delayed));
    await f.seed();
    directory = await Directory.systemTemp.createTemp('flowtrace-book-move-');
    bytes = NativeAttachmentBytes(directory);
    attachments = AttachmentRepository(f.local, bytes);
    remote = _Remote(f);
    final engine = SyncEngine(f.sync, onScopeRevoked: attachments.revokeScope);
    service = LedgerBookMoveService(
      f.ledger,
      attachments,
      refreshPermissions: (lease) async {
        await engine.refreshScopes(
          SyncLease(
            space: lease.space,
            clientId: lease.clientId,
            epoch: lease.epoch,
            isCurrent: lease.isCurrent,
            request: (method, path, {body, bodyJson}) =>
                lease.request(method, path, body: body),
          ),
        );
      },
    );
    for (final id in [targetExpense, targetIncome]) {
      await f.put('category', id, qOtherBook, {
        'projection_kind': 'category',
        'payload': {
          'name': '合成目标分类',
          'kind': id == targetIncome ? 'income' : 'expense',
          'parent_id': null,
          'icon': 'food',
          'sort_order': 0,
          'archived': false,
        },
      });
    }
    await f.put('tag', targetTag, qOtherBook, {
      'projection_kind': 'tag',
      'payload': {
        'name': '合成目标标签',
        'kind': 'tag',
        'group_id': null,
        'color': '#2279D7',
        'sort_order': 0,
        'archived': false,
      },
    });
    await remote.capture([qa, qb, qc, qd, qf]);
  });
  tearDown(() async {
    await bytes.close();
    await f.close();
    expect(directory.absolute.parent.path, Directory.systemTemp.absolute.path);
    expect(
      directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('flowtrace-book-move-'),
    );
    await directory.delete(recursive: true);
  });
  Future<LedgerBookMovePreview> preview([List<String>? ids]) => service.preview(
    remote.lease,
    ids: ids ?? [qc],
    targetBookId: qOtherBook,
    mappings: {
      for (final id in ids ?? [qc]) id: clearMapping(),
    },
  );
  Future<LedgerBookMoveResult> move([List<String>? ids]) async {
    final p = await preview(ids);
    expect(p.issues, isEmpty);
    return service.confirm(
      remote.lease,
      await service.prepare(remote.lease, p),
    );
  }

  Future<void> financialBill(
    String id,
    Map<String, Object?> input,
    List<Map<String, Object?>> entries,
  ) async {
    final full = normalizeLedgerPayload('bill', {
      'book_id': qBook,
      'business_date': '2026-10-21',
      'business_timezone': 'Asia/Shanghai',
      ...input,
    });
    final payload = ledgerCopy(full),
        hidden = <String>[],
        links = <String, Object?>{
          'account_id': null,
          'from_account_id': null,
          'to_account_id': null,
          'fee_account_id': null,
        };
    for (final field in ['account_id', 'from_account_id', 'to_account_id']) {
      if (payload[field] != null) {
        links[field] = payload[field];
        payload[field] = null;
        hidden.add(field);
      }
    }
    if (payload['fee'] != null) {
      final fee = ledgerObject(payload['fee']);
      links['fee_account_id'] = fee['account_id'];
      payload['fee'] = {...fee, 'account_id': null};
      hidden.add('fee.account_id');
    }
    await f.put('bill', id, qBook, {
      'projection_kind': 'bill_public',
      'payload': payload,
      'hidden_account_fields': hidden,
      'hidden_allocation_count': 0,
      'paid_by_user_ids': [qUser],
      'remaining_allocatable_minor': full['bill_type'] == 'expense'
          ? ledgerObject(full['money'])['amount_minor']
          : null,
    });
    await f.shadow('bill', id, qUser, {
      'projection_kind': 'bill_private_finance',
      'book_id': qBook,
      'bill_type': full['bill_type'],
      'business_date': full['business_date'],
      'business_timezone': full['business_timezone'],
      'account_links': links,
      'entries': entries,
    });
    await remote.capture([id]);
  }

  test(
    'capability and explicit field mappings are required before writes',
    () async {
      remote.supportsMove = false;
      await expectLater(
        preview(),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'bill_move_unsupported',
          ),
        ),
      );
      remote.supportsMove = true;
      final p = await service.preview(
        remote.lease,
        ids: [qc],
        targetBookId: qOtherBook,
        mappings: {},
      );
      expect(p.issues[qc], 'move.mapping_required');
      expect(await f.local.pending(f.space), isEmpty);
    },
  );
  test(
    'preview confirms target roles and rejects pending definitions',
    () async {
      await f.roles(otherRole: 'viewer');
      remote.roles[qOtherBook] = 'viewer';
      expect((await preview()).issues[qc], 'move.scope_readonly');
      await f.roles();
      remote.roles[qOtherBook] = 'owner';
      await f.ledger.save(
        f.space,
        entityType: 'category',
        scopeId: qOtherBook,
        entityId: targetIncome,
        payload: {
          ...(await f.ledger.read(
            f.space,
          )).find('category', targetIncome)!.payload,
          'name': '尚未同步',
        },
      );
      final p = await service.preview(
        remote.lease,
        ids: [qc],
        targetBookId: qOtherBook,
        mappings: {
          qc: BillBookMoveMapping(
            categoryId: targetIncome,
            tagIds: [],
            feeCategoryId: null,
          ),
        },
      );
      expect(p.issues[qc], 'move.sync_definitions_first');
    },
  );
  test(
    'queued move retains one UUID, maps explicit metadata and preserves balances',
    () async {
      final before = (await f.ledger.read(
        f.space,
      )).balances[qCash]!.value!.minor;
      final p = await service.preview(
        remote.lease,
        ids: [qc],
        targetBookId: qOtherBook,
        mappings: {
          qc: BillBookMoveMapping(
            categoryId: targetIncome,
            tagIds: [targetTag],
            feeCategoryId: null,
          ),
        },
      );
      final prepared = await service.prepare(remote.lease, p);
      expect(await f.local.pending(f.space), isEmpty);
      final result = await service.confirm(remote.lease, prepared);
      final bill = await f.entity(qc);
      expect(bill.scopeId, qOtherBook);
      expect(bill.id, qc);
      expect(bill.payload['category_id'], targetIncome);
      expect(bill.payload['tag_ids'], [targetTag]);
      final op = (await f.local.pending(f.space)).single;
      final body = jsonDecode(op.operationJson);
      expect(body['move']['target_scope_id'], qOtherBook);
      expect(body['scope_id'], qBook);
      expect(body['payload']['money'], remote.originals[qc]!['money']);
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.minor,
        before,
      );
      final again = await service.confirm(remote.lease, prepared);
      expect(again.alreadyQueued, isTrue);
      expect(again.operationIds, result.operationIds);
      expect(await f.local.pending(f.space), hasLength(1));
    },
  );
  test(
    'old applied history does not invalidate a proven pending move baseline',
    () async {
      final p = await preview();
      final prepared = await service.prepare(remote.lease, p);
      await move();
      // Prior acknowledged history for the same UUID can remain in the journal.
      final now = DateTime.now().toUtc();
      await f.db
          .into(f.db.pendingOperations)
          .insert(
            PendingOperationsCompanion.insert(
              spaceId: f.space.id,
              operationId: qid(900),
              entityType: 'bill',
              entityId: qc,
              operationJson: jsonEncode({'action': 'create'}),
              state: const Value('applied'),
              appliedRevision: const Value('1'),
              createdAt: now,
            ),
          );
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value?.minor,
        BigInt.from(100000),
      );
      // A preview that has not itself been queued becomes stale after another move.
      await expectLater(
        service.confirm(remote.lease, prepared),
        throwsA(isA<LedgerBookMoveException>()),
      );
    },
  );
  test(
    'same revision metadata change and newer remote revision both invalidate preview',
    () async {
      final p = await preview();
      final entity = await f.entity(qc), data = entity.projection;
      data['payload'] = {...entity.payload, 'note': '同修订本机变化'};
      await f.put('bill', qc, qBook, data);
      await expectLater(
        service.prepare(remote.lease, p),
        throwsA(isA<LedgerBookMoveException>()),
      );
      await f.putBill(qc, remote.originals[qc]!);
      final fresh = await preview();
      remote.staleBill = true;
      await expectLater(
        service.prepare(remote.lease, fresh),
        throwsA(isA<LedgerBookMoveException>()),
      );
      expect(await f.local.pending(f.space), isEmpty);
    },
  );
  test(
    'real source bytes clone to target ready ID before one move is queued',
    () async {
      remote.images[qid(42)] = picture();
      remote.scopes[qid(42)] = qBook;
      await attachments.stage(
        f.space,
        qEpoch,
        qBook,
        picture(),
        mediaType: 'image/png',
        attachmentId: qid(42),
      );
      final p = await preview([qa]);
      expect(p.imageCount, 1);
      final prepared = await service.prepare(remote.lease, p);
      expect(await f.local.pending(f.space), isEmpty);
      expect((await f.entity(qa)).scopeId, qBook);
      final target = remote.declarations.keys.single;
      expect(target, isNot(qid(42)));
      expect(remote.images[target], picture());
      expect(remote.scopes[target], qOtherBook);
      expect(remote.scopes[qid(42)], qBook);
      await service.confirm(remote.lease, prepared);
      final body = jsonDecode(
        (await f.local.pending(f.space)).single.operationJson,
      );
      expect(body['payload']['attachment_ids'], [target]);
      expect(body['move']['attachment_replacements'], [
        {'source_id': qid(42), 'target_id': target},
      ]);
      expect(
        await attachments.original(
          f.space,
          (await attachments.get(f.space, qid(42)))!,
        ),
        picture(),
      );
    },
  );
  test(
    'a last queue failure rolls back earlier moves, hints and balances',
    () async {
      final p = await preview([qc, qd]);
      final prepared = await service.prepare(remote.lease, p);
      await f.db.customStatement(
        "CREATE TRIGGER move_fail BEFORE INSERT ON pending_operations WHEN NEW.entity_id = '$qd' BEGIN SELECT RAISE(ABORT, 'isolated move failure'); END",
      );
      await expectLater(
        service.confirm(remote.lease, prepared),
        throwsA(anything),
      );
      expect((await f.entity(qc)).scopeId, qBook);
      expect((await f.entity(qd)).scopeId, qBook);
      expect(await f.local.pending(f.space), isEmpty);
      expect(
        (await f.db.select(f.db.appSettings).get()).where(
          (s) => s.key.startsWith('ledger.postings.'),
        ),
        isEmpty,
      );
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value!.minor,
        BigInt.from(100000),
      );
    },
  );
  test(
    'missing source hash or readable source authority cannot prove a balance',
    () async {
      final result = await move();
      final key = 'ledger.postings.v1.${f.space.id}.${result.operationIds[qc]}';
      final original = (await f.local.readSetting(key))!;
      final hint = jsonDecode(original) as Map<String, dynamic>;
      hint['move_source_projection_hash'] = '0' * 64;
      await f.local.writeSetting(key, jsonEncode(hint));
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.available,
        isFalse,
      );
      await f.local.writeSetting(key, original);
      await f.local.writeSetting(
        'sync.scope-details.${f.space.id}',
        jsonEncode({
          'version': 1,
          'epoch': qEpoch,
          'scopes': [
            {
              'scope_id': qOtherBook,
              'kind': 'book',
              'role': 'owner',
              'permission_version': '1',
            },
          ],
        }),
      );
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.available,
        isFalse,
      );
    },
  );
  test(
    'raw ACK does not turn a missing target canonical projection into zero',
    () async {
      final result = await move();
      final frozen = await f.sync.nextPush(f.space);
      expect(frozen, isNotNull);
      await f.sync.acknowledge(f.space, result.operationIds[qc]!, '2');
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.available,
        isFalse,
      );
    },
  );
  test(
    'historical signed +500 adjustment stays +500 while changing books',
    () async {
      final id = qid(210);
      await financialBill(
        id,
        {
          'bill_type': 'balance_adjustment',
          'money': qmoney('500'),
          'account_id': qCash,
          'target_balance_minor': '10500',
        },
        [
          {
            'account_id': qCash,
            'component': 'principal',
            'money': qmoney('500'),
          },
        ],
      );
      final account = (await f.ledger.read(f.space)).find('account', qCash)!;
      await f.put('account', qCash, qUser, {
        ...account.projection,
        'balance': qmoney('100500'),
      });
      final result = await move([id]);
      final hint = jsonDecode(
        (await f.local.readSetting(
          'ledger.postings.v1.${f.space.id}.${result.operationIds[id]}',
        ))!,
      );
      expect(hint['old_entries'].single['money']['amount_minor'], '500');
      expect(hint['new_entries'], hint['old_entries']);
      expect(
        (await f.ledger.read(f.space)).balances[qCash]!.value?.minor,
        BigInt.from(100500),
      );
    },
  );
  test(
    'transfer principal and separate fee retain all three signed entries',
    () async {
      await financialBill(
        qd,
        {
          'bill_type': 'transfer',
          'money': qmoney('1000'),
          'from_account_id': qCash,
          'to_account_id': qBank,
          'fee': {
            'money': qmoney('37'),
            'account_id': qCash,
            'category_id': qParent,
            'flags': {
              'exclude_from_statistics': false,
              'exclude_from_budget': false,
            },
          },
        },
        [
          {
            'account_id': qCash,
            'component': 'principal',
            'money': qmoney('-1000'),
          },
          {
            'account_id': qBank,
            'component': 'principal',
            'money': qmoney('1000'),
          },
          {'account_id': qCash, 'component': 'fee', 'money': qmoney('-37')},
        ],
      );
      final p = await service.preview(
        remote.lease,
        ids: [qd],
        targetBookId: qOtherBook,
        mappings: {
          qd: BillBookMoveMapping(
            categoryId: null,
            tagIds: [],
            feeCategoryId: targetExpense,
          ),
        },
      );
      final result = await service.confirm(
        remote.lease,
        await service.prepare(remote.lease, p),
      );
      final hint = jsonDecode(
        (await f.local.readSetting(
          'ledger.postings.v1.${f.space.id}.${result.operationIds[qd]}',
        ))!,
      );
      expect(hint['new_entries'], hasLength(3));
      expect(hint['new_entries'], hint['old_entries']);
      final balances = (await f.ledger.read(f.space)).balances;
      expect(balances[qCash]!.value?.minor, BigInt.from(100000));
      expect(balances[qBank]!.value?.minor, BigInt.from(100000));
    },
  );
  test(
    'fresh source revocation clears controlled projections while retaining original image intent',
    () async {
      remote.images[qid(42)] = picture();
      remote.scopes[qid(42)] = qBook;
      await attachments.stage(
        f.space,
        qEpoch,
        qBook,
        picture(),
        mediaType: 'image/png',
        attachmentId: qid(42),
      );
      await attachments.cache(
        f.space,
        qEpoch,
        qBook,
        qid(42),
        'original',
        picture(),
        sha256.convert(picture()).toString(),
      );
      final p = await preview([qa]);
      remote.roles.remove(qBook);
      await expectLater(service.prepare(remote.lease, p), throwsA(anything));
      expect((await f.ledger.read(f.space)).find('bill', qa), isNull);
      expect(
        (await attachments.get(f.space, qid(42)))!.errorCode,
        'scope_revoked',
      );
      expect(
        (await f.db.select(f.db.appSettings).get()).where(
          (s) => s.key.contains('.cache.'),
        ),
        isEmpty,
      );
      expect(await f.local.pending(f.space), isEmpty);
      remote.current = false;
    },
  );
  test(
    'fresh target downgrade and recovery make move preparation read only',
    () async {
      final p = await preview();
      remote.roles[qOtherBook] = 'viewer';
      await expectLater(service.prepare(remote.lease, p), throwsA(anything));
      expect((await f.ledger.read(f.space)).roleFor(qOtherBook), 'viewer');
      remote.roles[qOtherBook] = 'owner';
      final fresh = await preview();
      remote.requiresRebuild = true;
      await expectLater(
        service.prepare(remote.lease, fresh),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'resync_required'),
        ),
      );
      expect((await f.sync.state(f.space))!.status, 'recovery_required');
      expect(await f.local.pending(f.space), isEmpty);
    },
  );
  test(
    'identity changed during already-queued lookup cannot return late success',
    () async {
      final p = await preview(),
          prepared = await service.prepare(remote.lease, await preview());
      // Use the exact prepared preview for an idempotent second confirmation.
      expect(p.canPrepare, isTrue);
      await service.confirm(remote.lease, prepared);
      delayed.active = true;
      final assertion = expectLater(
        service.confirm(remote.lease, prepared),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      await delayed.started.future.timeout(const Duration(seconds: 3));
      remote.current = false;
      delayed.resume.complete();
      await assertion;
      expect(await f.local.pending(f.space), hasLength(1));
    },
  );
  for (final oldTomb in [true, false]) {
    test(
      'round trip with historical target ${oldTomb ? 'same-revision tomb' : 'older live'} keeps 9875',
      () async {
        final id = qid(220);
        await f.putBill(id, {
          'bill_type': 'expense',
          'money': qmoney('125'),
          'account_id': qCash,
        }, scope: qOtherBook);
        final old = await f.entity(id);
        final sourceData = ledgerCopy(old.projection)
          ..['payload'] = {...old.payload, 'book_id': qBook};
        final privateRow = (await f.db.select(f.db.serverShadows).get())
            .singleWhere((r) => r.entityId == id && r.scopeId == qUser);
        final finance = ledgerCopy(
          jsonDecode(privateRow.dataJson) as Map<String, Object?>,
        )..['book_id'] = qBook;
        await f.sync.applyPullPage(f.space, qEpoch, [
          [
            if (oldTomb)
              SyncEvent(
                scopeId: qOtherBook,
                entityType: 'bill',
                entityId: id,
                revision: '2',
                deleted: true,
                data: {},
              ),
            SyncEvent(
              scopeId: qBook,
              entityType: 'bill',
              entityId: id,
              revision: '2',
              deleted: false,
              data: sourceData,
            ),
            SyncEvent(
              scopeId: qUser,
              entityType: 'bill',
              entityId: id,
              revision: '2',
              deleted: false,
              data: finance,
            ),
          ],
        ], finalPage: false);
        final account = (await f.ledger.read(f.space)).find('account', qCash)!;
        await f.put('account', qCash, qUser, {
          ...account.projection,
          'balance': qmoney('9875'),
        });
        await remote.capture([id]);
        await move([id]);
        expect((await f.entity(id)).scopeId, qOtherBook);
        expect(
          (await f.ledger.read(f.space)).balances[qCash]!.value?.minor,
          BigInt.from(9875),
        );
        await f.shadow('bill', id, qOtherBook, {}, revision: '3');
        await (f.db.update(f.db.serverShadows)..where(
              (t) => t.entityId.equals(id) & t.scopeId.equals(qOtherBook),
            ))
            .write(const ServerShadowsCompanion(deleted: Value(true)));
        expect(
          (await f.ledger.read(f.space)).balances[qCash]!.available,
          isFalse,
        );
      },
    );
  }
  for (final targetFirst in [true, false]) {
    test(
      'canonical pull order targetFirst=$targetFirst preserves exact movement',
      () async {
        final result = await move();
        final moved = await f.entity(qc);
        final target = ledgerCopy(remote.public[qc]!)
          ..['payload'] = {
            ...ledgerObject(remote.public[qc]!['payload']),
            'book_id': qOtherBook,
            'category_id': null,
            'tag_ids': [],
          };
        final events = [
          SyncEvent(
            scopeId: qBook,
            entityType: 'bill',
            entityId: qc,
            revision: '2',
            deleted: true,
            data: {},
          ),
          SyncEvent(
            scopeId: qOtherBook,
            entityType: 'bill',
            entityId: qc,
            revision: '2',
            deleted: false,
            data: target,
          ),
        ];
        for (final event in targetFirst ? events.reversed : events) {
          await f.sync.applyPullPage(f.space, qEpoch, [
            [event],
          ], finalPage: false);
        }
        expect((await f.entity(qc)).scopeId, qOtherBook);
        expect(
          (await f.ledger.read(f.space)).balances[qCash]!.value?.minor,
          BigInt.from(100000),
        );
        await f.sync.nextPush(f.space);
        await f.sync.acknowledge(f.space, result.operationIds[qc]!, '2');
        expect(
          (await f.ledger.read(f.space)).balances[qCash]!.value?.minor,
          BigInt.from(100000),
        );
        expect(moved.id, qc);
      },
    );
  }
}
