import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'src/app.dart';
import 'src/media/managed_media_store.dart';
import 'src/providers.dart';

/// Composition root: the only place that decides which implementations the ports
/// get. Everything below it receives ports through Riverpod.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase(driftDatabase(name: 'salu'));
  final ids = RandomIdGenerator();
  final media = ManagedMediaStore(
    directory: getApplicationSupportDirectory,
    newId: ids.next,
  );

  await installBundledCatalogue(database);

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        idGeneratorProvider.overrideWithValue(ids),
        managedMediaStoreProvider.overrideWithValue(media),
      ],
      child: const _BootstrapGate(child: SaluApp()),
    ),
  );
}

/// Runs resumable reset and pending credential cleanup before exposing normal
/// app routes. If [DataResetService.resumeIfPending] fails, renders a Retry
/// screen rather than allowing access to partially reset data.
class _BootstrapGate extends ConsumerStatefulWidget {
  const _BootstrapGate({required this.child});

  final Widget child;

  @override
  ConsumerState<_BootstrapGate> createState() => _BootstrapGateState();
}

class _BootstrapGateState extends ConsumerState<_BootstrapGate> {
  late Future<void> _startup;

  @override
  void initState() {
    super.initState();
    _startup = _runStartupRecovery();
  }

  Future<void> _runStartupRecovery() async {
    await ref.read(dataResetServiceProvider).resumeIfPending();
    await ref.read(archiveServiceProvider).resumePendingCredentialCleanup();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _startup,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Could not finish clearing local data',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'A previous local data deletion was interrupted and '
                        'must finish before opening Salu.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () => setState(() {
                          _startup = _runStartupRecovery();
                        }),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return widget.child;
      },
    );
  }
}
