import 'dart:io';

Future<List<String>> platformConfigurationErrors(Directory app) async {
  final errors = <String>[];

  await _checkAndroidManifest(app, errors);
  await _checkAndroidGradle(app, errors);
  await _checkIosInfoPlist(app, errors);
  await _checkIosProject(app, errors);

  return errors;
}

Future<void> _checkAndroidManifest(Directory app, List<String> errors) async {
  final manifest = File('${app.path}/android/app/src/main/AndroidManifest.xml');
  if (!await manifest.exists()) {
    errors.add(
      'Missing Android manifest: android/app/src/main/AndroidManifest.xml',
    );
    return;
  }

  final content = await manifest.readAsString();

  final hasInternet = RegExp(
    r'''<uses-permission\b[^>]*\bandroid:name\s*=\s*["']android\.permission\.INTERNET["']''',
    dotAll: true,
  ).hasMatch(content);
  if (!hasInternet) {
    errors.add(
      'Missing android.permission.INTERNET in android/app/src/main/AndroidManifest.xml',
    );
  }

  final hasCamera = RegExp(
    r'''<uses-permission\b[^>]*\bandroid:name\s*=\s*["']android\.permission\.CAMERA["']''',
    dotAll: true,
  ).hasMatch(content);
  if (!hasCamera) {
    errors.add(
      'Missing android.permission.CAMERA in android/app/src/main/AndroidManifest.xml',
    );
  }

  final hasAllowBackupFalse = RegExp(
    r'''<application\b[^>]*\bandroid:allowBackup\s*=\s*["']false["']''',
    dotAll: true,
  ).hasMatch(content);

  if (!hasAllowBackupFalse && !await _hasReviewedBackupRules(app, content)) {
    errors.add(
      'Android Auto Backup must be explicitly excluded (set android:allowBackup="false" or configure reviewed backup rules) in android/app/src/main/AndroidManifest.xml',
    );
  }
}

Future<bool> _hasReviewedBackupRules(
  Directory app,
  String manifestContent,
) async {
  final ruleMatches = RegExp(
    r'''\bandroid:(?:fullBackupContent|dataExtractionRules)\s*=\s*["']@xml/([a-zA-Z0-9_]+)["']''',
  ).allMatches(manifestContent);
  if (ruleMatches.isEmpty) {
    return false;
  }

  for (final match in ruleMatches) {
    final xmlName = match.group(1);
    if (xmlName == null || xmlName.isEmpty) {
      return false;
    }
    final xmlFile = File(
      '${app.path}/android/app/src/main/res/xml/$xmlName.xml',
    );
    if (!await xmlFile.exists()) {
      return false;
    }
    final xmlContent = await xmlFile.readAsString();
    if (!xmlContent.contains('<exclude')) {
      return false;
    }
  }

  return true;
}

Future<void> _checkAndroidGradle(Directory app, List<String> errors) async {
  final kts = File('${app.path}/android/app/build.gradle.kts');
  final groovy = File('${app.path}/android/app/build.gradle');
  final gradleFile = await kts.exists()
      ? kts
      : (await groovy.exists() ? groovy : null);

  if (gradleFile == null) {
    errors.add(
      'Missing Android app Gradle file: android/app/build.gradle.kts (or build.gradle)',
    );
    return;
  }

  final content = await gradleFile.readAsString();
  final match = RegExp(
    r'''\bapplicationId\s*(?:=\s*)?["']([^"']+)["']''',
  ).firstMatch(content);

  if (match == null) {
    errors.add('Missing applicationId in ${gradleFile.path}');
    return;
  }

  final applicationId = match.group(1)!;
  if (!_isIntendedBundleId(applicationId)) {
    errors.add(
      'Invalid Android applicationId "$applicationId" (expected pt.salu.* without placeholder)',
    );
  }
}

Future<void> _checkIosInfoPlist(Directory app, List<String> errors) async {
  final plist = File('${app.path}/ios/Runner/Info.plist');
  if (!await plist.exists()) {
    errors.add('Missing iOS Info.plist: ios/Runner/Info.plist');
    return;
  }

  final content = await plist.readAsString();

  if (!_hasPlistStringKey(content, 'NSCameraUsageDescription')) {
    errors.add('Missing NSCameraUsageDescription in ios/Runner/Info.plist');
  }

  if (!_hasPlistStringKey(content, 'NSPhotoLibraryUsageDescription')) {
    errors.add(
      'Missing NSPhotoLibraryUsageDescription in ios/Runner/Info.plist',
    );
  }

  final bundleIdValue = _plistStringValue(content, 'CFBundleIdentifier');
  if (bundleIdValue == null ||
      (bundleIdValue != r'$(PRODUCT_BUNDLE_IDENTIFIER)' &&
          !_isIntendedBundleId(bundleIdValue))) {
    errors.add(
      'Missing or invalid CFBundleIdentifier in ios/Runner/Info.plist',
    );
  }
}

Future<void> _checkIosProject(Directory app, List<String> errors) async {
  final pbxproj = File('${app.path}/ios/Runner.xcodeproj/project.pbxproj');
  if (!await pbxproj.exists()) {
    errors.add(
      'Missing iOS Xcode project: ios/Runner.xcodeproj/project.pbxproj',
    );
    return;
  }

  final content = await pbxproj.readAsString();
  final matches = RegExp(
    r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^";\r\n]+)"?\s*;',
  ).allMatches(content).toList();

  final ids = matches.map((m) => m.group(1)!.trim()).toList();
  final appIds = ids.where((id) => !id.endsWith('.RunnerTests')).toList();

  if (appIds.isEmpty) {
    errors.add(
      'Missing PRODUCT_BUNDLE_IDENTIFIER in ios/Runner.xcodeproj/project.pbxproj',
    );
    return;
  }

  for (final id in ids) {
    if (!_isIntendedBundleId(id)) {
      errors.add(
        'Invalid iOS PRODUCT_BUNDLE_IDENTIFIER "$id" in ios/Runner.xcodeproj/project.pbxproj (expected pt.salu.* without placeholder)',
      );
    }
  }
}

bool _hasPlistStringKey(String plistContent, String key) {
  final value = _plistStringValue(plistContent, key);
  return value != null && value.trim().isNotEmpty;
}

String? _plistStringValue(String plistContent, String key) {
  final pattern = RegExp(
    '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>([^<]*)</string>',
    dotAll: true,
  );
  return pattern.firstMatch(plistContent)?.group(1);
}

bool _isIntendedBundleId(String id) {
  return RegExp(r'^pt\.salu(?:\.[a-zA-Z0-9_]+)+$').hasMatch(id) &&
      !id.toLowerCase().contains('example');
}
