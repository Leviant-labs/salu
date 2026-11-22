import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/onboarding/onboarding_screen.dart';
import '../providers.dart';
import '../theme/tactile_controls.dart';
import 'archive_service.dart';
import 'csv_export.dart';

/// Callback for choosing a save destination path. Returns `null` on cancel.
typedef PickSavePathCallback = Future<String?> Function({
  required String suggestedName,
  required String extension,
  required String label,
});

/// Callback for selecting an encrypted `.salu` archive file. Returns `null` on
/// cancel.
typedef PickArchiveBytesCallback = Future<Uint8List?> Function();

/// Callback for writing bytes to a chosen file path.
typedef WriteFileBytesCallback = Future<void> Function(
  String path,
  Uint8List bytes,
);

/// Manages encrypted backup, staged restore, plaintext CSV export, and
/// resumable local data deletion.
class DataTransferScreen extends ConsumerStatefulWidget {
  const DataTransferScreen({
    super.key,
    this.pickSavePath,
    this.pickArchiveBytes,
    this.writeBytes,
    this.onDataErased,
  });

  static const String routeName = '/settings/data';

  final PickSavePathCallback? pickSavePath;
  final PickArchiveBytesCallback? pickArchiveBytes;
  final WriteFileBytesCallback? writeBytes;
  final VoidCallback? onDataErased;

  @override
  ConsumerState<DataTransferScreen> createState() => _DataTransferScreenState();
}

class _DataTransferScreenState extends ConsumerState<DataTransferScreen> {
  bool _busy = false;

  Future<String?> _defaultPickSavePath({
    required String suggestedName,
    required String extension,
    required String label,
  }) async {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(label: label, extensions: <String>[extension]),
      ],
    );
    return location?.path;
  }

  Future<Uint8List?> _defaultPickArchiveBytes() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(label: 'Salu backup', extensions: <String>['salu']),
      ],
    );
    if (file == null) return null;
    return file.readAsBytes();
  }

  Future<void> _defaultWriteBytes(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes, flush: true);
  }

  Future<void> _handleBackup() async {
    final formResult = await showDialog<({String password, bool includeMedia})>(
      context: context,
      builder: (_) => const _BackupPasswordDialog(),
    );
    if (formResult == null || !mounted) return;

    final pickSave = widget.pickSavePath ?? _defaultPickSavePath;
    final savePath = await pickSave(
      suggestedName: 'salu-backup.salu',
      extension: 'salu',
      label: 'Salu encrypted backup',
    );
    if (savePath == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final bytes = await ref.read(archiveServiceProvider).export(
            password: formResult.password,
            includeMedia: formResult.includeMedia,
          );
      final writeFn = widget.writeBytes ?? _defaultWriteBytes;
      await writeFn(savePath, bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Encrypted backup saved.')),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleRestore() async {
    final pickBytes = widget.pickArchiveBytes ?? _defaultPickArchiveBytes;
    final encrypted = await pickBytes();
    if (encrypted == null || !mounted) return;

    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _RestorePasswordDialog(),
    );
    if (password == null || !mounted) return;

    setState(() => _busy = true);
    RestorePreview? preview;
    try {
      preview =
          await ref.read(archiveServiceProvider).inspect(encrypted, password);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open backup: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (preview == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _RestoreConfirmDialog(preview: preview!),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(archiveServiceProvider).restore(preview);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup restored.')),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleExportCsv() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export diary as CSV'),
        content: const Text(
          'CSV files are plaintext (unencrypted) and are not a full backup. '
          'They contain your diary nutrition rows only and omit photos, '
          'recipes, week plans, and edit history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    final pickSave = widget.pickSavePath ?? _defaultPickSavePath;
    final savePath = await pickSave(
      suggestedName: 'salu-diary.csv',
      extension: 'csv',
      label: 'CSV spreadsheet',
    );
    if (savePath == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final snapshot = await ref.read(userDataRepositoryProvider).snapshot();
      final csv = exportDiaryCsv(snapshot);
      final writeFn = widget.writeBytes ?? _defaultWriteBytes;
      await writeFn(savePath, Uint8List.fromList(utf8.encode(csv)));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSV exported.')),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('CSV export failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleErase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete local data?'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This permanently deletes all local Salu data on this device:',
              ),
              SizedBox(height: 8),
              Text(
                '• Diary entries, photo meals, and edit history\n'
                '• Recipes, week plans, and planning profile\n'
                '• Managed meal and label photos\n'
                '• Local AI connections and saved credentials',
              ),
              SizedBox(height: 12),
              Text(
                'Limitations: this does not delete backups or CSV files you '
                'exported, remote AI provider logs, OS device backups, or '
                'health stores, and does not provide flash-forensics erasure '
                'guarantees.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete local data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(dataResetServiceProvider).erase();
      if (!mounted) return;
      if (widget.onDataErased != null) {
        widget.onDataErased!();
      } else {
        context.go('${OnboardingScreen.routeName}?first=1');
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your data')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Encrypted backup'),
            subtitle: const Text(
              'Save a password-protected .salu archive of your diary, plans, '
              'recipes, and optional photos.',
            ),
            onTap: _busy ? null : _handleBackup,
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Restore backup'),
            subtitle: const Text(
              'Inspect and restore a .salu archive, replacing local data on '
              'this device.',
            ),
            onTap: _busy ? null : _handleRestore,
          ),
          ListTile(
            leading: const Icon(Icons.table_chart_outlined),
            title: const Text('Export CSV'),
            subtitle: const Text(
              'Plaintext spreadsheet of diary nutrition rows. Not a full backup.',
            ),
            onTap: _busy ? null : _handleExportCsv,
          ),
          const Divider(height: 32),
          ListTile(
            leading: Icon(
              Icons.delete_forever_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              'Delete local data',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: const Text(
              'Erase diary, photos, plans, recipes, and local AI credentials '
              'from this device.',
            ),
            onTap: _busy ? null : _handleErase,
          ),
        ],
      ),
    );
  }
}

class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog();

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _includeMedia = true;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordController.text;
    final confirm = _confirmController.text;
    if (password.length < 12) {
      setState(() => _error = 'Password must be at least 12 characters.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    Navigator.of(context)
        .pop((password: password, includeMedia: _includeMedia));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create encrypted backup'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose a password of at least 12 characters. If you forget '
              'this password, the archive cannot be recovered.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('backup-password-field'),
              controller: _passwordController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Backup password'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('backup-confirm-field'),
              controller: _confirmController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include photos'),
              subtitle: Text(
                _includeMedia
                    ? 'Includes meal and label photos'
                    : 'Records only (smaller file)',
              ),
              trailing: SaluTactileToggle(
                value: _includeMedia,
                semanticLabel: 'Include photos',
                onChanged: (value) => setState(() => _includeMedia = value),
              ),
              onTap: () => setState(() => _includeMedia = !_includeMedia),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        SaluTactileButton(
          onPressed: _submit,
          child: const Text('Create backup'),
        ),
      ],
    );
  }
}

class _RestorePasswordDialog extends StatefulWidget {
  const _RestorePasswordDialog();

  @override
  State<_RestorePasswordDialog> createState() => _RestorePasswordDialogState();
}

class _RestorePasswordDialogState extends State<_RestorePasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter backup password'),
      content: TextField(
        key: const Key('restore-password-field'),
        controller: _controller,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'Backup password'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Inspect backup'),
        ),
      ],
    );
  }
}

class _RestoreConfirmDialog extends StatelessWidget {
  const _RestoreConfirmDialog({required this.preview});

  final RestorePreview preview;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Replace local data?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Archive contents:\n'
              '• ${preview.mealCount} meals\n'
              '• ${preview.entryCount} legacy diary entries\n'
              '• ${preview.documentCount} profile/plan documents\n'
              '• ${preview.mediaOmitted ? 'Photos omitted' : '${preview.mediaCount} photos'}',
            ),
            const SizedBox(height: 12),
            const Text(
              'Restoring replaces all local diary records, plans, recipes, '
              'and photos on this device. Food catalogues must be reinstalled '
              'for search if not present, and AI connections must be '
              'reconnected after restore.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Replace local data'),
        ),
      ],
    );
  }
}
