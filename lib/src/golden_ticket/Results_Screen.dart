// golden_ticket/Results_Screen.dart
import 'package:flutter/material.dart';
// Import the http package for making API calls.
import 'package:http/http.dart' as http;
// Import Provider for accessing shared state like AuthState.
import 'package:provider/provider.dart';
// Import dart:convert for JSON encoding/decoding.
import 'dart:convert';
// Import logging framework.
import 'package:logging/logging.dart';
// Import intl package for date and number formatting.
import 'package:intl/intl.dart';
// Import dart:async (used for Future, though no Timers here).
import 'dart:async';
// Import services for interacting with the system clipboard.
import 'package:flutter/services.dart';

// --- Project-Specific Imports ---
// Import authentication state management.
import 'auth/auth_state.dart';
// Import database helper for accessing local cache and game rules.
import 'database_helper.dart';
// Import logging utility.
import 'logging_utils.dart';
// Import the data model for game results (includes parsing logic).
import 'GameResultData.dart';
// Import the data model for game rules.
import 'game_rules.dart';
// Import sqflite package (used indirectly via dbHelper, but also for Database type hint).
import 'package:sqflite/sqflite.dart';

/// A StatefulWidget that displays the detailed results for a specific game draw.
/// It receives the game name and draw date as arguments during navigation.
class ResultsScreen extends StatefulWidget {
  // Route name used for navigation to this screen.
  static const routeName = '/game-result';

  // The name of the game whose results are being displayed.
  final String gameName;
  // The date of the draw whose results are being displayed ('yyyy-MM-dd').
  final String drawDate;

  /// Constructor requires gameName and drawDate.
  /// Includes a print statement for debugging navigation arguments.
  ResultsScreen({
    super.key,
    required this.gameName,
    required this.drawDate,
  }) {
    // Debug print to verify constructor arguments upon screen creation.
    print(
        "ResultsScreen CONSTRUCTOR: gameName='$gameName', drawDate='$drawDate'");
  }

  @override
  State<ResultsScreen> createState() {
    // Debug print when the state object is created.
    print("ResultsScreen: createState() called.");
    return _ResultsScreenState();
  }
}

/// The State class for the ResultsScreen widget.
/// Manages fetching, caching, and displaying the game result data.
class _ResultsScreenState extends State<ResultsScreen> {
  // Logger instance for this screen.
  final _log = Logger('ResultsScreen');
  // Instance of the database helper.
  final dbHelper = DatabaseHelper();

  // --- State Variables ---
  // Holds the fetched or cached game result data.
  GameResultData? _resultData;
  // Holds the rules for the specific game being displayed.
  GameRule? _gameRule;
  // Flag indicating if data is currently being loaded.
  bool _isLoading = true;
  // Holds an error message if data loading fails.
  String? _errorMessage;
  // Flag indicating if the currently displayed data came from the local cache.
  bool _isDataFromCache = false;
  // Timestamp of when the cached data was fetched (if applicable).
  DateTime? _cacheTimestamp;
  // Flag indicating if the 'new_draw_flag' has been successfully cleared for this result.
  bool _flagCleared = false;

  @override
  void initState() {
    // Debug print when initState is entered.
    print("ResultsScreen STATE: initState() ENTERED.");
    _log.info(
        "ResultsScreen STATE: initState() Logger Initialized - gameName: '${widget.gameName}', drawDate: '${widget.drawDate}'");

    super.initState();
    // Configure the logger.
    LoggingUtils.setupLogger(_log);

    // --- Argument Validation ---
    // Check if required widget properties (gameName, drawDate) are valid.
    if (widget.gameName.isEmpty || widget.drawDate.isEmpty) {
      _log.severe("ResultsScreen STATE: initState - Invalid navigation arguments detected!");
      // If arguments are invalid, schedule state update after the first frame build
      // to show an error message instead of attempting to fetch data.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = "Error: Invalid navigation arguments received.";
          });
        }
      });
      return; // Stop further initialization if arguments are invalid.
    }

    // --- Initial Data Fetch ---
    // Schedule the data fetching logic to run after the first frame build.
    // This ensures context is available and avoids starting async work directly in initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _log.fine("ResultsScreen STATE: PostFrameCallback triggered.");
      if (mounted) {
        _log.info("ResultsScreen STATE: Widget is mounted, calling _fetchResultAndRules.");
        // Fetch game results and rules based on widget properties.
        _fetchResultAndRules(widget.gameName, widget.drawDate);
      } else {
        _log.warning("ResultsScreen STATE: Widget unmounted before fetch could start.");
      }
    });
    _log.info("ResultsScreen STATE: initState completed setup.");
  }

  @override
  void didChangeDependencies() {
    // This lifecycle method exists but has no custom logic here currently.
    // It's called after initState and when dependencies change.
    _log.info("ResultsScreen STATE: didChangeDependencies() ENTERED.");
    super.didChangeDependencies();
  }

  /// Fetches the game result and rules, prioritizing local cache and falling back to API.
  /// Also handles clearing the 'new_draw_flag' if applicable.
  Future<void> _fetchResultAndRules(String gameName, String drawDate) async {
    _log.info("ResultsScreen STATE: Starting _fetchResultAndRules for $gameName / $drawDate");
    // Exit if the widget is no longer mounted.
    if (!mounted) {
      _log.warning("ResultsScreen STATE: Widget unmounted during _fetchResultAndRules start.");
      return;
    }
    // Set loading state and reset previous data/errors.
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isDataFromCache = false;
      _cacheTimestamp = null;
      _resultData = null;
      _gameRule = null;
      _flagCleared = false; // Reset flag cleared status on each load.
    });

    // Temporary variables to hold loaded data.
    GameResultData? loadedData;
    GameRule? loadedRule;

    try {
      // Start fetching the game rule concurrently while checking the cache.
      final ruleFuture = dbHelper.getGameRule(gameName);

      // --- Cache Check ---
      _log.fine("ResultsScreen STATE: Checking cache for $gameName / $drawDate...");
      final cachedResult = await dbHelper.getGameResultFromCache(gameName, drawDate);

      if (!mounted) {
        _log.warning("ResultsScreen STATE: Widget unmounted after cache check.");
        return;
      }

      // If a result is found in the cache...
      if (cachedResult != null) {
        _log.info('ResultsScreen STATE: Using cache data for $gameName / $drawDate (Flag: ${cachedResult.newDrawFlag})');
        loadedData = cachedResult; // Use cached data initially.
        _isDataFromCache = true; // Mark data as coming from cache.

        // Attempt to retrieve the timestamp when the cache entry was last fetched.
        try {
          _log.fine("ResultsScreen STATE: Attempting to get cache timestamp...");
          final Database db = await dbHelper.database;
          final List<Map<String, dynamic>> maps = await db.query(
            'game_results_cache',
            columns: ['fetched_at'],
            where: 'game_name = ? AND draw_date = ?',
            whereArgs: [gameName, drawDate],
            limit: 1,
          );
          if (maps.isNotEmpty && maps.first['fetched_at'] != null) {
            // Parse the timestamp string.
            _cacheTimestamp = DateTime.tryParse(maps.first['fetched_at'] as String);
            if (_cacheTimestamp != null)
              _log.fine("ResultsScreen STATE: Cache timestamp retrieved: $_cacheTimestamp");
            else
              _log.warning("ResultsScreen STATE: Failed to parse cache timestamp string: ${maps.first['fetched_at']}");
          } else {
            _log.warning("ResultsScreen STATE: Cache timestamp not found or null in DB.");
          }
        } catch (tsError) {
          _log.warning("ResultsScreen STATE: Could not retrieve cache timestamp: $tsError");
        }

        // --- Flag Clearing ---
        // If the cached result has the 'new' flag set...
        if (cachedResult.newDrawFlag) {
          _log.info("ResultsScreen STATE: Cache data found with flag set. Attempting to clear flag...");
          // Call the helper method to clear the flag in the database.
          await _clearFlag(gameName, drawDate);
        } else {
          // If the flag is already clear, just update the local state.
          _log.info("ResultsScreen STATE: Cache data found, flag already clear.");
          if (mounted) setState(() => _flagCleared = true);
        }

        // --- Cache Validation ---
        // Check if the cached data is complete (e.g., contains draw numbers).
        // If not, discard the cached data to force an API fetch.
        if (loadedData.drawNumbers == null || loadedData.drawNumbers!.isEmpty) {
          _log.warning("ResultsScreen STATE: Cached data for $gameName / $drawDate is incomplete (missing numbers). Attempting API fetch...");
          loadedData = null; // Discard incomplete cached data.
          _isDataFromCache = false; // Mark that we need to fetch from API.
        }
      }

      // --- API Fetch (if needed) ---
      // If no valid data was loaded from cache...
      if (loadedData == null) {
        _log.info('ResultsScreen STATE: Fetching from API for $gameName / $drawDate.');
        // Call the private helper to fetch results from the API.
        final Map<String, dynamic>? apiDataMap = await _callApiForResult(gameName, drawDate);

        if (!mounted) {
          _log.warning("ResultsScreen STATE: Widget unmounted after API call.");
          return;
        }

        // If API returned valid data...
        if (apiDataMap != null && apiDataMap.isNotEmpty) {
          _log.fine("ResultsScreen STATE: Parsing API data...");
          // Parse the API response into a GameResultData object.
          loadedData = GameResultData.fromApiJson(
              json: apiDataMap, gameName: gameName, drawDate: drawDate);
          _isDataFromCache = false; // Mark data as coming from API.
          _cacheTimestamp = DateTime.now(); // Set timestamp to now.
          _log.info("ResultsScreen STATE: API data parsed successfully.");

          // If parsing was successful...
          if (loadedData != null) {
            _log.fine("ResultsScreen STATE: Attempting to update cache with fetched results...");
            // Save the fetched results back to the local cache database.
            await dbHelper.insertOrUpdateGameResultCache(loadedData);
            _log.info('ResultsScreen STATE: Updated cache for $gameName / $drawDate with fetched results.');
            // Since we just fetched, the 'new' flag (if set by DB helper) is considered cleared for this view.
            if (mounted) setState(() => _flagCleared = true);
          } else {
            // Handle case where API data couldn't be parsed correctly.
            _log.warning("ResultsScreen STATE: Parsed API data resulted in null, cannot update cache.");
            throw Exception("Failed to parse valid data from API response.");
          }
        } else {
          // Handle case where API call failed or returned no data.
          _log.warning("ResultsScreen STATE: API call for $gameName / $drawDate returned null or empty data.");
          // If we didn't have valid cache data either, throw an error.
          if (!_isDataFromCache) { // Check if we already had cache data before API call failed
            throw Exception("Failed to fetch results from API and no valid cache available.");
          }
          // If we had cache data but it was incomplete, this error indicates API couldn't provide complete data either.
          throw Exception("Failed to fetch complete results from API.");
        }
      }

      // --- Finalize Data Loading ---
      // Await the game rule future (started earlier).
      loadedRule = await ruleFuture;
      if(loadedRule == null){
        _log.warning("Failed to load GameRule for $gameName.");
        // Consider throwing an error if rules are essential for display.
      } else {
        _log.info("Successfully loaded GameRule for $gameName.");
      }

    } catch (e, stacktrace) {
      // Handle any errors during the fetching process.
      _log.severe('ResultsScreen STATE: Error in _fetchResultAndRules for $gameName / $drawDate: $e\nStacktrace: $stacktrace');
      if (mounted) {
        // Set error message to be displayed in the UI.
        setState(() {
          _errorMessage = 'Failed to load results or rules for $drawDate.\nError: ${e.toString()}';
        });
      }
    } finally {
      // This block executes regardless of success or failure.
      _log.info("ResultsScreen STATE: _fetchResultAndRules finished. Updating state.");
      if (mounted) {
        // Update the final state with loaded data (or nulls if errors occurred).
        setState(() {
          _resultData = loadedData;
          _gameRule = loadedRule;
          _isLoading = false; // Set loading to false.
        });
        _log.fine("ResultsScreen STATE: State updated. isLoading: $_isLoading, errorMessage: $_errorMessage, hasData: ${_resultData != null}, hasRule: ${_gameRule != null}");
      } else {
        _log.warning("ResultsScreen STATE: Widget unmounted before final setState.");
      }
    }
  }

  /// Clears the 'new_draw_flag' in the database for the given game and date.
  Future<void> _clearFlag(String gameName, String drawDate) async {
    _log.info("ResultsScreen STATE: Attempting to clear new_draw_flag for $gameName / $drawDate");
    try {
      // Call the database helper method.
      int rowsAffected = await dbHelper.clearNewDrawFlag(gameName, drawDate);
      if (rowsAffected > 0) {
        _log.info("ResultsScreen STATE: Successfully cleared new_draw_flag in DB.");
        // Update local state to reflect the change.
        if (mounted) setState(() => _flagCleared = true);
      } else {
        // This might happen if the flag was already 0 or the record didn't exist with flag=1.
        _log.info("ResultsScreen STATE: Flag was likely already cleared (or record not found with flag=1) for $gameName / $drawDate.");
        if (mounted) setState(() => _flagCleared = true); // Still mark as cleared locally.
      }
    } catch (e) {
      _log.severe("ResultsScreen STATE: Error calling dbHelper.clearNewDrawFlag: $e");
      if (mounted) _showSnackBar("Error updating results status.");
    }
  }

  /// Private helper to call the backend API to fetch results for a specific game/date.
  Future<Map<String, dynamic>?> _callApiForResult(String gameName, String drawDate) async {
    _log.fine("ResultsScreen STATE: Starting API call for $gameName / $drawDate");
    // Get auth token from AuthState.
    final authState = Provider.of<AuthState>(context, listen: false);
    if (authState.authToken.isEmpty) {
      _log.severe("ResultsScreen STATE: Authentication token is missing for API call.");
      throw Exception('Authentication token is missing.');
    }
    // Construct API URL.
    final url = Uri.https('governance.page', '/wp-json/apigold/v1/game-result', {
      'game_name': gameName,
      'draw_date': drawDate,
    });
    _log.info("ResultsScreen STATE: Calling API URL: ${url.toString()}");

    try {
      // Make GET request with Authorization header.
      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer ${authState.authToken}',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 20)); // Set timeout.

      _log.info("ResultsScreen STATE: API response status code: ${response.statusCode} for $gameName / $drawDate");
      _log.fine("ResultsScreen STATE: API response body: ${response.body}");

      // Handle successful response.
      if (response.statusCode == 200) {
        try {
          // Handle empty response body.
          if (response.body.isEmpty) {
            _log.warning("API result response body is empty for $gameName / $drawDate.");
            return null;
          }
          // Decode JSON response.
          final decoded = json.decode(response.body);
          if (decoded is Map<String, dynamic>) {
            _log.info("ResultsScreen STATE: API call successful and response parsed.");
            return decoded; // Return parsed map.
          } else {
            _log.severe("ResultsScreen STATE: API response was 200 but not a valid JSON object.");
            throw Exception('Invalid API response format.');
          }
        } catch (e) {
          // Handle JSON parsing errors.
          _log.severe("ResultsScreen STATE: Failed to parse API response JSON: $e");
          throw Exception('Failed to parse API response: $e');
        }
      } else {
        // Handle API errors (non-200 status).
        String errorBody = response.body;
        // Try to extract a specific error message from the response body.
        try {
          final decodedBody = json.decode(response.body);
          if (decodedBody is Map && decodedBody.containsKey('message'))
            errorBody = decodedBody['message'];
        } catch (_) { /* Ignore JSON parsing errors for the error body */ }
        _log.severe("ResultsScreen STATE: API Error (${response.statusCode}): $errorBody");
        throw Exception('API Error (${response.statusCode}): $errorBody');
      }
    } on TimeoutException catch (e) {
      // Handle timeouts.
      _log.severe("ResultsScreen STATE: API call timed out for $gameName / $drawDate: $e");
      throw Exception("Request timed out. Please try again.");
    } catch (e) {
      // Handle other network or unexpected errors.
      _log.severe("ResultsScreen STATE: Network or unexpected error during API call: $e");
      throw Exception("Network error fetching results: $e");
    }
  }

  /// Helper utility to show a SnackBar message.
  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Log state during build for debugging.
    _log.fine("ResultsScreen STATE: build() called. isLoading: $_isLoading, errorMessage: $_errorMessage, hasData: ${_resultData != null}, hasRule: ${_gameRule != null}");
    return Scaffold(
      appBar: AppBar(
        // Dynamically set title based on loading state and game name.
        title: Text('Results: ${_isLoading ? "Loading..." : widget.gameName}'),
      ),
      // Build the body content based on the current state.
      body: _buildBody(),
    );
  }

  /// Builds the main content widget based on loading, error, and data availability states.
  Widget _buildBody() {
    // Show loading indicator if data is loading.
    if (_isLoading) {
      _log.fine("ResultsScreen STATE: Building loading indicator.");
      return const Center(child: CircularProgressIndicator());
    }
    // Show error message and retry button if an error occurred.
    if (_errorMessage != null) {
      _log.fine("ResultsScreen STATE: Building error message: $_errorMessage");
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                // Retry button calls the fetch function again.
                onPressed: () => _fetchResultAndRules(widget.gameName, widget.drawDate),
                child: const Text('Retry'),
              )
            ],
          ),
        ),
      );
    }
    // Show message if essential data (results or rules) is missing after loading attempt.
    if (_resultData == null || _gameRule == null) {
      _log.warning("ResultsScreen STATE: Building 'Missing data' message. ResultData: ${_resultData != null}, GameRule: ${_gameRule != null}");
      return Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Text(
              'Required data could not be loaded for ${widget.gameName} on ${widget.drawDate}.\nPlease try refreshing.',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ));
    }

    // --- Display Results ---
    // If data is loaded successfully, build the results card.
    _log.fine("ResultsScreen STATE: Building results display for ${_resultData!.gameName}/${_resultData!.drawDate} with rules.");
    // Wrap content in RefreshIndicator for pull-to-refresh functionality.
    return RefreshIndicator(
      onRefresh: () => _fetchResultAndRules(widget.gameName, widget.drawDate),
      // Use SingleChildScrollView to allow scrolling if content exceeds screen height.
      child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(), // Ensure scrolling always works for refresh.
          padding: const EdgeInsets.all(16.0), // Padding around the card.
          // Build the main results card using a helper method.
          child: _buildRedesignedResultCard(_resultData!, _gameRule!)),
    );
  }

  /// Builds the Card widget containing the detailed game result information.
  Widget _buildRedesignedResultCard(GameResultData result, GameRule gameRule) {
    // Format the draw date for display.
    final DateFormat dateFormat = DateFormat('MMMM d, yyyy'); // Example format.
    String formattedDate = "Invalid Date";
    final parsedDate = DateTime.tryParse(result.drawDate);
    if (parsedDate != null) {
      formattedDate = dateFormat.format(parsedDate);
    } else {
      _log.warning("Could not parse drawDate '${result.drawDate}' for game '${result.gameName}' in _buildRedesignedResultCard.");
    }

    // Prepare cache information string for display.
    String cacheInfo = "";
    if (_isDataFromCache && _cacheTimestamp != null) {
      cacheInfo = " (Cached: ${DateFormat('MMM d, h:mm a').format(_cacheTimestamp!.toLocal())})";
    } else if (_isDataFromCache) {
      cacheInfo = " (From Cache)";
    }

    // Determine if the archive password should be displayed (exists and is meaningful).
    bool showPassword = result.archivePassword != null &&
        result.archivePassword!.isNotEmpty &&
        !result.archivePassword!.toLowerCase().contains('not available');

    // Check if any odds data is available to display the odds section.
    bool hasAnyOdds = result.odds6_6 != null || result.odds5_6_plus != null || result.odds5_6 != null ||
        result.odds4_6 != null || result.odds3_6 != null || result.odds2_6_plus != null ||
        result.odds2_6 != null || result.oddsAnyPrize != null;

    // Get the official odds display strings from the GameRule object.
    final officialOddsMap = gameRule.officialOddsDisplay;

    // Build the Card UI.
    return Card(
      elevation: 2.0,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, // Align content to the start.
          children: [

            // --- Section 1: Ingot Pool / Archive Results ---
            // Conditionally display archive checksum if available.
            if (result.archiveChecksum != null && result.archiveChecksum!.isNotEmpty)
              Text(
                'Ingot Pool Results for:', // Section title.
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            if (result.archiveChecksum != null && result.archiveChecksum!.isNotEmpty)
              _buildCopyableRow(context, 'Checksum:', result.archiveChecksum!), // Display checksum with copy button.
            if (result.archiveChecksum != null && result.archiveChecksum!.isNotEmpty)
              const SizedBox(height: 8), // Spacing.

            // Conditionally display winning ID if available.
            if (result.winId != null && result.winId!.isNotEmpty)
              _buildCopyableRow(context, 'Winning ID:', result.winId!), // Display win ID with copy button.
            if (result.winId != null && result.winId!.isNotEmpty)
              const SizedBox(height: 8), // Spacing.

            // --- Winning Combination Section ---
            Text('Winning Combination:', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            // Display winning numbers and bonus using Chips in a Wrap layout.
            (result.drawNumbers != null && result.drawNumbers!.isNotEmpty)
                ? Wrap(
              spacing: 8.0, // Horizontal space between chips.
              runSpacing: 4.0, // Vertical space between rows of chips.
              children: [
                // Map regular draw numbers to Chips.
                ...result.drawNumbers!.map((num) => Chip(
                  label: Text(num.toString()),
                  labelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  backgroundColor: Colors.amber[100], // Style for regular numbers.
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  visualDensity: VisualDensity.compact,
                )),
                // Conditionally display the bonus number Chip.
                if (result.bonusNumber != null)
                  Chip(
                    label: Text(result.bonusNumber.toString()),
                    labelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    backgroundColor: Colors.lightBlue[100], // Style for bonus number.
                    avatar: const Icon(Icons.star, size: 16, color: Colors.blue), // Add star icon.
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            )
            // Display placeholder text if numbers are not available.
                : const Text("Numbers not available.", style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey)),
            const SizedBox(height: 8), // Spacing.

            // --- Archive Password Section ---
            // Conditionally display the archive password with a copy button.
            if (showPassword)
              _buildCopyableRow(context, 'Magic Password:', result.archivePassword!)
            // Show placeholder text if password exists but isn't ready/available.
            else if (result.archivePassword != null)
              Text(
                'Magic Password: (Available after results processed)',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic, color: Colors.grey),
              ),
            // Add spacing if password section was shown.
            if (result.archivePassword != null)
              const SizedBox(height: 8),

            // --- Basic Info Section ---
            // Display formatted draw date and cache info.
            Text('Draw Date: $formattedDate$cacheInfo', style: Theme.of(context).textTheme.bodyMedium),
            // Display game name.
            Text('Game Name: ${result.gameName}', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8), // Spacing.

            // --- User Score Section ---
            // Display the user's score for this draw, if available.
            Text('Score for this Draw: ${result.userScore ?? "N/A"}', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.green[800], fontWeight: FontWeight.bold)),

            // Divider before the odds section.
            const Divider(height: 24.0, thickness: 1),

            // --- Section 2: Odds Display ---
            Text(
              'Ingot Odds (Official Odds)', // Section title.
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8), // Spacing.
            // Conditionally build the list of odds rows if any odds data exists.
            if (hasAnyOdds) ...[
              // Create an OddsRow widget for each available odds value.
              // Pass the label, the numeric odds value, and the official odds string from GameRule.
              if (result.odds6_6 != null) OddsRow(label: '6/6', value: result.odds6_6!, officialOddsString: officialOddsMap['6/6']),
              if (result.odds5_6_plus != null) OddsRow(label: '5/6 + Bonus', value: result.odds5_6_plus!, officialOddsString: officialOddsMap['5/6+']),
              if (result.odds5_6 != null) OddsRow(label: '5/6', value: result.odds5_6!, officialOddsString: officialOddsMap['5/6']),
              if (result.odds4_6 != null) OddsRow(label: '4/6', value: result.odds4_6!, officialOddsString: officialOddsMap['4/6']),
              if (result.odds3_6 != null) OddsRow(label: '3/6', value: result.odds3_6!, officialOddsString: officialOddsMap['3/6']),
              if (result.odds2_6_plus != null) OddsRow(label: '2/6 + Bonus', value: result.odds2_6_plus!, officialOddsString: officialOddsMap['2/6+']),
              if (result.odds2_6 != null) OddsRow(label: '2/6', value: result.odds2_6!, officialOddsString: officialOddsMap['2/6']),
              if (result.oddsAnyPrize != null) OddsRow(label: 'Any Prize', value: result.oddsAnyPrize!, officialOddsString: officialOddsMap['Any Prize']),
            ] else
            // Display placeholder text if no odds data is available.
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  "Odds data not available.",
                  style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
                ),
              ),
            // --- End Odds Section ---
          ],
        ),
      ),
    );
  }

  /// Helper widget to build a row containing a label, a value, and a copy button.
  /// Used for displaying checksum, winning ID, and password.
  Widget _buildCopyableRow(BuildContext context, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start, // Align items to the top.
      children: [
        // Display the label (e.g., "Checksum:").
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(width: 8), // Spacing between label and value.
        // Display the value, allowing it to expand and wrap if necessary. Use monospace font.
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
          ),
        ),
        // Add a copy icon button.
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy $label', // Tooltip for accessibility.
          visualDensity: VisualDensity.compact, // Reduce padding.
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(), // Remove default constraints.
          // Action performed when the copy button is pressed.
          onPressed: () {
            // Copy the value to the system clipboard.
            Clipboard.setData(ClipboardData(text: value));
            // Show a confirmation SnackBar.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$label copied!'), duration: const Duration(seconds: 1)),
            );
          },
        ),
      ],
    );
  }
} // End _ResultsScreenState

/// A StatelessWidget designed to display a single row of odds information.
/// Shows the match label (e.g., "6/6"), the calculated numeric odds (e.g., "1 : 13,983,816.00"),
/// and the official odds string (e.g., "(One in 13,983,816)").
class OddsRow extends StatelessWidget {
  final String label; // The match label (e.g., '6/6', '5/6 + Bonus').
  final double value; // The numeric odds value (e.g., 13983816.0).
  final String? officialOddsString; // The official textual representation of the odds.
  // TODO: Add poolValue comparison logic when data is available.
  // final double? poolValue;

  const OddsRow({
    super.key,
    required this.label,
    required this.value,
    this.officialOddsString,
    // this.poolValue,
  });

  @override
  Widget build(BuildContext context) {
    // Formatter for displaying the numeric odds value.
    final NumberFormat oddsFormat = NumberFormat("#,##0.00", "en_US");
    // Format the numeric part (e.g., "1 : 13,983,816.00").
    String numericOddsText = '1 : ${oddsFormat.format(value)}';
    // Format the official odds string part (e.g., " (One in 13,983,816)").
    String officialTextPart = officialOddsString != null ? ' ($officialOddsString)' : '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0), // Vertical padding for the row.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween, // Space between label and odds text.
        crossAxisAlignment: CrossAxisAlignment.start, // Align items to the top.
        children: [
          // Display the match label (e.g., "6/6").
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          // Use Expanded and RichText to display the odds text, allowing wrapping and mixed styles.
          Expanded(
            child: RichText(
              textAlign: TextAlign.right, // Align odds text to the right.
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyMedium, // Default text style for the row.
                children: [
                  // Display the numeric odds part with distinct styling.
                  TextSpan(
                    text: numericOddsText,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold, // Make numeric odds bold.
                      color: Colors.teal, // Use a distinct color.
                    ),
                  ),
                  // Display the official odds string part with less prominent styling.
                  TextSpan(
                    text: officialTextPart,
                    style: TextStyle(
                      color: Colors.grey[700], // Dimmer color.
                      fontSize: Theme.of(context).textTheme.bodySmall?.fontSize, // Slightly smaller font.
                    ),
                  ),
                  // TODO: Add TextSpan for pool odds comparison here when available.
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}