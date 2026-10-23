import 'byte_store.dart';

Future<AttachmentByteStore> openAttachmentBytes() =>
    Future.error(const AttachmentStorageFailure());
