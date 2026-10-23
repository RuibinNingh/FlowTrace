import '../../data/local/local_repository.dart';

abstract interface class ProtectionStore {
  Future<String?> read();
  Future<bool> compareAndSet(String? expected, String next);
}

class LocalProtectionStore implements ProtectionStore {
  LocalProtectionStore(this.repository);
  final LocalRepository repository;
  static const settingKey = 'app.protection.v1';
  @override
  Future<String?> read() => repository.readSetting(settingKey);

  @override
  Future<bool> compareAndSet(String? expected, String next) =>
      repository.database.atomicWrite(() async {
        if (await read() != expected) return false;
        await repository.writeSetting(settingKey, next);
        return true;
      });
}
