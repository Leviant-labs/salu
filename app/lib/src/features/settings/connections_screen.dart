import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../assistant/assistant.dart';
import '../../assistant/model_discovery.dart';
import '../../theme/tactile_controls.dart';
import 'connections_controller.dart';

/// Manage AI connections: ChatGPT plan sign-in and named API endpoint profiles.
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({
    required this.controller,
    this.onDiscoverModels,
    this.onTestConnection,
    this.onSignInChatGpt,
    this.onSignOutChatGpt,
    super.key,
  });

  final ConnectionsController controller;
  final Future<List<DiscoveredModel>> Function(String profileId)?
      onDiscoverModels;
  final Future<void> Function(String id)? onTestConnection;
  final Future<void> Function()? onSignInChatGpt;
  final Future<void> Function()? onSignOutChatGpt;

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  final Set<String> _localBusyIds = <String>{};
  final Map<String, String> _localErrors = <String, String>{};
  final Map<String, List<DiscoveredModel>> _localDiscovered =
      <String, List<DiscoveredModel>>{};

  @override
  void initState() {
    super.initState();
    if (!widget.controller.loaded) {
      widget.controller.load();
    }
  }

  bool _isBusy(String id) =>
      _localBusyIds.contains(id) || widget.controller.isBusy(id);

  bool get _anyBusy => _localBusyIds.isNotEmpty || widget.controller.anyBusy;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _select(String? id) async {
    try {
      await widget.controller.select(id);
    } on SaluAssistantException catch (error) {
      _showSnack(error.message);
    } on Object {
      _showSnack('Could not update the active connection.');
    }
  }

  Future<void> _discover(String profileId) async {
    setState(() {
      _localBusyIds.add(profileId);
      _localErrors.remove(profileId);
    });
    try {
      final callback = widget.onDiscoverModels;
      final models = callback != null
          ? await callback(profileId)
          : await widget.controller.discover(profileId);
      if (!mounted) return;
      setState(() {
        _localDiscovered[profileId] = models;
      });
    } on SaluAssistantException catch (error) {
      if (mounted) {
        setState(() => _localErrors[profileId] = error.message);
        _showSnack(error.message);
      }
    } on Object {
      if (mounted) {
        const message =
            'Model discovery failed. Check your endpoint and credentials, or enter a model ID manually.';
        setState(() => _localErrors[profileId] = message);
        _showSnack(message);
      }
    } finally {
      if (mounted) {
        setState(() => _localBusyIds.remove(profileId));
      }
    }
  }

  Future<void> _testConnection(String id) async {
    setState(() {
      _localBusyIds.add(id);
      _localErrors.remove(id);
    });
    try {
      final callback = widget.onTestConnection;
      if (callback != null) {
        await callback(id);
      } else {
        await widget.controller.testConnection(id);
      }
    } on SaluAssistantException catch (error) {
      if (mounted) {
        setState(() => _localErrors[id] = error.message);
        _showSnack(error.message);
      }
    } on Object {
      if (mounted) {
        const message =
            'Connection check failed. Generation and image input are not verified.';
        setState(() => _localErrors[id] = message);
        _showSnack(message);
      }
    } finally {
      if (mounted) {
        setState(() => _localBusyIds.remove(id));
      }
    }
  }

  Future<void> _signInChatGpt() async {
    const id = EndpointProfile.reservedChatGptId;
    setState(() {
      _localBusyIds.add(id);
      _localErrors.remove(id);
    });
    try {
      final callback = widget.onSignInChatGpt;
      if (callback != null) {
        await callback();
      } else {
        await widget.controller.connectChatGpt();
      }
    } on SaluAssistantException catch (error) {
      _showSnack(error.message);
    } on Object {
      _showSnack(
        'Could not connect ChatGPT. Check your browser and internet connection, and make sure plan permission was granted.',
      );
    } finally {
      if (mounted) {
        setState(() => _localBusyIds.remove(id));
      }
    }
  }

  Future<void> _disconnectChatGpt() async {
    const id = EndpointProfile.reservedChatGptId;
    setState(() {
      _localBusyIds.add(id);
      _localErrors.remove(id);
    });
    try {
      final callback = widget.onSignOutChatGpt;
      if (callback != null) {
        await callback();
      } else {
        await widget.controller.disconnectChatGpt();
      }
    } on SaluAssistantException catch (error) {
      _showSnack(error.message);
    } on Object {
      _showSnack(
        'Signed out on this device. Remote revocation could not be confirmed; manage access in ChatGPT settings.',
      );
    } finally {
      if (mounted) {
        setState(() => _localBusyIds.remove(id));
      }
    }
  }

  Future<void> _openEditor([EndpointProfile? existing]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _EndpointProfileEditorScreen(
          controller: widget.controller,
          existing: existing,
          onDiscoverModels: widget.onDiscoverModels,
        ),
      ),
    );
  }

  Future<void> _removeProfile(EndpointProfile profile) async {
    try {
      await widget.controller.removeProfile(profile.id);
      if (mounted) {
        setState(() {
          _localErrors.remove(profile.id);
          _localDiscovered.remove(profile.id);
        });
      }
    } on Object {
      _showSnack('Could not remove ${profile.name}. Try again.');
    }
  }

  Future<void> _pickDiscoveredModel(
    EndpointProfile profile,
    DiscoveredModel model,
  ) async {
    try {
      await widget.controller.saveProfile(profile.copyWith(modelId: model.id));
    } on Object {
      _showSnack('Could not save selected model.');
    }
  }

  String _activeSummary(ConnectionsController controller) {
    final activeId = controller.activeId;
    if (activeId == null) {
      return 'No active connection';
    }
    if (activeId == EndpointProfile.reservedChatGptId) {
      return controller.chatGptConnected
          ? 'Active: ChatGPT'
          : 'Active: ChatGPT (not signed in)';
    }
    final activeProfile = controller.activeProfile;
    if (activeProfile == null) {
      return 'No active connection';
    }
    return 'Active: ${activeProfile.name}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final activeId = controller.activeId;
        final chatGptStatus =
            controller.statusFor(EndpointProfile.reservedChatGptId);
        final chatGptError = _localErrors[EndpointProfile.reservedChatGptId];
        final chatGptBusy = _isBusy(EndpointProfile.reservedChatGptId);

        return Scaffold(
          appBar: AppBar(title: const Text('AI connections')),
          body: Column(
            children: [
              if (_anyBusy) const LinearProgressIndicator(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _activeSummary(controller),
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'AI features are optional. Only the selected connection is used when you explicitly ask for a meal estimate, label scan, correction, or suggestion. There is no automatic fallback between connections.',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('ChatGPT account', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.auto_awesome_outlined),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'ChatGPT',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                                if (activeId ==
                                    EndpointProfile.reservedChatGptId)
                                  const Chip(label: Text('Active')),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Eligible ChatGPT plan limits apply. Credentials stay in secure device storage.',
                            ),
                            const SizedBox(height: 8),
                            Text(
                              controller.chatGptConnected
                                  ? 'Session: Signed in'
                                  : 'Session: Not signed in',
                              style: theme.textTheme.bodySmall,
                            ),
                            if (chatGptError != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                chatGptError,
                                style:
                                    TextStyle(color: theme.colorScheme.error),
                              ),
                            ] else if (chatGptStatus.outcome !=
                                ConnectionCheckOutcome.untested) ...[
                              const SizedBox(height: 4),
                              Text(
                                chatGptStatus.message,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (!controller.chatGptConnected)
                                  FilledButton.icon(
                                    onPressed:
                                        chatGptBusy ? null : _signInChatGpt,
                                    icon: const Icon(Icons.login),
                                    label: const Text('Continue with ChatGPT'),
                                  )
                                else ...[
                                  if (activeId !=
                                      EndpointProfile.reservedChatGptId)
                                    FilledButton(
                                      onPressed: chatGptBusy
                                          ? null
                                          : () => _select(EndpointProfile
                                              .reservedChatGptId),
                                      child: const Text('Select'),
                                    )
                                  else
                                    OutlinedButton(
                                      onPressed: chatGptBusy
                                          ? null
                                          : () => _select(null),
                                      child: const Text('Deactivate'),
                                    ),
                                  OutlinedButton(
                                    onPressed: chatGptBusy
                                        ? null
                                        : () => _testConnection(
                                            EndpointProfile.reservedChatGptId),
                                    child: const Text('Test connection'),
                                  ),
                                  OutlinedButton(
                                    onPressed:
                                        chatGptBusy ? null : _disconnectChatGpt,
                                    child: const Text('Disconnect'),
                                  ),
                                  TextButton(
                                    onPressed: () => launchUrl(
                                      Uri.parse(
                                          'https://chatgpt.com/settings/usage'),
                                      mode: LaunchMode.externalApplication,
                                    ),
                                    child: const Text('Manage usage'),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'API endpoints',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: () => _openEditor(),
                          icon: const Icon(Icons.add),
                          label: const Text('Add endpoint'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Connect an OpenAI-compatible or Anthropic-compatible API endpoint with your own API key. Standard provider API billing may apply.',
                    ),
                    const SizedBox(height: 8),
                    if (controller.profiles.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No API endpoints configured yet.'),
                        ),
                      )
                    else
                      for (final profile in controller.profiles)
                        _ProfileCard(
                          profile: profile,
                          isActive: activeId == profile.id,
                          busy: _isBusy(profile.id),
                          hasCredentialFuture:
                              controller.hasCredential(profile.id),
                          status: controller.statusFor(profile.id),
                          localError: _localErrors[profile.id],
                          discoveredModels: _localDiscovered[profile.id] ??
                              controller.discoveredModelsFor(profile.id),
                          onSelect: () => _select(
                              activeId == profile.id ? null : profile.id),
                          onDiscover: () => _discover(profile.id),
                          onTest: () => _testConnection(profile.id),
                          onEdit: () => _openEditor(profile),
                          onRemove: () => _removeProfile(profile),
                          onSelectModel: (model) =>
                              _pickDiscoveredModel(profile, model),
                        ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.isActive,
    required this.busy,
    required this.hasCredentialFuture,
    required this.status,
    required this.localError,
    required this.discoveredModels,
    required this.onSelect,
    required this.onDiscover,
    required this.onTest,
    required this.onEdit,
    required this.onRemove,
    required this.onSelectModel,
  });

  final EndpointProfile profile;
  final bool isActive;
  final bool busy;
  final Future<bool> hasCredentialFuture;
  final ConnectionStatus status;
  final String? localError;
  final List<DiscoveredModel> discoveredModels;
  final VoidCallback onSelect;
  final VoidCallback onDiscover;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final ValueChanged<DiscoveredModel> onSelectModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorMessage = localError ??
        (status.outcome == ConnectionCheckOutcome.unavailable
            ? status.message
            : null);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    profile.name,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (isActive) const Chip(label: Text('Active')),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_protocolLabel(profile.protocol)} · ${profile.apiRoot}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Model: ${profile.modelId ?? 'None selected'}',
              style: theme.textTheme.bodyMedium,
            ),
            FutureBuilder<bool>(
              future: hasCredentialFuture,
              builder: (context, snapshot) {
                final text = switch (snapshot.data) {
                  true => 'API key: Saved in secure storage (hidden)',
                  false => 'API key: Missing (edit to re-enter)',
                  null => 'API key: Checking…',
                };
                return Text(text, style: theme.textTheme.bodySmall);
              },
            ),
            const SizedBox(height: 6),
            if (errorMessage != null) ...[
              Text(
                errorMessage,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              if (profile.discovery != ModelDiscoveryMode.manual)
                TextButton(
                  onPressed: busy ? null : onDiscover,
                  child: const Text('Retry discovery'),
                ),
            ] else
              Text(
                'Status: ${status.message}',
                style: theme.textTheme.bodySmall,
              ),
            if (discoveredModels.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Discovered models', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final model in discoveredModels)
                    ChoiceChip(
                      label: Text(model.name),
                      selected: profile.modelId == model.id,
                      onSelected: busy ? null : (_) => onSelectModel(model),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isActive)
                  OutlinedButton(
                    onPressed: busy ? null : onSelect,
                    child: const Text('Deactivate'),
                  )
                else
                  FilledButton(
                    onPressed: busy ? null : onSelect,
                    child: const Text('Select'),
                  ),
                if (profile.discovery != ModelDiscoveryMode.manual)
                  OutlinedButton(
                    onPressed: busy ? null : onDiscover,
                    child: const Text('Discover models'),
                  ),
                OutlinedButton(
                  onPressed: busy ? null : onTest,
                  child: const Text('Test connection'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : onEdit,
                  child: const Text('Edit'),
                ),
                TextButton(
                  onPressed: busy ? null : onRemove,
                  child: const Text('Remove'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EndpointProfileEditorScreen extends StatefulWidget {
  const _EndpointProfileEditorScreen({
    required this.controller,
    this.existing,
    this.onDiscoverModels,
  });

  final ConnectionsController controller;
  final EndpointProfile? existing;
  final Future<List<DiscoveredModel>> Function(String profileId)?
      onDiscoverModels;

  @override
  State<_EndpointProfileEditorScreen> createState() =>
      _EndpointProfileEditorScreenState();
}

class _EndpointProfileEditorScreenState
    extends State<_EndpointProfileEditorScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _apiRoot = TextEditingController(
    text: widget.existing?.apiRoot.toString() ?? 'https://api.openai.com/v1',
  );
  // Saved API keys are never prefilled or displayed.
  final _apiKey = TextEditingController();
  late final _modelId =
      TextEditingController(text: widget.existing?.modelId ?? '');

  late EndpointProtocol _protocol =
      widget.existing?.protocol ?? EndpointProtocol.openaiChat;
  late ModelDiscoveryMode _discovery =
      widget.existing?.discovery ?? ModelDiscoveryMode.models;
  late bool _allowInsecureLocal = widget.existing?.allowInsecureLocal ?? false;

  bool _saving = false;
  bool _discovering = false;
  String? _error;
  List<DiscoveredModel> _discovered = const <DiscoveredModel>[];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _discovered = widget.controller.discoveredModelsFor(existing.id);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _apiRoot.dispose();
    _apiKey.dispose();
    _modelId.dispose();
    super.dispose();
  }

  bool get _destinationChanged {
    final existing = widget.existing;
    if (existing == null) return false;
    if (_protocol != existing.protocol) return true;
    final parsed = Uri.tryParse(_apiRoot.text.trim());
    if (parsed == null) return true;
    return parsed.scheme != existing.apiRoot.scheme ||
        parsed.host != existing.apiRoot.host ||
        parsed.port != existing.apiRoot.port;
  }

  EndpointProfile _buildCandidate({required String id}) {
    final existing = widget.existing;
    final modelText = _modelId.text.trim();
    return EndpointProfile(
      id: id,
      name: _name.text.trim(),
      protocol: _protocol,
      apiRoot: Uri.parse(_apiRoot.text.trim()),
      credentialRef: existing?.credentialRef ?? 'salu.endpoint.$id.1',
      modelId: modelText.isEmpty ? null : modelText,
      discovery: _discovery,
      allowInsecureLocal: _allowInsecureLocal,
      imageInput: existing?.imageInput,
    );
  }

  Future<void> _save() async {
    if (_saving || _discovering) return;
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;

    final existing = widget.existing;
    final rawKey = _apiKey.text.trim();
    if (existing == null && rawKey.isEmpty) {
      setState(() => _error = 'Enter an API key for this endpoint.');
      return;
    }
    if (existing != null && _destinationChanged && rawKey.isEmpty) {
      setState(
        () => _error =
            'Changing the protocol or endpoint origin requires re-entering the API key.',
      );
      return;
    }

    final id = existing?.id ??
        'ep_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final EndpointProfile candidate;
    try {
      candidate = _buildCandidate(id: id);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    } on ArgumentError catch (error) {
      setState(() =>
          _error = error.message?.toString() ?? 'Invalid endpoint settings.');
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.controller.saveProfile(
        candidate,
        newKey: rawKey.isEmpty ? null : rawKey,
      );
      _apiKey.clear();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on SaluAssistantException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Could not save this endpoint. Any existing connection is unchanged.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _discoverInEditor() async {
    final existing = widget.existing;
    if (existing == null || _saving || _discovering) return;
    if (_destinationChanged ||
        _apiKey.text.trim().isNotEmpty ||
        _discovery != existing.discovery ||
        _allowInsecureLocal != existing.allowInsecureLocal) {
      setState(() => _error =
          'Save your endpoint changes first, then tap Discover models.');
      return;
    }
    setState(() {
      _discovering = true;
      _error = null;
    });
    try {
      final callback = widget.onDiscoverModels;
      final models = callback != null
          ? await callback(existing.id)
          : await widget.controller.discover(existing.id);
      if (mounted) {
        setState(() => _discovered = models);
      }
    } on SaluAssistantException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Model discovery failed. You can retry or enter a model ID manually.',
        );
      }
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  String? _validateApiRoot(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return 'Enter an API root URL.';
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      return 'Enter a valid URL with a host.';
    }
    if (uri.userInfo.isNotEmpty || uri.authority.contains('@')) {
      return 'URL must not contain credentials.';
    }
    if (uri.hasQuery || uri.hasFragment) {
      return 'URL must not contain query parameters or fragments.';
    }
    if (uri.scheme == 'https') return null;
    if (uri.scheme == 'http' && _allowInsecureLocal) return null;
    return 'Use https://, or enable "Allow local network HTTP" for loopback/private addresses.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existing = widget.existing;
    final destinationChanged = _destinationChanged;

    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'Add endpoint' : 'Edit endpoint'),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            if (_error case final error?) ...[
              Material(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    error,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _name,
              enabled: !_saving,
              maxLength: EndpointProfile.maxNameLength,
              decoration: const InputDecoration(
                labelText: 'Endpoint name',
                hintText: 'e.g. OpenAI, Anthropic, Local Ollama',
                counterText: '',
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a display name.'
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<EndpointProtocol>(
              initialValue: _protocol,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Protocol'),
              items: [
                for (final protocol in EndpointProtocol.values)
                  DropdownMenuItem(
                    value: protocol,
                    child: Text(_protocolLabel(protocol)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _protocol = value);
                      }
                    },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _apiRoot,
              enabled: !_saving,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'API root URL',
                hintText: 'https://api.openai.com/v1',
              ),
              onChanged: (_) => setState(() {}),
              validator: _validateApiRoot,
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow local network HTTP'),
              subtitle: const Text(
                'Permits http:// only for loopback and private network addresses. Public HTTP stays blocked.',
              ),
              trailing: SaluTactileToggle(
                value: _allowInsecureLocal,
                semanticLabel: 'Allow local network HTTP',
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _allowInsecureLocal = value),
              ),
              onTap: _saving
                  ? null
                  : () => setState(
                        () => _allowInsecureLocal = !_allowInsecureLocal,
                      ),
            ),
            if (destinationChanged) ...[
              const SizedBox(height: 8),
              Material(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Changing the protocol or endpoint origin requires re-entering the API key before saving.',
                    style: TextStyle(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _apiKey,
              enabled: !_saving,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: existing == null
                    ? 'API key'
                    : 'New API key (optional unless endpoint changed)',
                helperText: existing == null
                    ? 'Stored in secure device storage and never displayed again.'
                    : 'Existing key is hidden. Leave blank to keep it.',
              ),
              validator: (value) {
                final trimmed = value?.trim() ?? '';
                if (existing == null && trimmed.isEmpty) {
                  return 'Enter an API key.';
                }
                if (existing != null && destinationChanged && trimmed.isEmpty) {
                  return 'Re-enter the API key for the new endpoint.';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ModelDiscoveryMode>(
              initialValue: _discovery,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Model discovery'),
              items: [
                for (final mode in ModelDiscoveryMode.values)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(_discoveryLabel(mode)),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _discovery = value);
                      }
                    },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _modelId,
              enabled: !_saving,
              maxLength: EndpointProfile.maxModelIdLength,
              decoration: const InputDecoration(
                labelText: 'Model ID',
                hintText: 'e.g. gpt-4.1-mini or claude-sonnet-4-5',
                counterText: '',
              ),
            ),
            if (existing != null &&
                _discovery != ModelDiscoveryMode.manual) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed:
                        _saving || _discovering ? null : _discoverInEditor,
                    child: Text(
                      _discovering ? 'Discovering…' : 'Discover models',
                    ),
                  ),
                ],
              ),
            ],
            if (_discovered.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final model in _discovered)
                    ActionChip(
                      label: Text(model.name),
                      onPressed: _saving
                          ? null
                          : () => setState(() => _modelId.text = model.id),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            const Text(
              'Saving stores your endpoint configuration and key locally. It does not send test prompts or verify generation.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _protocolLabel(EndpointProtocol protocol) => switch (protocol) {
      EndpointProtocol.openaiChat => 'OpenAI Chat Completions',
      EndpointProtocol.openaiResponses => 'OpenAI Responses',
      EndpointProtocol.anthropicMessages => 'Anthropic Messages',
    };

String _discoveryLabel(ModelDiscoveryMode mode) => switch (mode) {
      ModelDiscoveryMode.models => 'Automatic (GET /models)',
      ModelDiscoveryMode.catalogue => 'Catalogue (GET /catalogue)',
      ModelDiscoveryMode.manual => 'Manual model ID',
    };
