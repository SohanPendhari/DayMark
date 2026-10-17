enum TaskPriority {
  low('Low'),
  medium('Medium'),
  high('High');

  const TaskPriority(this.label);

  final String label;

  /// Storage helper: unknown values fall back to [medium] instead of throwing.
  static TaskPriority fromIndex(int index) =>
      (index >= 0 && index < TaskPriority.values.length)
          ? TaskPriority.values[index]
          : TaskPriority.medium;
}
