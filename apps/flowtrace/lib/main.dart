import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'app/flowtrace_app.dart';
import 'data/local/app_database.dart';
import 'data/local/local_repository.dart';
import 'core/network/api_client.dart';
import 'core/network/platform_client.dart';
import 'core/security/platform_vault.dart';
import 'features/identity/identity_controller.dart';
import 'core/config/bundled_licenses.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledLicenses();
  final database = AppDatabase();
  final controller = AppController(
    database,
    identity: IdentityController(
      repository: LocalRepository(database),
      api: ApiClient(createPlatformClient()),
      vault: createSessionVault(),
    ),
  );
  runApp(FlowTraceApp(controller: controller));
  controller.initialize();
}
