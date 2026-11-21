import 'package:salu_core/salu_core.dart';

import 'local_document_store.dart';

final class OnboardingStore {
  const OnboardingStore(this.documents);

  static const _draftKey = 'onboarding-draft';
  static const _profileKey = 'planning-profile';

  final LocalDocumentStore documents;

  Future<OnboardingDraft> load() async {
    final record = await documents.read(_draftKey);
    if (record == null) return const OnboardingDraft();
    return OnboardingDraft.fromJson(record.data, revision: record.revision);
  }

  Future<bool> save(OnboardingDraft draft) async {
    draft.profile.validate();
    return documents.put(_draftKey, draft.revision, draft.toJson());
  }

  Future<bool> complete(OnboardingDraft draft) async {
    final committed = draft.profile.copyWith(onboarded: true)..validate();
    return documents.db.transaction(() async {
      final beforeDraft = await documents.read(_draftKey);
      if ((beforeDraft?.revision ?? 0) != draft.revision) return false;
      final beforeProfile = await documents.read(_profileKey);
      final saved = await documents.put(
        _profileKey,
        beforeProfile?.revision ?? 0,
        committed.toJson(),
      );
      if (!saved) return false;
      await documents.remove(_draftKey);
      return true;
    });
  }

  Future<void> skip() => documents.db.transaction(() async {
        final existing = await documents.read(_profileKey);
        final profile = existing == null
            ? const PlanningProfile(onboarded: true)
            : PlanningProfile.fromJson(existing.data).copyWith(onboarded: true);
        final saved = await documents.put(
          _profileKey,
          existing?.revision ?? 0,
          profile.toJson(),
        );
        if (!saved) {
          throw StateError('The profile changed while skipping onboarding');
        }
        await documents.remove(_draftKey);
      });
}
