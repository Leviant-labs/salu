import 'dart:io';

import 'platform_configuration.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart tool/verify_platforms.dart <app-directory>');
    exitCode = 1;
    return;
  }

  final appDir = Directory(args.first);
  if (!await appDir.exists()) {
    stderr.writeln('App directory does not exist: ${appDir.path}');
    exitCode = 1;
    return;
  }

  final errors = await platformConfigurationErrors(appDir);
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('FAIL: $error');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln('ok: platform configuration verified (${appDir.path})');
}
