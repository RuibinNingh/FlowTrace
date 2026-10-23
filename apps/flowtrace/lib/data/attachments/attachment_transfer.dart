import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../features/attachments/attachment_models.dart';
import '../../features/identity/identity_controller.dart';
import 'attachment_repository.dart';
import 'byte_store.dart';

typedef AttachmentRequest =
    Future<Map<String, Object?>> Function(
      String method,
      String path, {
      Map<String, Object?>? body,
      Uint8List? bodyBytes,
      String? contentType,
    });
typedef AttachmentDownload =
    Future<Uint8List> Function(String path, {int maxBytes});

/// Neither credentials nor a mutable global account are retained by a transfer.
final class AttachmentLease {
  const AttachmentLease({
    required this.space,
    required this.epoch,
    required this.clientId,
    required this.generation,
    required this.isCurrent,
    required this.request,
    required this.download,
  });
  final DataSpace space;
  final String epoch, clientId;
  final int generation;
  final bool Function() isCurrent;
  final AttachmentRequest request;
  final AttachmentDownload download;

  factory AttachmentLease.capture(IdentityController identity) {
    final space = identity.accountSpace;
    final epoch = identity.serverIdentity?.syncEpoch;
    final client = identity.clientId;
    final generation = identity.sessionGeneration;
    if (!identity.online ||
        identity.busy ||
        space == null ||
        epoch == null ||
        client == null) {
      throw const ApiFailure('session_invalid', '请联网登录后上传附件。', status: 401);
    }
    return AttachmentLease(
      space: space,
      epoch: epoch,
      clientId: client,
      generation: generation,
      isCurrent: () =>
          identity.online &&
          !identity.busy &&
          identity.sessionGeneration == generation &&
          identity.accountSpace?.id == space.id &&
          identity.serverIdentity?.syncEpoch == epoch &&
          identity.clientId == client,
      request: (method, path, {body, bodyBytes, contentType}) =>
          identity.authorizedRequest(
            method,
            path,
            body: body,
            bodyBytes: bodyBytes,
            contentType: contentType,
            expectedSpaceId: space.id,
            expectedEpoch: epoch,
            expectedClientId: client,
          ),
      download: (path, {maxBytes = attachmentMaxBytes}) =>
          identity.authorizedDownload(
            path,
            maxBytes: maxBytes,
            expectedSpaceId: space.id,
            expectedEpoch: epoch,
            expectedClientId: client,
          ),
    );
  }

  void check() {
    if (!isCurrent()) {
      throw const ApiFailure('identity_changed', '资料空间已切换，附件操作已停止。');
    }
  }
}

final class AttachmentTransfer {
  AttachmentTransfer(this.repository);
  final AttachmentRepository repository;
  final Map<String, Future<LocalAttachment>> _running = {};
  String _key(AttachmentLease lease, String id) =>
      '${lease.space.id}:${lease.epoch}:${lease.clientId}:${lease.generation}:$id';
  bool running(AttachmentLease lease, String id) =>
      _running.containsKey(_key(lease, id));

  Future<void> _guard(AttachmentLease lease, String scopeId) async {
    lease.check();
    await repository.requireAllowed(lease.space, lease.epoch, scopeId);
    lease.check();
  }

  Future<LocalAttachment> upload(AttachmentLease lease, String id) {
    lease.check();
    attachmentIdentifier(id);
    final key = _key(lease, id);
    return _running[key] ??= _upload(lease, id).whenComplete(() {
      _running.remove(key);
    });
  }

  Future<LocalAttachment> _upload(AttachmentLease lease, String id) async {
    final found = await repository.get(lease.space, id);
    lease.check();
    if (found == null) {
      throw const ApiFailure('attachment_missing', '没有找到本机待传原件。');
    }
    LocalAttachment record = found;
    if (record.epoch != lease.epoch) {
      await repository.save(
        lease.space,
        record.withPhase(
          AttachmentPhase.recoveryRequired,
          errorCode: 'recovery_required',
        ),
        enforceAccess: false,
      );
      throw const ApiFailure('recovery_required', '附件属于恢复前资料，原件保留，请先核对恢复。');
    }
    final scope = record.scopeId;
    try {
      await _guard(lease, scope);
      record = record.withPhase(AttachmentPhase.declaring);
      await repository.save(lease.space, record);
      lease.check();
      // Always re-declare; an expired upload gets a fresh ticket without changing
      // the immutable attachment ID in an already frozen bill command.
      final declaration = await lease.request(
        'POST',
        '/attachments/uploads',
        body: {
          'attachment_id': record.id,
          'scope_id': record.scopeId,
          'sha256': record.sha256,
          'size_bytes': record.sizeBytes,
          'media_type': record.mediaType,
        },
      );
      await _guard(lease, scope);
      if (declaration['attachment_id'] != id ||
          !{'pending', 'uploaded', 'ready'}.contains(declaration['status'])) {
        throw const FormatException('Invalid upload declaration');
      }
      final uploadId = attachmentIdentifier(declaration['upload_id']);
      record = record.withPhase(AttachmentPhase.uploading, uploadId: uploadId);
      await repository.save(lease.space, record);
      if (declaration['status'] == 'pending') {
        final original = await repository.original(lease.space, record);
        await _guard(lease, scope);
        final sent = await lease.request(
          'PUT',
          '/attachments/uploads/$uploadId/content',
          bodyBytes: original,
          contentType: record.mediaType,
        );
        await _guard(lease, scope);
        if (sent['attachment_id'] != id ||
            sent['upload_id'] != uploadId ||
            !{'uploaded', 'ready'}.contains(sent['status'])) {
          throw const FormatException('Invalid upload result');
        }
      }
      record = record.withPhase(AttachmentPhase.completing);
      await repository.save(lease.space, record);
      lease.check();
      final result = await lease.request(
        'POST',
        '/attachments/uploads/$uploadId/complete',
      );
      await _guard(lease, scope);
      _metadata(
        result,
        id: id,
        scope: scope,
        checksum: record.sha256,
        size: record.sizeBytes,
        mediaType: record.mediaType,
      );
      record = record.withPhase(AttachmentPhase.ready);
      await repository.save(lease.space, record);
      lease.check();
      await repository.diagnostics.recordQuietly(
        lease.space,
        'attachment_ready',
        scopeId: scope,
        entityId: id,
      );
      return record;
    } on ApiFailure catch (error) {
      if (lease.isCurrent()) {
        if ({'scope_forbidden', 'scope_revoked'}.contains(error.code)) {
          await repository.revokeScope(lease.space, scope);
        } else {
          await repository.save(
            lease.space,
            record.withPhase(
              error.code == 'recovery_required'
                  ? AttachmentPhase.recoveryRequired
                  : AttachmentPhase.failed,
              errorCode: error.code,
            ),
            enforceAccess: false,
          );
        }
        await repository.diagnostics.recordQuietly(
          lease.space,
          'attachment_upload_failed',
          scopeId: scope,
          entityId: id,
          code: error.code,
          status: error.status,
        );
      }
      rethrow;
    } catch (_) {
      if (lease.isCurrent()) {
        await repository.save(
          lease.space,
          record.withPhase(
            AttachmentPhase.failed,
            errorCode: 'attachment_transfer_failed',
          ),
          enforceAccess: false,
        );
        await repository.diagnostics.recordQuietly(
          lease.space,
          'attachment_upload_failed',
          scopeId: scope,
          entityId: id,
          code: 'attachment_transfer_failed',
        );
      }
      throw const ApiFailure(
        'attachment_transfer_failed',
        '附件未完成上传，本机原件仍保留，可重试。',
      );
    }
  }

  void _metadata(
    Map<String, Object?> value, {
    required String id,
    required String scope,
    String? checksum,
    int? size,
    String? mediaType,
  }) {
    final width = value['width'], height = value['height'];
    if (value['attachment_id'] != id ||
        value['scope_id'] != scope ||
        value['status'] != 'ready' ||
        !attachmentMediaTypes.contains(value['media_type']) ||
        value['size_bytes'] is! int ||
        (value['size_bytes'] as int) < 1 ||
        (value['size_bytes'] as int) > attachmentMaxBytes ||
        width is! int ||
        height is! int ||
        width < 1 ||
        height < 1 ||
        width * height > 40000000 ||
        (checksum != null && value['sha256'] != checksum) ||
        (size != null && value['size_bytes'] != size) ||
        (mediaType != null && value['media_type'] != mediaType)) {
      throw const FormatException('Invalid attachment metadata');
    }
    attachmentChecksum(value['sha256']);
  }

  Future<Uint8List> downloadOriginal(
    AttachmentLease lease,
    String scopeId,
    String id,
  ) async {
    attachmentIdentifier(id);
    attachmentIdentifier(scopeId);
    await _guard(lease, scopeId);
    final metadata = await lease.request('GET', '/attachments/$id');
    await _guard(lease, scopeId);
    _metadata(metadata, id: id, scope: scopeId);
    final content = await lease.download(
      '/attachments/$id/content',
      maxBytes: attachmentMaxBytes,
    );
    await _guard(lease, scopeId);
    if (content.length != metadata['size_bytes'] ||
        sha256.convert(content).toString() != metadata['sha256']) {
      throw const ApiFailure('hash_mismatch', '附件下载校验失败，未替换本机原件。');
    }
    validateLocalImage(content, metadata['media_type'] as String);
    await repository.cache(
      lease.space,
      lease.epoch,
      scopeId,
      id,
      'original',
      content,
      metadata['sha256'] as String,
    );
    lease.check();
    await repository.diagnostics.recordQuietly(
      lease.space,
      'attachment_downloaded',
      scopeId: scopeId,
      entityId: id,
    );
    return Uint8List.fromList(content);
  }

  /// Reconcile local staging only after a formal import/undo and a fresh GET.
  Future<void> adoptImportReceipt(
    AttachmentLease lease,
    Map<String, Object?> receipt, {
    bool reverse = false,
  }) async {
    const fields = {
      'attachment_id',
      'from_scope_id',
      'to_scope_id',
      'permission_version',
      'sha256',
      'size_bytes',
      'media_type',
    };
    if (receipt.length != fields.length ||
        !receipt.keys.every(fields.contains)) {
      throw const FormatException('Invalid attachment transfer receipt');
    }
    final id = attachmentIdentifier(receipt['attachment_id']);
    final originalFrom = attachmentIdentifier(receipt['from_scope_id']);
    final originalTo = attachmentIdentifier(receipt['to_scope_id']);
    final from = reverse ? originalTo : originalFrom;
    final to = reverse ? originalFrom : originalTo;
    final checksum = attachmentChecksum(receipt['sha256']);
    if (receipt['size_bytes'] is! int ||
        receipt['media_type'] is! String ||
        receipt['permission_version'] is! String ||
        originalFrom != lease.space.userId ||
        running(lease, id)) {
      throw const ApiFailure('attachment_transfer_busy', '附件状态尚未稳定，请稍后重试采纳。');
    }
    await _guard(lease, to);
    final metadata = await lease.request('GET', '/attachments/$id');
    await _guard(lease, to);
    _metadata(
      metadata,
      id: id,
      scope: to,
      checksum: checksum,
      size: receipt['size_bytes'] as int,
      mediaType: receipt['media_type'] as String,
    );
    await repository.adoptImportedScope(
      lease.space,
      epoch: lease.epoch,
      clientId: lease.clientId,
      id: id,
      fromScope: from,
      toScope: to,
      permissionVersion: receipt['permission_version'] as String,
      checksum: checksum,
      size: receipt['size_bytes'] as int,
      mediaType: receipt['media_type'] as String,
      isCurrent: lease.isCurrent,
      reverse: reverse,
    );
    lease.check();
  }

  /// Call before sending a bill containing these IDs, without rewriting its body.
  Future<void> ensureReady(
    AttachmentLease lease,
    String scopeId,
    Iterable<String> ids,
  ) async {
    await _guard(lease, scopeId);
    final identities = ids.toSet().toList()..sort();
    if (identities.length > 20) {
      throw const ApiFailure('attachment_limit', '一笔记录最多20个附件。');
    }
    for (final id in identities) {
      final local = await repository.get(lease.space, attachmentIdentifier(id));
      await _guard(lease, scopeId);
      if (local != null) {
        if (local.scopeId != scopeId) {
          throw const ApiFailure('attachment_scope_mismatch', '附件不属于当前账本。');
        }
        await upload(lease, id);
      } else {
        final remote = await lease.request('GET', '/attachments/$id');
        await _guard(lease, scopeId);
        _metadata(remote, id: id, scope: scopeId);
      }
    }
  }
}
