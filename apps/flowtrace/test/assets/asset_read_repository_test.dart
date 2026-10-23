import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flowtrace/core/money/money.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/assets/asset_config_repository.dart';
import 'package:flowtrace/data/assets/asset_config_store.dart';
import 'package:flowtrace/data/assets/asset_read_repository.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/domain/assets/asset_config.dart';

import '../ledger/query_fixtures.dart';
import 'asset_read_fixtures.dart';

void main() {
  late AssetReadFixture f;
  setUp(() async {
    f = AssetReadFixture();
    await f.open();
  });
  tearDown(() => f.close());
  Matcher code(String value) =>
      throwsA(isA<DomainError>().having((e) => e.code, 'code', value));
  Future<List<String>> cache() async =>
      (await f.data.db.select(f.data.db.appSettings).get())
          .where(
            (row) => row.key.startsWith(
              AssetReadRepository.cachePrefix(f.data.space),
            ),
          )
          .map((row) => row.value)
          .toList();

  test(
    'authorized exact entry page separates public detail from redacted private postings',
    () async {
      f.request = (method, path, {body, bodyJson}) async {
        expect(method, 'GET');
        expect(
          path,
          '/assets/accounts/$qCash/entries?start_date=2026-10-01&end_date_exclusive=2026-11-01&offset=0&limit=100',
        );
        expect(body, isNull);
        expect(bodyJson, isNull);
        return f.entriesBody();
      };
      final result = await f.reads.fetch(f.lease, f.entriesQuery);
      final entries = result.data as AssetAccountEntries;
      expect(entries.entries.map((row) => row.money.minor.toString()), [
        '-1',
        '-124',
      ]);
      expect(entries.entries.last.detailAvailable, isFalse);
      expect(entries.entries.last.bookId, isNull);
      expect(entries.entries.last.note, isNull);
      expect(entries.closingBalance!.display(), '98.75');
      expect(entries.hasNext, isFalse);
      final cached = (await f.reads.cached(f.data.space, f.entriesQuery))!;
      expect(cached.fromCache, isTrue);
      expect(cached.evidence, result.evidence);
      expect(f.requests, 1);
      expect(f.authorizations, 1);
      expect(
        await f.data.db.select(f.data.db.pendingOperations).get(),
        isEmpty,
      );
    },
  );

  test(
    'malformed or identity-mismatched reads cannot populate any cache',
    () async {
      final valid = f.entriesBody();
      final malformed = <Map<String, Object?>>[
        {...valid, 'instance_id': qid(999)},
        {...valid, 'sync_epoch': qid(999)},
        {...valid, 'scope_id': qBook},
        {...valid, 'account_id': qBank},
        {...valid, 'unknown': true},
        {...valid, 'entries': <Object?>[]},
        {...valid, 'total_count': 3},
        {...valid, 'currency_scale': 0},
        {...valid, 'closing_balance': qmoney('9876')},
        {
          ...valid,
          'entries': [
            f.entry(),
            {
              ...f.entry(number: 1, visible: false, amount: '-124'),
              'note': '失权正文不能泄漏',
            },
          ],
        },
        {
          ...valid,
          'entries': [
            f.entry(),
            {
              ...f.entry(number: 1, visible: false, amount: '-124'),
              'attachment_ids': [qid(500)],
            },
          ],
        },
        {
          ...valid,
          'entries': [
            {...f.entry(), 'note': 5},
            f.entry(number: 1, visible: false, amount: '-124'),
          ],
        },
        {
          ...valid,
          'entries': [
            {...f.entry(), 'book_id': qid(888)},
            f.entry(number: 1, visible: false, amount: '-124'),
          ],
        },
      ];
      for (final body in malformed) {
        // Capture each immutable candidate; request body must remain absent.
        final bodyForResponse = body;
        f.request = (method, path, {body, bodyJson}) async => bodyForResponse;
        await expectLater(
          f.reads.fetch(f.lease, f.entriesQuery),
          throwsA(isA<DomainError>()),
        );
        expect(await cache(), isEmpty);
      }
    },
  );

  test(
    'confirmed server cut can be newer than local, but cached reads wait for an exact cut',
    () async {
      f.request = (method, path, {body, bodyJson}) async =>
          f.entriesBody(revision: '6', config: '7');
      final online = await f.reads.fetch(f.lease, f.entriesQuery);
      expect(online.data.envelope.scopeRevision, '6');
      expect(await f.reads.cached(f.data.space, f.entriesQuery), isNull);
      await f.cursors('6');
      expect(await f.reads.cached(f.data.space, f.entriesQuery), isNull);
      await AssetConfigStore(f.data.local).acceptSection(
        f.lease,
        AssetConfigSectionSnapshot.fromJson(AssetConfigSection.groups, {
          'instance_id': f.data.space.serverInstanceId,
          'sync_epoch': qEpoch,
          'revision': '7',
          'groups': <Object?>[],
        }),
      );
      expect(await f.reads.cached(f.data.space, f.entriesQuery), isNotNull);
      f.request = (method, path, {body, bodyJson}) async =>
          f.entriesBody(revision: '5', config: '7');
      await expectLater(
        f.reads.fetch(f.lease, f.entriesQuery),
        code('assets.stale_response'),
      );
      f.request = (method, path, {body, bodyJson}) async =>
          f.entriesBody(revision: '6', config: '6');
      await expectLater(
        f.reads.fetch(f.lease, f.entriesQuery),
        code('assets.stale_response'),
      );
      expect((await cache()).single, contains('"scope_revision":"6"'));
    },
  );

  test(
    'revoke followed by regrant during GET rejects the late response through durable nonce',
    () async {
      await f.reads.fetch(f.lease, f.entriesQuery);
      f.request = (method, path, {body, bodyJson}) async {
        await f.data.sync.revokeScope(f.data.space, qBook);
        await f.data.sync.restoreScopeAccess(f.data.space, {
          qUser,
          qBook,
          qOtherBook,
        });
        return f.entriesBody();
      };
      await expectLater(
        f.reads.fetch(f.lease, f.entriesQuery),
        code('assets.evidence_changed'),
      );
      expect(
        await f.data.local.readSetting(
          AssetReadRepository.invalidationKey(f.data.space),
        ),
        '1',
      );
      expect(await cache(), isEmpty);
    },
  );

  test(
    'same scope data cannot cross a login lease or a configuration permission change',
    () async {
      f.request = (method, path, {body, bodyJson}) async {
        f.current = false;
        return f.entriesBody();
      };
      await expectLater(
        f.reads.fetch(f.lease, f.entriesQuery),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'identity_changed'),
        ),
      );
      expect(await cache(), isEmpty);
      f.current = true;
      f.request = (method, path, {body, bodyJson}) async {
        await f.data.local.writeSetting(
          'sync.scopes.${f.data.space.id}',
          jsonEncode({qUser: '1', qBook: '2', qOtherBook: '1'}),
        );
        return f.entriesBody();
      };
      await expectLater(
        f.reads.fetch(f.lease, f.entriesQuery),
        code('assets.evidence_changed'),
      );
      expect(await cache(), isEmpty);
    },
  );

  test(
    'local unconfirmed ledger or REST intent disables offline confirmation without hiding the online server cut',
    () async {
      await f.reads.fetch(f.lease, f.entriesQuery);
      await f.data.local.saveEntityAndQueue(
        f.data.space,
        QueuedCommand(
          operationId: qid(701),
          scopeId: qBook,
          entityType: 'tag',
          entityId: qid(702),
          action: 'create',
          baseRevision: '0',
          payload: {'name': '待同步'},
        ),
      );
      expect(await f.reads.cached(f.data.space, f.entriesQuery), isNull);
      final online = await f.reads.fetch(f.lease, f.entriesQuery);
      expect(online.fromCache, isFalse);
      expect(
        (online.data as AssetAccountEntries).closingBalance!.display(),
        '98.75',
      );
      await f.data.db.delete(f.data.db.pendingOperations).go();
      expect(await f.reads.cached(f.data.space, f.entriesQuery), isNotNull);
      f.request = (method, path, {body, bodyJson}) async =>
          throw const ApiFailure(
            'network_unavailable',
            'offline',
            offline: true,
          );
      await expectLater(
        AssetConfigRepository(
          AssetConfigStore(f.data.local),
          refreshPermissions: (_) async {},
        ).createGroup(f.lease, name: '待重试的真实配置命令'),
        throwsA(isA<ApiFailure>()),
      );
      expect(await f.reads.cached(f.data.space, f.entriesQuery), isNull);
    },
  );

  test(
    'restore-required response backs up controlled asset reads before disabling them',
    () async {
      await f.reads.fetch(f.lease, f.entriesQuery);
      final before = await cache();
      f.request = (method, path, {body, bodyJson}) async =>
          throw const ApiFailure('epoch_changed', 'restored', status: 409);
      await expectLater(
        f.reads.fetch(f.lease, f.entriesQuery),
        throwsA(isA<ApiFailure>()),
      );
      final backup =
          (await f.data.db.select(f.data.db.syncRecoveryBackups).get()).single;
      final saved = jsonDecode(backup.dataJson) as Map;
      final readCache = saved['asset_read_cache'] as List;
      expect(readCache.map((row) => row['value']), before);
      expect(
        (await f.data.sync.state(f.data.space))!.status,
        'recovery_required',
      );
      await expectLater(
        f.reads.cached(f.data.space, f.entriesQuery),
        code('assets.read_only'),
      );
    },
  );

  test(
    'history preserves greater than 2^53 values and missing days, rejecting truncated curves and false totals',
    () async {
      f.request = (method, path, {body, bodyJson}) async => f.historyBody();
      final history =
          (await f.reads.fetch(f.lease, f.historyQuery)).data as AssetHistory;
      expect(
        history.points.first.totals!.net.minor.toString(),
        '9007199254740993',
      );
      expect(
        history.points.last.totals!.net.minor.toString(),
        '9007199254740992',
      );
      expect(history.points[15].totals, isNull);
      expect(history.points[15].issues, ['asset.opening_date_required']);
      for (final change in ['truncated', 'partial_total', 'wrong_date']) {
        final candidate = f.historyBody(),
            points = (f.historyBody()['points'] as List)
                .cast<Map<String, Object?>>();
        if (change == 'truncated') {
          points.removeLast();
        }
        if (change == 'partial_total') {
          points[15] = {...points[15], 'totals': f.totals('0')};
        }
        if (change == 'wrong_date') {
          points[1] = {...points[1], 'date': '2026-10-01'};
        }
        candidate['points'] = points;
        f.request = (method, path, {body, bodyJson}) async => candidate;
        await expectLater(
          f.reads.fetch(f.lease, f.historyQuery),
          throwsA(isA<DomainError>()),
        );
      }
    },
  );

  test(
    'credit cycle distinguishes consumed, statement due and remaining due with exact calendar days',
    () async {
      f.request = (method, path, {body, bodyJson}) async => f.creditBody();
      final calendar =
          (await f.reads.fetch(f.lease, f.creditQuery)).data
              as AssetCreditCalendar;
      expect(calendar.totalDebt.display(), '50.00');
      expect(calendar.cycles.single.charges.display(), '50.00');
      expect(calendar.cycles.single.dueDate, '2026-11-10');
      expect(calendar.cycles.single.minInterestFreeDays, 10);
      expect(calendar.cycles.single.maxInterestFreeDays, 40);
      final incomplete = f.creditBody()
        ..['repayment_available'] = false
        ..['opening_carry_minor'] = null
        ..['issues'] = ['asset.opening_date_required'];
      incomplete['cycles'] = [
        {
          ...(f.creditBody()['cycles'] as List).single as Map<String, Object?>,
          'statement_due_minor': null,
          'remaining_due_minor': null,
        },
      ];
      f.request = (method, path, {body, bodyJson}) async => incomplete;
      final unknown =
          (await f.reads.fetch(f.lease, f.creditQuery)).data
              as AssetCreditCalendar;
      expect(unknown.totalDebt.display(), '50.00');
      expect(unknown.cycles.single.statementDue, isNull);
      expect(unknown.cycles.single.remainingDue, isNull);
    },
  );

  test(
    'pagination validates the exact requested window and never accepts an empty intermediate page',
    () async {
      final query = AssetReadQuery.entries(
        scopeId: qUser,
        accountId: qCash,
        startDate: '2026-10-01',
        endDateExclusive: '2026-11-01',
        offset: 1,
        limit: 1,
      );
      f.request = (method, path, {body, bodyJson}) async =>
          f.entriesBody(offset: 1, limit: 1);
      final page =
          (await f.reads.fetch(f.lease, query)).data as AssetAccountEntries;
      expect(page.entries.single.id, qid(901));
      expect(page.hasNext, isFalse);
      f.request = (method, path, {body, bodyJson}) async => {
        ...f.entriesBody(offset: 1, limit: 1),
        'entries': <Object?>[],
      };
      await expectLater(
        f.reads.fetch(f.lease, query),
        code('assets.invalid_data'),
      );
      expect(
        () => AssetReadQuery.history(
          scopeId: qUser,
          startDate: '2026-01-01',
          endDateExclusive: '2028-01-01',
        ),
        throwsA(isA<DomainError>()),
      );
    },
  );
}
