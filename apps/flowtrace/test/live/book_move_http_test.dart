import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/attachments/attachment_repository.dart';
import 'package:flowtrace/data/attachments/attachment_transfer.dart';
import 'package:flowtrace/data/attachments/byte_store_native.dart';
import 'package:flowtrace/data/ledger/ledger_book_move.dart';
import 'package:flowtrace/data/ledger/ledger_reporting.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/attachments/attachment_models.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';

import '../identity/identity_controller_test.dart' show MemoryVault;

const _uuid = Uuid();
const _time = '2026-10-20T16:00:00.123456Z';

Map<String, Object?> _money(String minor) => {
  'currency': 'CNY',
  'currency_scale': 2,
  'amount_minor': minor,
};

/// Drop only the selected real successful move response, after the HTTP
/// server has committed. The client coordinator must retry its frozen bytes.
final class _DropCommittedMove extends http.BaseClient {
  final inner = http.Client();
  String? operationId;
  bool drop = false;
  final bodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var selected = false;
    if (operationId != null &&
        request.method == 'POST' &&
        request.url.path.endsWith('/sync/push') &&
        request is http.Request) {
      final operations =
          (jsonDecode(request.body) as Map)['operations'] as List;
      selected = operations.any(
        (row) => (row as Map)['operation_id'] == operationId,
      );
      if (selected) bodies.add(request.body);
    }
    final response = await inner.send(request);
    if (selected && drop && response.statusCode == 200) {
      drop = false;
      await response.stream.drain<void>();
      throw const SocketException(
        'Synthetic committed book-move response loss',
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

final class _Client {
  _Client(Directory directory, this.transport) {
    database = AppDatabase(
      NativeDatabase(File(p.join(directory.path, 'local.sqlite'))),
    );
    local = LocalRepository(database);
    identity = IdentityController(
      repository: local,
      api: ApiClient(transport),
      vault: MemoryVault(),
      isWeb: false,
      allowLocalHttp: true,
      deviceName: 'book-move-http-${p.basename(directory.path)}',
    );
    store = SyncStore(local);
    bytes = NativeAttachmentBytes(Directory(p.join(directory.path, 'bytes')));
    attachments = AttachmentRepository(local, bytes);
    transfer = AttachmentTransfer(attachments);
    ledger = LedgerRepository(local);
    engine = SyncEngine(
      store,
      onScopeRevoked: attachments.revokeScope,
      beforePush: (captured, command) async {
        if (command['entity_type'] != 'bill' || command['action'] == 'delete') {
          return;
        }
        captured.check();
        final payload = command['payload'] as Map;
        final marker = command['move'] as Map?;
        await transfer.ensureReady(
          AttachmentLease.capture(identity),
          (marker?['target_scope_id'] ?? command['scope_id']) as String,
          (payload['attachment_ids'] as List).cast<String>(),
        );
        captured.check();
      },
    );
    mover = LedgerBookMoveService(
      ledger,
      attachments,
      transfer: transfer,
      refreshPermissions: (captured) async {
        captured.check();
        await engine.refreshScopes(
          SyncLease(
            space: captured.space,
            clientId: captured.clientId,
            epoch: captured.epoch,
            isCurrent: captured.isCurrent,
            request: (method, path, {body, bodyJson}) {
              if (bodyJson != null) {
                throw StateError('Permission refresh has no frozen body');
              }
              return captured.request(method, path, body: body);
            },
          ),
        );
        captured.check();
      },
    );
  }
  final http.Client transport;
  late final AppDatabase database;
  late final LocalRepository local;
  late final IdentityController identity;
  late final SyncStore store;
  late final SyncEngine engine;
  late final NativeAttachmentBytes bytes;
  late final AttachmentRepository attachments;
  late final AttachmentTransfer transfer;
  late final LedgerRepository ledger;
  late final LedgerBookMoveService mover;
  DataSpace get space => identity.accountSpace!;

  static Future<_Client> login(
    Map<String, Object?> config,
    String role,
    String name, {
    http.Client? transport,
  }) async {
    final directory = Directory(
      p.join(config['run_directory'] as String, name),
    );
    await directory.create(recursive: true);
    final result = _Client(directory, transport ?? http.Client());
    try {
      final account = (config['accounts'] as Map)[role] as Map;
      await result.identity.configure(
        ServerAddress.parse(config['server'] as String),
      );
      await result.identity.signIn(
        username: account['username'] as String,
        password: account['password'] as String,
      );
      await result.local.registerSpace(result.space);
      return result;
    } catch (_) {
      await result.close();
      rethrow;
    }
  }

  Future<void> sync() => engine.synchronize(SyncLease.capture(identity));
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) => identity.authorizedRequest(method, path, body: body);
  Future<void> close() async {
    try {
      if (identity.online) await identity.signOut();
    } finally {
      identity.dispose();
      transport.close();
      await bytes.close();
      await database.close();
    }
  }
}

ReportQuery _query(String book) => ReportQuery(
  bookId: book,
  reportCurrency: 'CNY',
  reportScale: 2,
  startDate: '2026-10-01',
  endDateExclusive: '2026-11-01',
);

Future<void> _expense(_Client client, String book, String minor) async {
  final report = await LedgerReportingService(
    client.local,
  ).read(client.space, _query(book));
  expect(report.available, isTrue, reason: report.issues.join(', '));
  expect(report.totals!.expense.minor.toString(), minor);
}

Future<void> _balance(_Client client, String account, String minor) async {
  final balance = (await client.ledger.read(client.space)).balances[account]!;
  expect(balance.available, isTrue, reason: balance.issue);
  expect(balance.value!.minor.toString(), minor);
}

void main() {
  final file = Platform.environment['FLOWTRACE_BOOK_MOVE_QA_FILE'];
  test(
    'real isolated move: ready clones exact money lost receipt two clients and fresh revocation',
    () async {
      final config = (jsonDecode(await File(file!).readAsString()) as Map)
          .cast<String, Object?>();
      final server = Uri.parse(config['server'] as String);
      final run = Directory(config['run_directory'] as String).absolute;
      final normalizedRun = run.path.replaceAll('\\', '/');
      if (server.host != '127.0.0.1' ||
          server.port != 18084 ||
          config['database'] != 'flowtrace_test_book_move_local' ||
          !normalizedRun.contains('/work/flowtrace-book-move/') ||
          File(file).absolute.parent.path != run.path) {
        throw StateError('Requires the dedicated synthetic book-move harness');
      }
      final opened = <_Client>[];
      final drop = _DropCommittedMove();
      try {
        final owner = await _Client.login(config, 'owner', 'owner');
        opened.add(owner);
        final actor = await _Client.login(
          config,
          'actor',
          'actor-one',
          transport: drop,
        );
        opened.add(actor);
        final peer = await _Client.login(config, 'actor', 'actor-two');
        opened.add(peer);
        final viewer = await _Client.login(config, 'viewer', 'viewer');
        opened.add(viewer);
        expect(actor.identity.clientId, isNot(peer.identity.clientId));

        final source = _uuid.v4(),
            target = _uuid.v4(),
            account = _uuid.v4(),
            bill = _uuid.v4();
        final sourceCategory = _uuid.v4(),
            targetCategory = _uuid.v4(),
            targetTag = _uuid.v4();
        for (final entry in {source: '合成移动来源', target: '合成移动目标'}.entries) {
          await owner.request(
            'POST',
            '/books',
            body: {'id': entry.key, 'name': entry.value},
          );
          final invitation = await owner.request(
            'POST',
            '/books/${entry.key}/invites',
            body: {'role': 'editor', 'days': 1},
          );
          await actor.request(
            'POST',
            '/books/join',
            body: {'token': invitation['token']},
          );
        }
        final viewerInvitation = await owner.request(
          'POST',
          '/books/$source/invites',
          body: {'role': 'viewer', 'days': 1},
        );
        await viewer.request(
          'POST',
          '/books/join',
          body: {'token': viewerInvitation['token']},
        );
        await actor.sync();
        await peer.sync();
        await viewer.sync();
        expect(
          (await actor.ledger.read(actor.space)).roleFor(source),
          'editor',
        );
        expect(
          (await actor.ledger.read(actor.space)).roleFor(target),
          'editor',
        );

        await actor.ledger.save(
          actor.space,
          entityType: 'account',
          scopeId: actor.space.userId,
          entityId: account,
          payload: {
            'name': '合成私有账户',
            'kind': 'cash',
            'opening': _money('10000'),
            'include_in_net_assets': true,
            'hidden': false,
          },
        );
        for (final entry in {
          sourceCategory: source,
          targetCategory: target,
        }.entries) {
          await actor.ledger.save(
            actor.space,
            entityType: 'category',
            scopeId: entry.value,
            entityId: entry.key,
            payload: {
              'name': '合成支出分类',
              'kind': 'expense',
              'parent_id': null,
              'icon': 'food',
              'sort_order': 0,
              'archived': false,
            },
          );
        }
        await actor.ledger.save(
          actor.space,
          entityType: 'tag',
          scopeId: target,
          entityId: targetTag,
          payload: {
            'name': '显式目标标签',
            'color': '#2279D7',
            'kind': 'tag',
            'group_id': null,
            'sort_order': 0,
            'archived': false,
          },
        );
        await actor.sync();

        final originals = <String>[];
        for (final raw in config['images'] as List) {
          final image = raw as Map;
          final content = base64Decode(image['base64'] as String);
          expect(sha256.convert(content).toString(), image['sha256']);
          final staged = await actor.attachments.stage(
            actor.space,
            actor.identity.serverIdentity!.syncEpoch,
            source,
            content,
            mediaType: 'image/png',
          );
          originals.add(staged.id);
          await actor.transfer.upload(
            AttachmentLease.capture(actor.identity),
            staged.id,
          );
        }
        final full = <String, Object?>{
          'bill_type': 'expense',
          'money': _money('125'),
          'book_id': source,
          'account_id': account,
          'business_date': '2026-10-21',
          'business_timezone': 'Asia/Shanghai',
          'occurred_at': _time,
          'category_id': sourceCategory,
          'tag_ids': <String>[],
          'attachment_ids': originals,
          'note': '合成带图移动，保留精确时间',
        };
        await actor.ledger.save(
          actor.space,
          entityType: 'bill',
          scopeId: source,
          entityId: bill,
          payload: full,
        );
        await actor.sync();
        await peer.sync();
        await viewer.sync();
        await _balance(actor, account, '9875');
        await _expense(actor, source, '125');
        await _expense(actor, target, '0');
        expect(
          (await viewer.ledger.read(viewer.space)).find('bill', bill),
          isNotNull,
        );

        final attachmentLease = AttachmentLease.capture(actor.identity);
        final preview = await actor.mover.preview(
          attachmentLease,
          ids: [bill],
          targetBookId: target,
          mappings: {
            bill: BillBookMoveMapping(
              categoryId: targetCategory,
              tagIds: [targetTag],
              feeCategoryId: null,
            ),
          },
        );
        expect(preview.canPrepare, isTrue, reason: preview.issues.toString());
        expect(preview.imageCount, 2);
        final prepared = await actor.mover.prepare(attachmentLease, preview);
        final result = await actor.mover.confirm(attachmentLease, prepared);
        final operationId = result.operationIds[bill]!;
        final repeated = await actor.mover.confirm(attachmentLease, prepared);
        expect(repeated.alreadyQueued, isTrue);
        expect(repeated.operationIds, result.operationIds);
        final pending = (await actor.local.pending(actor.space)).single;
        final command = jsonDecode(pending.operationJson) as Map;
        expect(command['scope_id'], source);
        expect(command['move']['target_scope_id'], target);
        expect(command['payload']['occurred_at'], _time);
        final clones = (command['payload']['attachment_ids'] as List)
            .cast<String>();
        expect(clones.toSet().intersection(originals.toSet()), isEmpty);
        await _balance(actor, account, '9875');
        final pendingReport = await LedgerReportingService(
          actor.local,
        ).read(actor.space, _query(target));
        expect(pendingReport.available, isFalse);
        expect(pendingReport.totals, isNull);

        drop.operationId = operationId;
        drop.drop = true;
        await expectLater(
          actor.sync(),
          throwsA(isA<ApiFailure>().having((e) => e.offline, 'offline', true)),
        );
        final retry = (await actor.local.pending(actor.space)).single;
        final frozen = retry.frozenRequestJson;
        expect(retry.state, 'retry');
        expect(frozen, isNotNull);
        await _balance(actor, account, '9875');
        await actor.sync();
        expect(drop.bodies, hasLength(2));
        expect(drop.bodies[0], frozen);
        expect(drop.bodies[1], frozen);
        final journal =
            (await actor.database
                    .select(actor.database.pendingOperations)
                    .get())
                .singleWhere((row) => row.operationId == operationId);
        expect(journal.state, 'applied');
        expect(journal.appliedRevision, '2');
        expect(journal.attemptCount, 2);
        await peer.sync();
        await viewer.sync();

        for (final client in [actor, peer]) {
          final moved = (await client.ledger.read(
            client.space,
          )).find('bill', bill)!;
          expect(moved.scopeId, target);
          expect(moved.revision, '2');
          expect(moved.payload['category_id'], targetCategory);
          expect(moved.payload['tag_ids'], [targetTag]);
          expect(moved.payload['occurred_at'], _time);
          expect(moved.payload['business_timezone'], 'Asia/Shanghai');
          await _balance(client, account, '9875');
          await _expense(client, source, '0');
          await _expense(client, target, '125');
        }
        final viewerView = await viewer.ledger.read(viewer.space);
        expect(viewerView.bills.where((row) => row.id == bill), isEmpty);
        final sourceTomb = viewerView.find('bill', bill)!;
        expect(sourceTomb.deleted, isTrue);
        expect(sourceTomb.scopeId, source);
        expect(sourceTomb.revision, '2');
        expect(sourceTomb.payload['note'], '');
        expect(sourceTomb.payload['attachment_ids'], isEmpty);
        await expectLater(
          viewer.request('GET', '/sync/entities/bill/$bill?scope_id=$target'),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
        );
        final sourceReport = await actor.request(
          'GET',
          '/books/$source/report?start_date=2026-10-01&end_date_exclusive=2026-11-01',
        );
        final targetReport = await actor.request(
          'GET',
          '/books/$target/report?start_date=2026-10-01&end_date_exclusive=2026-11-01',
        );
        final sourceProjection = sourceReport['report'] as Map;
        final targetProjection = targetReport['report'] as Map;
        expect(sourceProjection['available'], isTrue);
        expect(targetProjection['available'], isTrue);
        expect((sourceProjection['totals'] as Map)['expense_minor'], '0');
        expect((targetProjection['totals'] as Map)['expense_minor'], '125');
        for (var index = 0; index < clones.length; index++) {
          final remote = await actor.transfer.downloadOriginal(
            attachmentLease,
            target,
            clones[index],
          );
          final original = base64Decode(
            ((config['images'] as List)[index] as Map)['base64'] as String,
          );
          expect(remote, original);
        }

        // Prepare another real source bill, then revoke source membership. A
        // fresh centralized permission check must clear controlled cache before
        // confirmation, without destroying local originals or the user's draft.
        final blockedBill = _uuid.v4();
        await actor.ledger.save(
          actor.space,
          entityType: 'bill',
          scopeId: source,
          entityId: blockedBill,
          payload: {
            ...full,
            'money': _money('25'),
            'fee': null,
            'attachment_ids': [originals.first],
            'note': '合成撤权前准备的账单',
          },
        );
        await actor.sync();
        final blockedPreview = await actor.mover.preview(
          attachmentLease,
          ids: [blockedBill],
          targetBookId: target,
          mappings: {
            blockedBill: BillBookMoveMapping(
              categoryId: null,
              tagIds: [],
              feeCategoryId: null,
            ),
          },
        );
        final blockedPrepared = await actor.mover.prepare(
          attachmentLease,
          blockedPreview,
        );
        final draftId = await actor.local.saveDraft(actor.space, '撤权时仍保留的本机输入');
        final sourceRecord = (await actor.attachments.get(
          actor.space,
          originals.first,
        ))!;
        final imageBytes = await actor.transfer.downloadOriginal(
          attachmentLease,
          source,
          originals.first,
        );
        final cacheKey = attachmentBlobKey(
          actor.space.id,
          attachmentLease.epoch,
          source,
          originals.first,
          'remote-original-${sourceRecord.sha256}',
        );
        expect(await actor.bytes.read(cacheKey), imageBytes);
        final idsBefore =
            (await actor.database
                    .select(actor.database.pendingOperations)
                    .get())
                .map((row) => row.operationId)
                .toSet();
        await owner.request(
          'DELETE',
          '/books/$source/members/${actor.space.userId}',
        );
        await expectLater(
          actor.mover.confirm(attachmentLease, blockedPrepared),
          throwsA(isA<LedgerBookMoveException>()),
        );
        expect(
          (await actor.database.select(actor.database.pendingOperations).get())
              .map((row) => row.operationId)
              .toSet(),
          idsBefore,
        );
        expect(
          (await actor.ledger.read(actor.space)).find('bill', blockedBill),
          isNull,
        );
        expect(
          (await actor.ledger.read(actor.space)).find('bill', bill)!.scopeId,
          target,
        );
        expect(await actor.bytes.read(cacheKey), isNull);
        expect(
          await actor.attachments.original(actor.space, sourceRecord),
          imageBytes,
        );
        expect(
          (await actor.local.drafts(
            actor.space,
          )).singleWhere((row) => row.id == draftId).body,
          '撤权时仍保留的本机输入',
        );
        await _balance(actor, account, '9850');

        await File(config['receipt'] as String).writeAsString(
          jsonEncode({
            'passed': true,
            'bill_id': bill,
            'blocked_bill_id': blockedBill,
            'account_id': account,
            'source_book_id': source,
            'target_book_id': target,
            'operation_id': operationId,
            'source_attachment_ids': originals,
            'target_attachment_ids': clones,
            'final_balance_minor': '9850',
            'checks': [
              'ready_target_clones',
              'explicit_target_mapping',
              'same_uuid',
              'same_plan_confirm_idempotency',
              'pending_balance_preserved',
              'pending_report_explicitly_unavailable',
              'lost_reply_frozen_retry',
              'two_independent_file_sqlite_clients',
              'source_only_viewer_isolation',
              'source_and_target_reports',
              'exact_timestamp_and_timezone',
              'fresh_revocation_blocks_confirm',
              'controlled_cache_removed',
              'local_original_and_draft_preserved',
            ],
          }),
        );
      } finally {
        await Future.wait(opened.reversed.map((client) => client.close()));
      }
    },
    skip: file == null
        ? 'Set FLOWTRACE_BOOK_MOVE_QA_FILE using the dedicated 18084 harness'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
