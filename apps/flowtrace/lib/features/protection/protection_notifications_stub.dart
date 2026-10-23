import 'protection_notifications_api.dart';

ProtectionNotifications createProtectionNotifications() =>
    _LocalNotifications();

class _LocalNotifications implements ProtectionNotifications {
  @override
  bool get available => true;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  void publish() {}
  @override
  void close() {}
}
