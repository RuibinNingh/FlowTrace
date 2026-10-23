import 'dart:convert';

import '../../core/config/data_space.dart';
import '../local/app_database.dart';
import 'snapshot_protocol.dart';

String tombstoneProofPrefix(DataSpace space) =>
    'sync.tombstones.v1.${space.id}.';

String tombstoneProofKey(DataSpace space, String scopeId, String entityId) =>
    '${tombstoneProofPrefix(space)}$scopeId.$entityId';

/// A raw write receipt and a pulled tombstone both have an empty payload.
/// Keep transport provenance separate so exact server projection hashes stay
/// unchanged. Only a fully installed pull commit or snapshot creates this row.
bool isCanonicalBillTombstone(
  DataSpace space,
  String? epoch,
  ConfirmedEntity source,
  Map<String, String> settings,
) {
  if (source.spaceId != space.id ||
      !source.deleted ||
      source.entityType != 'bill' ||
      epoch == null) {
    return false;
  }
  try {
    final encoded =
        settings[tombstoneProofKey(space, source.scopeId, source.entityId)];
    if (encoded == null) return false;
    final proof = syncObject(jsonDecode(encoded));
    return proof.length == 7 &&
        proof['version'] == 1 &&
        proof['epoch'] == epoch &&
        proof['scope_id'] == source.scopeId &&
        proof['entity_id'] == source.entityId &&
        proof['entity_type'] == 'bill' &&
        proof['revision'] == source.revision &&
        proof['projection_hash'] ==
            syncContentHash(jsonDecode(source.dataJson));
  } on Object {
    return false;
  }
}
