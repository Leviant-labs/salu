import 'package:flutter/material.dart';

/// Settings: the honest state of each integration.
class SettingsScreen extends StatelessWidget {
  /// Creates the screen.
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
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
          title: 'Connected services',
          subtitle:
              'Optional. Every core workflow works with nothing connected, and '
              'nothing is uploaded unless you choose a provider and a purpose.',
          children: const [
            _Row(
              icon: Icons.auto_awesome_outlined,
              title: 'ChatGPT plan (label OCR, meal photos)',
              detail: 'not implemented',
            ),
            _Row(
              icon: Icons.key_outlined,
              title: 'Your own API key',
              detail: 'not implemented',
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
            'Salu 0.1.0 · scaffold',
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
