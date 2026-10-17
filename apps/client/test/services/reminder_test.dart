import 'package:daymark/models/recurrence.dart';
import 'package:daymark/models/task_item.dart';
import 'package:daymark/models/task_occurrence.dart';
import 'package:daymark/services/notification_gateway.dart';
import 'package:daymark/services/occurrence_engine.dart';
import 'package:daymark/services/reminder_planner.dart';
import 'package:daymark/services/reminder_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

List<TaskOccurrence> occurrencesOf(List<TaskItem> tasks, {List<OccurrenceCompletion> completions = const <OccurrenceCompletion>[]}) =>
    OccurrenceEngine.build(tasks: tasks, completions: completions, now: kNow);

TaskItem withReminder({String id = 't1', DateTime? due, int? minutes, DateTime? at, int atMinutes = 9 * 60, Recurrence rule = const Recurrence.none(), TaskStatus status = TaskStatus.pending}) {
  return makeTask(
    id: id,
    title: 'Task $id',
    due: due ?? DateTime(2026, 3, 12),
    minutes: minutes,
    recurrence: rule,
    status: status,
    completedAt: status == TaskStatus.completed ? kNow : null,
    reminder: true,
    reminderDate: at ?? DateTime(2026, 3, 11),
    reminderMinutes: atMinutes,
  );
}

void main() {
  group('ReminderPlanner', () {
    test('plans a future reminder with a readable body', () {
      final plan = ReminderPlanner.plan(occurrencesOf(<TaskItem>[withReminder(minutes: 14 * 60 + 30)]), kNow);
      expect(plan.length, 1);
      expect(plan.single.at, DateTime(2026, 3, 11, 9));
      expect(plan.single.title, 'Task t1');
      expect(plan.single.body, 'Due Thu 12 Mar at 14:30');
      expect(plan.single.key, 't1@2026-03-12');
    });

    test('skips completed, disabled, past and too-distant reminders', () {
      final plan = ReminderPlanner.plan(
        occurrencesOf(<TaskItem>[
          withReminder(id: 'done', status: TaskStatus.completed),
          withReminder(id: 'past', due: DateTime(2026, 3, 10), at: DateTime(2026, 3, 10), atMinutes: 9 * 60), // 09:00 < now 10:00
          withReminder(id: 'far', due: DateTime(2026, 6, 1), at: DateTime(2026, 5, 31)),
          makeTask(id: 'off', due: DateTime(2026, 3, 12), reminderDate: DateTime(2026, 3, 11), reminderMinutes: 540),
          withReminder(id: 'ok'),
        ]),
        kNow,
      );
      expect(plan.map((r) => r.key), <String>['ok@2026-03-12']);
    });

    test('a reminder at exactly "now" is not planned (it must be in the future)', () {
      final task = withReminder(due: DateTime(2026, 3, 10), at: DateTime(2026, 3, 10), atMinutes: 10 * 60);
      expect(ReminderPlanner.plan(occurrencesOf(<TaskItem>[task]), kNow), isEmpty);
    });

    test('repeating tasks get one reminder per upcoming occurrence, sorted by time', () {
      final task = withReminder(due: DateTime(2026, 3, 10), at: DateTime(2026, 3, 9), rule: const Recurrence.daily());
      final plan = ReminderPlanner.plan(occurrencesOf(<TaskItem>[task]), kNow);
      // Occurrence 10 Mar's reminder (9 Mar 09:00) has passed. 11 Mar's is 10 Mar 09:00 (passed). From 12 Mar: 11 Mar 09:00.
      expect(plan.first.at, DateTime(2026, 3, 11, 9));
      expect(plan.first.key, 't1@2026-03-12');
      for (var i = 1; i < plan.length; i++) {
        expect(plan[i].at.isAfter(plan[i - 1].at), isTrue);
      }
      expect(plan.last.at.isAfter(DateTime(2026, 4, 9, 10)), isFalse); // within 30 days of 10 Mar 10:00
    });

    test('completing one occurrence removes only its reminder', () {
      final task = withReminder(due: DateTime(2026, 3, 10), at: DateTime(2026, 3, 9), rule: const Recurrence.daily());
      final done = OccurrenceCompletion(taskId: 't1', date: DateTime(2026, 3, 13), completedAt: kNow);
      final before = ReminderPlanner.plan(occurrencesOf(<TaskItem>[task]), kNow);
      final after = ReminderPlanner.plan(occurrencesOf(<TaskItem>[task], completions: <OccurrenceCompletion>[done]), kNow);
      expect(after.length, before.length - 1);
      expect(after.any((r) => r.key == 't1@2026-03-13'), isFalse);
      expect(after.any((r) => r.key == 't1@2026-03-14'), isTrue);
    });

    test('rescheduling a task moves its reminder', () {
      final task = withReminder();
      final moved = task.rescheduled(DateTime(2026, 3, 20), null, kNow);
      final plan = ReminderPlanner.plan(occurrencesOf(<TaskItem>[moved]), kNow);
      expect(plan.single.key, 't1@2026-03-20');
      expect(plan.single.at, DateTime(2026, 3, 19, 9));
    });

    test('ids are stable, positive, 31-bit and unique', () {
      final tasks = <TaskItem>[for (var i = 0; i < 100; i++) withReminder(id: 'task-$i')];
      final a = ReminderPlanner.plan(occurrencesOf(tasks), kNow, maxReminders: 100);
      final b = ReminderPlanner.plan(occurrencesOf(tasks), kNow, maxReminders: 100);
      expect(a.map((r) => r.notificationId).toList(), b.map((r) => r.notificationId).toList());
      expect(a.map((r) => r.notificationId).toSet().length, 100);
      expect(a.every((r) => r.notificationId > 0 && r.notificationId <= 0x7fffffff), isTrue);
      expect(ReminderPlanner.stableId('t1@2026-03-12'), ReminderPlanner.stableId('t1@2026-03-12'));
      expect(ReminderPlanner.stableId('t1@2026-03-12'), isNot(ReminderPlanner.stableId('t1@2026-03-13')));
    });

    test('only the soonest reminders are kept when over the cap', () {
      final tasks = <TaskItem>[
        for (var i = 0; i < 10; i++) withReminder(id: 'x$i', due: DateTime(2026, 3, 12 + i), at: DateTime(2026, 3, 11 + i)),
      ];
      final plan = ReminderPlanner.plan(occurrencesOf(tasks), kNow, maxReminders: 3);
      expect(plan.map((r) => r.key), <String>['x0@2026-03-12', 'x1@2026-03-13', 'x2@2026-03-14']);
    });
  });

  group('ReminderService', () {
    late FakeNotificationGateway gateway;
    late ReminderService service;

    setUp(() {
      gateway = FakeNotificationGateway();
      service = ReminderService(gateway, clock: () => kNow, refreshInterval: Duration.zero);
    });

    tearDown(() => service.dispose());

    test('never prompts for permission by itself', () async {
      await service.initialize(enabled: false);
      await service.update(occurrencesOf(<TaskItem>[withReminder()]));
      expect(gateway.requestCount, 0);
      expect(service.isActive, isFalse);
    });

    test('while off, nothing is scheduled and anything old is cancelled', () async {
      await service.initialize(enabled: false);
      await service.update(occurrencesOf(<TaskItem>[withReminder()]));
      expect(gateway.scheduled, isEmpty);
      expect(gateway.cancelCount, greaterThan(0));
    });

    test('enable() asks once, then schedules the plan', () async {
      await service.initialize(enabled: false);
      await service.update(occurrencesOf(<TaskItem>[withReminder()]));
      final status = await service.enable();
      expect(status, NotificationPermissionStatus.granted);
      expect(gateway.requestCount, 1);
      expect(service.isActive, isTrue);
      expect(gateway.lastScheduled.single.key, 't1@2026-03-12');
    });

    test('a refused prompt leaves reminders off and schedules nothing', () async {
      gateway.grantOnRequest = false;
      await service.initialize(enabled: false);
      await service.update(occurrencesOf(<TaskItem>[withReminder()]));
      final status = await service.enable();
      expect(status, NotificationPermissionStatus.denied);
      expect(service.enabled, isFalse);
      expect(gateway.scheduled, isEmpty);
    });

    test('after a restart the stored choice re-plans without prompting', () async {
      gateway.permission = NotificationPermissionStatus.granted;
      await service.initialize(enabled: true);
      await service.update(occurrencesOf(<TaskItem>[withReminder()]));
      expect(gateway.requestCount, 0);
      expect(gateway.lastScheduled.length, 1);
    });

    test('permission revoked in system settings stops scheduling', () async {
      gateway.permission = NotificationPermissionStatus.granted;
      await service.initialize(enabled: true);
      await service.update(occurrencesOf(<TaskItem>[withReminder()]));
      expect(gateway.scheduled.length, 1);
      gateway.permission = NotificationPermissionStatus.denied;
      await service.update(occurrencesOf(<TaskItem>[withReminder()]));
      expect(gateway.scheduled.length, 1); // nothing new
      expect(service.isActive, isFalse);
      expect(service.planned, isEmpty);
    });

    test('completing, deleting and rescheduling re-plan the full schedule', () async {
      gateway.permission = NotificationPermissionStatus.granted;
      await service.initialize(enabled: true);
      final a = withReminder(id: 'a');
      final b = withReminder(id: 'b');
      await service.update(occurrencesOf(<TaskItem>[a, b]));
      expect(gateway.lastScheduled.map((r) => r.key).toSet(), <String>{'a@2026-03-12', 'b@2026-03-12'});

      await service.update(occurrencesOf(<TaskItem>[a.completed(kNow), b])); // complete a
      expect(gateway.lastScheduled.map((r) => r.key), <String>['b@2026-03-12']);

      await service.update(occurrencesOf(<TaskItem>[a.completed(kNow)])); // delete b
      expect(gateway.lastScheduled, isEmpty);

      await service.update(occurrencesOf(<TaskItem>[a.reopened(kNow).rescheduled(DateTime(2026, 3, 15), null, kNow)])); // reopen + reschedule a
      expect(gateway.lastScheduled.single.key, 'a@2026-03-15');
    });

    test('overlapping updates finish with the newest data', () async {
      gateway.permission = NotificationPermissionStatus.granted;
      await service.initialize(enabled: true);
      final first = service.update(occurrencesOf(<TaskItem>[withReminder(id: 'old')]));
      final second = service.update(occurrencesOf(<TaskItem>[withReminder(id: 'new')]));
      await Future.wait(<Future<void>>[first, second]);
      expect(service.planned.single.key, 'new@2026-03-12');
      expect(gateway.lastScheduled.single.key, 'new@2026-03-12');
    });

    test('disable() cancels everything', () async {
      gateway.permission = NotificationPermissionStatus.granted;
      await service.initialize(enabled: true);
      await service.update(occurrencesOf(<TaskItem>[withReminder()]));
      final cancelsBefore = gateway.cancelCount;
      await service.disable();
      expect(gateway.cancelCount, greaterThan(cancelsBefore));
      expect(service.planned, isEmpty);
      expect(service.isActive, isFalse);
    });
  });
}
