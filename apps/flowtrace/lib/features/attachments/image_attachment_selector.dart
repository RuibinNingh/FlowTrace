import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

import '../../core/network/api_failure.dart';
import '../../data/attachments/byte_store.dart';
import 'attachment_models.dart';

final class SelectedAttachmentImage {
  SelectedAttachmentImage(
    Uint8List bytes,
    this.mediaType,
    this.width,
    this.height,
  ) : _bytes = Uint8List.fromList(bytes);
  final Uint8List _bytes;
  final String mediaType;
  final int width, height;
  Uint8List get bytes => Uint8List.fromList(_bytes);
}

typedef AttachmentImagePicker = Future<SelectedAttachmentImage?> Function();

final class ImageAttachmentSelector {
  const ImageAttachmentSelector();
  static const types = XTypeGroup(
    label: '图片',
    extensions: ['jpg', 'jpeg', 'png', 'webp'],
    mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
    uniformTypeIdentifiers: [
      'public.jpeg',
      'public.png',
      'org.webmproject.webp',
    ],
  );

  Future<SelectedAttachmentImage?> pick() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [types],
        confirmButtonText: '选择图片',
      );
      return file == null ? null : await read(file);
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw const ApiFailure('attachment_selection_failed', '图片没有添加，请重新选择。');
    }
  }

  /// Web XFile.openRead uses one Blob slice, so apply a finite end BEFORE
  /// reading. Counting chunks alone would still load an oversized Blob first.
  Future<SelectedAttachmentImage> read(XFile file) async {
    try {
      final length = await file.length();
      if (length < 1 || length > attachmentMaxBytes) {
        throw const ApiFailure('attachment_too_large', '请选择10 MiB以内的图片。');
      }
      final output = BytesBuilder(copy: false);
      await for (final chunk in file.openRead(
        0,
        math.min(length, attachmentMaxBytes + 1),
      )) {
        if (output.length + chunk.length > attachmentMaxBytes) {
          throw const ApiFailure('attachment_too_large', '图片超过10 MiB，未添加到草稿。');
        }
        output.add(Uint8List.fromList(chunk));
      }
      if (output.length != length || await file.length() != length) {
        throw const ApiFailure('attachment_changed', '读取期间图片发生变化，请重新选择。');
      }
      final bytes = output.takeBytes();
      String? media;
      for (final candidate in attachmentMediaTypes) {
        try {
          validateLocalImage(bytes, candidate);
          media = candidate;
          break;
        } on ApiFailure {
          /* Try only the other allowed signatures. */
        }
      }
      if (media == null) {
        throw const ApiFailure('attachment_invalid', '请选择JPEG、PNG或WebP图片。');
      }
      final dimensions = await validateAttachmentPixels(bytes);
      return SelectedAttachmentImage(
        bytes,
        media,
        dimensions.$1,
        dimensions.$2,
      );
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw const ApiFailure('attachment_invalid', '图片无法读取或解码，未添加到草稿。');
    }
  }
}

Future<(int, int)> validateAttachmentPixels(Uint8List bytes) async {
  _validateAnimationAndPngDimensions(bytes);
  ui.Codec? codec;
  try {
    (int, int)? dimensions;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // This API owns/disposes the buffer and exposes intrinsic dimensions on
    // every platform. Encoded ImageDescriptor.width/height throw on Flutter Web.
    codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        if (width < 1 || height < 1 || width * height > 40000000) {
          throw const ApiFailure('image_dimensions', '图片最多4000万像素，请缩小后重试。');
        }
        dimensions = (width, height);
        return ui.TargetImageSize(width: math.min(720, width));
      },
    );
    if (codec.frameCount != 1) {
      throw const ApiFailure('image_animated', '暂不支持动画图片，请选择静态图片。');
    }
    final frame = await codec.getNextFrame();
    frame.image.dispose();
    if (dimensions == null) {
      throw const ApiFailure('attachment_invalid', '图片尺寸无法读取，未添加到草稿。');
    }
    return dimensions!;
  } on ApiFailure {
    rethrow;
  } catch (_) {
    throw const ApiFailure('attachment_invalid', '图片无法解码，未添加到草稿。');
  } finally {
    codec?.dispose();
  }
}

void _validateAnimationAndPngDimensions(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length >= 24 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71) {
    final width = data.getUint32(16), height = data.getUint32(20);
    if (width < 1 || height < 1 || width * height > 40000000) {
      throw const ApiFailure('image_dimensions', '图片最多4000万像素，请缩小后重试。');
    }
    var cursor = 8;
    while (cursor + 12 <= bytes.length) {
      final length = data.getUint32(cursor);
      if (length > bytes.length - cursor - 12) {
        throw const ApiFailure('attachment_invalid', '图片结构不完整，请重新选择。');
      }
      if (bytes[cursor + 4] == 97 &&
          bytes[cursor + 5] == 99 &&
          bytes[cursor + 6] == 84 &&
          bytes[cursor + 7] == 76 &&
          length >= 8 &&
          data.getUint32(cursor + 8) > 1) {
        throw const ApiFailure('image_animated', '暂不支持动画图片，请选择静态图片。');
      }
      cursor += length + 12;
    }
  }
  if (bytes.length >= 21 &&
      bytes[0] == 82 &&
      bytes[1] == 73 &&
      bytes[2] == 70 &&
      bytes[3] == 70 &&
      bytes[8] == 87 &&
      bytes[9] == 69 &&
      bytes[10] == 66 &&
      bytes[11] == 80 &&
      bytes[12] == 86 &&
      bytes[13] == 80 &&
      bytes[14] == 56 &&
      bytes[15] == 88 &&
      (bytes[20] & 2) != 0) {
    throw const ApiFailure('image_animated', '暂不支持动画图片，请选择静态图片。');
  }
}
