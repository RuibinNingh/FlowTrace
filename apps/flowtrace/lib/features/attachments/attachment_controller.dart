import 'package:flutter/foundation.dart';

import '../../core/config/data_space.dart';
import '../../core/network/api_failure.dart';
import '../../data/attachments/attachment_repository.dart';
import '../../data/attachments/attachment_transfer.dart';
import 'attachment_models.dart';

final class AttachmentController extends ChangeNotifier {
  AttachmentController(this.repository)
    : transfer = AttachmentTransfer(repository);
  final AttachmentRepository repository;
  final AttachmentTransfer transfer;
  List<LocalAttachment> items = const [];
  ApiFailure? failure;
  bool busy = false;
  bool _disposed = false;
  String? _spaceId;
  int _viewGeneration = 0;
  int _inFlight = 0;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load(DataSpace space) async {
    if (_spaceId != space.id) {
      items = const [];
      failure = null;
    }
    _spaceId = space.id;
    final generation = ++_viewGeneration;
    final found = await repository.list(space);
    if (_disposed || generation != _viewGeneration || _spaceId != space.id) {
      return;
    }
    items = found;
    _changed();
  }

  Future<LocalAttachment> stage(
    DataSpace space,
    String epoch,
    String scope,
    Uint8List bytes, {
    required String mediaType,
  }) async {
    final view = _spaceId;
    final result = await repository.stage(
      space,
      epoch,
      scope,
      bytes,
      mediaType: mediaType,
    );
    if (!_disposed &&
        view == _spaceId &&
        (_spaceId == null || _spaceId == space.id)) {
      await load(space);
    }
    return result;
  }

  Future<void> retry(AttachmentLease lease, String id) async {
    if (_spaceId != null && _spaceId != lease.space.id) return;
    _inFlight++;
    busy = true;
    failure = null;
    _changed();
    try {
      await transfer.upload(lease, id);
    } on ApiFailure catch (error) {
      if (lease.isCurrent() &&
          (_spaceId == null || _spaceId == lease.space.id)) {
        failure = error;
      }
    } finally {
      busy = --_inFlight > 0;
      if (!_disposed &&
          lease.isCurrent() &&
          (_spaceId == null || _spaceId == lease.space.id)) {
        await load(lease.space);
      }
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _viewGeneration++;
    super.dispose();
  }
}
