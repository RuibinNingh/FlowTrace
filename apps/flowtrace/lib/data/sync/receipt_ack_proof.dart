import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/config/data_space.dart';
import '../local/app_database.dart';
import 'snapshot_protocol.dart';

String receiptAckProofPrefix(DataSpace space) =>
    'sync.receipt-acks.v1.${space.id}.';
String receiptBindingsPrefix(DataSpace space) =>
    'sync.receipt-bindings.v1.${space.id}.';
String receiptFrozenHash(String bytes) =>
    sha256.convert(utf8.encode(bytes)).toString();

enum ReceiptCausalDisposition { satisfied, awaitingSourceSync, missingProof }

final class ReceiptCausalStatus {
  ReceiptCausalStatus(
    this.disposition, {
    Map<String, String> requiredCursors = const {},
    List<String> operationIds = const [],
    this.reason,
  }) : requiredCursors = Map.unmodifiable(requiredCursors),
       operationIds = List.unmodifiable(operationIds);

  final ReceiptCausalDisposition disposition;
  final Map<String, String> requiredCursors;
  final List<String> operationIds;
  final String? reason;
}

/// A source reader must also check its authorized public canonical projection
/// in the same database read snapshot. This function proves only local causal
/// catch-up, never the absence of subsequent remote changes.
ReceiptCausalStatus receiptCausalStatus({
  required DataSpace space,
  required SpaceSyncState? state,
  required Map<String, String> settings,
  required List<StoredOperation> operations,
  required String sourceId,
  required String sourceScopeId,
}) {
  ReceiptCausalStatus missing(String reason, [List<String> ids = const []]) =>
      ReceiptCausalStatus(
        ReceiptCausalDisposition.missingProof,
        operationIds: ids,
        reason: reason,
      );
  if (state == null || state.spaceId != space.id || state.status != 'active') {
    return missing('receipt_sync_identity_unavailable');
  }
  final required = <String, String>{}, affected = <String>[];
  try {
    final revoked = (jsonDecode(state.revokedScopesJson) as List)
        .cast<String>();
    if (revoked.contains(sourceScopeId)) {
      return missing('receipt_source_scope_revoked');
    }
    final cursors = syncVector(jsonDecode(state.cursorsJson));
    for (final operation in operations) {
      if (operation.spaceId != space.id ||
          operation.entityType != 'bill' ||
          operation.state != 'applied') {
        continue;
      }
      final body = operation.frozenRequestJson;
      if (body == null) {
        return missing('receipt_ack_missing', [operation.operationId]);
      }
      final request = syncObject(jsonDecode(body));
      final command = syncObject((request['operations'] as List).single);
      if (request['client_id'] != state.clientId ||
          request['sync_epoch'] != state.epoch) {
        return missing('receipt_ack_identity_mismatch', [
          operation.operationId,
        ]);
      }
      final encoded =
          settings['${receiptBindingsPrefix(space)}${operation.operationId}'];
      Map<String, Object?>? binding;
      if (encoded != null) {
        binding = syncObject(jsonDecode(encoded));
        if (!receiptProofIdentityMatches(binding, space, state, operation)) {
          return missing('receipt_ack_identity_mismatch', [
            operation.operationId,
          ]);
        }
      }
      // Old non-receipt creates cannot have removed any earlier allocation.
      // Updates/deletes without a frozen before remain conservatively unknown.
      if (binding == null &&
          command['action'] == 'create' &&
          !receiptPayloadMayAllocate(syncObject(command['payload']))) {
        continue;
      }
      if (binding?['relevant'] == false &&
          binding?['preserves_hidden'] != true) {
        continue;
      }
      final proofText =
          settings['${receiptAckProofPrefix(space)}${operation.operationId}'];
      if (proofText == null) {
        return missing('receipt_ack_missing', [operation.operationId]);
      }
      final proof = syncObject(jsonDecode(proofText));
      if (!receiptProofIdentityMatches(proof, space, state, operation) ||
          proof['revision'] != operation.appliedRevision ||
          binding == null ||
          proof['bindings_hash'] != syncContentHash(binding)) {
        return missing('receipt_ack_identity_mismatch', [
          operation.operationId,
        ]);
      }
      syncIdentifier(proof['commit_id']);
      final vector = syncVector(proof['scope_revisions']);
      final complete = binding['complete'] == true;
      final bindings = (binding['sources'] as List).map(syncObject).toList();
      if (complete &&
          !bindings.any(
            (row) =>
                row['source_id'] == sourceId &&
                row['scope_id'] == sourceScopeId,
          )) {
        continue;
      }
      final cursor = vector[sourceScopeId];
      if (cursor == null) {
        // The verified vector enumerates every affected scope. An incomplete
        // mapping cannot invent IDs in scopes absent from that full vector.
        if (!complete) continue;
        return missing('receipt_bindings_scope_missing', [
          operation.operationId,
        ]);
      }
      affected.add(operation.operationId);
      final previous = required[sourceScopeId];
      if (previous == null || BigInt.parse(cursor) > BigInt.parse(previous)) {
        required[sourceScopeId] = cursor;
      }
    }
    final waiting = required.entries.any(
      (entry) =>
          !cursors.containsKey(entry.key) ||
          BigInt.parse(cursors[entry.key]!) < BigInt.parse(entry.value),
    );
    return ReceiptCausalStatus(
      waiting
          ? ReceiptCausalDisposition.awaitingSourceSync
          : ReceiptCausalDisposition.satisfied,
      requiredCursors: required,
      operationIds: affected,
      reason: waiting ? 'awaiting_source_sync' : null,
    );
  } on Object {
    return missing('receipt_ack_invalid');
  }
}

bool receiptProofIdentityMatches(
  Map<String, Object?> proof,
  DataSpace space,
  SpaceSyncState state,
  StoredOperation operation,
) =>
    proof['version'] == 1 &&
    proof['space_id'] == space.id &&
    proof['instance_id'] == space.serverInstanceId &&
    proof['user_id'] == space.userId &&
    proof['client_id'] == state.clientId &&
    proof['epoch'] == state.epoch &&
    proof['operation_id'] == operation.operationId &&
    operation.frozenRequestJson != null &&
    proof['frozen_hash'] == receiptFrozenHash(operation.frozenRequestJson!);

bool receiptPayloadMayAllocate(Map<String, Object?> payload) =>
    {'refund', 'reimbursement'}.contains(payload['bill_type']) ||
    (payload['allocations'] is List &&
        (payload['allocations'] as List).isNotEmpty);

/// Compare all visible financial fields; no hidden identifier is reconstructed.
/// The accepted server preserve command is itself strict about omitted fields.
bool receiptPreservesHiddenFinancials(
  Map<String, Object?> command,
  Map<String, Object?>? beforeProjection,
) {
  final after = syncObject(command['payload']);
  if (command['action'] != 'update' ||
      after['preserve_hidden_financial_links'] != true ||
      beforeProjection?['projection_kind'] != 'bill_public') {
    return false;
  }
  final before = syncObject(beforeProjection!['payload']);
  const metadata = {
    'note',
    'category_id',
    'tag_ids',
    'attachment_ids',
    'flags',
    'reimbursement_tracking',
    'preserve_hidden_financial_links',
  };
  final keys = {...before.keys, ...after.keys}.difference(metadata);
  return keys.every(
    (key) => canonicalSyncJson(before[key]) == canonicalSyncJson(after[key]),
  );
}
