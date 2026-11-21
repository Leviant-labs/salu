import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:salu_core/salu_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../assistant/assistant.dart';
import '../../providers.dart';
import '../onboarding/onboarding_screen.dart';
import 'connections_controller.dart';
import 'connections_screen.dart';

/// Settings: the honest state of each integration.
class SettingsScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final controller = ref.read(connectionsControllerProvider);
      if (!controller.loaded) {
        controller.load();
      }
    });
  }

  Future<void> _openConnections() async {
    final controller = ref.read(connectionsControllerProvider);
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ConnectionsScreen(controller: controller),
      ),
    );
  }

  Future<void> _disconnect(ConnectionsController controller) async {
    try {
      if (controller.activeId == EndpointProfile.reservedChatGptId) {
        await controller.disconnectChatGpt();
      } else {
        await controller.select(null);
      }
    } on SaluAssistantException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            'Disconnected on this device. Remote revocation could not be confirmed.',
          ),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = ref.watch(connectionsControllerProvider);
    final activeId = controller.activeId;
    final activeProfile = controller.activeProfile;
    final isChatGptActive = activeId == EndpointProfile.reservedChatGptId &&
        controller.chatGptConnected;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Planning profile'),
          subtitle: const Text(
            'Starting weight, goals, activity and food preferences',
          ),
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
              'Connect your ChatGPT account or a compatible API endpoint to estimate meals and help with planning. '
              'Only the information you choose to send is shared.',
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!controller.loaded)
                    const LinearProgressIndicator()
                  else if (isChatGptActive) ...[
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.auto_awesome_outlined),
                      title: Text('Active: ChatGPT plan'),
                      subtitle: Text('Eligible ChatGPT plan limits apply.'),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonal(
                          onPressed: _openConnections,
                          child: const Text('Manage AI connections'),
                        ),
                        OutlinedButton(
                          onPressed: () => _disconnect(controller),
                          child: const Text('Disconnect'),
                        ),
                        TextButton(
                          onPressed: () => launchUrl(
                            Uri.parse('https://chatgpt.com/settings/usage'),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: const Text('Manage usage'),
                        ),
                      ],
                    ),
                  ] else if (activeProfile != null) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.hub_outlined),
                      title: Text('Active: ${activeProfile.name}'),
                      subtitle: Text(
                        '${activeProfile.protocol.name} · ${activeProfile.apiRoot}'
                        '${activeProfile.modelId != null ? ' · ${activeProfile.modelId}' : ''}',
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonal(
                          onPressed: _openConnections,
                          child: const Text('Manage AI connections'),
                        ),
                        OutlinedButton(
                          onPressed: () => _disconnect(controller),
                          child: const Text('Disconnect'),
                        ),
                      ],
                    ),
                  ] else ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.cloud_off_outlined),
                      title: const Text('Not connected'),
                      subtitle: Text(
                        controller.profiles.isEmpty
                            ? 'Optional. Your diary and planner work offline without AI.'
                            : '${controller.profiles.length} saved endpoint${controller.profiles.length == 1 ? '' : 's'} · none selected',
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _openConnections,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: const Text('Manage AI connections'),
                    ),
                  ],
                ],
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
