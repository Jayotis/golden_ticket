// golden_ticket/ingot_crucible.dart
import 'dart:convert';
import 'package:logging/logging.dart'; // Added for logging parse errors
import 'package:intl/intl.dart'; // Import intl package

// Logger for this file
final _log = Logger('IngotCrucible');

/// Represents a single combination of numbers along with its unique Ingot ID.
/// (No changes needed in this class)
class CombinationWithId {
  final int ingotId;
  final List<int> numbers;

  CombinationWithId({required this.ingotId, required this.numbers});

  Map<String, dynamic> toJson() => {
    'ingotId': ingotId,
    'numbers': numbers,
  };

  factory CombinationWithId.fromJson(Map<String, dynamic> json) {
    final ingotId = json['ingotId'];
    final numbersRaw = json['numbers'];

    if (ingotId is! int) {
      throw FormatException("Invalid 'ingotId' type: ${ingotId?.runtimeType}");
    }
    if (numbersRaw is! List) {
      throw FormatException("Invalid 'numbers' type: ${numbersRaw?.runtimeType}");
    }

    List<int> parsedNumbers = [];
    try {
      parsedNumbers = numbersRaw.map((e) => int.parse(e.toString())).toList();
    } catch (e) {
      throw FormatException("Error parsing numbers list: $e");
    }

    return CombinationWithId(
      ingotId: ingotId,
      numbers: parsedNumbers,
    );
  }

  @override
  String toString() {
    return 'Ingot#$ingotId: ${numbers.join(', ')}';
  }
}


// --- RENAMED CLASS: PlayCard -> IngotCrucible ---
/// Represents a user's collection of ingots placed for a specific draw.
class IngotCrucible {
  int? id; // Database ID
  List<CombinationWithId> combinations; // Ingots placed in the crucible
  DateTime submittedDate; // Timestamp of last save or forge
  String status; // e.g., 'draft', 'submitted', 'locked'
  int? userId;
  String? name; // Name for the crucible (e.g., "Lotto 649 Crucible")
  DateTime drawDate; // The target draw date

  IngotCrucible({
    this.id,
    required this.combinations,
    required this.submittedDate,
    required this.status,
    this.userId,
    this.name,
    required this.drawDate,
  });

  /// Adds an ingot to the crucible.
  void addCombination(CombinationWithId combinationWithId) {
    // Consider adding checks for max combinations based on game rules if needed elsewhere
    combinations.add(combinationWithId);
  }

  /// Removes an ingot from the crucible by its index.
  void removeCombination(int index) {
    if (index >= 0 && index < combinations.length) {
      combinations.removeAt(index);
    }
  }


  /// Convert to Map for database storage.
  Map<String, dynamic> toMap() {
    // --- MODIFICATION START: Store drawDate as 'yyyy-MM-dd' ---
    final DateFormat formatter = DateFormat('yyyy-MM-dd');
    final String formattedDrawDate = formatter.format(drawDate);
    // --- MODIFICATION END ---

    return {
      'id': id,
      'name': name ?? "$userId Crucible for $formattedDrawDate", // Use formatted date in default name
      'user_id': userId,
      'submitted_date': submittedDate.toIso8601String(),
      'status': status,
      // Encode the list of CombinationWithId objects into a JSON string
      'combinations': jsonEncode(combinations.map((c) => c.toJson()).toList()),
      'draw_date': formattedDrawDate, // Store the formatted date string
      // 'membership_level' was removed as it seemed unused here
    };
  }

  /// Factory constructor from database map.
  factory IngotCrucible.fromMap(Map<String, dynamic> map) {
    List<CombinationWithId> decodedCombinations = [];
    try {
      final combinationsJson = map['combinations'];
      if (combinationsJson is String && combinationsJson.isNotEmpty) {
        var decodedJson = jsonDecode(combinationsJson);
        if (decodedJson is List) {
          decodedCombinations = decodedJson
              .map<CombinationWithId?>((item) {
            try {
              if (item is Map<String, dynamic>) {
                return CombinationWithId.fromJson(item);
              }
              _log.warning("Skipping invalid item in combinations JSON list: $item");
              return null; // Skip invalid items
            } catch (e) {
              _log.severe("Error parsing single combination from JSON: $e - Item: $item");
              return null; // Skip items that fail parsing
            }
          })
              .whereType<CombinationWithId>() // Filter out nulls
              .toList();
        } else {
          _log.warning("Decoded IngotCrucible combinations JSON was not a List: $combinationsJson");
        }
      } else if (combinationsJson != null && combinationsJson is! String){
        _log.warning("IngotCrucible combinations field was not a string: $combinationsJson");
      }
      // If combinationsJson is null or empty string, decodedCombinations remains empty list []
    } catch (e, stacktrace) {
      _log.severe("Error decoding IngotCrucible combinations JSON string: $e", e, stacktrace);
      decodedCombinations = []; // Default to empty list on error
    }

    // Helper to parse dates safely
    DateTime parseDateTime(String? dateString) {
      if (dateString != null) {
        try {
          return DateTime.parse(dateString);
        } catch (e) {
          _log.warning("Failed to parse DateTime string '$dateString', using current time.", e);
        }
      }
      return DateTime.now(); // Fallback to current time
    }

    // --- MODIFICATION START: Parse draw_date expecting 'yyyy-MM-dd' ---
    DateTime parsedDrawDate;
    final drawDateString = map['draw_date'] as String?;
    if (drawDateString != null) {
      try {
        // DateTime.parse can handle 'yyyy-MM-dd' format directly
        parsedDrawDate = DateTime.parse(drawDateString);
      } catch (e) {
        _log.warning("Failed to parse draw_date string '$drawDateString' as yyyy-MM-dd, using current date.", e);
        // Fallback to current date (midnight) if parsing fails
        final now = DateTime.now();
        parsedDrawDate = DateTime(now.year, now.month, now.day);
      }
    } else {
      _log.warning("draw_date string was null, using current date.");
      final now = DateTime.now();
      parsedDrawDate = DateTime(now.year, now.month, now.day);
    }
    // --- MODIFICATION END ---


    return IngotCrucible(
      id: map['id'] as int?,
      combinations: decodedCombinations,
      submittedDate: parseDateTime(map['submitted_date'] as String?),
      status: map['status'] as String? ?? 'unknown',
      userId: map['user_id'] as int?,
      name: map['name'] as String?,
      drawDate: parsedDrawDate, // Use the correctly parsed date
    );
  }


  @override
  String toString() {
    // Use the same formatter for consistent output
    final DateFormat formatter = DateFormat('yyyy-MM-dd');
    return 'IngotCrucible{id: $id, combinations: $combinations, submittedDate: $submittedDate, status: $status, userId: $userId, name: $name, drawDate: ${formatter.format(drawDate)}}';
  }
}
    