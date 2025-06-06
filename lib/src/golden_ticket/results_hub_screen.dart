// golden_ticket/results_hub_screen.dart

import 'package:flutter/material.dart';
// Import Provider for accessing shared state like AuthState.
import 'package:provider/provider.dart';
// Import logging framework.
import 'package:logging/logging.dart';
// Import intl package for date formatting.
import 'package:intl/intl.dart';
// Import dart:async (though not directly used for Timer here).
import 'dart:async';
// Import dart:collection for using HashSet.
import 'dart:collection';

// --- Project-Specific Imports ---
// Import authentication state management.
import 'auth/auth_state.dart';
// Import database helper for accessing local data (user progress, results cache).
import 'database_helper.dart';
// Import logging utility.
import 'logging_utils.dart';

// Import the service handling game logic, API calls, and date calculations.
import 'game_event_service.dart';
// Import named route constants.
import 'routes.dart';
// Import the screen used for selecting/adding games.
import 'game_selector_screen.dart';

/// A simple data class to hold the information needed to display
/// each game entry in the Results Hub list.
class GameResultDisplayData {
  // The name of the game (e.g., "lotto649").
  final String gameName;
  // The date string of the most recent past draw for this game ('yyyy-MM-dd'). Null if unavailable.
  final String? lastDrawDate;
  // Flag indicating if the cached result for the lastDrawDate has the 'new_draw_flag' set.
  final bool hasNewResults;

  /// Constructor for GameResultDisplayData.
  GameResultDisplayData({
    required this.gameName,
    this.lastDrawDate,
    required this.hasNewResults,
  });
}


/// A StatefulWidget that displays a list of games the user is involved with,
/// showing the date of the last result and indicating if new results are available.
class ResultsHubScreen extends StatefulWidget {
  // Route name for navigation.
  static const routeName = '/results-hub';

  const ResultsHubScreen({super.key});

  @override
  State<ResultsHubScreen> createState() => _ResultsHubScreenState();
}

/// The State class for the ResultsHubScreen widget.
class _ResultsHubScreenState extends State<ResultsHubScreen> {
  // Logger instance for this screen.
  final _log = Logger('ResultsHubScreen');
  // Instance of the database helper.
  final dbHelper = DatabaseHelper();
  // Instance of the game event service (initialized in initState).
  late GameEventService _gameEventService;
  // Instance of the authentication state (initialized in initState).
  late AuthState _authState;

  // --- State Variables ---
  // Flag indicating if data is currently being loaded.
  bool _isLoading = true;
  // Holds an error message if data loading fails.
  String? _errorMessage;
  // List holding the display data for each game shown in the hub.
  List<GameResultDisplayData> _gamesData = [];
  // The default game that should always be checked/displayed.
  final String _defaultGame = "lotto649";

  @override
  void initState() {
    super.initState();
    // Configure the logger.
    LoggingUtils.setupLogger(_log);
    // Get AuthState instance (listen: false as it's only needed for initialization here).
    _authState = Provider.of<AuthState>(context, listen: false);
    // Initialize the GameEventService, passing the AuthState.
    _gameEventService = GameEventService(_authState);
    // Load the data needed for the hub when the screen initializes.
    _loadHubData();
  }

  /// Asynchronously loads the data required to display the results hub.
  /// Fetches the list of games the user follows, determines the last draw date for each,
  /// and checks the cache for new result flags.
  Future<void> _loadHubData() async {
    _log.info("Loading data for Results Hub...");
    // Exit if the widget is no longer mounted.
    if (!mounted) return;

    // Set loading state and clear previous data/errors.
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _gamesData = [];
    });

    // Check if the user is signed in.
    if (!_authState.isSignedIn) {
      _log.warning("User not signed in. Cannot load hub data.");
      if (mounted) setState(() { _isLoading = false; _errorMessage = "Please sign in to view results."; });
      return;
    }

    // Get the current user ID.
    int? currentUserId;
    try {
      currentUserId = int.tryParse(_authState.userId);
      if (currentUserId == null) throw Exception("Invalid User ID");
    } catch (e) {
      _log.severe("Error getting User ID: $e");
      if (mounted) setState(() { _isLoading = false; _errorMessage = "Error identifying user."; });
      return;
    }

    // --- Data Loading Logic ---
    List<GameResultDisplayData> loadedData = [];
    // Use a HashSet to efficiently store unique game names to check.
    Set<String> gamesToCheck = HashSet<String>();
    // Always include the default game in the list.
    gamesToCheck.add(_defaultGame);

    try {
      // 1. Get all game progress records for the current user from the database.
      final List<Map<String, dynamic>> userProgress = await dbHelper.getAllUserGameProgress(currentUserId);
      _log.info("Found ${userProgress.length} game progress entries for user $currentUserId.");

      // Add game names from the user's progress records to the set.
      for (var progressEntry in userProgress) {
        String gameName = progressEntry['game_name'] as String? ?? '';
        if (gameName.isNotEmpty) {
          gamesToCheck.add(gameName);
        }
      }
      _log.info("Total unique games to check (including default): ${gamesToCheck.length}");

      // Exit if widget unmounted during DB query.
      if (!mounted) return;

      // 2. For each unique game name, fetch necessary details.
      for (String gameName in gamesToCheck) {
        String? nextDrawDate;
        String? lastDrawDate;
        bool hasNew = false; // Flag for new results for this specific game.

        try {
          _log.fine("Processing hub data for game: $gameName");
          // Get the next draw date using the service.
          nextDrawDate = await _gameEventService.getNextDrawDate(gameName);
          if (nextDrawDate != null) {
            // Calculate the last draw date based on the next draw date.
            lastDrawDate = await _gameEventService.calculateLastDrawDate(gameName, nextDrawDate);
            if (lastDrawDate != null) {
              // Check the results cache in the database for this game and last draw date.
              final cachedResult = await dbHelper.getGameResultFromCache(gameName, lastDrawDate);
              // Determine if the 'new_draw_flag' is set (true if flag is 1, false otherwise or if no cache).
              hasNew = cachedResult?.newDrawFlag ?? false;
              _log.fine("Checked cache for $gameName/$lastDrawDate: Found=${cachedResult != null}, HasNew=$hasNew");
            } else {
              _log.warning("Could not calculate last draw date for $gameName (next: $nextDrawDate).");
            }
          } else {
            _log.warning("Could not determine next draw date for $gameName.");
          }
        } catch(e) {
          // Log errors during processing for a single game, but continue with others.
          _log.severe("Error processing game $gameName for hub: $e");
        }

        // Create display data object for this game and add it to the list.
        loadedData.add(GameResultDisplayData(
          gameName: gameName,
          lastDrawDate: lastDrawDate, // Store the calculated last draw date.
          hasNewResults: hasNew, // Store the new results flag status.
        ));

        // Exit loop early if widget unmounted.
        if (!mounted) return;
      }

      // Sort the loaded game data alphabetically by game name.
      loadedData.sort((a, b) => a.gameName.compareTo(b.gameName));

      // Update the state with the loaded and sorted data.
      if (mounted) {
        setState(() {
          _gamesData = loadedData;
          _isLoading = false; // Set loading to false.
        });
      }

    } catch (e, stacktrace) {
      // Handle any general errors during the loading process.
      _log.severe("Error loading results hub data: $e\nStack: $stacktrace");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = "Failed to load game data. Please try again.";
        });
      }
    }
  }

  /// Navigates to the GameSelectorScreen to allow the user to add/select more games.
  /// Reloads the hub data when returning from the selector screen.
  void _navigateToAddGame() {
    Navigator.pushNamed(context, GameSelectorScreen.routeName).then((_) {
      // Reload data after the selector screen is popped, in case a game was added.
      _loadHubData();
    });
  }

  /// Navigates to the detailed ResultsScreen for a specific game and draw date.
  /// Reloads the hub data when returning from the results screen.
  void _navigateToResults(String gameName, String? drawDate) {
    // Do not navigate if the draw date is unavailable.
    if (drawDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Draw date not available for $gameName")),
      );
      return;
    }
    _log.info("Navigating to results for $gameName / $drawDate");
    // Navigate using the named route for the results screen.
    Navigator.pushNamed(
      context,
      Routes.gameResult, // Route defined for ResultsScreen.
      arguments: { // Pass game name and draw date as arguments.
        'gameName': gameName,
        'drawDate': drawDate,
      },
    ).then((_) {
      // Reload data after the results screen is popped, in case the 'new_draw_flag' was cleared.
      _loadHubData();
    });
  }


  @override
  Widget build(BuildContext context) {
    // Build the main scaffold for the screen.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Results Hub'),
        actions: [
          // Add a refresh button to the app bar.
          IconButton(
            icon: const Icon(Icons.refresh),
            // Disable button while loading.
            onPressed: _isLoading ? null : _loadHubData,
            tooltip: 'Refresh Results Status',
          ),
        ],
      ),
      // Build the body content based on the current state.
      body: _buildBody(),
      // Add a FloatingActionButton to navigate to the game selector/adder screen.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToAddGame,
        icon: const Icon(Icons.add),
        label: const Text("Add Game"), // TODO: Clarify if this adds or just selects.
      ),
    );
  }

  /// Builds the main content widget based on the loading and error states.
  Widget _buildBody() {
    // Show loading indicator if data is loading.
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Show error message and retry button if an error occurred.
    if (_errorMessage != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_errorMessage!, style: TextStyle(color: Colors.red[700]), textAlign: TextAlign.center),
                    const SizedBox(height: 10),
                    ElevatedButton(onPressed: _loadHubData, child: const Text('Retry'))
                  ]
              )
          )
      );
    }

    // Show an empty state message if no game data could be loaded (should be rare if default game works).
    if (_gamesData.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Text(
            "Could not load game data. Please try refreshing.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ),
      );
    }

    // --- Build the List of Games ---
    // Display the list of games using ListView.builder for efficiency.
    return ListView.builder(
      padding: const EdgeInsets.all(8.0), // Padding around the list.
      itemCount: _gamesData.length, // Number of items in the list.
      // Builder function creates a widget for each item in _gamesData.
      itemBuilder: (context, index) {
        // Get the display data for the current game.
        final gameData = _gamesData[index];
        // Define date format for display.
        final DateFormat dateFormat = DateFormat('MMM d, yyyy');
        String displayDate = "Date N/A"; // Default display text for date.
        // Safely parse and format the last draw date if available.
        if (gameData.lastDrawDate != null) {
          final parsedDate = DateTime.tryParse(gameData.lastDrawDate!);
          if (parsedDate != null) {
            displayDate = dateFormat.format(parsedDate);
          }
        }

        // Create a Card containing a ListTile for each game.
        return Card(
          elevation: 1.0,
          margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
          child: ListTile(
            // Display the game name.
            title: Text(gameData.gameName, style: Theme.of(context).textTheme.titleMedium),
            // Display the formatted last result date.
            subtitle: Text("Last Result: $displayDate"),
            // Display a 'New' chip or a navigation icon in the trailing position.
            trailing: gameData.hasNewResults
                ? Chip( // Show a 'New' chip if hasNewResults is true.
              label: const Text('New'),
              backgroundColor: Colors.lightBlue[100],
              padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0),
              labelStyle: TextStyle(fontSize: 12, color: Colors.blue[800], fontWeight: FontWeight.bold),
              visualDensity: VisualDensity.compact, // Make the chip smaller.
            )
                : const Icon(Icons.chevron_right, color: Colors.grey), // Show arrow otherwise.
            // Set the onTap callback to navigate to the detailed results screen.
            // Only enable tap if lastDrawDate is available.
            onTap: gameData.lastDrawDate != null
                ? () => _navigateToResults(gameData.gameName, gameData.lastDrawDate)
                : null, // Disable tap if date is null.
            // Visually disable the ListTile if onTap is null.
            enabled: gameData.lastDrawDate != null,
          ),
        );
      },
    );
  }
}