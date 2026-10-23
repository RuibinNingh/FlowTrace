abstract interface class ProtectionNotifications {
  bool get available;
  Stream<void> get changes;
  void publish();
  void close();
}
