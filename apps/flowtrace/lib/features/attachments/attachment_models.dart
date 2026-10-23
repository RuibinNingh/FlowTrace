import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/network/api_failure.dart';
import '../../data/attachments/byte_store.dart';

const attachmentMediaTypes = {'image/jpeg', 'image/png', 'image/webp'};

String attachmentIdentifier(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
      ).hasMatch(value)) {
    throw const FormatException('Invalid attachment identifier');
  }
  return value;
}

String attachmentChecksum(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid attachment checksum');
  }
  return value;
}

void validateLocalImage(Uint8List bytes, String mediaType) {
  if (bytes.isEmpty ||
      bytes.length > attachmentMaxBytes ||
      !attachmentMediaTypes.contains(mediaType)) {
    throw const ApiFailure(
      'attachment_invalid',
      '请选择10 MiB以内的JPEG、PNG或WebP图片。',
    );
  }
  final png =
      bytes.length >= 8 &&
      bytes.sublist(0, 8).join(',') == '137,80,78,71,13,10,26,10';
  final jpeg =
      bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  final webp =
      bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
  if (!(mediaType == 'image/png' && png ||
      mediaType == 'image/jpeg' && jpeg ||
      mediaType == 'image/webp' && webp)) {
    throw const ApiFailure('attachment_invalid', '图片格式与所选类型不一致。');
  }
}

enum AttachmentPhase {
  staged,
  declaring,
  uploading,
  completing,
  ready,
  failed,
  revoked,
  recoveryRequired,
}

final class LocalAttachment {
  const LocalAttachment({
    required this.id,
    required this.spaceId,
    required this.scopeId,
    required this.epoch,
    required this.sha256,
    required this.sizeBytes,
    required this.mediaType,
    required this.blobKey,
    required this.phase,
    required this.createdAt,
    this.uploadId,
    this.errorCode,
  });
  final String id, spaceId, scopeId, epoch, sha256, mediaType, blobKey;
  final int sizeBytes;
  final AttachmentPhase phase;
  final DateTime createdAt;
  final String? uploadId, errorCode;

  LocalAttachment withPhase(
    AttachmentPhase next, {
    String? uploadId,
    String? errorCode,
  }) => LocalAttachment(
    id: id,
    spaceId: spaceId,
    scopeId: scopeId,
    epoch: epoch,
    sha256: sha256,
    sizeBytes: sizeBytes,
    mediaType: mediaType,
    blobKey: blobKey,
    phase: next,
    createdAt: createdAt,
    uploadId: uploadId ?? this.uploadId,
    errorCode: errorCode,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'space_id': spaceId,
    'scope_id': scopeId,
    'epoch': epoch,
    'sha256': sha256,
    'size_bytes': sizeBytes,
    'media_type': mediaType,
    'blob_key': blobKey,
    'phase': phase.name,
    'created_at': createdAt.toUtc().toIso8601String(),
    'upload_id': uploadId,
    'error_code': errorCode,
  };

  factory LocalAttachment.fromJson(Map<String, Object?> value) {
    if (value['version'] != 1 ||
        value['size_bytes'] is! int ||
        (value['size_bytes'] as int) < 1 ||
        (value['size_bytes'] as int) > attachmentMaxBytes ||
        !attachmentMediaTypes.contains(value['media_type']) ||
        value['phase'] is! String ||
        value['created_at'] is! String) {
      throw const FormatException('Invalid attachment record');
    }
    final phase = AttachmentPhase.values
        .where((item) => item.name == value['phase'])
        .firstOrNull;
    final created = DateTime.tryParse(value['created_at'] as String);
    if (phase == null || created == null || !created.isUtc) {
      throw const FormatException('Invalid attachment state');
    }
    final error = value['error_code'];
    if (error != null &&
        (error is! String || !RegExp(r'^[a-z0-9_.]{1,64}$').hasMatch(error))) {
      throw const FormatException('Invalid attachment error');
    }
    final record = LocalAttachment(
      id: attachmentIdentifier(value['id']),
      spaceId: attachmentChecksum(value['space_id']),
      scopeId: attachmentIdentifier(value['scope_id']),
      epoch: attachmentIdentifier(value['epoch']),
      sha256: attachmentChecksum(value['sha256']),
      sizeBytes: value['size_bytes'] as int,
      mediaType: value['media_type'] as String,
      blobKey: attachmentChecksum(value['blob_key']),
      phase: phase,
      createdAt: created,
      uploadId: value['upload_id'] == null
          ? null
          : attachmentIdentifier(value['upload_id']),
      errorCode: error as String?,
    );
    if (record.blobKey !=
        attachmentBlobKey(
          record.spaceId,
          record.epoch,
          record.scopeId,
          record.id,
          'local-original-${record.sha256}',
        )) {
      throw const FormatException('Invalid attachment original key');
    }
    return record;
  }
}

String attachmentBlobKey(
  String spaceId,
  String epoch,
  String scopeId,
  String id,
  String variant,
) => sha256
    .convert(utf8.encode(jsonEncode([spaceId, epoch, scopeId, id, variant])))
    .toString();
