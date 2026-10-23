import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../features/attachments/attachment_models.dart';
import '../attachments/attachment_repository.dart';
import '../attachments/attachment_transfer.dart';
import '../attachments/byte_store.dart';
import '../sync/snapshot_protocol.dart';
import 'image_export/saver.dart';
import 'image_export/target.dart';
import 'ledger_repository.dart';

export 'image_export/target.dart';

final class LedgerImageExportIssue {
  const LedgerImageExportIssue(this.code, {this.billId});
  final String code;
  final String? billId;
}

final class LedgerImageExportPreview {
  LedgerImageExportPreview._({
    required this.spaceId,
    required this.epoch,
    required this.selectedBillCount,
    required this.knownOriginalBytes,
    required this.unknownSizeCount,
    required List<LedgerImageExportIssue> issues,
    required _Selection selection,
    required Object owner,
  }) : issues = List.unmodifiable(issues),
       _selection = selection,
       _owner = owner;
  final String spaceId;
  final String? epoch;
  final int selectedBillCount, knownOriginalBytes, unknownSizeCount;
  final List<LedgerImageExportIssue> issues;
  final _Selection _selection;
  final Object _owner;
  int get imageCount => _selection.images.length;
  bool get canExport => issues.isEmpty && imageCount > 0;
}

final class LedgerImageExportResult {
  const LedgerImageExportResult({
    required this.status,
    required this.imageCount,
    required this.archiveBytes,
    this.fileName = imageExportFileName,
  });
  final LedgerImageExportStatus status;
  final int imageCount, archiveBytes;
  final String fileName;
}

final class _Selection {
  _Selection({
    required this.space,
    required this.view,
    required this.clientId,
    required this.fingerprint,
    required this.billIds,
    required this.images,
    required this.permissionVersions,
    required this.localBooks,
  });
  final DataSpace space;
  final LedgerView view;
  final String? clientId;
  final String fingerprint;
  final List<String> billIds;
  final Map<String, String> images;
  final Map<String, String> permissionVersions;
  final Set<String> localBooks;
}

/// Original bytes and the final ZIP are bounded. ZIP entries contain generated
/// names only; image bytes themselves remain unchanged, including any EXIF.
final class LedgerImageExportService {
  LedgerImageExportService(
    this.ledger,
    this.attachments, {
    AttachmentTransfer? transfer,
    LedgerImageExportSaver? saver,
  }) : transfer = transfer ?? AttachmentTransfer(attachments),
       _saver = saver {
    if (!identical(ledger.repository.database, attachments.local.database)) {
      throw ArgumentError('账务和附件必须使用同一本机资料库。');
    }
  }
  final LedgerRepository ledger;
  final AttachmentRepository attachments;
  final AttachmentTransfer transfer;
  final LedgerImageExportSaver? _saver;
  final Object _owner = Object();
  bool _exporting = false;
  static const maxBills = 1000;
  static const maxImages = 100;

  Future<_Selection> _capture(DataSpace space, List<String> ids) =>
      ledger.repository.database.readSnapshot(() async {
        final view = await ledger.read(
          space,
          query: const LedgerQuery(includeArchived: true, includeDeleted: true),
        );
        final db = ledger.repository.database;
        final state = await (db.select(
          db.syncStates,
        )..where((t) => t.spaceId.equals(space.id))).getSingleOrNull();
        final details = await ledger.repository.readSetting(
          'sync.scope-details.${space.id}',
        );
        final versions = <String, String>{};
        if (details != null) {
          final data = ledgerObject(jsonDecode(details));
          if (data['version'] == 1 && data['epoch'] == view.epoch) {
            for (final raw in data['scopes'] as List) {
              final scope = ledgerObject(raw);
              final id = attachmentIdentifier(scope['scope_id']);
              final version = scope['permission_version'];
              if (version is! String ||
                  !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(version)) {
                throw const FormatException('Invalid permission version');
              }
              versions[id] = version;
            }
          }
        }
        final images = <String, String>{}, selected = <Map<String, Object?>>[];
        final localBooks = <String>{};
        for (final id in ids) {
          final bill = view.find('bill', id);
          if (bill == null) {
            selected.add({'id': id, 'missing': true});
            continue;
          }
          final payload = bill.payload;
          selected.add({
            'id': id,
            'scope_id': bill.scopeId,
            'revision': bill.revision,
            'deleted': bill.deleted,
            'pending': bill.pending,
            'conflicted': bill.conflicted,
            'role': view.roleFor(bill.scopeId),
            'payload': payload,
          });
          final book = view.find('book', bill.scopeId);
          if (book?.revision == '0' &&
              book?.pending == true &&
              view.roleFor(bill.scopeId) == 'owner') {
            localBooks.add(bill.scopeId);
          }
          for (final raw in payload['attachment_ids'] as List? ?? []) {
            final image = attachmentIdentifier(raw);
            final oldScope = images[image];
            if (oldScope != null && oldScope != bill.scopeId) {
              throw const ApiFailure(
                'image_export_invalid_reference',
                '所选图片引用不一致，请先同步核对。',
              );
            }
            images[image] = bill.scopeId;
          }
        }
        final sorted = images.keys.toList()..sort();
        return _Selection(
          space: space,
          view: view,
          clientId: state?.clientId,
          fingerprint: sha256
              .convert(
                utf8.encode(
                  canonicalSyncJson({
                    'epoch': view.epoch,
                    'status': view.syncStatus,
                    'client_id': state?.clientId,
                    'permission_details': details,
                    'selected': selected,
                  }),
                ),
              )
              .toString(),
          billIds: List.unmodifiable(ids),
          images: Map.unmodifiable({for (final id in sorted) id: images[id]!}),
          permissionVersions: Map.unmodifiable(versions),
          localBooks: Set.unmodifiable(localBooks),
        );
      });

  Future<LedgerImageExportPreview> preview(
    DataSpace space,
    Iterable<String> billIds,
  ) async {
    final inputs = billIds.take(maxBills + 1).toList();
    if (inputs.isEmpty || inputs.length > maxBills) {
      throw const ApiFailure('image_export_selection_limit', '请选择1至1000笔账单。');
    }
    final ids = inputs.toSet().toList()..sort();
    final issues = <LedgerImageExportIssue>[];
    if (ids.isEmpty || ids.length > maxBills) {
      throw const ApiFailure('image_export_selection_limit', '请选择1至1000笔账单。');
    }
    for (final id in ids) {
      attachmentIdentifier(id);
    }
    final selection = await _capture(space, ids), view = selection.view;
    if (!space.verified || view.epoch == null || view.syncStatus != 'active') {
      issues.add(
        const LedgerImageExportIssue('image_export_recovery_required'),
      );
    }
    for (final id in ids) {
      final bill = view.find('bill', id);
      if (bill == null || bill.deleted) {
        issues.add(
          LedgerImageExportIssue('image_export_bill_missing', billId: id),
        );
        continue;
      }
      final book = view.find('book', bill.scopeId);
      if (book == null ||
          book.deleted ||
          bill.payload['book_id'] != bill.scopeId ||
          !{'owner', 'editor', 'viewer'}.contains(view.roleFor(bill.scopeId))) {
        issues.add(
          LedgerImageExportIssue('image_export_scope_unavailable', billId: id),
        );
      }
      if (bill.conflicted) {
        issues.add(
          LedgerImageExportIssue('image_export_conflicted', billId: id),
        );
      }
      final refs = bill.payload['attachment_ids'] as List? ?? [];
      if (refs.length > 20 || refs.toSet().length != refs.length) {
        issues.add(
          LedgerImageExportIssue('image_export_invalid_reference', billId: id),
        );
      }
    }
    if (selection.images.isEmpty) {
      issues.add(const LedgerImageExportIssue('image_export_no_images'));
    }
    if (selection.images.length > maxImages) {
      issues.add(const LedgerImageExportIssue('image_export_image_limit'));
    }
    var known = 0, unknown = 0;
    for (final image in selection.images.entries.take(maxImages)) {
      final local = await attachments.get(space, image.key);
      if (local == null) {
        unknown++;
      } else if (local.scopeId != image.value ||
          local.epoch != view.epoch ||
          {
            AttachmentPhase.revoked,
            AttachmentPhase.recoveryRequired,
          }.contains(local.phase)) {
        issues.add(
          const LedgerImageExportIssue('image_export_scope_unavailable'),
        );
      } else {
        known += local.sizeBytes;
      }
    }
    if (known > imageExportMaxOriginalBytes) {
      issues.add(const LedgerImageExportIssue('image_export_size_limit'));
    }
    return LedgerImageExportPreview._(
      spaceId: space.id,
      epoch: view.epoch,
      selectedBillCount: ids.length,
      knownOriginalBytes: known,
      unknownSizeCount: unknown,
      issues: issues,
      selection: selection,
      owner: _owner,
    );
  }

  Future<void> _guard(
    AttachmentLease lease,
    LedgerImageExportPreview preview, {
    bool remote = false,
  }) async {
    lease.check();
    final selected = preview._selection;
    if (lease.space.id != preview.spaceId ||
        lease.epoch != preview.epoch ||
        lease.clientId != selected.clientId) {
      throw const ApiFailure('image_export_stale', '资料版本已变化，请重新预览导出。');
    }
    final current = await _capture(lease.space, selected.billIds);
    if (current.fingerprint != selected.fingerprint) {
      throw const ApiFailure('image_export_stale', '所选账单或权限已变化，请重新预览导出。');
    }
    for (final scope in selected.images.values.toSet()) {
      await attachments.requireAllowed(lease.space, lease.epoch, scope);
    }
    if (remote) await _remoteScopes(lease, selected);
    lease.check();
  }

  Future<void> _remoteScopes(AttachmentLease lease, _Selection selected) async {
    final response = await lease.request('GET', '/sync/scopes');
    lease.check();
    if (response['sync_epoch'] != lease.epoch ||
        response['requires_rebuild'] != false) {
      throw const ApiFailure(
        'image_export_recovery_required',
        '服务器资料需要恢复，请先核对资料。',
      );
    }
    final scopes = response['scopes'], revoked = response['revoked_scope_ids'];
    if (scopes is! List ||
        scopes.length > 1000 ||
        revoked is! List ||
        revoked.length > 1000) {
      throw const FormatException('Invalid scope response');
    }
    final roles = <String, String>{}, versions = <String, String>{};
    for (final raw in scopes) {
      final row = ledgerObject(raw), id = attachmentIdentifier(row['scope_id']);
      final role = row['role'], version = row['permission_version'];
      if (!{'owner', 'editor', 'viewer'}.contains(role) ||
          version is! String ||
          !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(version) ||
          roles.containsKey(id)) {
        throw const FormatException('Invalid scope response');
      }
      roles[id] = role as String;
      versions[id] = version;
    }
    final revokedIds = revoked.map(attachmentIdentifier).toSet();
    for (final scope in selected.images.values.toSet()) {
      final role = roles[scope];
      if (revokedIds.contains(scope) ||
          !(role == selected.view.roleFor(scope) ||
              role == null && selected.localBooks.contains(scope)) ||
          selected.permissionVersions[scope] != null &&
              selected.permissionVersions[scope] != versions[scope]) {
        throw const ApiFailure(
          'image_export_scope_unavailable',
          '账本权限已变化，请先同步核对。',
          status: 403,
        );
      }
    }
  }

  Future<LedgerImageExportResult> export(
    AttachmentLease lease,
    LedgerImageExportPreview preview,
  ) async {
    if (_exporting) throw const ApiFailure('image_export_busy', '正在导出，请稍候。');
    if (!identical(preview._owner, _owner) || !preview.canExport) {
      throw const ApiFailure('image_export_invalid_preview', '请先核对可导出的图片。');
    }
    _exporting = true;
    LedgerImageExportDestination? destination;
    try {
      await _guard(lease, preview, remote: true);
      final archive = Archive();
      var originalBytes = 0, index = 0;
      for (final image in preview._selection.images.entries) {
        await _guard(lease, preview);
        final local = await attachments.get(lease.space, image.key);
        Uint8List bytes;
        if (local != null) {
          if (local.epoch != lease.epoch ||
              local.scopeId != image.value ||
              {
                AttachmentPhase.revoked,
                AttachmentPhase.recoveryRequired,
              }.contains(local.phase)) {
            throw const ApiFailure(
              'image_export_scope_unavailable',
              '图片所属账本当前不可读。',
            );
          }
          bytes = await attachments.original(lease.space, local);
          validateLocalImage(bytes, local.mediaType);
        } else {
          bytes = await transfer.downloadOriginal(
            lease,
            image.value,
            image.key,
          );
        }
        await _guard(lease, preview);
        originalBytes += bytes.length;
        if (bytes.isEmpty ||
            bytes.length > attachmentMaxBytes ||
            originalBytes > imageExportMaxOriginalBytes) {
          throw const ApiFailure(
            'image_export_size_limit',
            '图片原件合计最多20 MiB，请减少选择。',
          );
        }
        final extension = _extension(bytes);
        final name =
            'images/image_${(++index).toString().padLeft(4, '0')}.$extension';
        archive.add(
          ArchiveFile.noCompress(name, bytes.length, bytes)
            ..lastModTime = 315532800
            ..creationTime = 315532800
            ..comment = null,
        );
      }
      final encoded = ZipEncoder().encodeBytes(
        archive,
        modified: DateTime.utc(1980),
      );
      if (encoded.length > imageExportMaxZipBytes) {
        throw const ApiFailure(
          'image_export_size_limit',
          '图片压缩包超过21 MiB，请减少选择。',
        );
      }
      await _guard(lease, preview, remote: true);
      destination = await (_saver ?? openLedgerImageExportSaver()).choose();
      await _guard(lease, preview, remote: true);
      if (destination == null) {
        return const LedgerImageExportResult(
          status: LedgerImageExportStatus.cancelled,
          imageCount: 0,
          archiveBytes: 0,
        );
      }
      final status = await destination.write(
        encoded,
        guard: () => _guard(lease, preview, remote: true),
      );
      await _guard(lease, preview, remote: true);
      return LedgerImageExportResult(
        status: status,
        imageCount: index,
        archiveBytes: encoded.length,
        fileName: destination is LedgerNamedImageExportDestination
            ? destination.fileName
            : imageExportFileName,
      );
    } finally {
      _exporting = false;
      await destination?.discard();
    }
  }

  String _extension(Uint8List bytes) {
    if (bytes.length >= 8 && bytes[0] == 137 && bytes[1] == 80) return 'png';
    if (bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216) return 'jpg';
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF') {
      return 'webp';
    }
    throw const ApiFailure('image_export_invalid_image', '图片原件格式无法识别。');
  }
}
