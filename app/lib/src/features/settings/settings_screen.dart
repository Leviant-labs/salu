import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../assistant/assistant.dart';
import '../../providers.dart';
import '../onboarding/onboarding_screen.dart';

/// Settings: the honest state of each integration.
class SettingsScreen extends StatefulWidget {
  /// Creates the screen.
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<bool> _connection = saluAssistant.isConnected;

  Future<void> _connect() async {
    final key = await showDialog<String>(
      context: context,
      builder: (_) => const _KeyDialog(),
    );
    if (!mounted || key == null) return;
    await _update(() => saluAssistant.connect(key));
  }

  Future<void> _update(Future<void> Function() change) async {
    setState(() => _connection = _changeConnection(change));
  }

  Future<bool> _changeConnection(Future<void> Function() change) async {
    try {
      await change();
    } on SaluAssistantException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
    return saluAssistant.isConnected;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Planning profile'),
          subtitle: const Text(
              'Starting weight, goals, activity and food preferences'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push(OnboardingScreen.routeName),
        ),
        _Section(
          title: 'Your data',
          subtitle:
              'Records are stored in a local SQLite database on this device. '
              'There is no account and no backend that holds your diary.',
          children: const [
            _Row(
              icon: Icons.phone_iphone,
              title: 'On-device storage',
              detail: 'active',
            ),
            _Row(
              icon: Icons.file_download_outlined,
              title: 'CSV and full-archive export',
              detail: 'not built yet',
            ),
            _Row(
              icon: Icons.delete_outline,
              title: 'Delete all data',
              detail: 'not built yet',
            ),
          ],
        ),
        _Section(
          title: 'Salu assistant',
          subtitle:
              'Connect an OpenAI API key to estimate meals and assist with corrections '
              'and planning. Requests use your API project and may incur charges. '
              'A ChatGPT subscription does not cover API usage.',
          children: [
            FutureBuilder<bool>(
              future: _connection,
              builder: (context, snapshot) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key_outlined),
                title: Text(snapshot.data == true
                    ? 'OpenAI key saved'
                    : 'OpenAI API key'),
                subtitle: snapshot.hasError
                    ? const Text('Could not read secure storage')
                    : null,
                trailing: snapshot.connectionState != ConnectionState.done
                    ? const CircularProgressIndicator()
                    : TextButton(
                        onPressed: snapshot.data == true
                            ? () => _update(saluAssistant.disconnect)
                            : _connect,
                        child: Text(
                            snapshot.data == true ? 'Disconnect' : 'Connect'),
                      ),
              ),
            ),
          ],
        ),
        _Section(
          title: 'Health',
          subtitle: 'HealthKit on iOS, Health Connect on Android.',
          children: const [
            _Row(
              icon: Icons.favorite_border,
              title: 'Read weight and activity',
              detail: 'not implemented',
            ),
            _Row(
              icon: Icons.upload_outlined,
              title: 'Write confirmed nutrition',
              detail: 'not implemented',
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Text(
            'Salu 0.1.0',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _KeyDialog extends StatefulWidget {
  const _KeyDialog();

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _key = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Connect OpenAI'),
        content: TextField(
          controller: _key,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'OpenAI API key'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _key.text.trim()),
              child: const Text('Save key')),
        ],
      );
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(subtitle, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      trailing: Text(
        detail,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}
