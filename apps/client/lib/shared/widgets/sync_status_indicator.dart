import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/daymark_theme.dart';
import '../../core/theme/daymark_tokens.dart';
import '../../services/sync_status.dart';

/// Compact sync indicator for the app header: a coloured dot, an optional text
/// label, a tooltip, and a screen-reader description. The label is shown on wide
/// screens so the state is never conveyed by colour alone.
///
///   grey   Local only   - no backend configured (the state in this release)
///   green  Synced       - backend acknowledged everything
///   yellow Syncing      - request in progress
///   red    Offline      - backend unavailable, failed, or changes waiting
class SyncStatusIndicator extends StatelessWidget {
  const SyncStatusIndicator({super.key, this.showLabel = false});

  final bool showLabel;

  static Color colorFor(BuildContext context, SyncStatus status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case SyncStatus.localOnly:
        return scheme.onSurfaceVariant;
      case SyncStatus.synced:
        return context.dm.success;
      case SyncStatus.syncing:
        return DmColors.warningDark; // amber/yellow in both themes
      case SyncStatus.offline:
        return scheme.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (BuildContext context, Widget? _) {
        final snapshot = sync.snapshot;
        final color = colorFor(context, snapshot.status);
        final scheme = Theme.of(context).colorScheme;
        return Semantics(
          container: true,
          button: true,
          label: 'Sync status: ${snapshot.description}',
          excludeSemantics: true,
          child: Tooltip(
            message: snapshot.description,
            child: InkWell(
              borderRadius: BorderRadius.circular(DmRadius.full),
              onTap: () {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(snapshot.description)));
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DmSpace.x1_5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        key: const ValueKey<String>('sync-dot'),
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.onSurface.withValues(alpha: 0.25)),
                        ),
                      ),
                      if (showLabel) ...<Widget>[
                        const SizedBox(width: DmSpace.x1),
                        Text(snapshot.label, style: Theme.of(context).textTheme.labelMedium),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
