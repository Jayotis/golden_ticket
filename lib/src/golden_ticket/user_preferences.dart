import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

// Store Map data in Shared Preferences
Future<void> storeGameData(Map<String, int> gameCombinations) async {
  final prefs = await SharedPreferences.getInstance();
  String gameDataString = jsonEncode(gameCombinations);
  await prefs.setString('gameData', gameDataString);
}

// Retrieve Map data from Shared Preferences
Future<Map<String, int>> retrieveGameData() async {
  final prefs = await SharedPreferences.getInstance();
  String? gameDataString = prefs.getString('gameData');
  if (gameDataString!= null) {
    return jsonDecode(gameDataString) as Map<String, int>;
  } else {
    return {}; // Return an empty map if no data is found
  }
}