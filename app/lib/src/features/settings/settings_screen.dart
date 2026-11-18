import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

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
    await _update(() async {
      await saluAssistant.signInWithChatGpt();
      const storage = FlutterSecureStorage();
      if (await storage.read(key: 'salu.chatgpt.welcome') != 'shown' &&
          mounted) {
        await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('You’re using your ChatGPT plan'),
                  content: const Text(
                      'Eligible AI requests in Salu use your ChatGPT plan or credits. You can review and manage your usage in ChatGPT settings.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Got it'))
                  ],
                ));
        await storage.write(key: 'salu.chatgpt.welcome', value: 'shown');
      }
    });
  }

  Future<void> _update(Future<void> Function() change,
      {bool signingOut = false}) async {
    setState(() {
      _connection = _changeConnection(change, signingOut: signingOut);
    });
  }

  Future<bool> _changeConnection(Future<void> Function() change,
      {required bool signingOut}) async {
    try {
      await change();
    } on SaluAssistantException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(signingOut
              ? 'Signed out on this device. Remote revocation could not be confirmed; manage access in ChatGPT settings.'
              : 'Could not connect ChatGPT. Check your browser and internet connection, and make sure plan permission was granted.'),
        ));
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
              'Connect your ChatGPT account to estimate meals and help with planning. '
              'Your eligible ChatGPT plan and its usage limits apply. Only the information you choose to send is shared.',
          children: [
            FutureBuilder<bool>(
              future: _connection,
              builder: (context, snapshot) => Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (snapshot.connectionState != ConnectionState.done)
                        const Row(children: [
                          SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 12),
                          Expanded(
                              child: Text('Connecting… check your browser'))
                        ])
                      else if (snapshot.data == true) ...[
                        const ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.auto_awesome_outlined),
                            title: Text('Using ChatGPT plan')),
                        Wrap(spacing: 8, children: [
                          OutlinedButton(
                              onPressed: () => _update(saluAssistant.disconnect,
                                  signingOut: true),
                              child: const Text('Disconnect')),
                          TextButton(
                              onPressed: () => launchUrl(
                                  Uri.parse(
                                      'https://chatgpt.com/settings/usage'),
                                  mode: LaunchMode.externalApplication),
                              child: const Text('Manage usage')),
                        ]),
                      ] else ...[
                        if (snapshot.hasError)
                          const Text('Could not read secure storage.'),
                        FilledButton.icon(
                            onPressed: _connect,
                            icon: const Icon(Icons.auto_awesome_outlined),
                            label: const Text('Continue with ChatGPT')),
                      ],
                    ]),
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
