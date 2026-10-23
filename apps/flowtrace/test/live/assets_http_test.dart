import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:flowtrace/core/config/data_space.dart';
import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/assets/asset_config_repository.dart';
import 'package:flowtrace/data/assets/asset_config_store.dart';
import 'package:flowtrace/data/assets/asset_read_repository.dart';
import 'package:flowtrace/data/assets/asset_repository.dart';
import 'package:flowtrace/data/attachments/attachment_repository.dart';
import 'package:flowtrace/data/attachments/attachment_transfer.dart';
import 'package:flowtrace/data/attachments/byte_store_native.dart';
import 'package:flowtrace/data/ledger/ledger_repository.dart';
import 'package:flowtrace/data/local/app_database.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/domain/assets/asset_config.dart';
import 'package:flowtrace/features/attachments/attachment_models.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';

import '../identity/identity_controller_test.dart' show MemoryVault;

const _uuid = Uuid();
Map<String, Object?> _money(String minor, [String code = 'CNY']) => {
  'currency': code,
  'currency_scale': 2,
  'amount_minor': minor,
};

final class _DropCommittedGroup extends http.BaseClient {
  final inner = http.Client();
  String? groupId;
  bool drop = false;
  final bodies = <String, List<String>>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var selected = false;
    if (request.method == 'POST' &&
        request.url.path.endsWith('/assets/groups') &&
        request is http.Request) {
      final raw = utf8.decode(request.bodyBytes);
      final body = jsonDecode(raw) as Map;
      selected = (body['group'] as Map)['id'] == groupId;
      if (selected) bodies.putIfAbsent(groupId!, () => []).add(raw);
    }
    final response = await inner.send(request);
    if (selected && drop && response.statusCode == 200) {
      drop = false;
      await response.stream.drain<void>();
      throw const SocketException(
        'Synthetic committed asset-config response loss',
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
      deviceName: 'synthetic-assets-http',
    );
    store = SyncStore(local);
    bytes = NativeAttachmentBytes(Directory(p.join(directory.path, 'bytes')));
    attachments = AttachmentRepository(local, bytes);
    transfer = AttachmentTransfer(attachments);
    engine = SyncEngine(store, onScopeRevoked: attachments.revokeScope);
    ledger = LedgerRepository(local);
    configStore = AssetConfigStore(local);
    config = AssetConfigRepository(
      configStore,
      refreshPermissions: (lease) async {
        await engine.refreshScopes(lease);
      },
    );
    reads = AssetReadRepository(
      local,
      refreshPermissions: (lease) async {
        await engine.refreshScopes(lease);
      },
    );
  }
  final http.Client transport;
  late final AppDatabase database;
  late final LocalRepository local;
  late final IdentityController identity;
  late final SyncStore store;
  late final SyncEngine engine;
  late final LedgerRepository ledger;
  late final AssetConfigStore configStore;
  late final AssetConfigRepository config;
  late final AssetReadRepository reads;
  late final NativeAttachmentBytes bytes;
  late final AttachmentRepository attachments;
  late final AttachmentTransfer transfer;
  DataSpace get space => identity.accountSpace!;
  SyncLease get lease => SyncLease.capture(identity);
  static Future<_Client> login(
    Map<String, Object?> fixture,
    String role, {
    http.Client? transport,
  }) async {
    final directory = Directory(
      p.join(fixture['run_directory'] as String, role),
    );
    await directory.create(recursive: true);
    final client = _Client(directory, transport ?? http.Client());
    try {
      final account = (fixture['accounts'] as Map)[role] as Map;
      await client.identity.configure(
        ServerAddress.parse(fixture['server'] as String),
      );
      await client.identity.signIn(
        username: account['username'] as String,
        password: account['password'] as String,
      );
      expect(client.space.serverInstanceId, fixture['instance_id']);
      expect(client.identity.serverIdentity!.syncEpoch, fixture['sync_epoch']);
      expect(client.space.userId, account['id']);
      await client.local.registerSpace(client.space);
      await client.sync();
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<void> sync() => engine.synchronize(lease);
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) => identity.authorizedRequest(method, path, body: body);
  Future<void> refreshConfig() async {
    for (final section in AssetConfigSection.values) {
      await config.refresh(lease, section);
    }
  }

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

Future<void> _save(
  _Client client,
  String type,
  String scope,
  String id,
  Map<String, Object?> body, {
  String? revision,
}) => client.ledger
    .save(
      client.space,
      entityType: type,
      scopeId: scope,
      entityId: id,
      payload: body,
      baseRevision: revision,
    )
    .then((_) {});

Map<String, Object?> _account(
  String kind,
  String amount, {
  String currency = 'CNY',
  String? groupId,
  Map<String, Object?>? credit,
}) => {
  'name': '合成P4资产',
  'kind': kind,
  'opening': _money(amount, currency),
  'include_in_net_assets': true,
  'hidden': false,
  'opening_date': '2026-01-01',
  'group_id': groupId,
  'credit': credit,
};
Map<String, Object?> _bill(
  String book,
  String kind,
  String amount, {
  String day = '2026-10-21',
  Map<String, Object?> extra = const {},
}) => {
  'book_id': book,
  'bill_type': kind,
  'money': _money(amount),
  'business_date': day,
  'business_timezone': 'Asia/Shanghai',
  ...extra,
};

void main() {
  final file = Platform.environment['FLOWTRACE_ASSETS_QA_FILE'];
  test(
    'real assets configuration frozen retries exact FX typed reads and revocation',
    () async {
      final fixture = (jsonDecode(await File(file!).readAsString()) as Map)
          .cast<String, Object?>();
      final server = Uri.parse(fixture['server'] as String);
      final run = Directory(fixture['run_directory'] as String).absolute;
      if (server.host != '127.0.0.1' ||
          server.port != 18085 ||
          fixture['database'] != 'flowtrace_test_assets_local' ||
          !run.path
              .replaceAll('\\', '/')
              .contains('/work/flowtrace-assets/live/') ||
          File(file).absolute.parent.path != run.path) {
        throw StateError('Dedicated synthetic assets harness required');
      }
      final opened = <_Client>[];
      final drop = _DropCommittedGroup();
      final checks = <String>[];
      try {
        final owner = await _Client.login(fixture, 'owner');
        opened.add(owner);
        final actor = await _Client.login(fixture, 'actor', transport: drop);
        opened.add(actor);
        final book =
            ((fixture['accounts'] as Map)['actor'] as Map)['book_id'] as String;
        await actor.refreshConfig();
        final groupId = _uuid.v4();
        drop.groupId = groupId;
        drop.drop = true;
        await expectLater(
          actor.config.createGroup(
            actor.lease,
            name: '合成丢回复组',
            groupId: groupId,
          ),
          throwsA(isA<ApiFailure>()),
        );
        final lost = (await actor.config.operations(actor.space)).single;
        expect(lost.state, 'retry');
        expect(
          await actor.configStore.readSection(
            actor.space,
            AssetConfigSection.groups,
          ),
          isNotNull,
        );
        await expectLater(
          actor.configStore.requireConfirmedGroup(actor.space, groupId),
          throwsA(isA<DomainError>()),
        );
        final retried = await actor.config.retry(actor.lease, lost.id);
        expect(retried.state, 'applied');
        expect(drop.bodies[groupId], [lost.bodyJson, lost.bodyJson]);
        await actor.configStore.requireConfirmedGroup(actor.space, groupId);
        final firstGroup = (await actor.configStore.readSection(
          actor.space,
          AssetConfigSection.groups,
        ))!.groups.single;
        await actor.config.updateGroup(
          actor.lease,
          firstGroup,
          name: '确认后的分组',
          sortOrder: 7,
        );
        checks.add('frozen_post_reply_loss_same_bytes_one_operation');
        final bank = _uuid.v4(), eur = _uuid.v4(), card = _uuid.v4();
        await _save(
          actor,
          'account',
          actor.space.userId,
          bank,
          _account('bank', '100000', groupId: groupId),
        );
        await _save(
          actor,
          'account',
          actor.space.userId,
          eur,
          _account('investment', '0', currency: 'EUR'),
        );
        await _save(
          actor,
          'account',
          actor.space.userId,
          card,
          _account(
            'credit_card',
            '-10000',
            credit: {
              'limit': _money('20000'),
              'statement_day': 15,
              'statement_day_inclusive': true,
              'due_mode': 'fixed_day',
              'due_day': 5,
              'due_days': null,
            },
          ),
        );
        final pending = await actor.local.pending(actor.space);
        final accountCommand =
            (jsonDecode(
                  pending
                      .singleWhere(
                        (op) =>
                            (jsonDecode(op.operationJson)
                                as Map)['entity_id'] ==
                            bank,
                      )
                      .operationJson,
                )
                as Map);
        expect(accountCommand['depends_on'], isNull);
        await actor.sync();
        await expectLater(
          actor.config.deleteGroup(actor.lease, groupId),
          throwsA(isA<DomainError>()),
        );
        checks.add(
          'rest_group_confirmed_before_account_sync_no_group_dependency',
        );
        await actor.config.savePreferences(
          actor.lease,
          CurrencyPreferences(
            baseCurrency: 'CNY',
            enabledCodes: ['CNY', 'EUR'],
            valuationPolicy: 'latest_on_or_before',
          ),
        );
        final oldRate = _uuid.v4();
        await actor.config.createRate(
          actor.lease,
          AssetRate(
            id: oldRate,
            fromCurrency: 'EUR',
            toCurrency: 'CNY',
            effectiveDate: '2026-10-21',
            rate: '8.000000000000000001',
            source: 'manual',
            revision: '0',
          ),
        );
        final transferId = _uuid.v4(),
            expenseId = _uuid.v4(),
            repayId = _uuid.v4();
        final transfer = _bill(
          book,
          'transfer',
          '10000',
          extra: {
            'from_account_id': bank,
            'to_account_id': eur,
            'target_money': _money('1250', 'EUR'),
            'transfer_fx': {
              'rate': '0.125',
              'rate_date': '2026-10-21',
              'rate_source': 'manual',
            },
            'fee': {
              'money': _money('25'),
              'account_id': bank,
              'category_id': null,
              'flags': {
                'exclude_from_statistics': false,
                'exclude_from_budget': false,
              },
              'reporting': null,
            },
            'note': '合成原币与冻结FX',
          },
        );
        await _save(actor, 'bill', book, transferId, transfer);
        await _save(
          actor,
          'bill',
          book,
          expenseId,
          _bill(
            book,
            'expense',
            '3000',
            day: '2026-10-10',
            extra: {'account_id': card},
          ),
        );
        await _save(
          actor,
          'bill',
          book,
          repayId,
          _bill(
            book,
            'credit_repayment',
            '5000',
            day: '2026-10-20',
            extra: {'from_account_id': bank, 'to_account_id': card},
          ),
        );
        await actor.sync();
        final shared = _uuid.v4();
        await owner.request(
          'POST',
          '/books',
          body: {'id': shared, 'name': '合成撤权资产明细'},
        );
        final invitation = await owner.request(
          'POST',
          '/books/$shared/invites',
          body: {'role': 'editor', 'days': 1},
        );
        await actor.request(
          'POST',
          '/books/join',
          body: {'token': invitation['token']},
        );
        await actor.sync();
        final image = fixture['image'] as Map;
        final imageBytes = base64Decode(image['base64'] as String);
        expect(sha256.convert(imageBytes).toString(), image['sha256']);
        final original = await actor.attachments.stage(
          actor.space,
          actor.lease.epoch,
          shared,
          imageBytes,
          mediaType: 'image/png',
        );
        await actor.transfer.upload(
          AttachmentLease.capture(actor.identity),
          original.id,
        );
        final sharedBill = _uuid.v4();
        await _save(
          actor,
          'bill',
          shared,
          sharedBill,
          _bill(
            shared,
            'expense',
            '125',
            extra: {
              'account_id': bank,
              'note': '失权后必须消失的共享正文',
              'attachment_ids': [original.id],
            },
          ),
        );
        await actor.sync();
        await actor.transfer.downloadOriginal(
          AttachmentLease.capture(actor.identity),
          shared,
          original.id,
        );
        final cacheKey = attachmentBlobKey(
          actor.space.id,
          actor.lease.epoch,
          shared,
          original.id,
          'remote-original-${original.sha256}',
        );
        expect(await actor.bytes.read(cacheKey), imageBytes);
        await actor.refreshConfig();
        final entriesQuery = AssetReadQuery.entries(
          scopeId: actor.space.userId,
          accountId: bank,
          startDate: '2026-10-01',
          endDateExclusive: '2026-11-01',
        );
        final historyQuery = AssetReadQuery.history(
          scopeId: actor.space.userId,
          startDate: '2026-10-21',
          endDateExclusive: '2026-10-23',
          baseCurrency: 'CNY',
          valuationPolicy: 'latest_on_or_before',
        );
        final creditQuery = AssetReadQuery.creditCalendar(
          scopeId: actor.space.userId,
          accountId: card,
          startDate: '2026-10-01',
          endDateExclusive: '2026-11-01',
        );
        final typedEntries =
            (await actor.reads.fetch(actor.lease, entriesQuery)).data
                as AssetAccountEntries;
        expect(typedEntries.totalCount, 4);
        expect(typedEntries.closingBalance!.minor.toString(), '84850');
        expect(
          typedEntries.entries.singleWhere((e) => e.billId == sharedBill).note,
          '失权后必须消失的共享正文',
        );
        final history =
            (await actor.reads.fetch(actor.lease, historyQuery)).data
                as AssetHistory;
        expect(history.points.map((p) => p.totals!.net.minor.toString()), [
          '86850',
          '86850',
        ]);
        final creditRead =
            (await actor.reads.fetch(actor.lease, creditQuery)).data
                as AssetCreditCalendar;
        expect(creditRead.totalDebt.minor.toString(), '8000');
        expect(creditRead.openingCarry!.minor.toString(), '5000');
        expect(creditRead.cycles.single.statementDue!.minor.toString(), '3000');
        expect(creditRead.cycles.single.remainingDue!.minor.toString(), '3000');
        checks.add('typed_private_entries_history_and_credit_fifo');
        final frozen = await actor.request(
          'GET',
          '/sync/entities/bill/$transferId?scope_id=$book',
        );
        await actor.config.deleteRate(actor.lease, oldRate);
        final newRate = _uuid.v4();
        await actor.config.createRate(
          actor.lease,
          AssetRate(
            id: newRate,
            fromCurrency: 'EUR',
            toCurrency: 'CNY',
            effectiveDate: '2026-10-21',
            rate: '9',
            source: 'manual',
            revision: '0',
          ),
        );
        await actor.refreshConfig();
        final valued = await AssetRepository(
          actor.ledger,
          actor.configStore,
        ).read(actor.space, valuationDate: '2026-10-21');
        expect(valued.configurationConfirmed, isTrue);
        expect(valued.totals.available, isTrue);
        expect(valued.totals.net!.minor.toString(), '88100');
        expect(
          await actor.request(
            'GET',
            '/sync/entities/bill/$transferId?scope_id=$book',
          ),
          frozen,
        );
        final changedHistory =
            (await actor.reads.fetch(actor.lease, historyQuery)).data
                as AssetHistory;
        expect(
          changedHistory.points.first.totals!.net.minor.toString(),
          '88100',
        );
        await actor.reads.fetch(actor.lease, entriesQuery);
        expect(await actor.reads.cached(actor.space, entriesQuery), isNotNull);
        checks.add(
          'valuation_change_preserves_original_money_target_money_and_frozen_fx',
        );
        final heldGroup = _uuid.v4();
        drop.groupId = heldGroup;
        drop.drop = true;
        await expectLater(
          actor.config.createGroup(
            actor.lease,
            name: '撤权时保留配置意图',
            groupId: heldGroup,
          ),
          throwsA(isA<ApiFailure>()),
        );
        final held = (await actor.config.operations(
          actor.space,
        )).singleWhere((op) => op.pending);
        final draftId = await actor.ledger.saveDraft(
          actor.space,
          bookId: shared,
          payload: {
            'note': '撤权后保留的未发送输入',
            'attachment_ids': [original.id],
          },
        );
        final beforeNonce =
            await actor.local.readSetting(
              AssetReadRepository.invalidationKey(actor.space),
            ) ??
            '0';
        await owner.request(
          'DELETE',
          '/books/$shared/members/${actor.space.userId}',
        );
        await actor.engine.refreshScopes(actor.lease);
        final afterNonce =
            await actor.local.readSetting(
              AssetReadRepository.invalidationKey(actor.space),
            ) ??
            '0';
        expect(
          BigInt.parse(afterNonce),
          greaterThan(BigInt.parse(beforeNonce)),
        );
        final controlled =
            await (actor.database.select(actor.database.appSettings)..where(
                  (r) => r.key.like(
                    '${AssetReadRepository.cachePrefix(actor.space)}%',
                  ),
                ))
                .get();
        expect(controlled, isEmpty);
        expect(await actor.reads.cached(actor.space, entriesQuery), isNull);
        expect(await actor.bytes.read(cacheKey), isNull);
        expect(
          await actor.attachments.original(actor.space, original),
          imageBytes,
        );
        final kept = (await actor.config.operations(
          actor.space,
        )).singleWhere((op) => op.id == held.id);
        expect(kept.bodyJson, held.bodyJson);
        expect(kept.state, 'retry');
        expect(
          (await actor.ledger.readDraft(actor.space, draftId))!.payload['note'],
          '撤权后保留的未发送输入',
        );
        final redacted =
            (await actor.reads.fetch(actor.lease, entriesQuery)).data
                as AssetAccountEntries;
        final redactedShared = redacted.entries.singleWhere(
          (e) => e.money.minor.toString() == '-125',
        );
        expect(redactedShared.detailAvailable, isFalse);
        expect(redactedShared.billId, isNull);
        expect(redactedShared.bookId, isNull);
        expect(redactedShared.note, isNull);
        expect(redactedShared.attachmentIds, isEmpty);
        checks.add(
          'fresh_revocation_invalidates_read_cache_nonce_and_downloads_keeps_local_intent',
        );
        // Explicit new grant allows financial cleanup; an old invitation is never reused.
        await actor.config.retry(actor.lease, held.id);
        expect(drop.bodies[heldGroup], [held.bodyJson, held.bodyJson]);
        final again = await owner.request(
          'POST',
          '/books/$shared/invites',
          body: {'role': 'editor', 'days': 1},
        );
        await actor.request(
          'POST',
          '/books/join',
          body: {'token': again['token']},
        );
        await actor.sync();
        for (final id in [sharedBill, repayId, expenseId, transferId]) {
          final item = (await actor.ledger.read(actor.space)).find('bill', id)!;
          await actor.ledger.delete(actor.space, item);
          await actor.sync();
        }
        final reset = (await actor.ledger.read(actor.space)).balances;
        expect(reset[bank]!.value!.minor.toString(), '100000');
        expect(reset[eur]!.value!.minor.toString(), '0');
        expect(reset[card]!.value!.minor.toString(), '-10000');
        for (final id in [bank, eur, card]) {
          await actor.ledger.delete(
            actor.space,
            (await actor.ledger.read(actor.space)).find('account', id)!,
          );
          await actor.sync();
        }
        await actor.config.deleteGroup(actor.lease, heldGroup);
        await actor.config.deleteGroup(actor.lease, groupId);
        await actor.config.deleteRate(actor.lease, newRate);
        await actor.config.savePreferences(
          actor.lease,
          CurrencyPreferences(baseCurrency: 'CNY', enabledCodes: ['CNY']),
        );
        await owner.sync();
        await owner.ledger.delete(
          owner.space,
          (await owner.ledger.read(owner.space)).find('book', shared)!,
        );
        await owner.sync();
        checks.add(
          'normal_tombstones_config_cleanup_and_exact_balance_restoration',
        );
        await File(fixture['receipt'] as String).writeAsString(
          jsonEncode({
            'passed': true,
            'date': '2026-10-22',
            'checks': checks,
            'actor_id': actor.space.userId,
            'group_id': groupId,
            'held_group_id': heldGroup,
            'lost_operation_id': lost.id,
            'held_operation_id': held.id,
            'transfer_id': transferId,
            'expense_id': expenseId,
            'repayment_id': repayId,
            'shared_bill_id': sharedBill,
            'shared_book_id': shared,
            'bank_id': bank,
            'eur_id': eur,
            'card_id': card,
            'attachment_id': original.id,
            'nonce_before': beforeNonce,
            'nonce_after': afterNonce,
            'initial_net_minor': '86850',
            'revalued_net_minor': '88100',
            'restored_balances': {
              'bank': '100000',
              'eur': '0',
              'credit_card': '-10000',
            },
          }),
        );
      } finally {
        await Future.wait(opened.reversed.map((client) => client.close()));
      }
    },
    skip: file == null
        ? 'Set FLOWTRACE_ASSETS_QA_FILE using the dedicated 18085 assets harness'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
