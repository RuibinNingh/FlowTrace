import 'dart:convert';
import 'dart:io';

import 'package:flowtrace/core/config/server_address.dart';
import 'package:flowtrace/core/network/api_client.dart';
import 'package:flowtrace/core/network/api_failure.dart';
import 'package:flowtrace/data/attachments/attachment_repository.dart';
import 'package:flowtrace/data/attachments/attachment_transfer.dart';
import 'package:flowtrace/data/local/local_repository.dart';
import 'package:flowtrace/data/sync/sync_engine.dart';
import 'package:flowtrace/data/sync/sync_store.dart';
import 'package:flowtrace/features/attachments/attachment_models.dart';
import 'package:flowtrace/features/identity/identity_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../identity/identity_controller_test.dart' show MemoryVault;
import 'attachment_repository_test.dart' show AttachmentHarness, picture;

final class DropCommittedUpload extends http.BaseClient {
  final inner = http.Client();
  bool drop = false;
  int committedPuts = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (request.method == 'PUT' &&
        request.url.path.contains('/attachments/uploads/') &&
        response.statusCode == 200) {
      committedPuts++;
      if (drop) {
        drop = false;
        await response.stream.drain<void>();
        throw const SocketException(
          'Synthetic upload reply loss after real commit',
        );
      }
    }
    return response;
  }

  @override
  void close() => inner.close();
}

/// Opt-in synthetic users only, using the named loopback development service.
/// Every attachment byte uses a real temporary directory, not an in-memory store.
void main() {
  final credentials = Platform.environment['FLOWTRACE_ATTACHMENT_QA_FILE'];
  test(
    'real HTTP: lost upload reply, frozen bill retry, private access and sync revocation',
    () async {
      final rows = jsonDecode(await File(credentials!).readAsString()) as List;
      if (rows.length != 2 ||
          !credentials
              .replaceAll('\\', '/')
              .endsWith('/work/flowtrace-dev/client-auth-qa.json')) {
        throw StateError(
          'Requires the isolated synthetic attachment QA credentials',
        );
      }
      final directory = await Directory.systemTemp.createTemp(
        'flowtrace-attachment-http-',
      );
      final ownerHarness = AttachmentHarness(
        Directory(p.join(directory.path, 'owner')),
      );
      final friendHarness = AttachmentHarness(
        Directory(p.join(directory.path, 'friend')),
      );
      await ownerHarness.directory.create();
      await friendHarness.directory.create();
      await ownerHarness.open();
      await friendHarness.open();
      final transport = DropCommittedUpload();
      final owner = IdentityController(
        repository: ownerHarness.local,
        api: ApiClient(transport),
        vault: MemoryVault(),
        isWeb: false,
        allowLocalHttp: true,
        deviceName: 'attachment-http-owner',
      );
      final friend = IdentityController(
        repository: friendHarness.local,
        api: ApiClient(http.Client()),
        vault: MemoryVault(),
        isWeb: false,
        allowLocalHttp: true,
        deviceName: 'attachment-http-friend',
      );
      final id = const Uuid().v4(),
          bookId = const Uuid().v4(),
          billId = const Uuid().v4();
      try {
        for (final entry in [
          MapEntry(owner, rows[0]),
          MapEntry(friend, rows[1]),
        ]) {
          await entry.key.configure(
            ServerAddress.parse('http://127.0.0.1:18080'),
          );
          await entry.key.signIn(
            username: entry.value['username'] as String,
            password: entry.value['password'] as String,
          );
          expect(entry.key.online, isTrue);
        }
        final space = owner.accountSpace!, friendSpace = friend.accountSpace!;
        await ownerHarness.local.registerSpace(space);
        await friendHarness.local.registerSpace(friendSpace);
        final repository = AttachmentRepository(
          ownerHarness.local,
          ownerHarness.bytes,
        );
        final friendRepo = AttachmentRepository(
          friendHarness.local,
          friendHarness.bytes,
        );
        final transfer = AttachmentTransfer(repository),
            friendTransfer = AttachmentTransfer(friendRepo);
        final engine = SyncEngine(
          SyncStore(ownerHarness.local),
          beforePush: (lease, command) async {
            if (command['entity_type'] == 'bill' &&
                command['action'] != 'delete') {
              final payload = (command['payload'] as Map)
                  .cast<String, Object?>();
              await transfer.ensureReady(
                AttachmentLease.capture(owner),
                command['scope_id'] as String,
                (payload['attachment_ids'] as List).cast<String>(),
              );
            }
          },
        );
        final friendEngine = SyncEngine(
          SyncStore(friendHarness.local),
          onScopeRevoked: friendRepo.revokeScope,
        );
        await owner.authorizedRequest(
          'POST',
          '/books',
          body: {'id': bookId, 'name': '附件HTTP隔离验收'},
        );
        final staged = await repository.stage(
          space,
          owner.serverIdentity!.syncEpoch,
          bookId,
          picture(),
          mediaType: 'image/png',
          attachmentId: id,
        );
        final command = QueuedCommand(
          operationId: const Uuid().v4(),
          scopeId: bookId,
          entityType: 'bill',
          entityId: billId,
          action: 'create',
          baseRevision: '0',
          payload: {
            'bill_type': 'expense',
            'money': {
              'amount_minor': '123',
              'currency': 'CNY',
              'currency_scale': 2,
            },
            'business_date': '2026-10-21',
            'business_timezone': 'Asia/Shanghai',
            'attachment_ids': [id],
          },
        );
        await ownerHarness.local.saveEntityAndQueue(space, command);
        transport.drop = true;
        await expectLater(
          engine.synchronize(SyncLease.capture(owner)),
          throwsA(isA<ApiFailure>().having((e) => e.offline, 'offline', true)),
        );
        final pending = (await ownerHarness.local.pending(space)).single;
        final frozen = pending.frozenRequestJson;
        expect(pending.state, 'retry');
        expect(await repository.original(space, staged), picture());
        await expectLater(
          owner.authorizedRequest(
            'GET',
            '/sync/entities/bill/$billId?scope_id=$bookId',
          ),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)),
        );
        await engine.synchronize(SyncLease.capture(owner));
        expect(await ownerHarness.local.pending(space), isEmpty);
        final journal = await ownerHarness.db
            .select(ownerHarness.db.pendingOperations)
            .get();
        final actual = journal.singleWhere(
          (item) => item.operationId == command.operationId,
        );
        expect(actual.frozenRequestJson, frozen);
        expect(actual.attemptCount, 2);
        expect(transport.committedPuts, 1);
        final bill = await owner.authorizedRequest(
          'GET',
          '/sync/entities/bill/$billId?scope_id=$bookId',
        );
        expect((bill['editable_payload'] as Map)['attachment_ids'], [id]);
        expect(
          await transfer.downloadOriginal(
            AttachmentLease.capture(owner),
            bookId,
            id,
          ),
          picture(),
        );
        await expectLater(
          friendTransfer.downloadOriginal(
            AttachmentLease.capture(friend),
            bookId,
            id,
          ),
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.status,
              'status',
              anyOf(403, 404),
            ),
          ),
        );
        final invite = await owner.authorizedRequest(
          'POST',
          '/books/$bookId/invites',
          body: {'role': 'viewer', 'days': 1},
        );
        await friend.authorizedRequest(
          'POST',
          '/books/join',
          body: {'token': invite['token']},
        );
        await friendEngine.synchronize(SyncLease.capture(friend));
        expect(
          await friendTransfer.downloadOriginal(
            AttachmentLease.capture(friend),
            bookId,
            id,
          ),
          picture(),
        );
        final localOnly = await friendRepo.stage(
          friendSpace,
          friend.serverIdentity!.syncEpoch,
          bookId,
          picture(),
          mediaType: 'image/png',
        );
        await owner.authorizedRequest(
          'DELETE',
          '/books/$bookId/members/${friendSpace.userId}',
        );
        await friendEngine.synchronize(SyncLease.capture(friend));
        expect(
          await friendRepo.cached(
            friendSpace,
            friend.serverIdentity!.syncEpoch,
            id,
            'original',
          ),
          isNull,
        );
        final remaining = await friendHarness.bytes.read(
          attachmentBlobKey(
            friendSpace.id,
            friend.serverIdentity!.syncEpoch,
            bookId,
            id,
            'remote-original-${staged.sha256}',
          ),
        );
        expect(remaining, isNull);
        expect(
          (await friendRepo.get(friendSpace, localOnly.id))!.phase,
          AttachmentPhase.revoked,
        );
        expect(await friendRepo.original(friendSpace, localOnly), picture());
        await expectLater(
          friendTransfer.downloadOriginal(
            AttachmentLease.capture(friend),
            bookId,
            id,
          ),
          throwsA(
            isA<ApiFailure>().having((e) => e.code, 'code', 'scope_revoked'),
          ),
        );
        await ownerHarness.local.saveEntityAndQueue(
          space,
          QueuedCommand(
            operationId: const Uuid().v4(),
            scopeId: bookId,
            entityType: 'bill',
            entityId: billId,
            action: 'delete',
            baseRevision: '1',
            payload: {},
          ),
        );
        await engine.synchronize(SyncLease.capture(owner));
        await ownerHarness.local.saveEntityAndQueue(
          space,
          QueuedCommand(
            operationId: const Uuid().v4(),
            scopeId: bookId,
            entityType: 'book',
            entityId: bookId,
            action: 'delete',
            baseRevision: '1',
            payload: {},
          ),
        );
        await engine.synchronize(SyncLease.capture(owner));
      } finally {
        for (final identity in [owner, friend]) {
          try {
            if (identity.online) await identity.signOut();
          } finally {
            identity.dispose();
          }
        }
        await ownerHarness.close();
        await friendHarness.close();
        final resolved = p.normalize(p.absolute(directory.path));
        if (!p.isWithin(p.absolute(Directory.systemTemp.path), resolved) ||
            !p.basename(resolved).startsWith('flowtrace-attachment-http-')) {
          throw StateError(
            'Refusing deletion outside isolated HTTP test directory',
          );
        }
        await Directory(resolved).delete(recursive: true);
      }
    },
    skip: credentials == null
        ? 'Set FLOWTRACE_ATTACHMENT_QA_FILE for isolated real HTTP attachment test'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
