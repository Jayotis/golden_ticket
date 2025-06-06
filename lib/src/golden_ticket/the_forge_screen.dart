import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math'; // For Random
import 'package:confetti/confetti.dart';
import 'package:logging/logging.dart';
import 'dart:async'; // For Timer
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

// Import project files (adjust paths if needed)
import 'ingot_crucible.dart'; // *** UPDATED IMPORT *** (was play_card.dart)
import 'logging_utils.dart';
import 'auth/auth_state.dart';
import 'database_helper.dart'; // Assumed to contain updated GameDrawInfo
import 'game_rules.dart';
import 'routes.dart'; // For Back button navigation

/// A screen where users can manage their "Ingot Crucible" by:
/// 1. Smelting "Ingots" (combinations) from the server.
/// 2. Storing Ingots in a local collection.
/// 3. Placing Ingots from the collection onto the Crucible.
/// 4. Forging the final Crucible tickets via API call.
class TheForgeScreen extends StatefulWidget {
  const TheForgeScreen({super.key});
  static const routeName = Routes.theForge; // Use constant from routes.dart

  @override
  State<TheForgeScreen> createState() => _TheForgeScreenState();
}

class _TheForgeScreenState extends State<TheForgeScreen> {
  final _log = Logger('TheForgeScreen');
  final dbHelper = DatabaseHelper();

  // State variables
  bool _isLoading = true;
  String? _errorMessage;
  late String _gameName;
  late String _targetDrawDate;
  GameRule? _currentGameRule;
  int? _totalCombinations;
  int? _requestsUsed;
  int? _requestLimit;
  String? _archiveChecksum; // <<< Added state variable for the checksum
  int _calculatedRequestsRemaining = 0;
  DateTime? _cutoffTimeUtc;
  bool _isPastCutoff = false;
  Timer? _timer;

  // *** RENAMED STATE VARIABLES ***
  IngotCrucible? _currentCrucible; // Was _currentPlayCard
  List<CombinationWithId> _ingotCollection = [];
  CombinationWithId? _selectedIngotFromCollection;
  CombinationWithId? _selectedIngotInCrucible; // Was _selectedCombinationOnPlayCard

  bool _isCrucibleLocked = false; // Was _isPlayCardLocked
  bool _isForging = false; // Was _isLockingIn
  bool _isSmelting = false; // Was _isCasting
  // *** END RENAMED STATE VARIABLES ***

  // Confetti controllers
  late ConfettiController _confettiController;
  late ConfettiController _sparksController;

  // Helper getter
  bool get _interactionsDisabled =>
      _isLoading ||
          _isPastCutoff ||
          _isCrucibleLocked ||
          _isForging ||
          _isSmelting;

  @override
  void initState() {
    super.initState();
    LoggingUtils.setupLogger(_log);
    _confettiController =
        ConfettiController(duration: const Duration(seconds: 2));
    _sparksController =
        ConfettiController(duration: const Duration(seconds: 1));
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) {
        _updateCutoffStatus();
      } else {
        timer.cancel();
      }
    });
    // Data loading moved to didChangeDependencies to access arguments
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Load data only once when dependencies first change
    // Use a flag to prevent reloading if already loaded/loading
    if (_isLoading && ModalRoute.of(context)?.settings.arguments != null) {
      _processArgumentsAndLoadData();
    } else if (ModalRoute.of(context)?.settings.arguments == null &&
        _isLoading) {
      // Handle case where arguments are missing but maybe shouldn't be
      _log.severe(
          "didChangeDependencies called but arguments are null. Cannot load data.");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = "Error: Navigation arguments missing.";
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _confettiController.dispose();
    _sparksController.dispose();
    super.dispose();
  }

  /// Processes arguments and loads data (Crucible AND Ingot Collection).
  Future<void> _processArgumentsAndLoadData() async {
    // Prevent multiple concurrent loads
    // Check if _isLoading is already false (meaning load completed or failed)
    if (!_isLoading) {
      _log.fine(
          "Load already completed or failed, skipping _processArgumentsAndLoadData.");
      return;
    }

    if (!mounted) return;

    final arguments =
    ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

    if (arguments == null ||
        arguments['gameName'] == null ||
        arguments['nextDrawDate'] == null) {
      _log.severe(
          "TheForgeScreen requires 'gameName' and 'nextDrawDate' arguments.");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = "Error: Missing required navigation data.";
        });
      }
      return;
    }

    // Set loading state now that arguments are validated
    // No need for setState here as it's the initial state or already true
    // _isLoading = true; // Ensure it's true if called again somehow
    _errorMessage = null; // Reset error message on new load attempt

    _gameName = arguments['gameName'] as String;
    _targetDrawDate = arguments['nextDrawDate'] as String;
    _log.info(
        "Loading data for Forge: game=$_gameName, targetDrawDate=$_targetDrawDate");

    final authState = Provider.of<AuthState>(context, listen: false);
    int? currentUserId;
    try {
      currentUserId = int.parse(authState.userId);
    } catch (e) {
      _log.severe("Invalid User ID in AuthState: ${authState.userId}");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = "Error: Invalid User ID.";
        });
      }
      return;
    }

    // --- MODIFICATION START: Flag to track if initial save is needed ---
    bool needsInitialSave = false;
    // --- MODIFICATION END ---

    try {
      // Fetch rule, draw info, crucible, and collection concurrently
      final ruleFuture = dbHelper.getGameRule(_gameName);
      final drawInfoFuture =
      dbHelper.getGameDrawInfo(_gameName, _targetDrawDate);
      final crucibleFuture =
      dbHelper.getUserCrucibleForDraw(currentUserId, _targetDrawDate); // Use renamed method
      final ingotCollectionFuture = dbHelper.getIngotCollection(
          currentUserId, _gameName, _targetDrawDate);

      final results = await Future.wait(
          [ruleFuture, drawInfoFuture, crucibleFuture, ingotCollectionFuture]);
      if (!mounted) return;

      _currentGameRule = results[0] as GameRule?;
      final GameDrawInfo? drawInfo = results[1]
      as GameDrawInfo?; // Assumes GameDrawInfo includes archiveChecksum
      final IngotCrucible? loadedCrucible = results[2] as IngotCrucible?; // Load into temp variable
      _ingotCollection = results[3] as List<CombinationWithId>;

      // *** ADDED LOGGING: Log loaded crucible data ***
      if (loadedCrucible != null) {
        _log.fine(
            "Loaded Crucible from DB: ID=${loadedCrucible.id}, Status=${loadedCrucible.status}, Combinations=${loadedCrucible.combinations.length}");
        _log.finest(
            "Loaded Crucible details: ${loadedCrucible.toString()}"); // Log full details at finest level
      } else {
        _log.info("No Crucible found in DB for this draw.");
      }
      _currentCrucible = loadedCrucible; // Assign to state variable
      // *** END ADDED LOGGING ***

      _log.info("Loaded ${_ingotCollection.length} ingots from collection.");

      if (_currentGameRule == null) {
        throw Exception("Failed to load game rule.");
      }
      if (drawInfo == null) {
        throw Exception("Required draw information not found.");
      }

      _totalCombinations = drawInfo.totalCombinations;
      _requestsUsed = drawInfo.userCombinationsRequested;
      _requestLimit = drawInfo.userRequestLimit;
      _archiveChecksum =
          drawInfo.archiveChecksum; // <<< Assign the checksum here
      int limit = _requestLimit ?? 0;
      int used = _requestsUsed ?? 0;
      _calculatedRequestsRemaining = (limit - used) < 0 ? 0 : (limit - used);
      _log.info(
          'Smelt limits loaded: Used: $used, Limit: $limit, Remaining: $_calculatedRequestsRemaining');
      _log.info('Archive Checksum loaded: $_archiveChecksum'); // Log checksum

      if (_currentCrucible == null) {
        _log.info(
            'No existing crucible found for $_targetDrawDate. Creating new one.');
        DateTime? parsedDrawDate = DateTime.tryParse(_targetDrawDate);
        if (parsedDrawDate == null) {
          throw Exception("Invalid target draw date provided.");
        }
        _currentCrucible = IngotCrucible(
            combinations: [],
            status: 'draft',
            submittedDate: DateTime.now(),
            drawDate: parsedDrawDate,
            userId: currentUserId,
            name: "$_gameName Crucible");

        needsInitialSave = true;
      }

      _cutoffTimeUtc = _calculateCutoffTime(_targetDrawDate, _currentGameRule);
      _updateCutoffStatus(); // Initial check
      _isCrucibleLocked = (_currentCrucible?.status == 'locked' ||
          _currentCrucible?.status == 'submitted');
      if (_isCrucibleLocked) {
        _log.info(
            "Crucible loaded with locked status: '${_currentCrucible?.status}'");
      }
    } catch (e, stacktrace) {
      _log.severe(
          "Error loading data for Forge screen: $e\nStack: $stacktrace");
      if (mounted) {
        // Set error message but keep loading true until finally block
        _errorMessage = "Error loading required data: ${e.toString()}";
      }
    } finally {
      // Perform initial save here if needed ---
      if (mounted && needsInitialSave && _currentCrucible != null) {
        _log.info("Performing initial save of newly created draft crucible...");
        // Call save without the isLoading check interfering
        await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true);
      }
      //

      // Set loading to false only after all loading and potential initial save are done
      if (mounted) {
        setState(() {
          _isLoading = false;
          // _errorMessage might have been set in the catch block
        });
      }
    }
  }

  /// Calculates the cutoff time (UTC).
  DateTime? _calculateCutoffTime(String drawDateStr, GameRule? rule) {
    if (rule == null) return null;
    try {
      DateTime targetDrawDay = DateTime.parse(drawDateStr);
      List<Map<String, dynamic>> possibleDraws = [];
      final dayMap = {
        'Mon': 1,
        'Tue': 2,
        'Wed': 3,
        'Thu': 4,
        'Fri': 5,
        'Sat': 6,
        'Sun': 7
      };
      final scheduleParts = rule.drawSchedule.split(',');
      for (String part in scheduleParts) {
        final components = part.trim().split(' ');
        if (components.length == 3) {
          int? weekday = dayMap[components[0]];
          final timeParts = components[1].split(':');
          final tzId = components[2];
          if (weekday != null && timeParts.length == 2 && tzId.contains('/')) {
            int hour = int.parse(timeParts[0]);
            int minute = int.parse(timeParts[1]);
            possibleDraws.add({
              'weekday': weekday,
              'hour': hour,
              'minute': minute,
              'tzId': tzId
            });
          } else {
            _log.warning("Invalid schedule part format skipped: '$part'");
          }
        } else {
          _log.warning("Invalid schedule part format skipped: '$part'");
        }
      }
      if (possibleDraws.isEmpty) {
        _log.warning(
            "Could not parse any valid draw schedules from: ${rule.drawSchedule}");
        return null;
      }
      tz.TZDateTime? foundDrawTime;
      int targetWeekday = targetDrawDay.weekday;
      for (var drawInfo in possibleDraws) {
        if (drawInfo['weekday'] == targetWeekday) {
          try {
            final location = tz.getLocation(drawInfo['tzId']);
            final potentialDraw = tz.TZDateTime(
                location,
                targetDrawDay.year,
                targetDrawDay.month,
                targetDrawDay.day,
                drawInfo['hour'],
                drawInfo['minute']);
            if (potentialDraw.year == targetDrawDay.year &&
                potentialDraw.month == targetDrawDay.month &&
                potentialDraw.day == targetDrawDay.day) {
              foundDrawTime = potentialDraw;
              break;
            } else {
              _log.warning(
                  "Potential draw time $potentialDraw does not match target date $targetDrawDay after timezone conversion.");
            }
          } catch (e) {
            _log.severe(
                "Timezone Error processing schedule for ${drawInfo['tzId']}: $e.");
          }
        }
      }
      if (foundDrawTime == null) {
        _log.severe(
            "Could not determine the exact draw time instance for ${rule.gameName} on $drawDateStr using schedule ${rule.drawSchedule}");
        return null;
      }

      // --- USE ACTUAL CUTOFF LOGIC (e.g., subtract duration) ---
      // Example: Cutoff is 1 hour before the draw
      DateTime cutoffTime = foundDrawTime.subtract(const Duration(hours: 1));
      _log.fine(
          "Calculated draw time for ${rule.gameName} on $drawDateStr: $foundDrawTime, Cutoff: $cutoffTime (Timezone: ${foundDrawTime.location.name})");

      return cutoffTime.toUtc();
    } catch (e, stacktrace) {
      _log.severe(
          "Error calculating cutoff time for ${rule?.gameName} / $drawDateStr: $e\nStack: $stacktrace");
      return null;
    }
  }

  /// Updates the `_isPastCutoff` state variable.
  void _updateCutoffStatus() {
    if (_cutoffTimeUtc != null) {
      final nowUtc = DateTime.now().toUtc();
      final newStatus = nowUtc.isAfter(_cutoffTimeUtc!);
      if (newStatus != _isPastCutoff && mounted) {
        setState(() {
          _isPastCutoff = newStatus;
        });
        _log.fine(
            "Cutoff status updated: IsPastCutoff = $newStatus (Now: $nowUtc, Cutoff: $_cutoffTimeUtc)");
      }
    } else if (!_isPastCutoff && mounted) {
      // Only log/set if not loading and cutoff is unknown
      if (!_isLoading) {
        _log.warning("Cutoff time could not be calculated, assuming cutoff passed.");
        setState(() => _isPastCutoff = true);
      }
    }
  }

  /// Fetches a new ingot from the API and adds it to the local collection.
  Future<void> _smeltIngot() async {
    // Guard clauses removed comments, kept logic
    if (_interactionsDisabled || _isSmelting) {
      return;
    }
    if (_calculatedRequestsRemaining <= 0) {
      _showSnackBar("Cannot smelt ingot: No smelts remaining.");
      return;
    }
    if (_totalCombinations == null) {
      _showSnackBar('Game data not loaded.');
      return;
    }
    final authState = Provider.of<AuthState>(context, listen: false);
    if (authState.authToken.isEmpty) {
      _showSnackBar('Authentication error.');
      return;
    }

    setState(() {
      _isSmelting = true;
    });
    final url =
    Uri.https('governance.page', '/wp-json/apigold/v1/request-combination');
    final randomNumber = Random().nextInt(_totalCombinations!) + 1;
    int? previousRequestsUsed = _requestsUsed;
    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${authState.authToken}',
        },
        body: jsonEncode({
          'game_name': _gameName,
          'draw_date': _targetDrawDate,
          'combination_number': randomNumber,
        }),
      );
      _log.info('Smelt Request - Response status code: ${response.statusCode}');
      _log.fine('Smelt Request - Response body: ${response.body}');
      if (!mounted) return;
      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final ingotId = responseData['combination_sequence_id'];
        final combinationNumbersRaw = responseData['combination_numbers'];
        final int? updatedRequestsUsed =
        responseData['user_requests_count'] as int?;
        if (ingotId is! int) {
          throw FormatException('Invalid Ingot ID received');
        }
        if (updatedRequestsUsed == null) {
          throw FormatException('Missing updated request count from server');
        }
        List<int>? parsedCombinationNumbers;
        if (combinationNumbersRaw is List && combinationNumbersRaw.isNotEmpty) {
          parsedCombinationNumbers = combinationNumbersRaw
              .map((e) => int.parse(e.toString()))
              .toList();
        } else {
          throw FormatException('Invalid combination numbers received');
        }
        await dbHelper.addIngotToCollection(
          userId: int.parse(authState.userId),
          gameName: _gameName,
          drawDate: _targetDrawDate,
          ingotId: ingotId,
          numbers: parsedCombinationNumbers,
        );
        await _updateDbRequestCount(updatedRequestsUsed);
        if (mounted) {
          setState(() {
            _ingotCollection.insert(
                0,
                CombinationWithId(
                    ingotId: ingotId, numbers: parsedCombinationNumbers!));
            _requestsUsed = updatedRequestsUsed;
            int limit = _requestLimit ?? 0;
            _calculatedRequestsRemaining =
            (limit - _requestsUsed!) < 0 ? 0 : (limit - _requestsUsed!);
            _log.info(
                'Smelt counts updated: Used=$_requestsUsed, Remaining=$_calculatedRequestsRemaining');
          });
        }
        _showSnackBar("Ingot #$ingotId added to collection!");
        _sparksController.play();
      } else {
        _log.warning('Failed to smelt ingot: ${response.body}');
        String message =
            'Failed to smelt ingot (Status: ${response.statusCode})';
        try {
          message = json.decode(response.body)['message'] ?? message;
        } catch (_) {}
        _showSnackBar(message);
      }
    } catch (e, stacktrace) {
      _log.severe('Error smelting/processing ingot: $e', e, stacktrace);
      _showSnackBar('Error smelting ingot: ${e.toString()}');
      if (mounted && previousRequestsUsed != null) {
        setState(() {
          _requestsUsed = previousRequestsUsed;
          int limit = _requestLimit ?? 0;
          _calculatedRequestsRemaining =
          (limit - _requestsUsed!) < 0 ? 0 : (limit - _requestsUsed!);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSmelting = false;
        });
      }
    }
  }

  /// Updates the request count in the `game_draw_info` table.
  Future<void> _updateDbRequestCount(int newRequestCount) async {
    if (!mounted) return;
    _log.info(
        "Updating DB request count for $_gameName / $_targetDrawDate to $newRequestCount");
    try {
      // Fetch existing info first to preserve other fields if necessary
      // Although upsertGameDrawInfo in helper might handle this, being explicit can be safer
      final existingInfo =
      await dbHelper.getGameDrawInfo(_gameName, _targetDrawDate);
      final infoToUpdate = GameDrawInfo(
        gameName: _gameName,
        drawDate: _targetDrawDate,
        userCombinationsRequested: newRequestCount,
        // Preserve existing values if available, otherwise use current state
        userRequestLimit: existingInfo?.userRequestLimit ?? _requestLimit,
        totalCombinations: existingInfo?.totalCombinations ?? _totalCombinations,
        archiveChecksum: existingInfo?.archiveChecksum ?? _archiveChecksum, // Preserve checksum
      );
      await dbHelper.upsertGameDrawInfo(infoToUpdate);
      _log.info("DB request count updated successfully.");
    } catch (e) {
      _log.severe("Failed to update request count in DB: $e");
      _showSnackBar("Error saving request count update.");
    }
  }

  /// Adds the selected ingot from collection to the next empty slot on the Crucible.
  Future<void> _addSelectedIngotToCrucible() async {
    // Guard clauses removed comments, kept logic
    if (_interactionsDisabled) {
      _showSnackBar("Cannot modify crucible now.");
      return;
    }
    if (_selectedIngotFromCollection == null) {
      _showSnackBar("Select an ingot from your collection first.");
      return;
    }
    if (_currentCrucible == null) {
      _log.severe("Crucible object is null, cannot add ingot.");
      _showSnackBar("Error: Crucible data not available.");
      return;
    }
    final maxSlots = _currentGameRule?.regularBallsDrawn ?? 6;
    if (_currentCrucible!.combinations.length >= maxSlots) {
      _showSnackBar("Crucible is full. Select a slot to replace.");
      return;
    }

    final ingotToAdd = _selectedIngotFromCollection!;
    _currentCrucible!.addCombination(ingotToAdd);
    try {
      await dbHelper.removeIngotFromCollection(ingotToAdd.ingotId);
      if (mounted) {
        setState(() {
          _ingotCollection
              .removeWhere((ingot) => ingot.ingotId == ingotToAdd.ingotId);
          _selectedIngotFromCollection = null;
        });
        await _saveDraftCrucible(); // Calls save
        _confettiController.play();
        _showSnackBar("Ingot #${ingotToAdd.ingotId} added to crucible.");
      }
    } catch (e) {
      _log.severe(
          "Error removing ingot ${ingotToAdd.ingotId} from collection DB: $e");
      // Rollback UI change if DB operation failed
      _currentCrucible!.combinations.remove(ingotToAdd);
      _showSnackBar("Error updating collection.");
      if (mounted) setState(() {});
    }
  }

  /// Swaps a selected ingot in the crucible with the selected ingot from the collection.
  Future<void> _swapCrucibleAndCollectionIngots() async {
    // Guard clauses removed comments, kept logic
    if (_interactionsDisabled) {
      _showSnackBar("Cannot modify crucible now.");
      return;
    }
    if (_selectedIngotFromCollection == null) {
      _showSnackBar("Select an ingot from your collection to swap.");
      return;
    }
    if (_selectedIngotInCrucible == null) {
      _showSnackBar("Select a slot on the Crucible to replace.");
      return;
    }
    if (_currentCrucible == null) {
      _log.severe("Crucible object is null, cannot swap ingots.");
      _showSnackBar("Error: Crucible data not available.");
      return;
    }

    final ingotFromCollection = _selectedIngotFromCollection!;
    final ingotInCrucible = _selectedIngotInCrucible!;
    int indexInCrucible = _currentCrucible!.combinations
        .indexWhere((c) => c.ingotId == ingotInCrucible.ingotId);

    // *** ADDED: Proper error handling for index not found ***
    if (indexInCrucible == -1) {
      _log.warning(
          "Could not find selected crucible slot (Ingot ID# ${ingotInCrucible.ingotId}) to replace.");
      _showSnackBar("Error: Could not find the selected crucible slot.");
      // Deselect to avoid inconsistent state
      setState(() {
        _selectedIngotInCrucible = null;
      });
      return; // Exit function
    }
    // *** END ADDED ***

    // Perform UI swap first for responsiveness
    setState(() {
      _currentCrucible!.combinations[indexInCrucible] = ingotFromCollection;
      _ingotCollection
          .removeWhere((ingot) => ingot.ingotId == ingotFromCollection.ingotId);
      _ingotCollection.insert(0, ingotInCrucible); // Add back to collection UI
      _selectedIngotFromCollection = null;
      _selectedIngotInCrucible = null;
    });

    try {
      // Update DB
      await dbHelper.removeIngotFromCollection(ingotFromCollection.ingotId);
      await dbHelper.addIngotToCollection(
          userId: _currentCrucible!.userId!,
          gameName: _gameName,
          drawDate: _targetDrawDate,
          ingotId: ingotInCrucible.ingotId,
          numbers: ingotInCrucible.numbers);
      // Save the swapped crucible state
      await _saveDraftCrucible();
      _confettiController.play();
      _showSnackBar(
          "Ingot #${ingotFromCollection.ingotId} placed in crucible, Ingot #${ingotInCrucible.ingotId} returned to collection.");
    } catch (e) {
      _log.severe("Error updating ingot collection DB during swap: $e");
      _showSnackBar("Error updating collection during swap.");
      // Rollback UI changes on DB error
      setState(() {
        _currentCrucible!.combinations[indexInCrucible] =
            ingotInCrucible; // Put original back
        _ingotCollection.removeWhere(
                (ingot) => ingot.ingotId == ingotInCrucible.ingotId); // Remove the one we added back
        _ingotCollection.insert(
            0, ingotFromCollection); // Add the collection one back
        // Keep selections null
      });
    }
  }

  /// Saves the current Crucible state to the database with 'draft' status.
  /// Added bypassLoadingCheck for the initial save.
  Future<void> _saveDraftCrucible(
      {bool showSnackbar = true, bool bypassLoadingCheck = false}) async {
    // --- MODIFICATION START: Adjust guard clause ---
    if (_currentCrucible == null || (!bypassLoadingCheck && _isLoading)) {
      _log.warning(
          "Attempted to save draft crucible when null or loading (Bypass: $bypassLoadingCheck). Skipping.");
      return;
    }
    // --- MODIFICATION END ---

    if (_isCrucibleLocked) {
      _log.info("Skipping draft save because crucible is locked.");
      return;
    }

    _currentCrucible!.status = 'draft';
    _currentCrucible!.submittedDate = DateTime.now();

    _log.fine(
        "Attempting to save draft crucible (BypassLoadingCheck: $bypassLoadingCheck)...");
    _log.finest(
        "Crucible state to save: ${_currentCrucible!.toMap()}"); // Log map representation

    try {
      int resultId = await dbHelper.insertIngotCrucible(_currentCrucible!);
      _log.info(
          "Draft Crucible save operation completed. Result ID/Rows affected: $resultId");

      if (resultId > 0) {
        // Update the local crucible's ID if it was just inserted
        if (mounted && _currentCrucible!.id == null) {
          _log.info("Crucible was newly inserted, updating local ID to $resultId");
          // No need for setState here as ID is not directly displayed
          _currentCrucible!.id = resultId;
        } else if (mounted) {
          _log.info("Crucible with ID ${_currentCrucible!.id} was updated.");
        }
        if (showSnackbar) _showSnackBar('Draft saved.');
      } else {
        _log.warning(
            "Failed to save draft crucible (DB insert/replace returned 0 or negative).");
        if (showSnackbar) _showSnackBar('Failed to save draft.');
      }
    } catch (e, stacktrace) {
      _log.severe('Error saving draft crucible: $e', e, stacktrace);
      if (showSnackbar) _showSnackBar('Error saving draft.');
    }
  }

  /// Handles locking the crucible: shows confirmation, updates status locally, saves, and calls API.
  Future<void> _forgeTickets() async {
    // Guard clauses removed comments, kept logic
    if (_interactionsDisabled || _isForging) {
      return;
    }
    if (_currentCrucible == null) {
      return;
    }
    final maxSlots = _currentGameRule?.regularBallsDrawn ?? 6;
    if (_currentCrucible!.combinations.length < maxSlots) {
      _showSnackBar("Please fill all $maxSlots crucible slots before forging.");
      return;
    }

    // Confirmation Dialog
    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirm Forge'),
          content: const SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('Are you sure you want to forge these tickets?'),
                SizedBox(height: 8),
                Text(
                    'This action is permanent for this draw and cannot be undone.',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
                child: const Text('Cancel'),
                onPressed: () => Navigator.of(context).pop(false)),
            FilledButton(
                child: const Text('Forge Tickets'),
                onPressed: () => Navigator.of(context).pop(true)),
          ],
        );
      },
    );
    if (confirmed != true) {
      _log.info("Ticket forging cancelled by user.");
      return;
    }

    setState(() {
      _isForging = true;
    });
    _log.info(
        "Attempting to forge tickets (Crucible ID: ${_currentCrucible!.id}) for draw $_targetDrawDate");

    // Local Save
    _currentCrucible!.status = 'submitted';
    _currentCrucible!.submittedDate = DateTime.now();
    try {
      // Save with bypassLoadingCheck true, as _isForging handles UI disabling
      await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true);
      _log.info(
          "Locally updated Crucible status to '${_currentCrucible!.status}'.");
    } catch (e) {
      _log.severe("Error saving forged status locally: $e");
      _showSnackBar("Error saving crucible status locally.");
      if (mounted) {
        setState(() {
          _isForging = false;
        });
      }
      return;
    }

    // API Call Prep
    final authState = Provider.of<AuthState>(context, listen: false);
    final List<int> ingotIdsToSend =
    _currentCrucible!.combinations.map((c) => c.ingotId).toList();
    final requestBody = jsonEncode({
      'user_id': _currentCrucible!.userId,
      'game_name': _gameName,
      'draw_date': _targetDrawDate,
      'play_card_id': _currentCrucible!.id,
      'ingot_ids': ingotIdsToSend,
    });

    // API Call
    try {
      _log.info("Making API call to submit crucible with body: $requestBody");
      final url =
      Uri.https('governance.page', '/wp-json/apigold/v1/submit-playcard');
      final response = await http
          .post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${authState.authToken}',
        },
        body: requestBody,
      )
          .timeout(const Duration(seconds: 20));
      _log.info("Submit Crucible API Response Status: ${response.statusCode}");
      _log.fine("Submit Crucible API Response Body: ${response.body}");
      if (!mounted) return;

      // Handle API Response
      if (response.statusCode == 200 || response.statusCode == 201) {
        bool success = false;
        String message = "Tickets Forged Successfully!";
        try {
          final responseData = json.decode(response.body);
          if (responseData['status'] == 'success' ||
              responseData['status'] == 'playcard_submitted') {
            success = true;
            message = responseData['message'] ?? message;
          } else {
            message = responseData['message'] ?? "Server indicated submission failed.";
          }
        } catch (e) {
          _log.warning("Could not parse successful forge response JSON: $e");
          success = true; // Assume success if parse fails but status was 200/201
        }
        if (success) {
          _log.info("Crucible successfully submitted to server.");
          _showSnackBar(message);
          if (mounted) {
            setState(() {
              _isCrucibleLocked = true;
            }); // Update locked state immediately
            try {
              int userId = int.parse(authState.userId);
              await dbHelper.clearIngotCollectionForDraw(
                  userId, _gameName, _targetDrawDate);
              setState(() {
                _ingotCollection = [];
                _selectedIngotFromCollection = null;
              });
              _log.info("Cleared ingot collection after successful forge.");
            } catch (e) {
              _log.warning("Failed to clear ingot collection after forge: $e");
            }
          }
        } else {
          _log.warning(
              "Crucible submission failed (API Status OK, but response indicates error): ${response.body}");
          _showSnackBar(message);
          // Revert status locally if API indicated failure despite 200 OK
          _currentCrucible!.status = 'draft';
          await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true); // Save reverted status
          if (mounted) {
            setState(() => _isCrucibleLocked = false);
          } // Ensure UI reflects unlocked state
        }
      } else {
        String errorMessage = "Failed to forge tickets.";
        try {
          final responseData = json.decode(response.body);
          errorMessage =
              responseData['message'] ?? "Server error ${response.statusCode}";
        } catch (e) {
          errorMessage =
          "Server error ${response.statusCode}. Could not parse response.";
        }
        _log.warning(
            "Failed to submit Crucible to server. Status: ${response.statusCode}, Body: ${response.body}");
        _showSnackBar(errorMessage);
        // Revert status locally on non-200 response
        _currentCrucible!.status = 'draft';
        await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true); // Save reverted status
        if (mounted) {
          setState(() {
            _isCrucibleLocked = false;
          });
        } // Ensure UI reflects unlocked state
      }
    } on TimeoutException catch (e) {
      _log.severe("Error submitting Crucible to server (Timeout): $e");
      _showSnackBar("Network timeout forging tickets. Please try again.");
      // Revert status locally on timeout
      _currentCrucible!.status = 'draft';
      await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true); // Save reverted status
      if (mounted) {
        setState(() {
          _isCrucibleLocked = false;
        });
      } // Ensure UI reflects unlocked state
    } catch (e, stacktrace) {
      _log.severe("Error submitting Crucible to server: $e", e, stacktrace);
      _showSnackBar("Network error forging tickets.");
      // Revert status locally on other errors
      _currentCrucible!.status = 'draft';
      await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true); // Save reverted status
      if (mounted) {
        setState(() {
          _isCrucibleLocked = false;
        });
      } // Ensure UI reflects unlocked state
    } finally {
      if (mounted) {
        setState(() {
          _isForging = false;
        });
      }
    }
  }

  /// Shows a SnackBar message.
  void _showSnackBar(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
    }
  }

  /// Formats a Duration.
  String _formatDuration(Duration duration) {
    if (duration.isNegative) return "Cutoff Passed";
    int days = duration.inDays;
    int hours = duration.inHours % 24;
    int minutes = duration.inMinutes % 60;
    List<String> parts = [];
    if (days > 0) parts.add('${days}d');
    if (hours > 0) parts.add('${hours}h');
    if (minutes >= 0 || parts.isEmpty) parts.add('${minutes}m');
    if (parts.isEmpty) return "< 1m";
    return parts.join(' ');
  }

  /// <<< Helper function to truncate checksum for display. >>>
  String _truncateChecksum(String checksum, {int length = 16}) {
    if (checksum.length <= length) {
      return checksum;
    }
    // Ensure we don't try to substring beyond the string length
    int endIndex = length < checksum.length ? length : checksum.length;
    return '${checksum.substring(0, endIndex)}...';
  }

  // --- Build Method (UI Updated) ---
  @override
  Widget build(BuildContext context) {
    final cutoffTime = _cutoffTimeUtc;
    String timeRemainingStr = "Loading...";
    if (!_isLoading) {
      if (cutoffTime != null) {
        final now = DateTime.now().toUtc();
        timeRemainingStr = now.isBefore(cutoffTime)
            ? "Cutoff in ${_formatDuration(cutoffTime.difference(now))}"
            : "Cutoff Passed";
      } else if (_targetDrawDate.isNotEmpty) {
        timeRemainingStr = "Cutoff time unknown";
      } else {
        timeRemainingStr = "Draw info unavailable";
      }
    }

    String crucibleStatusText = "";
    Color crucibleStatusColor = Colors.grey;
    IconData crucibleStatusIcon = Icons.info_outline;
    int currentSlots = _currentCrucible?.combinations.length ?? 0;
    int maxSlots = _currentGameRule?.regularBallsDrawn ?? 6;
    bool isCrucibleFull =
        !_isLoading && _currentCrucible != null && currentSlots >= maxSlots;

    // Update crucible status logic slightly to avoid accessing _currentCrucible when _isLoading
    if (!_isLoading && _currentCrucible != null) {
      if (_isCrucibleLocked) {
        crucibleStatusText = "Crucible Locked";
        crucibleStatusColor = Colors.red[700]!;
        crucibleStatusIcon = Icons.lock_outline;
      } else if (_isPastCutoff) {
        crucibleStatusText = "Cutoff Passed";
        crucibleStatusColor = Colors.red[700]!;
        crucibleStatusIcon = Icons.timer_off_outlined;
      } else if (currentSlots == 0) {
        crucibleStatusText = "Crucible Empty";
        crucibleStatusColor = Colors.orange[700]!;
        crucibleStatusIcon = Icons.warning_amber_rounded;
      } else if (currentSlots < maxSlots) {
        crucibleStatusText =
        "Crucible Partially Forged ($currentSlots / $maxSlots slots)";
        crucibleStatusColor = Colors.blue[700]!;
        crucibleStatusIcon = Icons.info_outline;
      } else {
        crucibleStatusText =
        "Crucible Full ($currentSlots / $maxSlots slots) - Ready to Forge";
        crucibleStatusColor = Colors.green[700]!;
        crucibleStatusIcon = Icons.check_circle_outline;
      }
    } else if (_isLoading) {
      crucibleStatusText = "Loading crucible status...";
    } else {
      // Case where not loading but crucible is still null (error during load?)
      crucibleStatusText = "Crucible status unavailable.";
    }

    final bool canSmelt =
        !_interactionsDisabled && _calculatedRequestsRemaining > 0;
    final bool canReplace = !_interactionsDisabled &&
        _selectedIngotInCrucible != null &&
        _selectedIngotFromCollection != null;
    final bool canAdd = !_interactionsDisabled &&
        _selectedIngotFromCollection != null &&
        !isCrucibleFull;
    final bool canForge = !_interactionsDisabled && isCrucibleFull;

    return Scaffold(
      appBar: AppBar(
        title: Text('Forge: ${_isLoading ? "..." : _gameName}'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _errorMessage = null;
                  });
                  _processArgumentsAndLoadData();
                },
                child: const Text('Retry Load'),
              ),
            ],
          ),
        ),
      )
          : Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 1,
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Game: $_gameName',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      'Draw Date: ${DateFormat('EEEE, MMMM d, yyyy').format(DateTime.parse(_targetDrawDate))}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      timeRemainingStr,
                      style: TextStyle(
                        color: _isPastCutoff
                            ? Colors.red
                            : Colors.green[700],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    Text(
                      'Smelts Remaining: $_calculatedRequestsRemaining / ${_requestLimit ?? "?"}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    // <<< Display Ingot Pool Checksum >>>
                    if (_archiveChecksum != null &&
                        _archiveChecksum!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          'Ingot Pool Checksum: ${_truncateChecksum(_archiveChecksum!)}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.grey[600]),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            ElevatedButton.icon(
              icon: _isSmelting
                  ? Container(
                width: 20,
                height: 20,
                padding: const EdgeInsets.all(2.0),
                child: const CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.black54,
                ),
              )
                  : const Icon(Icons.whatshot),
              label: Text(_isSmelting ? 'Smelting...' : 'Smelt Ingot'),
              onPressed: canSmelt ? _smeltIngot : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: canSmelt
                    ? Colors.orange[300]
                    : Theme.of(context).disabledColor,
                foregroundColor:
                canSmelt ? Colors.black : Colors.white70,
                minimumSize: const Size(double.infinity, 44),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Ingot Collection (${_ingotCollection.length})",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Container(
              height: 100,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _ingotCollection.isEmpty
                  ? Center(
                child: Text(
                  "Smelt ingots to collect them here.",
                  style: TextStyle(color: Colors.grey[600]),
                ),
              )
                  : ListView.builder(
                itemCount: _ingotCollection.length,
                itemBuilder: (context, index) {
                  final ingot = _ingotCollection[index];
                  bool isSelected =
                      _selectedIngotFromCollection?.ingotId ==
                          ingot.ingotId;
                  return ListTile(
                    dense: true,
                    title: Text('Ingot #${ingot.ingotId}'),
                    subtitle: Text(ingot.numbers.join(', ')),
                    selected: isSelected,
                    selectedTileColor: Colors.blue[50],
                    onTap: _interactionsDisabled
                        ? null
                        : () {
                      setState(() {
                        _selectedIngotFromCollection =
                        isSelected ? null : ingot;
                      });
                    },
                    trailing: isSelected
                        ? const Icon(Icons.check_circle,
                        color: Colors.blue)
                        : null,
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.add_box_outlined, size: 18),
                  label: const Text("Add to Crucible"),
                  onPressed:
                  canAdd ? _addSelectedIngotToCrucible : null,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[100]),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text("Replace Slot"),
                  onPressed: canReplace
                      ? _swapCrucibleAndCollectionIngots
                      : null,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange[100]),
                ),
              ],
            ),
            const Divider(height: 20, thickness: 1),
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  Icon(crucibleStatusIcon,
                      color: crucibleStatusColor, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      crucibleStatusText,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: crucibleStatusColor),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: (_currentCrucible?.combinations.isEmpty ?? true)
                  ? Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border:
                  Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[50],
                ),
                child: Text(
                  'Add ingots from your collection to the crucible.',
                  style: TextStyle(
                      color: Colors.grey[600],
                      fontStyle: FontStyle.italic),
                ),
              )
                  : GridView.builder(
                gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 2.5 / 1.2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: maxSlots,
                itemBuilder: (context, index) {
                  final combination = (index < currentSlots)
                      ? _currentCrucible!.combinations[index]
                      : null;
                  bool isSelected =
                      _selectedIngotInCrucible?.ingotId ==
                          combination?.ingotId;
                  bool isEmptySlot = combination == null;
                  return GestureDetector(
                    onTap: _interactionsDisabled
                        ? null
                        : () {
                      setState(() {
                        _selectedIngotInCrucible =
                        (isSelected || isEmptySlot)
                            ? null
                            : combination;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 6),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isSelected
                              ? Colors.orange.shade300
                              : (isEmptySlot
                              ? Colors.grey.shade300
                              : Colors.black54),
                          width: isSelected ? 2 : 1,
                          style: BorderStyle.solid,
                        ),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: isSelected
                            ? [
                          BoxShadow(
                            color: Colors.orange
                                .withOpacity(0.3),
                            spreadRadius: 1,
                            blurRadius: 3,
                          ),
                        ]
                            : [],
                        backgroundBlendMode:
                        _interactionsDisabled
                            ? BlendMode.saturation
                            : null,
                        color: _interactionsDisabled
                            ? Colors.grey[300]
                            : (isSelected
                            ? Colors.orange[100]
                            : (isEmptySlot
                            ? Colors.grey[100]
                            : Colors.amber[100])),
                      ),
                      child: isEmptySlot
                          ? Center(
                        child: Text(
                          "Slot ${index + 1}",
                          style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 12),
                        ),
                      )
                          : Column(
                        mainAxisAlignment:
                        MainAxisAlignment.center,
                        children: [
                          Text(
                            combination.numbers.join(' '),
                            style: TextStyle(
                              color:
                              _interactionsDisabled
                                  ? Colors.grey[600]
                                  : Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow:
                            TextOverflow.ellipsis,
                          ),
                          Text(
                            'ID# ${combination.ingotId}',
                            style: TextStyle(
                              color:
                              _interactionsDisabled
                                  ? Colors.grey[500]
                                  : Colors.black54,
                              fontSize: 10,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow:
                            TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            if (canForge)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: ElevatedButton.icon(
                  icon: _isForging
                      ? Container(
                    width: 20,
                    height: 20,
                    padding: const EdgeInsets.all(2.0),
                    child: const CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  )
                      : const Icon(Icons.gavel),
                  label:
                  Text(_isForging ? 'Forging...' : 'Forge Tickets'),
                  onPressed: _isForging ? null : _forgeTickets,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                    Theme.of(context).colorScheme.primary,
                    foregroundColor:
                    Theme.of(context).colorScheme.onPrimary,
                    minimumSize: const Size(double.infinity, 44),
                  ),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Back to Smelter'), // Assuming Smelter is previous screen
            ),
            Align(
              alignment: Alignment.topCenter,
              child: ConfettiWidget(
                confettiController: _confettiController,
                blastDirectionality: BlastDirectionality.explosive,
                shouldLoop: false,
                numberOfParticles: 15,
                gravity: 0.1,
              ),
            ),
            Align(
              alignment: Alignment.center,
              child: ConfettiWidget(
                confettiController: _sparksController,
                blastDirectionality: BlastDirectionality.explosive,
                emissionFrequency: 0.05,
                numberOfParticles: 8,
                gravity: 0.05,
                colors: const [
                  Colors.yellow,
                  Colors.orange,
                  Colors.amber
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}