import 'export_saver.dart';

Future<DataToolsExportDestination?> chooseExport(String format) =>
    Future.error(UnsupportedError('当前平台暂不支持此导出入口。'));
