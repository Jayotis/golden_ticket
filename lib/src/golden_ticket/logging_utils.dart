import 'package:flutter/foundation.dart'; // Import foundation.dart
import 'package:logging/logging.dart';
//logging_utils.dart
final _log = Logger('AppLogger'); // Or however you configure your logger

void logThis(String message, {Level level = Level.INFO, Object? error, StackTrace? stackTrace}) {
  print('[$level] $message ${error ?? ''}');
}

class LoggingUtils {


  static void setupLogger(Logger logger,
      {Level level = Level.ALL, Function(LogRecord)? onLogRecord}) {
    logger.level = level;

    if (onLogRecord != null) {
      logger.onRecord.listen(onLogRecord);
    } else {
      // Default handler: print during development, do nothing in release
      logger.onRecord.listen((record) {
        if (kDebugMode) { // Check if in debug mode
          print(
              '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
        }
      });
    }
  }
}