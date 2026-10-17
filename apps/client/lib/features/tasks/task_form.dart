import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/daymark_tokens.dart';
import '../../models/date_utils.dart';
import '../../models/ids.dart';
import '../../models/recurrence.dart';
import '../../models/task_item.dart';
import '../../models/task_priority.dart';
import '../../services/notification_gateway.dart';
import '../../shared/format.dart';
import 'task_actions.dart';

/// Opens the create form, or the edit form when [existing] is given.
/// [initialDate] pre-fills the due date of a new task.
Future<void> showTaskForm(
  BuildContext context, {
  TaskItem? existing,
  DateTime? initialDate,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        TaskFormDialog(existing: existing, initialDate: initialDate),
  );
}

class TaskFormDialog extends StatefulWidget {
  const TaskFormDialog({super.key, this.existing, this.initialDate});

  final TaskItem? existing;
  final DateTime? initialDate;

  @override
  State<TaskFormDialog> createState() => _TaskFormDialogState();
}

class _TaskFormDialogState extends State<TaskFormDialog> {
  static const int _defaultReminderMinutes = 9 * 60;

  late final TextEditingController _title;
  late final TextEditingController _description;
  DateTime? _dueDate;
  int? _dueMinutes;
  TaskPriority _priority = TaskPriority.medium;
  RecurrenceType _type = RecurrenceType.none;
  Set<int> _weekdays = <int>{};
  int _monthDay = 1;
  bool _reminderOn = false;
  DateTime? _reminderDate;
  int? _reminderMinutes;
  Map<String, String> _errors = <String, String>{};
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final task = widget.existing;
    _title = TextEditingController(text: task?.title ?? '');
    _description = TextEditingController(text: task?.description ?? '');
    if (task != null) {
      _dueDate = task.dueDate;
      _dueMinutes = task.dueMinutes;
      _priority = task.priority;
      _type = task.recurrence.type;
      _weekdays = Set<int>.of(task.recurrence.weekdays);
      _monthDay = task.recurrence.dayOfMonth ?? task.dueDate?.day ?? 1;
      _reminderOn = task.reminderEnabled;
      _reminderDate = task.reminderDate;
      _reminderMinutes = task.reminderMinutes;
    } else {
      final initial = widget.initialDate;
      _dueDate = initial == null ? null : dateOnly(initial);
      _monthDay = _dueDate?.day ?? 1;
    }
    if (_weekdays.isEmpty && _dueDate != null) _weekdays = <int>{_dueDate!.weekday};
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  // ---- pickers ------------------------------------------------------------

  Future<DateTime?> _pickDate(DateTime? current, String help) {
    final today = dateOnly(AppScope.read(context).currentTime());
    var initial = current ?? today;
    if (initial.year < 2000 || initial.year > 2100) initial = today;
    return showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      helpText: help,
    );
  }

  Future<int?> _pickTime(int? current) async {
    final start = current ?? _defaultReminderMinutes;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: start ~/ 60, minute: start % 60),
    );
    return picked == null ? null : picked.hour * 60 + picked.minute;
  }

  Future<void> _chooseDueDate() async {
    final picked = await _pickDate(_dueDate, 'Due date');
    if (picked == null || !mounted) return;
    _setDueDate(dateOnly(picked));
  }

  void _setDueDate(DateTime? date) {
    final old = _dueDate;
    setState(() {
      // Keep the repeat defaults following the date until the user customises them.
      if (date != null && old != null) {
        if (_type == RecurrenceType.weekly &&
            _weekdays.length == 1 &&
            _weekdays.contains(old.weekday)) {
          _weekdays = <int>{date.weekday};
        }
        if (_type == RecurrenceType.monthly && _monthDay == old.day) _monthDay = date.day;
      }
      _dueDate = date;
      if (date == null) _dueMinutes = null;
    });
  }

  Future<void> _chooseDueTime() async {
    final picked = await _pickTime(_dueMinutes);
    if (picked == null || !mounted) return;
    setState(() => _dueMinutes = picked);
  }

  Future<void> _chooseReminderDate() async {
    final picked = await _pickDate(_reminderDate ?? _dueDate, 'Reminder date');
    if (picked == null || !mounted) return;
    setState(() => _reminderDate = dateOnly(picked));
  }

  Future<void> _chooseReminderTime() async {
    final picked = await _pickTime(_reminderMinutes);
    if (picked == null || !mounted) return;
    setState(() => _reminderMinutes = picked);
  }

  void _setReminderOn(bool on) {
    setState(() {
      _reminderOn = on;
      if (on) {
        final today = dateOnly(AppScope.read(context).currentTime());
        _reminderDate ??= _dueDate ?? today;
        _reminderMinutes ??= _dueMinutes ?? _defaultReminderMinutes;
      }
    });
  }

  // ---- save -----------------------------------------------------------------

  Recurrence _recurrence() {
    switch (_type) {
      case RecurrenceType.none:
        return const Recurrence.none();
      case RecurrenceType.daily:
        return const Recurrence.daily();
      case RecurrenceType.weekly:
        return Recurrence.weekly(_weekdays);
      case RecurrenceType.monthly:
        return Recurrence.monthly(_monthDay);
    }
  }

  TaskItem _buildItem(DateTime now) {
    final base = widget.existing;
    return TaskItem(
      id: base?.id ?? newId(),
      title: _title.text,
      description: _description.text,
      dueDate: _dueDate,
      dueMinutes: _dueDate == null ? null : _dueMinutes,
      priority: _priority,
      status: base?.status ?? TaskStatus.pending,
      createdAt: base?.createdAt ?? now,
      completedAt: base?.completedAt,
      updatedAt: now,
      reminderEnabled: _reminderOn,
      reminderDate: _reminderOn ? _reminderDate : null,
      reminderMinutes: _reminderOn ? _reminderMinutes : null,
      recurrence: _recurrence(),
    );
  }

  Future<void> _save() async {
    final controller = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final now = controller.currentTime();
    final item = _buildItem(now);
    final base = widget.existing;

    // Do not nag about a reminder time that was already in the past when the
    // user is only changing something else.
    final reminderUnchanged = base != null &&
        base.reminderEnabled == item.reminderEnabled &&
        base.reminderDate == item.reminderDate &&
        base.reminderMinutes == item.reminderMinutes;
    final errors = TaskValidator.validate(item, now: now, checkReminderInPast: !reminderUnchanged);
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    setState(() {
      _saving = true;
      _errors = <String, String>{};
    });
    final error = await controller.saveTask(item);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _errors = <String, String>{'form': error};
      });
      return;
    }
    navigator.pop();
    showMessage(messenger, _isEdit ? 'Task updated' : 'Task added');
  }

  Future<void> _enableNotifications() async {
    final controller = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final status = await controller.setNotificationsEnabled(true);
    if (!mounted) return;
    setState(() {});
    if (status != NotificationPermissionStatus.granted) {
      showMessage(messenger, _permissionHelp(status));
    }
  }

  static String _permissionHelp(NotificationPermissionStatus status) {
    switch (status) {
      case NotificationPermissionStatus.denied:
        return 'Notifications are blocked. Allow them in your browser or phone settings.';
      case NotificationPermissionStatus.unsupported:
        return 'Notifications are not supported here.';
      case NotificationPermissionStatus.notDetermined:
      case NotificationPermissionStatus.granted:
        return 'Notifications are on.';
    }
  }

  // ---- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = AppScope.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final helper = theme.textTheme.labelMedium?.copyWith(color: muted);

    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: DmSpace.x2, vertical: DmSpace.x3),
      title: Text(_isEdit ? 'Edit task' : 'New task'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                key: const ValueKey<String>('task-title'),
                controller: _title,
                autofocus: !_isEdit,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: 'Title', errorText: _errors['title']),
              ),
              const SizedBox(height: DmSpace.x1_5),
              TextField(
                key: const ValueKey<String>('task-notes'),
                controller: _description,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Notes (optional)',
                  errorText: _errors['description'],
                ),
              ),
              const SizedBox(height: DmSpace.x2),
              Text('Due', style: theme.textTheme.labelLarge),
              const SizedBox(height: DmSpace.x1),
              Wrap(
                spacing: DmSpace.x1,
                runSpacing: DmSpace.x1,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const ValueKey<String>('due-date'),
                    onPressed: _chooseDueDate,
                    icon: const Icon(Icons.event_outlined),
                    label: Text(_dueDate == null
                        ? 'No due date'
                        : describeDay(_dueDate!, controller.now)),
                  ),
                  if (_dueDate != null)
                    IconButton(
                      tooltip: 'Clear due date',
                      icon: const Icon(Icons.close),
                      onPressed: () => _setDueDate(null),
                    ),
                  OutlinedButton.icon(
                    key: const ValueKey<String>('due-time'),
                    onPressed: _dueDate == null ? null : _chooseDueTime,
                    icon: const Icon(Icons.schedule),
                    label: Text(_dueMinutes == null
                        ? 'Add time'
                        : formatTimeOfDay(context, _dueMinutes!)),
                  ),
                  if (_dueMinutes != null)
                    IconButton(
                      tooltip: 'Clear due time',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _dueMinutes = null),
                    ),
                ],
              ),
              _FieldError(_errors['dueDate']),
              _FieldError(_errors['dueTime']),
              const SizedBox(height: DmSpace.x2),
              Text('Priority', style: theme.textTheme.labelLarge),
              const SizedBox(height: DmSpace.x1),
              SegmentedButton<TaskPriority>(
                segments: <ButtonSegment<TaskPriority>>[
                  for (final priority in TaskPriority.values)
                    ButtonSegment<TaskPriority>(value: priority, label: Text(priority.label)),
                ],
                selected: <TaskPriority>{_priority},
                onSelectionChanged: (Set<TaskPriority> value) =>
                    setState(() => _priority = value.first),
              ),
              const SizedBox(height: DmSpace.x2),
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Repeat'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<RecurrenceType>(
                    key: const ValueKey<String>('repeat-type'),
                    value: _type,
                    isExpanded: true,
                    items: const <DropdownMenuItem<RecurrenceType>>[
                      DropdownMenuItem<RecurrenceType>(
                        value: RecurrenceType.none,
                        child: Text('Does not repeat'),
                      ),
                      DropdownMenuItem<RecurrenceType>(
                        value: RecurrenceType.daily,
                        child: Text('Daily'),
                      ),
                      DropdownMenuItem<RecurrenceType>(
                        value: RecurrenceType.weekly,
                        child: Text('Weekly'),
                      ),
                      DropdownMenuItem<RecurrenceType>(
                        value: RecurrenceType.monthly,
                        child: Text('Monthly'),
                      ),
                    ],
                    onChanged: (RecurrenceType? value) {
                      if (value == null) return;
                      setState(() {
                        _type = value;
                        if (value == RecurrenceType.weekly && _weekdays.isEmpty) {
                          _weekdays = <int>{(_dueDate ?? controller.now).weekday};
                        }
                        if (value == RecurrenceType.monthly) {
                          _monthDay = (_dueDate ?? controller.now).day;
                        }
                      });
                    },
                  ),
                ),
              ),
              if (_type == RecurrenceType.weekly) ...<Widget>[
                const SizedBox(height: DmSpace.x1_5),
                Wrap(
                  spacing: DmSpace.x1,
                  runSpacing: DmSpace.x0_5,
                  children: <Widget>[
                    for (var day = 1; day <= 7; day++)
                      FilterChip(
                        key: ValueKey<String>('weekday-$day'),
                        label: Text(kWeekdayShort[day - 1]),
                        selected: _weekdays.contains(day),
                        onSelected: (bool selected) => setState(() {
                          if (selected) {
                            _weekdays.add(day);
                          } else {
                            _weekdays.remove(day);
                          }
                        }),
                      ),
                  ],
                ),
              ],
              if (_type == RecurrenceType.monthly) ...<Widget>[
                const SizedBox(height: DmSpace.x1_5),
                InputDecorator(
                  decoration: const InputDecoration(labelText: 'Day of the month'),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      key: const ValueKey<String>('month-day'),
                      value: _monthDay,
                      isExpanded: true,
                      items: <DropdownMenuItem<int>>[
                        for (var day = 1; day <= 31; day++)
                          DropdownMenuItem<int>(value: day, child: Text('$day')),
                      ],
                      onChanged: (int? value) {
                        if (value != null) setState(() => _monthDay = value);
                      },
                    ),
                  ),
                ),
                if (_monthDay >= 29)
                  Padding(
                    padding: const EdgeInsets.only(top: DmSpace.x0_5),
                    child: Text(
                      'In months with fewer days, this runs on the last day of the month.',
                      style: helper,
                    ),
                  ),
              ],
              if (_type != RecurrenceType.none)
                Padding(
                  padding: const EdgeInsets.only(top: DmSpace.x0_5),
                  child: Text(
                    'Starts on the due date. Editing changes the whole series; each date is completed separately.',
                    style: helper,
                  ),
                ),
              _FieldError(_errors['recurrence']),
              const SizedBox(height: DmSpace.x1),
              SwitchListTile(
                key: const ValueKey<String>('reminder-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Remind me'),
                value: _reminderOn,
                onChanged: _setReminderOn,
              ),
              if (_reminderOn) ...<Widget>[
                Wrap(
                  spacing: DmSpace.x1,
                  runSpacing: DmSpace.x1,
                  children: <Widget>[
                    OutlinedButton.icon(
                      key: const ValueKey<String>('reminder-date'),
                      onPressed: _chooseReminderDate,
                      icon: const Icon(Icons.event_outlined),
                      label: Text(_reminderDate == null
                          ? 'Pick date'
                          : describeDay(_reminderDate!, controller.now)),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey<String>('reminder-time'),
                      onPressed: _chooseReminderTime,
                      icon: const Icon(Icons.notifications_outlined),
                      label: Text(_reminderMinutes == null
                          ? 'Pick time'
                          : formatTimeOfDay(context, _reminderMinutes!)),
                    ),
                  ],
                ),
                if (_type != RecurrenceType.none)
                  Padding(
                    padding: const EdgeInsets.only(top: DmSpace.x0_5),
                    child: Text(
                      'Repeats at the same distance from every due date.',
                      style: helper,
                    ),
                  ),
                _FieldError(_errors['reminder']),
                if (!controller.reminders.isActive)
                  _NotificationNotice(
                    status: controller.reminders.permission,
                    onEnable: _enableNotifications,
                  ),
                if (!controller.reminders.deliversWhileClosed)
                  Padding(
                    padding: const EdgeInsets.only(top: DmSpace.x1),
                    child: Text(
                      'In the browser, reminders appear only while DAYMARK is open in a tab.',
                      style: helper,
                    ),
                  ),
              ],
              _FieldError(_errors['form']),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('save-task'),
          onPressed: _saving ? null : _save,
          child: Text(_isEdit ? 'Save' : 'Add task'),
        ),
      ],
    );
  }
}

class _FieldError extends StatelessWidget {
  const _FieldError(this.message);

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: DmSpace.x0_5),
      child: Text(
        message!,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

class _NotificationNotice extends StatelessWidget {
  const _NotificationNotice({required this.status, required this.onEnable});

  final NotificationPermissionStatus status;
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = status == NotificationPermissionStatus.denied;
    final unsupported = status == NotificationPermissionStatus.unsupported;
    final text = unsupported
        ? 'Notifications are not available on this device or browser. The reminder is saved but will not alert you.'
        : blocked
            ? 'Notifications are blocked. Allow them in your browser or phone settings to be reminded.'
            : 'Notifications are off. Turn them on to be reminded.';
    return Padding(
      padding: const EdgeInsets.only(top: DmSpace.x1),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(DmRadius.md),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(DmSpace.x1_5),
          child: Row(
            children: <Widget>[
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: DmSpace.x1),
              Expanded(child: Text(text, style: theme.textTheme.labelMedium)),
              if (!unsupported && !blocked)
                TextButton(
                  key: const ValueKey<String>('enable-notifications'),
                  onPressed: onEnable,
                  child: const Text('Turn on'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
