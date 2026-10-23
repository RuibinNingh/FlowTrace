import 'package:flowtrace/data/data_tools/stage_import_jobs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ledger/query_fixtures.dart' show qid;

Map<String, Object?> queueJob({
  String action = 'apply',
  String status = 'failed',
  int version = 1,
}) => {
  'action': action,
  'job_id': qid(85),
  'stage_version': version,
  'status': status,
  'attempt': 1,
  'error_code': 'import_stage_changed',
  'available_at': '2026-10-23T00:00:00Z',
  'lease_until': null,
};
Map<String, Object?> queuePage(List<Map<String, Object?>> jobs) => {
  'stage_id': qid(70),
  'stage_version': 2,
  'jobs': jobs,
};

void main() {
  test('真实旧版本任务保留，只将队列的真实状态判为进行中', () {
    final page = StageImportJobs.parse(queuePage([queueJob()]));
    expect(page.forAction('apply')!.version, 1);
    expect(page.forAction('apply')!.status, 'failed');
    expect(page.active, isFalse);
    for (final status in ['pending', 'running', 'retry_wait']) {
      expect(
        StageImportJobs.parse(queuePage([queueJob(status: status)])).active,
        isTrue,
      );
    }
    expect(StageImportJobs.parse(queuePage([])).jobs, isEmpty);
  });

  test('拒绝重复任务、未来版本、未知金融正文与非安全错误字段', () {
    final job = queueJob();
    for (final raw in [
      queuePage([job, job]),
      queuePage([queueJob(version: 3)]),
      queuePage([
        {
          ...job,
          'payload': {'money': 1},
        },
      ]),
      queuePage([
        {...job, 'error_code': 'private URL/token'},
      ]),
      queuePage([
        {...job, 'lease_until': 'not an instant'},
      ]),
      queuePage([
        {...job, 'attempt': 6},
      ]),
    ]) {
      expect(() => StageImportJobs.parse(raw), throwsFormatException);
    }
  });
}
