import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_data/salu_data.dart';

import 'app.dart';
import 'features/startup/startup_screen.dart';
import 'providers.dart';

/// Manages recoverable database opening and startup initialization.
class BootstrapController extends ChangeNotifier {
  BootstrapController({
    required Future<AppDatabase> Function() openDatabase,
    required Future<void> Function(AppDatabase) initialize,
  })  : _openDatabase = openDatabase,
        _initialize = initialize;

  final Future<AppDatabase> Function() _openDatabase;
  final Future<void> Function(AppDatabase) _initialize;

  bool _busy = false;
  String? _error;
  AppDatabase? _database;
  bool _disposed = false;
  bool _closedOwned = false;

  /// Whether a startup attempt is currently in progress.
  bool get busy => _busy;

  /// The last startup error message, if the most recent attempt failed.
  String? get error => _error;

  /// The opened and initialized database, once ready.
  AppDatabase? get database => _database;

  /// Starts (or retries) opening and initializing the database.
  ///
  /// Concurrent calls while [busy] or after [database] is ready are ignored.
  Future<void> start() async {
    if (_busy || _database != null || _disposed) return;
    _busy = true;
    _error = null;
    _safeNotify();

    AppDatabase? opened;
    try {
      opened = await _openDatabase();
      if (_disposed) {
        await _closeQuietly(opened);
        return;
      }
      await _initialize(opened);
      if (_disposed) {
        await _closeQuietly(opened);
        return;
      }
      _database = opened;
      _busy = false;
      _error = null;
      _safeNotify();
    } catch (e) {
      if (opened != null) {
        await _closeQuietly(opened);
      }
      if (_disposed) return;
      _busy = false;
      _error = e.toString();
      _safeNotify();
    }
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _closeQuietly(AppDatabase db) async {
    try {
      await db.close();
    } catch (_) {
      // Ignore close errors on already-failed or already-closed instances.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final db = _database;
    _database = null;
    if (db != null && !_closedOwned) {
      _closedOwned = true;
      unawaited(_closeQuietly(db));
    }
    super.dispose();
  }
}

/// Root widget that renders [StartupScreen] until [BootstrapController] opens
/// and initializes the database, then mounts [ProviderScope] and [child].
class BootstrapApp extends StatefulWidget {
  const BootstrapApp({
    super.key,
    required this.openDatabase,
    required this.initialize,
    this.overrides = const [],
    this.child = const SaluApp(),
  });

  final Future<AppDatabase> Function() openDatabase;
  final Future<void> Function(AppDatabase) initialize;
  final List<Override> overrides;
  final Widget child;

  @override
  State<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<BootstrapApp> {
  late final BootstrapController _controller;

  @override
  void initState() {
    super.initState();
    _controller = BootstrapController(
      openDatabase: widget.openDatabase,
      initialize: widget.initialize,
    );
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final db = _controller.database;
        if (db == null) {
          return MaterialApp(
            title: 'Salu',
            debugShowCheckedModeBanner: false,
            theme: saluTheme(Brightness.light),
            darkTheme: saluTheme(Brightness.dark),
            home: StartupScreen(
              busy: _controller.busy,
              error: _controller.error,
              onRetry: _controller.start,
            ),
          );
        }
        return ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            ...widget.overrides,
          ],
          child: widget.child,
        );
      },
    );
  }
}
