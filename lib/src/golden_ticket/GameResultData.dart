// golden_ticket/GameResultData.dart
import 'dart:convert';
import 'package:logging/logging.dart';

// Import logging utility if available and needed
// import 'logging_utils.dart';
// Simple logging fallback:
// void log(String message, {String level = 'info'}) {
//   print('[$level] GameResultData: $message');
// }
// Use actual logger if available
final _log = Logger('GameResultData');


/// Represents the data structure for a game result, based on the original structure.
/// Includes details about the draw, winning numbers, odds, score, and archive info.
class GameResultData {
  /// Name of the game.
  final String gameName;
  /// Date of the draw (stored as String, e.g., 'YYYY-MM-DD').
  final String drawDate;
  /// Winning numbers drawn.
  final List<int>? drawNumbers;
  /// Bonus number, if applicable.
  final int? bonusNumber;
  /// Total possible combinations for the game.
  final int? totalCombinations;
  // Odds fields (as doubles)
  final double? odds6_6;
  final double? odds5_6_plus;
  final double? odds5_6;
  final double? odds4_6;
  final double? odds3_6;
  final double? odds2_6_plus;
  final double? odds2_6;
  final double? oddsAnyPrize;
  /// User's score related to this draw (if calculated/stored).
  final int? userScore; // Storing score as int
  /// Flag indicating if this is a newly fetched draw result.
  final bool newDrawFlag;
  /// Identifier for a winning ticket/claim related to this draw.
  final String? winId;
  /// Password associated with the archive data (if applicable).
  final String? archivePassword;
  /// Checksum for the archived result data.
  final String? archiveChecksum;

  /// Constructor for creating a GameResultData instance.
  GameResultData({
    required this.gameName,
    required this.drawDate,
    this.drawNumbers,
    this.bonusNumber,
    this.totalCombinations,
    this.odds6_6,
    this.odds5_6_plus,
    this.odds5_6,
    this.odds4_6,
    this.odds3_6,
    this.odds2_6_plus,
    this.odds2_6,
    this.oddsAnyPrize,
    this.userScore,
    this.newDrawFlag = false, // Default to false if not provided
    this.winId,
    this.archivePassword,
    this.archiveChecksum,
  });

  /// Factory constructor to create GameResultData from API JSON response.
  factory GameResultData.fromApiJson({
    required Map<String, dynamic> json,
    required String gameName,
    required String drawDate,
  }) {
    _log.fine(
        "Parsing GameResultData from API JSON: $json (for $gameName / $drawDate)");

    List<int>? numbers;
    int? bonus;
    final winningNumbersRaw = json['winning_numbers'];

    // Safely parse winning numbers
    if (winningNumbersRaw != null && winningNumbersRaw is List) {
      try {
        numbers = winningNumbersRaw
            .map((e) => int.tryParse(e.toString()))
            .whereType<int>()
            .toList();
        if (numbers.length != winningNumbersRaw.length) {
          _log.warning(
              "Some elements in 'winning_numbers' could not be parsed as int: $winningNumbersRaw");
        }
        _log.fine("Parsed winning_numbers: $numbers");
      } catch (e) {
        _log.severe(
            "Error processing 'winning_numbers' list: $winningNumbersRaw, Error: $e");
        numbers = null;
      }
    } else {
      _log.warning(
          "'winning_numbers' key not found, not a List, or empty in API JSON.");
      numbers = null;
    }

    // Safely parse bonus number
    bonus = _parseInt(json['bonus_number']);
    if (json.containsKey('bonus_number') &&
        bonus == null &&
        json['bonus_number'] != null) {
      _log.warning(
          "Found 'bonus_number' key but failed to parse it: ${json['bonus_number']}");
    }

    // Safely parse user score from potential fields
    int? score;
    dynamic scoreSource;
    if (json['stored_score_results'] is Map &&
        json['stored_score_results']['total_score'] != null) {
      scoreSource = json['stored_score_results']['total_score'];
      _log.fine("Score source: nested 'stored_score_results.total_score'");
    } else if (json['calculated_score_for_draw'] != null) {
      scoreSource = json['calculated_score_for_draw'];
      _log.fine("Score source: top-level 'calculated_score_for_draw'");
    } else if (json['user_score'] != null) {
      scoreSource = json['user_score'];
      _log.fine("Score source: fallback 'user_score'");
    }

    if (scoreSource != null) {
      double? scoreDouble =
      _parseDouble(scoreSource); // Use helper to parse potentially double score
      if (scoreDouble != null) {
        score = scoreDouble.round(); // Round to int
        _log.fine("Parsed score: $score (from $scoreSource)");
      } else {
        _log.warning("Failed to parse score source: $scoreSource");
      }
    }

    // Parse other fields
    final winId = json['win_id'] as String?;
    final archivePassword = json['archive_password'] as String?;
    final archiveChecksum = json['archive_checksum'] as String?;

    // Create the instance
    return GameResultData(
      gameName: gameName,
      drawDate: drawDate, // Assuming drawDate is passed in correctly as String
      drawNumbers: numbers,
      bonusNumber: bonus,
      totalCombinations: _parseInt(json['total_combinations']),
      // Parse odds safely using helper
      odds6_6: _parseDouble(json['odds']?['odds_6_6']),
      odds5_6_plus: _parseDouble(json['odds']?['odds_5_6_plus']),
      odds5_6: _parseDouble(json['odds']?['odds_5_6']),
      odds4_6: _parseDouble(json['odds']?['odds_4_6']),
      odds3_6: _parseDouble(json['odds']?['odds_3_6']),
      odds2_6_plus: _parseDouble(json['odds']?['odds_2_6_plus']),
      odds2_6: _parseDouble(json['odds']?['odds_2_6']),
      oddsAnyPrize: _parseDouble(json['odds']?['odds_any_prize']),
      userScore: score,
      winId: winId,
      archivePassword: archivePassword,
      archiveChecksum: archiveChecksum,
      // newDrawFlag is not typically set from API, defaults to false
    );
  }

  /// Converts this GameResultData instance to a Map suitable for database storage.
  Map<String, dynamic> toMap() {
    return {
      // Ensure keys match database column names expected by DatabaseHelper
      'game_name': gameName,
      'draw_date': drawDate, // Store date as String
      // --- FIX: Use 'last_draw_numbers' key to match DB schema ---
      'last_draw_numbers': drawNumbers != null ? jsonEncode(drawNumbers) : null,
      // --- END FIX ---
      'bonus_number': bonusNumber,
      'total_combinations': totalCombinations,
      'odds_6_6': odds6_6,
      'odds_5_6_plus': odds5_6_plus,
      'odds_5_6': odds5_6,
      'odds_4_6': odds4_6,
      'odds_3_6': odds3_6,
      'odds_2_6_plus': odds2_6_plus,
      'odds_2_6': odds2_6,
      'odds_any_prize': oddsAnyPrize,
      'user_score': userScore,
      'new_draw_flag': newDrawFlag ? 1 : 0, // Store bool as int (0 or 1)
      'win_id': winId,
      'archive_password': archivePassword,
      'archive_checksum': archiveChecksum,
      // Note: 'fetched_at' is typically added by DatabaseHelper during insert/update
    };
  }

  /// Factory constructor to create GameResultData from a database Map.
  factory GameResultData.fromMap(Map<String, dynamic> map) {
    List<int>? numbers;
    // --- FIX: Ensure reading from 'last_draw_numbers' column ---
    final numbersJson = map['last_draw_numbers']; // Use the correct column name
    // --- END FIX ---
    if (numbersJson != null && numbersJson is String) {
      try {
        var decoded = jsonDecode(numbersJson);
        if (decoded is List) {
          numbers = decoded
              .map((item) => int.tryParse(item.toString()))
              .whereType<int>()
              .toList();
          if (numbers.length != decoded.length) {
            _log.warning(
                "Some elements in DB 'last_draw_numbers' could not be parsed as int: $numbersJson");
          }
        } else {
          _log.warning(
              "Decoded 'last_draw_numbers' from DB is not a List: $numbersJson");
        }
      } catch (e) {
        _log.severe("Error decoding numbers from DB map: $map, Error: $e");
        numbers = null;
      }
    }

    // Create the instance
    return GameResultData(
      gameName: map['game_name'] as String? ?? 'Unknown', // Provide default
      drawDate: map['draw_date'] as String? ?? '', // Provide default
      drawNumbers: numbers,
      bonusNumber: map['bonus_number'] as int?,
      totalCombinations: map['total_combinations'] as int?,
      // Safely cast odds from num? to double?
      odds6_6: (map['odds_6_6'] as num?)?.toDouble(),
      odds5_6_plus: (map['odds_5_6_plus'] as num?)?.toDouble(),
      odds5_6: (map['odds_5_6'] as num?)?.toDouble(),
      odds4_6: (map['odds_4_6'] as num?)?.toDouble(),
      odds3_6: (map['odds_3_6'] as num?)?.toDouble(),
      odds2_6_plus: (map['odds_2_6_plus'] as num?)?.toDouble(),
      odds2_6: (map['odds_2_6'] as num?)?.toDouble(),
      oddsAnyPrize: (map['odds_any_prize'] as num?)?.toDouble(),
      userScore: map['user_score'] as int?,
      // Convert int (0/1) back to bool
      newDrawFlag: (map['new_draw_flag'] as int? ?? 0) == 1,
      winId: map['win_id'] as String?,
      archivePassword: map['archive_password'] as String?,
      archiveChecksum: map['archive_checksum'] as String?,
    );
  }

  /// Internal static helper for safe integer parsing from various types.
  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    if (value is double) return value.round(); // Allow rounding from double
    _log.warning(
        "Could not parse value as int: $value (Type: ${value.runtimeType})");
    return null;
  }

  /// Internal static helper for safe double parsing from various types.
  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble(); // Allow conversion from int
    if (value is String) return double.tryParse(value);
    _log.warning(
        "Could not parse value as double: $value (Type: ${value.runtimeType})");
    return null;
  }

  /// Provides a string representation of the GameResultData instance.
  @override
  String toString() {
    // Keep the original toString format if preferred, or adjust as needed
    return 'GameResultData(gameName: $gameName, drawDate: $drawDate, numbers: ${drawNumbers?.join(',') ?? 'N/A'}, bonus: ${bonusNumber ?? 'N/A'}, score: ${userScore ?? 'N/A'}, newFlag: $newDrawFlag, winId: ${winId ?? 'N/A'}, archivePassword: ${archivePassword != null ? 'Present' : 'N/A'}, archiveChecksum: ${archiveChecksum ?? 'N/A'})';
  }

// Note: Overriding == and hashCode is generally recommended for data classes,
// but they were not present in the original snippet. Add them if needed
// for use in Sets/Maps or for reliable comparison.
// Example:
// @override
// bool operator ==(Object other) =>
//     identical(this, other) ||
//     other is GameResultData &&
//         runtimeType == other.runtimeType &&
//         gameName == other.gameName &&
//         drawDate == other.drawDate &&
//         // Compare lists carefully (e.g., using DeepCollectionEquality)
//         // const DeepCollectionEquality().equals(drawNumbers, other.drawNumbers) &&
//         bonusNumber == other.bonusNumber &&
//         totalCombinations == other.totalCombinations &&
//         // ... compare all other fields including archiveChecksum ...
//         archiveChecksum == other.archiveChecksum;
//
// @override
// int get hashCode =>
//     gameName.hashCode ^
//     drawDate.hashCode ^
//     // Combine list hash codes carefully
//     // const DeepCollectionEquality().hash(drawNumbers) ^
//     bonusNumber.hashCode ^
//     totalCombinations.hashCode ^
//     // ... combine hash codes of all other fields including archiveChecksum ...
//     archiveChecksum.hashCode;

}
