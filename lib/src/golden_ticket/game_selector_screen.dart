import 'package:flutter/material.dart';
import 'game_rules.dart'; // For GameRule class
import 'database_helper.dart'; // For DatabaseHelper

class GameSelectorScreen extends StatefulWidget {
  const GameSelectorScreen({super.key});
  static const routeName = '/game-selector';

  @override
  State<GameSelectorScreen> createState() => _GameSelectorScreenState();
}

class _GameSelectorScreenState extends State<GameSelectorScreen> {
  String? selectedGameKey;
  late Future<List<GameRule>> _futureRules;

  @override
  void initState() {
    super.initState();
    _futureRules = DatabaseHelper().fetchAllGameRules();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Event')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: FutureBuilder<List<GameRule>>(
            future: _futureRules,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const CircularProgressIndicator();
              }
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return const Text('No games available.');
              }
              final rules = snapshot.data!;
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Choose the event you want to add:',
                    style: TextStyle(fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 30),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400, width: 1),
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedGameKey,
                        isExpanded: true,
                        hint: const Text("Select a game event..."),
                        icon: const Icon(Icons.arrow_drop_down, color: Colors.deepPurple),
                        elevation: 16,
                        style: const TextStyle(color: Colors.deepPurple, fontSize: 16),
                        onChanged: (String? newValue) {
                          setState(() {
                            selectedGameKey = newValue;
                          });
                        },
                        items: rules.map((rule) {
                          return DropdownMenuItem<String>(
                            value: rule.gameName,
                            child: Text(_prettifyGameName(rule.gameName)),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(minimumSize: const Size(200, 45)),
                    onPressed: selectedGameKey == null ? null : () {
                      Navigator.pop(context, selectedGameKey);
                    },
                    child: const Text('Confirm Selection'),
                  )
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String _prettifyGameName(String key) {
    switch (key) {
      case 'lotto649':
        return "Lotto 6/49";
      case 'LottoMax':
        return "Lotto Max";
      case 'DailyGrand':
        return "Daily Grand";
      default:
        return key;
    }
  }
}