import 'dart:io';

import '../platform_configuration.dart';

Future<void> main() async {
  await _testMissingIosKeys();
  await _testValidFixture();
  await _testReviewedBackupRulesPass();
  await _testPreviewBundleIdPasses();
  await _testMissingInternetPermission();
  await _testMissingCameraPermission();
  await _testMissingAllowBackupExclusion();
  await _testInvalidBundleIds();
  await _testMissingIosBundleId();
  stdout.writeln('ok: all verify_platforms_test assertions passed');
}

Future<void> _testMissingIosKeys() async {
  final root = await Directory.systemTemp.createTemp('salu-platform-test-');
  try {
    await Directory('${root.path}/ios/Runner').create(recursive: true);
    await File(
      '${root.path}/ios/Runner/Info.plist',
    ).writeAsString('<plist><dict/></plist>');
    final errors = await platformConfigurationErrors(root);
    assert(errors.any((e) => e.contains('NSCameraUsageDescription')));
    assert(errors.any((e) => e.contains('NSPhotoLibraryUsageDescription')));
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> _testValidFixture() async {
  final root = await _createValidFixture();
  try {
    final errors = await platformConfigurationErrors(root);
    assert(errors.isEmpty, 'Expected no errors, got: $errors');
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> _testMissingInternetPermission() async {
  final root = await _createValidFixture(includeInternet: false);
  try {
    final errors = await platformConfigurationErrors(root);
    assert(
      errors.any((e) => e.contains('android.permission.INTERNET')),
      'Expected missing INTERNET error, got: $errors',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> _testMissingCameraPermission() async {
  final root = await _createValidFixture(includeCamera: false);
  try {
    final errors = await platformConfigurationErrors(root);
    assert(
      errors.any((e) => e.contains('android.permission.CAMERA')),
      'Expected missing CAMERA error, got: $errors',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> _testMissingAllowBackupExclusion() async {
  final rootOmitted = await _createValidFixture(allowBackupValue: null);
  try {
    final errors = await platformConfigurationErrors(rootOmitted);
    assert(
      errors.any((e) => e.contains('android:allowBackup="false"')),
      'Expected allowBackup exclusion error when omitted, got: $errors',
    );
  } finally {
    await rootOmitted.delete(recursive: true);
  }

  final rootTrue = await _createValidFixture(allowBackupValue: 'true');
  try {
    final errors = await platformConfigurationErrors(rootTrue);
    assert(
      errors.any((e) => e.contains('android:allowBackup="false"')),
      'Expected allowBackup exclusion error when true, got: $errors',
    );
  } finally {
    await rootTrue.delete(recursive: true);
  }
}

Future<void> _testInvalidBundleIds() async {
  final root = await _createValidFixture(
    androidApplicationId: 'com.example.salu',
    iosBundleId: 'com.example.salu',
  );
  try {
    final errors = await platformConfigurationErrors(root);
    assert(
      errors.any((e) => e.contains('applicationId')),
      'Expected applicationId error, got: $errors',
    );
    assert(
      errors.any((e) => e.contains('PRODUCT_BUNDLE_IDENTIFIER')),
      'Expected PRODUCT_BUNDLE_IDENTIFIER error, got: $errors',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> _testMissingIosBundleId() async {
  final root = await _createValidFixture();
  try {
    await File(
      '${root.path}/ios/Runner.xcodeproj/project.pbxproj',
    ).writeAsString('buildSettings = {};');
    final errors = await platformConfigurationErrors(root);
    assert(
      errors.any((e) => e.contains('PRODUCT_BUNDLE_IDENTIFIER')),
      'Expected missing PRODUCT_BUNDLE_IDENTIFIER error, got: $errors',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> _testPreviewBundleIdPasses() async {
  final root = await _createValidFixture(
    androidApplicationId: 'pt.salu.preview.salu',
    iosBundleId: 'pt.salu.preview.salu',
  );
  try {
    final errors = await platformConfigurationErrors(root);
    assert(errors.isEmpty, 'Expected preview bundle IDs to pass, got: $errors');
  } finally {
    await root.delete(recursive: true);
  }
}

Future<void> _testReviewedBackupRulesPass() async {
  final root = await _createValidFixture(allowBackupValue: 'true');
  try {
    await File(
      '${root.path}/android/app/src/main/AndroidManifest.xml',
    ).writeAsString('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.CAMERA" />
    <application
        android:allowBackup="true"
        android:fullBackupContent="@xml/backup_rules"
        android:label="salu"
        android:name="\${applicationName}">
    </application>
</manifest>
''');
    await Directory(
      '${root.path}/android/app/src/main/res/xml',
    ).create(recursive: true);
    await File(
      '${root.path}/android/app/src/main/res/xml/backup_rules.xml',
    ).writeAsString('''
<full-backup-content>
    <exclude domain="database" path="." />
    <exclude domain="file" path="." />
    <exclude domain="sharedpref" path="." />
</full-backup-content>
''');
    final errors = await platformConfigurationErrors(root);
    assert(
      errors.isEmpty,
      'Expected reviewed backup rules to pass, got: $errors',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

Future<Directory> _createValidFixture({
  bool includeInternet = true,
  bool includeCamera = true,
  String? allowBackupValue = 'false',
  String androidApplicationId = 'pt.salu.salu',
  String iosBundleId = 'pt.salu.salu',
}) async {
  final root = await Directory.systemTemp.createTemp('salu-platform-test-');
  await Directory('${root.path}/android/app/src/main').create(recursive: true);
  await Directory('${root.path}/ios/Runner').create(recursive: true);
  await Directory('${root.path}/ios/Runner.xcodeproj').create(recursive: true);

  final permissions = <String>[
    if (includeInternet)
      '    <uses-permission android:name="android.permission.INTERNET" />',
    if (includeCamera)
      '    <uses-permission android:name="android.permission.CAMERA" />',
  ].join('\n');

  final allowBackupAttr = allowBackupValue == null
      ? ''
      : '\n        android:allowBackup="$allowBackupValue"';

  await File(
    '${root.path}/android/app/src/main/AndroidManifest.xml',
  ).writeAsString('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
$permissions
    <application$allowBackupAttr
        android:label="salu"
        android:name="\${applicationName}">
    </application>
</manifest>
''');

  await File('${root.path}/android/app/build.gradle.kts').writeAsString('''
android {
    namespace = "$androidApplicationId"
    defaultConfig {
        applicationId = "$androidApplicationId"
    }
}
''');

  await File('${root.path}/ios/Runner/Info.plist').writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>NSCameraUsageDescription</key>
    <string>Take photos of meals and nutrition labels for your diary.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Choose photos of meals and nutrition labels for your diary.</string>
</dict>
</plist>
''');

  await File('${root.path}/ios/Runner.xcodeproj/project.pbxproj').writeAsString(
    '''
buildSettings = {
    PRODUCT_BUNDLE_IDENTIFIER = $iosBundleId;
};
buildSettings = {
    PRODUCT_BUNDLE_IDENTIFIER = $iosBundleId.RunnerTests;
};
''',
  );

  return root;
}
