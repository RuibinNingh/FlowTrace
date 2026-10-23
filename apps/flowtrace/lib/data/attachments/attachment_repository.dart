import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../features/attachments/attachment_models.dart';
import '../local/app_database.dart';
import '../local/local_repository.dart';
import '../diagnostics/client_diagnostics.dart';
import 'byte_store.dart';

final class AttachmentRepository {
  AttachmentRepository(this.local, this.bytes, {ClientDiagnostics? diagnostics})
    : diagnostics = diagnostics ?? ClientDiagnostics(local);
  final LocalRepository local;
  final AttachmentByteStore bytes;
  final ClientDiagnostics diagnostics;
  AppDatabase get db => local.database;
  static const _uuid = Uuid();
  String queuePrefix(DataSpace space) => 'attachments.v1.${space.id}.queue.';
  String _cachePrefix(DataSpace space) => 'attachments.v1.${space.id}.cache.';
  String _queueKey(DataSpace space, String id) =>
      '${queuePrefix(space)}${attachmentIdentifier(id)}';

  Future<List<LocalAttachment>> list(DataSpace space) async {
    final rows = await (db.select(
      db.appSettings,
    )..where((row) => row.key.like('${queuePrefix(space)}%'))).get();
    final result = rows
        .map(
          (row) => LocalAttachment.fromJson(
            (jsonDecode(row.value) as Map<String, dynamic>)
                .cast<String, Object?>(),
          ),
        )
        .toList();
    if (result.any((row) => row.spaceId != space.id)) {
      throw const FormatException('Attachment space mismatch');
    }
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result;
  }

  Future<LocalAttachment?> get(DataSpace space, String id) async {
    final value = await local.readSetting(_queueKey(space, id));
    if (value == null) return null;
    final result = LocalAttachment.fromJson(
      (jsonDecode(value) as Map<String, dynamic>).cast<String, Object?>(),
    );
    if (result.spaceId != space.id || result.id != id) {
      throw const FormatException('Attachment space mismatch');
    }
    return result;
  }

  Future<LocalAttachment> stage(
    DataSpace space,
    String epoch,
    String scopeId,
    Uint8List original, {
    required String mediaType,
    String? attachmentId,
  }) async {
    if (!space.verified) {
      throw const ApiFailure('identity_required', '请先建立账号资料空间。');
    }
    attachmentIdentifier(epoch);
    attachmentIdentifier(scopeId);
    final id = attachmentIdentifier(attachmentId ?? _uuid.v4());
    final frozen = Uint8List.fromList(original);
    validateLocalImage(frozen, mediaType);
    final checksum = sha256.convert(frozen).toString();
    final existing = await get(space, id);
    if (existing != null) {
      if (existing.epoch != epoch ||
          existing.scopeId != scopeId ||
          existing.sha256 != checksum ||
          existing.mediaType != mediaType) {
        throw const ApiFailure('attachment_mismatch', '附件已固定，修改图片需另建附件。');
      }
      return existing;
    }
    final key = attachmentBlobKey(
      space.id,
      epoch,
      scopeId,
      id,
      'local-original-$checksum',
    );
    await bytes.write(key, frozen);
    var record = LocalAttachment(
      id: id,
      spaceId: space.id,
      scopeId: scopeId,
      epoch: epoch,
      sha256: checksum,
      sizeBytes: frozen.length,
      mediaType: mediaType,
      blobKey: key,
      phase: AttachmentPhase.staged,
      createdAt: DateTime.now().toUtc(),
    );
    try {
      await db.atomicWrite(() async {
        final concurrent = await get(space, id);
        if (concurrent != null) {
          if (concurrent.scopeId != scopeId ||
              concurrent.epoch != epoch ||
              concurrent.sha256 != checksum ||
              concurrent.mediaType != mediaType) {
            throw const ApiFailure('attachment_mismatch', '附件已固定，修改图片需另建附件。');
          }
          record = concurrent;
          return;
        }
        final state = await (db.select(
          db.syncStates,
        )..where((row) => row.spaceId.equals(space.id))).getSingleOrNull();
        if (state != null &&
            (jsonDecode(state.revokedScopesJson) as List).contains(scopeId)) {
          record = record.withPhase(
            AttachmentPhase.revoked,
            errorCode: 'scope_revoked',
          );
        }
        await local.writeSetting(
          _queueKey(space, id),
          jsonEncode(record.toJson()),
        );
      });
    } on ApiFailure {
      rethrow;
    } catch (_) {
      // A failed metadata commit is never reported as successful staging.
      // An unreferenced private file may remain for later local maintenance.
      throw const AttachmentStorageFailure();
    }
    await diagnostics.recordQuietly(
      space,
      'attachment_staged',
      scopeId: scopeId,
      entityId: id,
    );
    return record;
  }

  Future<void> requireAllowed(
    DataSpace space,
    String epoch,
    String scopeId,
  ) async {
    if (!space.verified) {
      throw const ApiFailure('identity_required', '请先建立账号资料空间。');
    }
    attachmentIdentifier(epoch);
    attachmentIdentifier(scopeId);
    final state = await (db.select(
      db.syncStates,
    )..where((row) => row.spaceId.equals(space.id))).getSingleOrNull();
    if (state != null) {
      if (state.status != 'active' || state.epoch != epoch) {
        throw const ApiFailure('recovery_required', '本机资料待恢复，附件原件已保留。');
      }
      if ((jsonDecode(state.revokedScopesJson) as List).contains(scopeId)) {
        throw const ApiFailure(
          'scope_revoked',
          '该账本权限已撤销，未传原件仍保留。',
          status: 403,
        );
      }
    }
  }

  /// A preview observes persisted permission/recovery changes independently of
  /// AppController notifications. Stream errors must be treated as denied.
  Stream<bool> watchAllowed(DataSpace space, String epoch, String scopeId) {
    attachmentIdentifier(epoch);
    attachmentIdentifier(scopeId);
    return (db.select(
      db.syncStates,
    )..where((row) => row.spaceId.equals(space.id))).watchSingleOrNull().map((
      state,
    ) {
      if (!space.verified) return false;
      // Private local staging may precede the first sync configuration.
      if (state == null) return true;
      try {
        return state.status == 'active' &&
            state.epoch == epoch &&
            !(jsonDecode(state.revokedScopesJson) as List).contains(scopeId);
      } catch (_) {
        return false;
      }
    }).distinct();
  }

  Future<void> save(
    DataSpace space,
    LocalAttachment record, {
    bool enforceAccess = true,
  }) async {
    if (record.spaceId != space.id) {
      throw const FormatException('Attachment space mismatch');
    }
    await db.atomicWrite(() async {
      if (enforceAccess) {
        await requireAllowed(space, record.epoch, record.scopeId);
      }
      await local.writeSetting(
        _queueKey(space, record.id),
        jsonEncode(record.toJson()),
      );
    });
  }

  /// Adopt a server-confirmed import transfer without redeclaring its upload.
  /// The old private blob is retained; a failed metadata write leaves the
  /// original queue usable and never reports that local adoption completed.
  Future<void> adoptImportedScope(
    DataSpace space, {
    required String epoch,
    required String clientId,
    required String id,
    required String fromScope,
    required String toScope,
    required String permissionVersion,
    required String checksum,
    required int size,
    required String mediaType,
    required bool Function() isCurrent,
    bool reverse = false,
  }) async {
    for (final value in [epoch, clientId, id, fromScope, toScope]) {
      attachmentIdentifier(value);
    }
    attachmentChecksum(checksum);
    final version = BigInt.tryParse(permissionVersion);
    if ((!reverse && fromScope != space.userId) ||
        (reverse && (fromScope == space.userId || toScope != space.userId)) ||
        toScope == fromScope ||
        !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(permissionVersion) ||
        version == null ||
        version > BigInt.parse('9223372036854775807') ||
        size < 1 ||
        size > attachmentMaxBytes ||
        !attachmentMediaTypes.contains(mediaType)) {
      throw const FormatException('Invalid attachment transfer receipt');
    }

    Future<void> guard() async {
      if (!isCurrent()) {
        throw const ApiFailure('identity_changed', '资料空间已变化，附件采纳已停止。');
      }
      await requireAllowed(space, epoch, toScope);
      final state = await (db.select(
        db.syncStates,
      )..where((row) => row.spaceId.equals(space.id))).getSingleOrNull();
      final raw = await local.readSetting('sync.scope-details.${space.id}');
      final details = raw == null ? null : jsonDecode(raw);
      final scopes = details is Map && details['scopes'] is List
          ? details['scopes'] as List
          : const [];
      final found = scopes.whereType<Map>().where(
        (item) => item['scope_id'] == toScope,
      );
      final scope = found.length == 1 ? found.single : null;
      final currentVersion = scope?['permission_version'];
      final current = currentVersion is String
          ? BigInt.tryParse(currentVersion)
          : null;
      if (state == null ||
          state.status != 'active' ||
          state.clientId != clientId ||
          state.epoch != epoch ||
          details is! Map ||
          details['version'] != 1 ||
          details['epoch'] != epoch ||
          scope?['kind'] != (reverse ? 'user' : 'book') ||
          !(reverse ? {'owner'} : {'owner', 'editor'}).contains(
            scope?['role'],
          ) ||
          current == null ||
          current < BigInt.one ||
          (!reverse && current < version) ||
          !isCurrent()) {
        throw const ApiFailure(
          'attachment_authority_changed',
          '请刷新账本权限后重试附件采纳。',
        );
      }
    }

    await guard();
    final prior = await get(space, id);
    if (prior == null) {
      return; // A replay on another device has no staged queue.
    }
    if (prior.epoch != epoch ||
        !{fromScope, toScope}.contains(prior.scopeId) ||
        (prior.phase != AttachmentPhase.ready &&
            !(reverse && prior.phase == AttachmentPhase.revoked)) ||
        prior.sha256 != checksum ||
        prior.sizeBytes != size ||
        prior.mediaType != mediaType) {
      throw const ApiFailure('attachment_mismatch', '本机原件与已导入附件不一致，原件已保留。');
    }
    final content = await original(space, prior);
    await guard();
    final blob = attachmentBlobKey(
      space.id,
      epoch,
      toScope,
      id,
      'local-original-$checksum',
    );
    if (prior.scopeId != toScope) await bytes.write(blob, content);
    await db.atomicWrite(() async {
      await guard();
      final current = await get(space, id);
      if (current == null ||
          jsonEncode(current.toJson()) != jsonEncode(prior.toJson())) {
        throw const ApiFailure('attachment_changed', '附件状态已变化，请保留原件并重试。');
      }
      final adopted = LocalAttachment(
        id: id,
        spaceId: space.id,
        scopeId: toScope,
        epoch: epoch,
        sha256: checksum,
        sizeBytes: size,
        mediaType: mediaType,
        blobKey: blob,
        phase: AttachmentPhase.ready,
        createdAt: prior.createdAt,
      );
      await local.writeSetting(
        _queueKey(space, id),
        jsonEncode(adopted.toJson()),
      );
      if (!isCurrent()) {
        throw const ApiFailure('identity_changed', '资料空间已变化，附件采纳已停止。');
      }
    });
  }

  Future<Uint8List> original(DataSpace space, LocalAttachment record) async {
    if (record.spaceId != space.id) {
      throw const FormatException('Attachment space mismatch');
    }
    final content = await bytes.read(record.blobKey);
    if (content == null ||
        content.length != record.sizeBytes ||
        sha256.convert(content).toString() != record.sha256) {
      throw const ApiFailure(
        'local_attachment_missing',
        '本机附件缺失或校验失败，请保留原图并重新选择。',
      );
    }
    return content;
  }

  Future<void> revokeScope(DataSpace space, String scopeId) async {
    attachmentIdentifier(scopeId);
    final pending = await list(space);
    final cached = await (db.select(
      db.appSettings,
    )..where((row) => row.key.like('${_cachePrefix(space)}%'))).get();
    await db.atomicWrite(() async {
      for (final item in pending.where((item) => item.scopeId == scopeId)) {
        await save(
          space,
          item.withPhase(AttachmentPhase.revoked, errorCode: 'scope_revoked'),
          enforceAccess: false,
        );
      }
      for (final item in cached) {
        final data = _CachedAttachment.parse(space, item.key, item.value);
        if (data.scopeId == scopeId) {
          // Keep the metadata if a deletion fails, so startup can retry it.
          // The sync revoked-scope marker already blocks all controlled reads.
          await bytes.delete(data.blobKey);
          await (db.delete(
            db.appSettings,
          )..where((row) => row.key.equals(item.key))).go();
        }
      }
    });
    await diagnostics.recordQuietly(space, 'scope_revoked', scopeId: scopeId);
  }

  Future<void> cache(
    DataSpace space,
    String epoch,
    String scopeId,
    String id,
    String variant,
    Uint8List content,
    String checksum,
  ) async {
    if (!{'original', 'thumbnail'}.contains(variant)) {
      throw const FormatException('Invalid attachment variant');
    }
    attachmentIdentifier(id);
    attachmentIdentifier(scopeId);
    attachmentIdentifier(epoch);
    attachmentChecksum(checksum);
    await requireAllowed(space, epoch, scopeId);
    if (sha256.convert(content).toString() != checksum) {
      throw const ApiFailure('hash_mismatch', '附件下载校验失败，未替换本机资料。');
    }
    final blob = attachmentBlobKey(
      space.id,
      epoch,
      scopeId,
      id,
      'remote-$variant-$checksum',
    );
    await bytes.write(blob, content);
    try {
      await db.atomicWrite(() async {
        await requireAllowed(space, epoch, scopeId);
        final previous = await local.readSetting(
          '${_cachePrefix(space)}$id.$variant',
        );
        if (previous != null) {
          final prior = _CachedAttachment.parse(
            space,
            '${_cachePrefix(space)}$id.$variant',
            previous,
          );
          if (prior.blobKey != blob) await bytes.delete(prior.blobKey);
        }
        await local.writeSetting(
          '${_cachePrefix(space)}$id.$variant',
          jsonEncode({
            'version': 1,
            'attachment_id': id,
            'variant': variant,
            'scope_id': scopeId,
            'epoch': epoch,
            'blob_key': blob,
            'sha256': checksum,
          }),
        );
      });
    } catch (_) {
      await bytes.delete(blob);
      rethrow;
    }
  }

  Future<Uint8List?> cached(
    DataSpace space,
    String epoch,
    String id,
    String variant,
  ) async {
    attachmentIdentifier(id);
    if (!{'original', 'thumbnail'}.contains(variant)) {
      throw const FormatException('Invalid attachment variant');
    }
    final raw = await local.readSetting('${_cachePrefix(space)}$id.$variant');
    if (raw == null) return null;
    final value = _CachedAttachment.parse(
      space,
      '${_cachePrefix(space)}$id.$variant',
      raw,
    );
    if (value.epoch != epoch) return null;
    final scope = value.scopeId;
    await requireAllowed(space, epoch, scope);
    final content = await bytes.read(value.blobKey);
    await requireAllowed(space, epoch, scope);
    if (content == null ||
        sha256.convert(content).toString() != value.checksum) {
      return null;
    }
    return content;
  }
}

final class _CachedAttachment {
  const _CachedAttachment(
    this.scopeId,
    this.epoch,
    this.blobKey,
    this.checksum,
  );
  final String scopeId, epoch, blobKey, checksum;

  factory _CachedAttachment.parse(DataSpace space, String key, String raw) {
    final value = (jsonDecode(raw) as Map<String, dynamic>);
    final id = attachmentIdentifier(value['attachment_id']);
    final scope = attachmentIdentifier(value['scope_id']);
    final epoch = attachmentIdentifier(value['epoch']);
    final checksum = attachmentChecksum(value['sha256']);
    final blob = attachmentChecksum(value['blob_key']);
    final variant = value['variant'];
    if (value['version'] != 1 ||
        !{'original', 'thumbnail'}.contains(variant) ||
        key != 'attachments.v1.${space.id}.cache.$id.$variant' ||
        blob !=
            attachmentBlobKey(
              space.id,
              epoch,
              scope,
              id,
              'remote-$variant-$checksum',
            )) {
      throw const FormatException('Invalid controlled attachment cache');
    }
    return _CachedAttachment(scope, epoch, blob, checksum);
  }
}
