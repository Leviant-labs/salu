import 'package:salu_core/salu_core.dart';

/// UI wording for domain enums. Kept in the app so the core stays free of copy
/// that will later move into `arb` files for EN / pt-PT.
extension EntryChannelLabel on EntryChannel {
  /// Short label for a diary row.
  String get label => switch (this) {
    EntryChannel.manual => 'manual',
    EntryChannel.search => 'search',
    EntryChannel.barcode => 'barcode',
    EntryChannel.labelOcr => 'label',
    EntryChannel.mealPhoto => 'photo',
    EntryChannel.naturalLanguage => 'text',
    EntryChannel.plan => 'plan',
    EntryChannel.imported => 'imported',
  };
}
