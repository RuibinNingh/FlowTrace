import 'package:flutter/material.dart';

import 'attachment_models.dart';

class AttachmentStatusTile extends StatelessWidget {
  const AttachmentStatusTile({
    super.key,
    required this.item,
    required this.running,
    this.onRetry,
  });
  final LocalAttachment item;
  final bool running;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final label = switch (item.phase) {
      AttachmentPhase.ready => '附件已上传',
      AttachmentPhase.revoked => '权限已变化，本机原件保留',
      AttachmentPhase.recoveryRequired => '待核对恢复，本机原件保留',
      _ => running ? '附件上传中' : '附件待上传，可重试',
    };
    return ListTile(
      leading: const Icon(Icons.image_outlined),
      title: Text(label),
      subtitle: Text(
        '${(item.sizeBytes / 1024).ceil()} KiB · ${item.mediaType}',
      ),
      trailing: running
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : item.phase == AttachmentPhase.ready
          ? const Icon(Icons.check_circle_outline)
          : TextButton(onPressed: onRetry, child: const Text('重试')),
    );
  }
}
