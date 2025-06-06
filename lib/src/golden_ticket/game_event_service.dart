import 'dart:async'; // Used for Timer for polling.
import 'dart:convert'; // Used for JSON encoding/decoding.
// Import material.dart cautiously - only if BuildContext is truly needed, otherwise remove.
// import 'package:flutter/material.dart';
// Import the http package for making API calls.
import 'package:http/http.dart' as http;
// Import intl package for date formatting.
import 'package:intl/intl.dart';
// Import logging framework.
import 'package:logging/logging.dart';
// Import Provider - potentially useful if needing BuildContext to access AuthState, but direct passing is used here.
// import 'package:provider/provider.dart';
// Import timezone package for handling timezone calculations (draw times, cutoffs).
import 'package:timezone/timezone.dart' as tz;

// --- Project-Specific Imports ---
// Import authentication state (needed for auth token).
import 'auth/auth_state.dart';
// Import database helper (provides GameDrawInfo model and DB access).
import 'database_helper.dart';
// Import game rules definition.
import 'game_rules.dart';
// Import the data model for game results.
import 'GameResultData.dart';
// Import logging utility.
import 'logging_utils.dart';

/// Service responsible for managing game-related events and data.
///
/// This includes:
/// - Fetching game information (next draw dates, limits) from the backend API.
/// - Calculating previous draw dates based on schedules.
/// - Fetching game results from the API.
/// - Caching game information and results locally using DatabaseHelper.
/// - Implementing a polling mechanism to automatically check for new results.
class GameEventService {
  // Logger instance for this service.
  final _log = Logger('GameEventService');
  // Instance of the database helper for local data persistence.
  final DatabaseHelper _dbHelper = DatabaseHelper();
  // Instance of AuthState, passed in constructor, used to get auth token.
  final AuthState _authState;

  // --- Polling State ---
  // Timer used for periodic polling checks.
  Timer? _pollingTimer;
  // Flag indicating if polling is currently active.
  bool _isPolling = false;
  // Interval between polling checks (e.g., check every hour).
  final Duration _pollingInterval = const Duration(hours: 1);

  // --- Caching ---
  // Simple in-memory cache for the *next* draw date string of each game.
  // Reduces redundant API calls for just the date, but DB is the source of truth for full GameDrawInfo.
  final Map<String, String?> _serviceCachedNextDrawDates = {};

  /// Constructor requires an AuthState instance to access the authentication token
  /// needed for API calls.
  GameEventService(this._authState) {
    // Setup the logger for this service instance.
    LoggingUtils.setupLogger(_log);
    _log.info("GameEventService initialized.");
  }

  /// Handles the initial population or verification of the local cache,
  /// typically called once during application startup (from main.dart) if the user is signed in.
  /// Ensures results for the last draw are cached and a placeholder for the next draw exists.
  ///
  /// Args:
  ///   [gameName]: The name of the game (e.g., "lotto649").
  ///   [lastDrawDate]: The calculated date string of the most recent past draw (YYYY-MM-DD).
  ///   [nextDrawDate]: The date string of the upcoming draw (YYYY-MM-DD).
  Future<void> handleInitialCachePopulation(String gameName, String lastDrawDate, String nextDrawDate) async {
    _log.info('Handling initial cache population for $gameName (Last: $lastDrawDate, Next: $nextDrawDate)');
    // Ensure user is signed in before proceeding.
    if (!_authState.isSignedIn || _authState.authToken.isEmpty) {
      _log.warning('Cannot populate cache: User not signed in or token missing.');
      return;
    }

    // --- Action 0: Ensure GameDrawInfo for the *next* draw is in the DB ---
    // Calling getNextDrawDate with forceRefresh=true ensures that the full draw info
    // (limits, total combinations, checksum) associated with the next draw date is fetched
    // from the API and saved to the local game_draw_info table via upsertGameDrawInfo.
    try {
      _log.fine("Ensuring GameDrawInfo is populated/updated in DB for $gameName / $nextDrawDate via getNextDrawDate(forceRefresh=true)");
      await getNextDrawDate(gameName, forceRefresh: true);
    } catch (e) {
      _log.severe("Error during forced GameDrawInfo population for $nextDrawDate: $e");
      // Decide whether to proceed if this fails. Currently logs error and continues.
    }

    // --- Action 1: Fetch and Cache Results for the *last* draw ---
    try {
      // Check if valid results (with draw numbers) for the last draw already exist in the cache.
      final existingLastDrawCache = await _dbHelper.getGameResultFromCache(gameName, lastDrawDate);
      if (existingLastDrawCache != null && (existingLastDrawCache.drawNumbers?.isNotEmpty ?? false)) {
        _log.info("Valid results for last draw $lastDrawDate already in cache. Skipping API fetch.");
      } else {
        // If not cached or cache is incomplete, fetch from API.
        _log.info("Fetching results from API for last draw: $lastDrawDate...");
        final Map<String, dynamic>? lastDrawApiData = await _callApiForResult(_authState.authToken, gameName, lastDrawDate);

        if (lastDrawApiData != null) {
          // Parse the API response into a GameResultData object.
          final GameResultData lastDrawResult = GameResultData.fromApiJson(
              json: lastDrawApiData,
              gameName: gameName,
              drawDate: lastDrawDate
          );
          // Save the parsed result to the local cache database.
          // insertOrUpdateGameResultCache handles setting the new_draw_flag appropriately.
          await _dbHelper.insertOrUpdateGameResultCache(lastDrawResult);
          _log.info('Fetched and potentially cached results for last draw: $lastDrawDate.');
        } else {
          _log.warning('Failed to fetch API results for last draw: $lastDrawDate. API returned null data.');
          // Consider creating a placeholder even for the last draw if API fails? (Currently doesn't)
        }
      }
    } catch (e, stacktrace) {
      _log.severe('Error fetching/caching last draw results ($lastDrawDate) in Service: $e\nStacktrace: $stacktrace');
    }

    // --- Action 2: Create Placeholder Cache Entry for the *next* draw ---
    // Check if a cache entry (even a placeholder) already exists for the next draw date.
    final existingNextDrawCache = await _dbHelper.getGameResultFromCache(gameName, nextDrawDate);
    if (existingNextDrawCache == null) {
      // If no entry exists, create a placeholder entry.
      try {
        // Create a GameResultData object with minimal info (no results).
        final GameResultData nextDrawPlaceholder = GameResultData(
            gameName: gameName,
            drawDate: nextDrawDate,
            newDrawFlag: false // Placeholders are never considered 'new'.
        );
        // Insert the placeholder into the cache table.
        await _dbHelper.insertOrUpdateGameResultCache(nextDrawPlaceholder);
        _log.info('Created placeholder cache entry for next draw: $nextDrawDate.');
      } catch (e) {
        _log.severe('Error creating placeholder cache for next draw ($nextDrawDate) in Service: $e');
      }
    } else {
      // If an entry already exists, skip creation.
      _log.info('Placeholder cache entry for next draw ($nextDrawDate) already exists. Skipping creation.');
    }
  }

  /// Gets the next draw date string (YYYY-MM-DD) for a given game.
  ///
  /// This method prioritizes the local service cache. If not found or `forceRefresh` is true,
  /// it fetches the full game info from the API using [_fetchGameInfo].
  /// **Crucially, it saves the fetched full game info (date, limits, totals, checksum)
  /// to the local `game_draw_info` database table via `_dbHelper.upsertGameDrawInfo`.**
  /// It also ensures the DB has the info even on a service cache hit.
  ///
  /// Args:
  ///   [gameName]: The name of the game.
  ///   [forceRefresh]: If true, bypasses the service cache and always hits the API.
  ///
  /// Returns:
  ///   The next draw date string (YYYY-MM-DD) or null if unavailable or an error occurs.
  Future<String?> getNextDrawDate(String gameName, {bool forceRefresh = false}) async {
    // Check authentication status.
    if (!_authState.isSignedIn) {
      _log.warning("Cannot get next draw date: User not signed in.");
      return null;
    }

    // --- Check Service Cache ---
    // If not forcing refresh and the date is in the service's memory cache...
    if (!forceRefresh && _serviceCachedNextDrawDates.containsKey(gameName)) {
      _log.finer("Using service cache for next draw date of $gameName.");

      // --- DB Verification on Cache Hit ---
      // Even with a service cache hit for the date string, verify the full GameDrawInfo
      // exists in the database. If not, force a refresh to populate it.
      final dbDrawInfo = await _dbHelper.getGameDrawInfo(gameName, _serviceCachedNextDrawDates[gameName]);
      if (dbDrawInfo == null) {
        _log.info("Service cache hit for $gameName date, but DB missing full GameDrawInfo. Forcing refresh.");
        // Recursive call with forceRefresh=true to ensure DB population.
        return await getNextDrawDate(gameName, forceRefresh: true);
      }
      // --- End DB Verification ---

      // If DB check passes, return the cached date string.
      return _serviceCachedNextDrawDates[gameName];
    }

    // --- Fetch from API ---
    _log.info("Fetching draw date and full game info from API for $gameName (Force refresh: $forceRefresh)");
    try {
      // Call the private helper to fetch game info from the API.
      final gameInfo = await _fetchGameInfo(_authState.authToken, gameName);
      _log.fine("Raw gameInfo received from API for $gameName: $gameInfo");

      // Check if the API returned data and contains the 'draw_date' key.
      if (gameInfo != null && gameInfo.containsKey('draw_date')) {
        final fetchedNextDrawDate = gameInfo['draw_date'] as String?;
        // Validate the fetched date string.
        if (fetchedNextDrawDate == null || fetchedNextDrawDate.isEmpty) {
          _log.warning("API returned null or empty 'draw_date' for $gameName.");
          _serviceCachedNextDrawDates.remove(gameName); // Clear potentially invalid cache.
          return null;
        }

        // --- Parse and Save Full GameDrawInfo to DB ---
        try {
          // Parse additional fields from the API response. Use the safe _parseInt helper.
          final int? totalCombinations = _parseInt(gameInfo['total_combinations']);
          final int? userRequestLimit = _parseInt(gameInfo['user_request_limit']);
          final int? userCombinationsRequested = _parseInt(gameInfo['user_combinations_requested']);
          // --- FIX START ---
          // Extract the archive checksum as a string. It might be null from the API.
          final String? archiveChecksum = gameInfo['archive_checksum'] as String?;
          // --- FIX END ---

          // Create a GameDrawInfo object with all fetched data.
          final drawInfoToSave = GameDrawInfo(
            gameName: gameName,
            drawDate: fetchedNextDrawDate,
            totalCombinations: totalCombinations,
            userRequestLimit: userRequestLimit,
            userCombinationsRequested: userCombinationsRequested,
            archiveChecksum: archiveChecksum, // <<< PASS THE EXTRACTED CHECKSUM HERE
            // lastUpdated timestamp will be set automatically by upsertGameDrawInfo.
          );
          // Log the object *with* the checksum included (or null if API didn't send it)
          _log.fine("GameDrawInfo object created before DB save: ${drawInfoToSave.toMap()}");

          // Save the complete GameDrawInfo object to the local database.
          await _dbHelper.upsertGameDrawInfo(drawInfoToSave);
          _log.info("Successfully fetched and saved GameDrawInfo to DB for $gameName / $fetchedNextDrawDate.");

        } catch (dbError) {
          _log.severe("Error saving fetched GameDrawInfo to DB for $gameName / $fetchedNextDrawDate: $dbError");
          // Log the error but still return the fetched date if available.
        }
        // --- End DB Save ---

        // Update the service's in-memory cache with the fetched date string.
        _serviceCachedNextDrawDates[gameName] = fetchedNextDrawDate;
        return fetchedNextDrawDate; // Return the successfully fetched date.

      } else {
        // Handle cases where API response is invalid or missing the draw date.
        _serviceCachedNextDrawDates.remove(gameName); // Clear cache.
        _log.warning("API did not return 'draw_date' or gameInfo was null for $gameName.");
        return null;
      }
    } catch (e) {
      // Handle exceptions during the API fetch process.
      _log.severe("Error fetching next draw date/info for $gameName: $e");
      _serviceCachedNextDrawDates.remove(gameName); // Clear potentially stale cache.
      return null;
    }
  }


  /// Calculates the date string (YYYY-MM-DD) of the most recent past draw
  /// relative to a given upcoming draw date, based on the game's schedule.
  ///
  /// Args:
  ///   [gameName]: The name of the game.
  ///   [nextDrawDateStr]: The upcoming draw date string (YYYY-MM-DD).
  ///
  /// Returns:
  ///   The previous draw date string (YYYY-MM-DD) or null if calculation fails.
  Future<String?> calculateLastDrawDate(String gameName, String? nextDrawDateStr) async {
    if (nextDrawDateStr == null) {
      _log.warning("Cannot calculate last draw date: nextDrawDateStr is null for $gameName.");
      return null;
    }
    // Fetch the game rules from the database.
    final rule = await _dbHelper.getGameRule(gameName);
    if (rule == null) {
      _log.warning("Cannot calculate last draw date: Rule not found for $gameName.");
      return null;
    }

    try {
      // Parse the next draw date string into a DateTime object.
      final nextDraw = DateTime.parse(nextDrawDateStr);
      // Parse the schedule string from the game rule into a structured list.
      final schedule = _parseDrawSchedule(rule.drawSchedule);
      if (schedule.isEmpty) {
        _log.warning("Cannot calculate last draw date: Failed to parse schedule for $gameName.");
        return null;
      }

      // Sort the schedule by weekday (1=Mon, 7=Sun) for easier calculation.
      schedule.sort((a, b) => a['weekday'].compareTo(b['weekday']));

      // Get the weekday of the next draw.
      int nextDrawWeekday = nextDraw.weekday;

      // Find the index of the next draw's weekday within the sorted schedule.
      int currentScheduleIndex = schedule.indexWhere((s) => s['weekday'] == nextDrawWeekday);
      if (currentScheduleIndex == -1) {
        // This should not happen if the nextDrawDateStr corresponds to a valid draw day.
        _log.warning("Cannot calculate last draw date: Next draw weekday ($nextDrawWeekday) not found in parsed schedule for $gameName.");
        return null;
      }

      // Determine the index of the *previous* draw day in the schedule, wrapping around if necessary.
      int previousScheduleIndex = (currentScheduleIndex - 1 + schedule.length) % schedule.length;
      int previousDrawWeekday = schedule[previousScheduleIndex]['weekday'];

      // Calculate the difference in days between the next draw and the previous draw weekday.
      // The +7 and %7 handle wrapping around the week (e.g., Sun to Sat).
      int daysToSubtract = (nextDrawWeekday - previousDrawWeekday + 7) % 7;

      // If the difference is 0, it means the previous draw was exactly 7 days ago
      // (e.g., for a weekly game, or a daily game where the previous draw was the same day last week).
      if (daysToSubtract == 0) {
        daysToSubtract = 7;
      }

      // Subtract the calculated number of days from the next draw date to get the last draw date.
      DateTime lastDrawDate = nextDraw.subtract(Duration(days: daysToSubtract));
      // Format the result as a 'yyyy-MM-dd' string.
      String formattedLastDrawDate = DateFormat('yyyy-MM-dd').format(lastDrawDate);
      _log.fine("Calculated last draw date for $gameName (next: $nextDrawDateStr) -> $formattedLastDrawDate");
      return formattedLastDrawDate;
    } catch (e, st) {
      _log.severe("Error calculating last draw date for $gameName (from next: $nextDrawDateStr): $e\n$st");
      return null;
    }
  }

  /// Determines if enough time has passed since the last draw to reasonably expect
  /// results to be available from the API.
  ///
  /// Current logic checks if the current local time is past noon on the day *after*
  /// the `lastCalculatedDrawDateStr`.
  ///
  /// Args:
  ///   [gameName]: The name of the game.
  ///   [lastCalculatedDrawDateStr]: The date string of the most recent past draw (YYYY-MM-DD).
  ///
  /// Returns:
  ///   True if it's time to check for new results, false otherwise.
  Future<bool> shouldCheckForNewDraw(String gameName, String? lastCalculatedDrawDateStr) async {
    if (lastCalculatedDrawDateStr == null) return false; // Cannot check without a date.
    // Get game rules to determine the actual draw time.
    final rule = await _dbHelper.getGameRule(gameName);
    if (rule == null) return false;
    // Calculate the specific draw time in UTC for the given date.
    final drawTimeUtc = _getDrawTimeUtcForDate(lastCalculatedDrawDateStr, rule);
    if (drawTimeUtc == null) return false; // Cannot proceed if draw time is unknown.

    try {
      // Convert the UTC draw time to the device's local timezone.
      final drawTimeLocal = tz.TZDateTime.from(drawTimeUtc, tz.local);
      // Calculate noon on the day *following* the draw date.
      final noonNextDayLocal = DateTime(drawTimeLocal.year, drawTimeLocal.month, drawTimeLocal.day + 1, 12);
      // Get the current time in the local timezone.
      final nowLocal = DateTime.now();

      // Check if the current time is after the calculated check time (noon next day).
      bool timeToCheck = nowLocal.isAfter(noonNextDayLocal);
      _log.fine("Should check for new draw for $gameName (last draw $lastCalculatedDrawDateStr)? Now: $nowLocal, Check after: $noonNextDayLocal -> $timeToCheck");
      return timeToCheck;
    } catch (e) {
      _log.severe("Error comparing dates for shouldCheckForNewDraw ($gameName): $e");
      return false; // Return false on error.
    }
  }

  /// Starts the periodic polling mechanism if it's not already running and
  /// if `shouldCheckForNewDraw` indicates it's time to start checking.
  ///
  /// Args:
  ///   [gameName]: The name of the game to potentially start polling for.
  ///   [lastCalculatedDrawDate]: The date string of the last known draw (YYYY-MM-DD).
  void startPollingIfNeeded(String gameName, String? lastCalculatedDrawDate) {
    // If polling is already active, do nothing.
    if (_isPolling) {
      _log.fine("Polling already active for $gameName.");
      return;
    }
    // Asynchronously check if polling should start.
    shouldCheckForNewDraw(gameName, lastCalculatedDrawDate).then((shouldPoll) {
      // Start polling only if it should start AND it's not already running.
      if (shouldPoll && !_isPolling) {
        _log.info("Starting polling (interval: ${_pollingInterval.inHours} hour) for $gameName...");
        _isPolling = true; // Set the polling flag.
        checkForNewDrawEvent(gameName); // Perform an initial check immediately.
        _pollingTimer?.cancel(); // Cancel any lingering timer.
        // Start the periodic timer.
        _pollingTimer = Timer.periodic(_pollingInterval, (_) {
          _log.finer("Polling timer triggered for $gameName.");
          if (_isPolling) {
            checkForNewDrawEvent(gameName); // Perform the periodic check.
          } else {
            // If _isPolling became false elsewhere, cancel the timer.
            _log.info("Polling stopped, cancelling timer for $gameName.");
            _pollingTimer?.cancel();
          }
        });
      } else {
        _log.fine("Not starting polling for $gameName. Should Poll: $shouldPoll, Is Polling: $_isPolling");
      }
    }).catchError((e) {
      // Log errors during the shouldCheckForNewDraw check.
      _log.severe("Error determining if polling should start for $gameName: $e");
    });
  }

  /// Stops the active polling timer and resets the polling flag.
  void stopPolling() {
    if (_isPolling) {
      _log.info("Stopping polling.");
      _isPolling = false; // Reset the flag.
      _pollingTimer?.cancel(); // Cancel the timer.
      _pollingTimer = null; // Clear the timer reference.
    } else {
      _log.fine("Polling not active, no need to stop.");
    }
  }

  /// Performs a check for new draw results for a specific game.
  ///
  /// This involves:
  /// 1. Fetching the *latest* next draw date from the API.
  /// 2. Calculating the corresponding *last* draw date.
  /// 3. Checking the local cache for results for that *last* draw date.
  /// 4. If results are missing or incomplete in the cache:
  ///    - Fetch results from the API for the *last* draw date.
  ///    - If successful and results contain numbers, save them to cache (setting the flag) and stop polling.
  /// 5. If results are present in the cache:
  ///    - Check the `new_draw_flag`. If set, stop polling (results are already known locally).
  ///
  /// Args:
  ///   [gameName]: The name of the game to check.
  ///
  /// Returns:
  ///   True if new results were fetched and processed successfully, false otherwise.
  Future<bool> checkForNewDrawEvent(String gameName) async {
    _log.info("Checking for new draw event for $gameName...");
    // Ensure user is signed in.
    if (!_authState.isSignedIn) {
      _log.warning("Not signed in, stopping polling check for $gameName.");
      stopPolling();
      return false;
    }

    String? apiNextDrawDate;
    String? calculatedLastDrawDate;
    bool newEventProcessed = false; // Flag to indicate if new results were fetched/saved.

    try {
      // Step 1: Get the absolute latest next draw date from the API.
      // Use forceRefresh=true to bypass service cache and ensure DB GameDrawInfo is updated.
      apiNextDrawDate = await getNextDrawDate(gameName, forceRefresh: true);
      if (apiNextDrawDate == null) {
        _log.warning("Could not get next_draw_date from API for $gameName during polling check.");
        return false; // Cannot proceed without the latest date.
      }

      // Step 2: Calculate the last draw date based on the latest next draw date.
      calculatedLastDrawDate = await calculateLastDrawDate(gameName, apiNextDrawDate);
      if (calculatedLastDrawDate == null) {
        _log.warning("Could not calculate last draw date for $gameName from next date $apiNextDrawDate during polling check.");
        return false; // Cannot proceed.
      }

      // Step 3: Check the local cache for results corresponding to the calculated last draw date.
      final cachedResult = await _dbHelper.getGameResultFromCache(gameName, calculatedLastDrawDate);

      // Step 4: Handle Cache Miss or Incomplete Cache.
      if (cachedResult == null || (cachedResult.drawNumbers?.isEmpty ?? true)) {
        _log.info("NEW DRAW DETECTED or CACHE INCOMPLETE for $gameName: Cache miss/incomplete for calculated last draw date $calculatedLastDrawDate.");
        _log.info("Fetching results from API for $gameName / $calculatedLastDrawDate...");
        try {
          // Fetch results from the API for the date we expect them.
          final resultApiData = await _callApiForResult(_authState.authToken, gameName, calculatedLastDrawDate);
          if (resultApiData != null && resultApiData.isNotEmpty) {
            // Parse the API data.
            final fetchedResultData = GameResultData.fromApiJson(
                json: resultApiData,
                gameName: gameName,
                drawDate: calculatedLastDrawDate
            );
            // Check if the fetched results actually contain winning numbers.
            if (fetchedResultData.drawNumbers != null && fetchedResultData.drawNumbers!.isNotEmpty) {
              // Save the valid results to the cache (this sets the new_draw_flag).
              await _dbHelper.insertOrUpdateGameResultCache(fetchedResultData);
              _log.info("Fetched/saved new results for $gameName / $calculatedLastDrawDate. Flag automatically set by DB helper.");
              newEventProcessed = true; // Mark that new results were processed.
              stopPolling(); // Stop polling as we've successfully handled the new results.
            } else {
              // API returned data but no numbers yet - results might not be finalized. Keep polling.
              _log.warning("API for $calculatedLastDrawDate returned data but no winning numbers. Polling continues.");
            }
          } else {
            // API call failed or returned empty data. Keep polling.
            _log.warning("API call for new draw results $gameName / $calculatedLastDrawDate returned null or empty. Polling continues.");
          }
        } catch (e) {
          // Handle errors during the API fetch/save process. Keep polling.
          _log.severe("Failed to fetch/save results for new draw $gameName / $calculatedLastDrawDate: $e");
        }
      }
      // Step 5: Handle Cache Hit.
      else {
        _log.fine("Results already exist in cache for $gameName / $calculatedLastDrawDate.");
        // Check the flag on the existing cached data.
        if (cachedResult.newDrawFlag) {
          // If the flag is set, it means new results are already cached locally. Stop polling.
          _log.info("Existing cache entry for $calculatedLastDrawDate has flag set. New results ready. Stopping polling.");
          stopPolling();
        } else {
          // If the flag is clear, the cached results have been seen. Continue polling if active.
          _log.fine("Existing cache entry for $calculatedLastDrawDate has flag cleared. Polling continues if needed.");
        }
      }
    } catch (e) {
      // Handle any other errors during the check process.
      _log.severe("Error during checkForNewDrawEvent for $gameName: $e");
      // Consider whether to stop polling on general errors. Currently continues.
    }
    return newEventProcessed; // Return whether new results were fetched and saved.
  }


  // --- Private Helper Methods ---

  /// Parses the draw schedule string (e.g., "Day HH:mm TZID,Day HH:mm TZID")
  /// from GameRule into a more usable list of maps.
  /// Each map contains 'weekday', 'hour', 'minute', 'tzId'.
  List<Map<String, dynamic>> _parseDrawSchedule(String scheduleString) {
    List<Map<String, dynamic>> schedule = [];
    // Map of weekday abbreviations to DateTime weekday constants (Monday=1, Sunday=7).
    final dayMap = {'Mon': 1, 'Tue': 2, 'Wed': 3, 'Thu': 4, 'Fri': 5, 'Sat': 6, 'Sun': 7};
    // Split the schedule string by commas for multiple draw times/days.
    final parts = scheduleString.split(',');

    for (String part in parts) {
      // Split each part into components: Day, Time (HH:mm), TimezoneID.
      final components = part.trim().split(' ');
      if (components.length == 3) {
        int? weekday = dayMap[components[0]]; // Get the numeric weekday.
        final timeParts = components[1].split(':'); // Split HH:mm.
        final tzId = components[2]; // Timezone ID (e.g., 'America/Edmonton').

        // Validate parsed components.
        if (weekday != null && timeParts.length == 2) {
          try {
            int hour = int.parse(timeParts[0]);
            int minute = int.parse(timeParts[1]);
            // Basic validation of Timezone ID format.
            if (tzId.contains('/')) {
              schedule.add({'weekday': weekday, 'hour': hour, 'minute': minute, 'tzId': tzId});
            } else {
              _log.warning("Invalid Timezone ID format skipped: $tzId in schedule part '$part'");
            }
          } catch (e) {
            _log.warning("Error parsing time component '$part': $e");
          }
        }
      } else {
        _log.warning("Invalid schedule part format skipped: '$part'");
      }
    }
    return schedule;
  }

  /// Calculates the exact draw time in UTC for a specific date,
  /// using the game's rule schedule and timezone information.
  ///
  /// Args:
  ///   [drawDateStr]: The specific date string (YYYY-MM-DD) to calculate the draw time for.
  ///   [rule]: The GameRule object containing the schedule.
  ///
  /// Returns:
  ///   The draw time as a UTC DateTime object, or null if calculation fails.
  DateTime? _getDrawTimeUtcForDate(String drawDateStr, GameRule? rule) {
    if (rule == null) return null;
    try {
      // Parse the target date string.
      final targetDate = DateTime.parse(drawDateStr);
      // Get the weekday of the target date.
      final targetWeekday = targetDate.weekday;
      // Parse the game's schedule string.
      final schedule = _parseDrawSchedule(rule.drawSchedule);

      // Find the schedule entry matching the target date's weekday.
      for (var drawInfo in schedule) {
        if (drawInfo['weekday'] == targetWeekday) {
          try {
            // Get the timezone location object using the ID from the schedule.
            // Requires the timezone database to be initialized (done in main.dart).
            final location = tz.getLocation(drawInfo['tzId']);
            // Construct the draw DateTime in its specific timezone.
            final drawTimeInTz = tz.TZDateTime(
                location,
                targetDate.year,
                targetDate.month,
                targetDate.day,
                drawInfo['hour'],
                drawInfo['minute']
            );
            // Convert the timezone-specific DateTime to UTC for consistent comparisons.
            return drawTimeInTz.toUtc();
          } catch (e) {
            // Handle errors, e.g., invalid timezone ID.
            _log.severe("Timezone Error processing schedule for ${drawInfo['tzId']}: $e. Ensure timezone database is initialized.");
            // Continue loop in case other schedule parts are valid.
          }
        }
      }
      // If no matching schedule entry was found for the target date's weekday.
      _log.warning("Could not find matching schedule entry for ${rule.gameName} on weekday $targetWeekday (Date: $drawDateStr)");
      return null;
    } catch (e, st) {
      _log.severe("Error calculating draw time UTC for ${rule.gameName}/$drawDateStr: $e\n$st");
      return null;
    }
  }

  /// Private helper to fetch general game information (next draw date, limits, etc.)
  /// from the `/game-info` API endpoint. Requires authentication.
  Future<Map<String, dynamic>?> _fetchGameInfo(String authToken, String gameName) async {
    if (authToken.isEmpty) {
      _log.severe("Auth token missing for _fetchGameInfo");
      throw Exception("Auth token missing");
    }
    // Construct the API URL.
    final url = Uri.https('governance.page', '/wp-json/apigold/v1/game-info', {'game_name': gameName});
    _log.fine("Fetching game info from: ${url.path}?game_name=$gameName");
    try {
      // Make the GET request with Authorization header.
      final response = await http.get(
          url,
          headers: {'Authorization': 'Bearer $authToken'}
      ).timeout(const Duration(seconds: 15)); // Set timeout.

      _log.fine("Game info response for $gameName (${response.statusCode})");
      // Check for successful response.
      if (response.statusCode == 200) {
        try {
          // Handle empty response body.
          if (response.body.isEmpty) {
            _log.warning("Game info API response body is empty for $gameName.");
            return null;
          }
          // Decode and return the JSON response.
          return json.decode(response.body) as Map<String, dynamic>;
        } catch (e) {
          _log.severe("Failed to parse game info API response JSON for $gameName: $e");
          throw Exception("Failed to parse API response: $e");
        }
      } else {
        // Handle API errors (non-200 status).
        _log.warning("Game info API Error for $gameName (${response.statusCode}): ${response.body}");
        throw Exception("API Error (${response.statusCode})");
      }
    } on TimeoutException catch (e) {
      // Handle timeouts.
      _log.severe("Game info API call timed out for $gameName: $e");
      throw Exception("Request timed out");
    } catch (e) {
      // Handle other network or unexpected errors.
      _log.severe("Network error fetching game info for $gameName: $e");
      throw Exception("Network error fetching game info: $e");
    }
  }

  /// Private helper to fetch specific game results from the `/game-result` API endpoint
  /// for a given game and date. Requires authentication. Returns nullable map.
  Future<Map<String, dynamic>?> _callApiForResult(String authToken, String gameName, String drawDate) async {
    if (authToken.isEmpty) {
      _log.severe("Auth token missing for _callApiForResult");
      throw Exception('Auth token missing.');
    }
    // Construct the API URL with query parameters.
    final url = Uri.https('governance.page', '/wp-json/apigold/v1/game-result', {
      'game_name': gameName,
      'draw_date': drawDate,
    });
    _log.info("Calling API for results: ${url.path}?game_name=$gameName&draw_date=$drawDate");

    try {
      // Make the GET request with Authorization header.
      final response = await http.get(
          url,
          headers: {
            'Authorization': 'Bearer $authToken',
            'Content-Type': 'application/json', // Optional for GET, but can be included.
          }
      ).timeout(const Duration(seconds: 20)); // Set timeout.

      _log.fine("API result response status: ${response.statusCode} for $gameName / $drawDate");

      // Check for successful response.
      if (response.statusCode == 200) {
        try {
          // Handle empty response body.
          if (response.body.isEmpty) {
            _log.warning("API result response body is empty for $gameName / $drawDate.");
            return null;
          }
          // Decode and return the JSON response.
          return json.decode(response.body) as Map<String, dynamic>;
        } catch (e) {
          _log.severe("Failed to parse API result response JSON for $gameName / $drawDate: $e");
          throw Exception('Failed to parse API response: $e');
        }
      } else {
        // Handle API errors (non-200 status). Try to extract a message.
        String errorBody = response.body;
        try {
          final decodedBody = json.decode(response.body);
          if (decodedBody is Map && decodedBody.containsKey('message')) {
            errorBody = decodedBody['message'];
          }
        } catch (_) { /* Ignore parsing errors for the error body */ }
        _log.severe("API Result Error for $gameName / $drawDate (${response.statusCode}): $errorBody");
        throw Exception('API Error (${response.statusCode}): $errorBody');
      }
    } on TimeoutException catch(e) {
      // Handle timeouts.
      _log.severe("API result call timed out for $gameName / $drawDate: $e");
      throw Exception("Request timed out. Please try again.");
    } catch (e) {
      // Handle other network or unexpected errors.
      _log.severe("Network or unexpected error during API result call for $gameName / $drawDate: $e");
      throw Exception("Network error fetching results: $e");
    }
  }

  /// Static helper method for safely parsing dynamic values into integers.
  /// Returns null if parsing fails.
  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    if (value is double) return value.round(); // Allow rounding doubles.
    // Log warning if parsing fails (cannot use instance logger in static method).
    print("[GameEventService._parseInt] Warning: Could not parse value as int: $value (Type: ${value.runtimeType})");
    return null;
  }


  /// Cleans up resources used by the service, specifically stopping the polling timer.
  /// Should be called when the service is no longer needed (e.g., in main app disposal).
  void dispose() {
    _log.info("Disposing GameEventService.");
    stopPolling(); // Ensure the polling timer is cancelled.
  }
}
