import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart'; // Import the logging package

/// Represents the data for a specific game draw, including details like
/// draw date, jackpot, winning numbers (as a string), and associated metadata.
class GameDrawData {
  final int gameId;
  final String gameName;
  final String drawDate; // Keep as String for consistent formatting
  final String jackpot;
  final String? nextDrawDate; // Keep as String
  final String? nextJackpot;
  final String? winningNumbersString; // Store winning numbers as comma-separated String
  final String? extra;
  final String? encore;
  final String? checksum; // Checksum for the draw data
  final String? archiveChecksum; // Checksum for the ingot pool archive
  final String? drawStatus; // Status of the draw (e.g., 'Official', 'Unofficial')
  final DateTime fetchedAt; // Timestamp when the data was fetched

  /// Constructor for creating a [GameDrawData] instance.
  /// Requires [gameId], [gameName], [drawDate], and [jackpot].
  /// Other fields are optional.
  GameDrawData({
    required this.gameId,
    required this.gameName,
    required this.drawDate,
    required this.jackpot,
    this.nextDrawDate,
    this.nextJackpot,
    this.winningNumbersString, // Updated parameter
    this.extra,
    this.encore,
    this.checksum,
    this.archiveChecksum,
    this.drawStatus,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ??
      DateTime.now(); // Default to current time if not provided

  /// Factory constructor to create a [GameDrawData] instance from a JSON map.
  /// Handles parsing and type checking for each field.
  factory GameDrawData.fromJson(Map<String, dynamic> json) {
    // Instantiate Logger directly for this context
    final logger = Logger('GameDrawData.fromJson');
    logger.fine('Parsing GameDrawData from JSON: $json'); // Log the incoming JSON (use fine level)

    // Helper function to safely parse integers
    int? safeParseInt(dynamic value) {
      if (value == null) return null;
      if (value is int) return value;
      if (value is String) return int.tryParse(value);
      return null;
    }

    // Helper function to safely parse strings
    String? safeParseString(dynamic value) {
      return value?.toString();
    }

    // Helper function to parse date strings, attempting multiple formats
    String? parseDrawDate(dynamic dateValue) {
      if (dateValue == null) return null;
      String dateStr = dateValue.toString();
      try {
        // Try parsing with the expected format first
        DateTime parsedDate = DateFormat("yyyy-MM-dd").parse(dateStr);
        return DateFormat("yyyy-MM-dd")
            .format(parsedDate); // Return in consistent format
      } catch (e) {
        logger.warning('Could not parse date $dateStr with format yyyy-MM-dd: $e');
        // Consider adding more formats to try if needed
        return dateStr; // Return original string if parsing fails
      }
    }

    /// Parses winning numbers from various formats (List, String)
    /// into a sorted, comma-separated String.
    /// Returns null if input is null or results in no valid numbers.
    String? parseWinningNumbersToString(dynamic numbersInput) {
      if (numbersInput == null) return null;

      List<int> numbersList = [];

      if (numbersInput is List) {
        // Input is already a list
        numbersList = numbersInput
            .map((n) => safeParseInt(n))
            .where((n) => n != null) // Filter out nulls after parsing
            .cast<int>()
            .toList();
      } else if (numbersInput is String) {
        // Input is a string (potentially comma-separated)
        if (numbersInput.trim().isEmpty) return null; // Handle empty string input
        numbersList = numbersInput
            .split(',')
            .map((s) => int.tryParse(s.trim()))
            .where((n) => n != null) // Filter out nulls after parsing
            .cast<int>()
            .toList();
      } else {
        // Unsupported type
        logger.warning('Unsupported type for winning_numbers: ${numbersInput.runtimeType}');
        return null;
      }

      if (numbersList.isEmpty) {
        return null; // Return null if no valid numbers were found
      }

      // Sort numbers for consistency
      numbersList.sort();

      // Join into a comma-separated string
      return numbersList.join(',');
    }

    try {
      // --- Required fields ---
      final gameId = safeParseInt(json['game_id']);
      final gameName = safeParseString(json['game_name']);
      final drawDate = parseDrawDate(json['draw_date']);
      final jackpot = safeParseString(json['jackpot']);

      // --- Check for null required fields ---
      if (gameId == null) {
        logger.severe('Missing or invalid game_id in JSON: $json');
        throw const FormatException('Missing or invalid game_id');
      }
      if (gameName == null) {
        logger.severe('Missing or invalid game_name in JSON: $json');
        throw const FormatException('Missing or invalid game_name');
      }
      if (drawDate == null) {
        logger.severe('Missing or invalid draw_date in JSON: $json');
        throw const FormatException('Missing or invalid draw_date');
      }
      if (jackpot == null) {
        logger.severe('Missing or invalid jackpot in JSON: $json');
        throw const FormatException('Missing or invalid jackpot');
      }

      // --- Optional fields ---
      final nextDrawDate = parseDrawDate(json['next_draw_date']);
      final nextJackpot = safeParseString(json['next_jackpot']);
      // Parse winning numbers into a string
      final winningNumbersString = parseWinningNumbersToString(json['winning_numbers']);
      final extra = safeParseString(json['extra']);
      final encore = safeParseString(json['encore']);
      final checksum = safeParseString(json['checksum']);
      final archiveChecksum = safeParseString(json['archive_checksum']);
      final drawStatus = safeParseString(json['draw_status']);
      DateTime fetchedAt = DateTime.now(); // Record fetch time

      // Log successful parsing
      logger.info( // Use info level for successful parse
          'Successfully parsed GameDrawData for gameId: $gameId, drawDate: $drawDate');

      return GameDrawData(
        gameId: gameId,
        gameName: gameName,
        drawDate: drawDate,
        jackpot: jackpot,
        nextDrawDate: nextDrawDate,
        nextJackpot: nextJackpot,
        winningNumbersString: winningNumbersString, // Assign parsed string
        extra: extra,
        encore: encore,
        checksum: checksum,
        archiveChecksum: archiveChecksum,
        drawStatus: drawStatus,
        fetchedAt: fetchedAt,
      );
    } catch (e, stackTrace) {
      // Log the error and the problematic JSON
      // Use positional arguments for error and stackTrace
      logger.severe('Error parsing GameDrawData from JSON: $json', e, stackTrace);
      // Re-throw the exception to be handled by the caller
      rethrow;
    }
  }

  /// Converts the [GameDrawData] instance to a JSON map.
  Map<String, dynamic> toJson() {
    // Instantiate Logger directly for this context
    final logger = Logger('GameDrawData.toJson');
    logger.fine('Converting GameDrawData to JSON for gameId: $gameId'); // Use fine level
    return {
      'game_id': gameId,
      'game_name': gameName,
      'draw_date': drawDate,
      'jackpot': jackpot,
      'next_draw_date': nextDrawDate,
      'next_jackpot': nextJackpot,
      'winning_numbers': winningNumbersString, // Store the string directly
      'extra': extra,
      'encore': encore,
      'checksum': checksum,
      'archive_checksum': archiveChecksum,
      'draw_status': drawStatus,
      'fetched_at': fetchedAt.toIso8601String(),
    };
  }

  /// Provides a string representation of the [GameDrawData] instance,
  /// useful for debugging and logging.
  @override
  String toString() {
    return 'GameDrawData('
        'gameId: $gameId, '
        'gameName: $gameName, '
        'drawDate: $drawDate, '
        'jackpot: $jackpot, '
        'nextDrawDate: $nextDrawDate, '
        'nextJackpot: $nextJackpot, '
        'winningNumbersString: $winningNumbersString, ' // Updated field name
        'extra: $extra, '
        'encore: $encore, '
        'checksum: $checksum, '
        'archiveChecksum: $archiveChecksum, '
        'drawStatus: $drawStatus, '
        'fetchedAt: ${fetchedAt.toIso8601String()}'
        ')';
  }

  /// Overrides the equality operator to compare [GameDrawData] instances
  /// based on their properties.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is GameDrawData &&
        other.gameId == gameId &&
        other.gameName == gameName &&
        other.drawDate == drawDate &&
        other.jackpot == jackpot &&
        other.nextDrawDate == nextDrawDate &&
        other.nextJackpot == nextJackpot &&
        other.winningNumbersString == winningNumbersString && // Compare strings
        other.extra == extra &&
        other.encore == encore &&
        other.checksum == checksum &&
        other.archiveChecksum == archiveChecksum &&
        other.drawStatus == drawStatus &&
        other.fetchedAt == fetchedAt;
  }

  /// Overrides the hashCode getter to generate a hash code based on the
  /// properties of the [GameDrawData] instance.
  /// Handles null values safely.
  @override
  int get hashCode {
    // Use null-aware access (?.) and null-coalescing operator (??) for safety
    return gameId.hashCode ^
    gameName.hashCode ^
    drawDate.hashCode ^
    jackpot.hashCode ^
    (nextDrawDate?.hashCode ?? 0) ^
    (nextJackpot?.hashCode ?? 0) ^
    (winningNumbersString?.hashCode ?? 0) ^ // Use string hashcode
    (extra?.hashCode ?? 0) ^
    (encore?.hashCode ?? 0) ^
    (checksum?.hashCode ?? 0) ^
    (archiveChecksum?.hashCode ?? 0) ^
    (drawStatus?.hashCode ?? 0) ^
    fetchedAt.hashCode;
  }

  /// Helper getter to convert the winning numbers string back to a list of integers.
  /// Returns an empty list if the string is null or empty.
  List<int> get winningNumbersList {
    if (winningNumbersString == null || winningNumbersString!.isEmpty) {
      return [];
    }
    try {
      return winningNumbersString!
          .split(',')
          .map((s) => int.parse(s.trim()))
          .toList();
    } catch (e) {
      // Log error if parsing fails
      final logger = Logger('GameDrawData.winningNumbersList');
      logger.warning('Failed to parse winningNumbersString "$winningNumbersString" back to List<int>', e);
      return []; // Return empty list on error
    }
  }
}