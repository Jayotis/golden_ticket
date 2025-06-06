// golden_ticket/game_rules.dart
import 'dart:convert'; // Import for jsonEncode/Decode

class GameRule {
  final String gameName;
  final int totalNumbers;
  final int regularBallsDrawn;
  final int bonusBallPool;
  final int bonusBallsDrawn;
  final String drawSchedule;
  final String prizeTierFormat;
  // Added field to store official odds as strings
  final Map<String, String> officialOddsDisplay;

  const GameRule({
    required this.gameName,
    required this.totalNumbers,
    required this.regularBallsDrawn,
    required this.bonusBallPool,
    required this.bonusBallsDrawn,
    required this.drawSchedule,
    required this.prizeTierFormat,
    required this.officialOddsDisplay, // Added to constructor
  });

  // Method to convert a GameRule instance into a Map for SQLite insertion
  Map<String, dynamic> toMap() {
    return {
      'game_name': gameName,
      'total_numbers': totalNumbers,
      'regular_balls_drawn': regularBallsDrawn,
      'bonus_ball_pool': bonusBallPool,
      'bonus_balls_drawn': bonusBallsDrawn,
      'draw_schedule': drawSchedule,
      'prize_tier_format': prizeTierFormat,
      // Encode the map as a JSON string for storage
      'official_odds_json': jsonEncode(officialOddsDisplay),
    };
  }

  // Static method to create a GameRule instance from a Map
  static GameRule fromMap(Map<String, dynamic> map) {
    Map<String, String> oddsMap = {};
    // Decode the JSON string back into a map
    if (map['official_odds_json'] != null && map['official_odds_json'] is String) {
      try {
        // Ensure the decoded JSON is correctly cast to the expected type
        var decoded = jsonDecode(map['official_odds_json']);
        if (decoded is Map) {
          // Cast keys and values if necessary, assuming they are strings
          oddsMap = decoded.map((key, value) => MapEntry(key.toString(), value.toString()));
        }
      } catch (e) {
        print("Error decoding official_odds_json: $e");
        // Handle error, perhaps default to empty map
        oddsMap = {};
      }
    }

    return GameRule(
      gameName: map['game_name'] as String? ?? 'Unknown', // Add null checks
      totalNumbers: map['total_numbers'] as int? ?? 0,
      regularBallsDrawn: map['regular_balls_drawn'] as int? ?? 0,
      bonusBallPool: map['bonus_ball_pool'] as int? ?? 0,
      bonusBallsDrawn: map['bonus_balls_drawn'] as int? ?? 0,
      drawSchedule: map['draw_schedule'] as String? ?? '',
      prizeTierFormat: map['prize_tier_format'] as String? ?? '',
      officialOddsDisplay: oddsMap, // Assign the decoded map
    );
  }

  @override
  String toString() {
    // Updated toString to include the new field
    return 'GameRule{gameName: $gameName, totalNumbers: $totalNumbers, regularBallsDrawn: $regularBallsDrawn, bonusBallPool: $bonusBallPool, bonusBallsDrawn: $bonusBallsDrawn, drawSchedule: $drawSchedule, prizeTierFormat: $prizeTierFormat, officialOddsDisplay: $officialOddsDisplay}';
  }

  // Updated columns list
  static const List<String> columns = [
    'game_name',
    'total_numbers',
    'regular_balls_drawn',
    'bonus_ball_pool',
    'bonus_balls_drawn',
    'draw_schedule',
    'prize_tier_format',
    'official_odds_json', // Added new column name
  ];
}

// Static list holding the game rules data
class GameRules {
  // Define the odds map for lotto649
  static const Map<String, String> _lotto649Odds = {
    "6/6": "One in 13,983,816",
    "5/6+": "One in 2,330,636",
    "5/6": "One in 55,492",
    "4/6": "One in 1,033",
    "3/6": "One in 56.7",
    "2/6+": "One in 81.2",
    "2/6": "One in 8.3",
    "Any Prize": "One in 6.6",
  };

  // Define empty maps for other games for now
  static const Map<String, String> _lottoMaxOdds = {}; // Add odds later if needed
  static const Map<String, String> _dailyGrandOdds = {}; // Add odds later if needed


  static const List<GameRule> gameRulesData = [
    GameRule(
      gameName: 'lotto649',
      totalNumbers: 49,
      regularBallsDrawn: 6,
      bonusBallPool: 49,
      bonusBallsDrawn: 1,
      drawSchedule: 'Wed 20:30 America/Edmonton,Sat 20:30 America/Edmonton',
      prizeTierFormat: 'matches/6+',
      officialOddsDisplay: _lotto649Odds, // Assign the map
    ),
    GameRule(
      gameName: 'LottoMax',
      totalNumbers: 50,
      regularBallsDrawn: 7,
      bonusBallPool: 50,
      bonusBallsDrawn: 1,
      drawSchedule: 'Tue 20:30 America/Edmonton,Fri 20:30 America/Edmonton',
      prizeTierFormat: 'matches/7+',
      officialOddsDisplay: _lottoMaxOdds, // Assign empty map for now
    ),
    GameRule(
      gameName: 'DailyGrand',
      totalNumbers: 49,
      regularBallsDrawn: 5,
      bonusBallPool: 7,
      bonusBallsDrawn: 1,
      drawSchedule: 'Mon 20:30 America/Edmonton,Thu 20:30 America/Edmonton',
      prizeTierFormat: 'matches/5 + GN/1',
      officialOddsDisplay: _dailyGrandOdds, // Assign empty map for now
    ),
  ];
}
