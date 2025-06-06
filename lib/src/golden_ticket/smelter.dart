import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';

import 'package:timezone/data/latest.dart' as tz; // Required for timezone initialization
import 'package:timezone/timezone.dart' as tz; // Required for TZDateTime

import 'logging_utils.dart';
import 'package:logging/logging.dart';
import 'routes.dart';
import 'auth/auth_state.dart';
import 'database_helper.dart'; // Provides GameDrawInfo
import 'game_selector_screen.dart';
import 'game_rules.dart';
import 'ingot_crucible.dart'; // *** UPDATED IMPORT *** (was play_card.dart)

// Updated class to hold display data for each game
class ActiveGameDisplayData {
  final String gameName;
  final String? nextDrawDate;
  final bool isCardLockedOrSubmitted; // True if status is 'locked' or 'submitted'
  final DateTime? cutoffTime; // Calculated cutoff time (UTC)
  final GameRule? gameRule;
  final GameDrawInfo? gameDrawInfo;

  ActiveGameDisplayData({
    required this.gameName,
    this.nextDrawDate,
    required this.isCardLockedOrSubmitted,
    this.cutoffTime,
    this.gameRule,
    this.gameDrawInfo,
  });
}


class TheSmelter extends StatefulWidget {
  const TheSmelter({super.key});
  static const routeName = '/the-smelter';

  @override
  State<TheSmelter> createState() => _TheSmelterState();
}

class _TheSmelterState extends State<TheSmelter> with SingleTickerProviderStateMixin {
  final _log = Logger('TheSmelter');
  final dbHelper = DatabaseHelper();

  bool _isLoading = true;
  List<ActiveGameDisplayData> _activeGames = [];
  String? _errorMessage;
  Timer? _timer;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    LoggingUtils.setupLogger(_log);
    try {
      tz.initializeTimeZones();
      _log.info("Timezone database initialized in TheSmelter.");
    } catch (e) {
      _log.severe("Failed to initialize timezone database: $e");
    }

    _pulseController = AnimationController(
        duration: const Duration(milliseconds: 800), vsync: this);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.addStatusListener((status) {
      if (status == AnimationStatus.completed) _pulseController.reverse();
      else if (status == AnimationStatus.dismissed) _pulseController.forward();
    });
    _loadSmelterData();
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) setState(() {}); else timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  /// Loads data for all games the user is participating in.
  Future<void> _loadSmelterData() async {

    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _activeGames = [];
    });

    final authState = Provider.of<AuthState>(context, listen: false);
    int? currentUserId;
    try {
      currentUserId = int.tryParse(authState.userId);
      if (currentUserId == null) throw Exception("Invalid User ID in AuthState.");
    } catch (e) {
      _log.severe("Error getting User ID: $e");
      if (mounted) setState(() { _isLoading = false; _errorMessage = "Error: Could not identify user."; });
      return;
    }

    try {
      final List<Map<String, dynamic>> userProgress = await dbHelper.getAllUserGameProgress(currentUserId);
      _log.info("Found ${userProgress.length} game progress entries for user $currentUserId.");
      if (!mounted) return;

      List<Future<ActiveGameDisplayData?>> fetchTasks = [];
      for (var progressEntry in userProgress) {
        String gameName = progressEntry['game_name'] as String? ?? 'Unknown Game';
        if (gameName != 'Unknown Game') {
          fetchTasks.add(_processSingleGame(gameName, currentUserId));
        } else {
          _log.warning("Skipping entry with unknown game name for user $currentUserId.");
        }
      }

      final List<ActiveGameDisplayData?> results = await Future.wait(fetchTasks);
      if (!mounted) return;

      List<ActiveGameDisplayData> gamesData = results.whereType<ActiveGameDisplayData>().toList();
      bool needsPulse = false;

      for (var gameData in gamesData) {
        bool needsForge = !gameData.isCardLockedOrSubmitted;
        bool isBeforeCutoff = gameData.cutoffTime != null && DateTime.now().toUtc().isBefore(gameData.cutoffTime!);
        if(needsForge && isBeforeCutoff) {
          needsPulse = true;
        }
      }

      gamesData.sort((a, b) => a.gameName.compareTo(b.gameName));

      if (mounted) {
        setState(() { _activeGames = gamesData; _isLoading = false; });
        if (needsPulse && !_pulseController.isAnimating) _pulseController.forward();
        else if (!needsPulse && _pulseController.isAnimating) { _pulseController.stop(); _pulseController.reset(); }
      }
    } catch (e, stacktrace) {
      _log.severe("Error loading smelter data: $e \nStack: $stacktrace");
      if (mounted) setState(() { _isLoading = false; _errorMessage = "Failed to load game data. Please try again."; });
    }
  }

  /// Fetches and processes data for a single game.
  Future<ActiveGameDisplayData?> _processSingleGame(String gameName, int userId) async {
    String? nextDrawDate;
    bool isLockedOrSubmitted = false;
    DateTime? cutoffTime;
    GameRule? rule;
    GameDrawInfo? drawInfo;

    try {
      // Fetch rule and LATEST draw info concurrently
      final ruleFuture = dbHelper.getGameRule(gameName);
      final drawInfoFuture = dbHelper.getGameDrawInfo(gameName); // Gets latest draw info

      final results = await Future.wait([ruleFuture, drawInfoFuture]);

      rule = results[0] as GameRule?;
      drawInfo = results[1] as GameDrawInfo?;

      if (rule == null) {
        _log.warning("Rule not found in DB for $gameName.");
        return null;
      }

      if (drawInfo != null) {
        nextDrawDate = drawInfo.drawDate;
        _log.fine("Latest draw info found for $gameName: Date=$nextDrawDate, Limit=${drawInfo.userRequestLimit}, Used=${drawInfo.userCombinationsRequested}");

        // --- *** UPDATED: Fetch IngotCrucible and check its status *** ---
        final IngotCrucible? crucible = await dbHelper.getUserCrucibleForDraw(userId, nextDrawDate); // Use new method
        if (crucible != null) {
          isLockedOrSubmitted = (crucible.status == 'submitted' || crucible.status == 'locked');
          _log.fine("Crucible found for $userId/$gameName/$nextDrawDate. Status: ${crucible.status}. LockedOrSubmitted: $isLockedOrSubmitted");
        } else {
          _log.fine("No Crucible found for $userId/$gameName/$nextDrawDate. LockedOrSubmitted: false");
          isLockedOrSubmitted = false; // No crucible means it's not submitted/locked
        }
        // --- *** END UPDATED *** ---

        cutoffTime = _calculateCutoffTime(nextDrawDate, rule);
      } else {
        _log.warning("No draw info found in DB for $gameName. Cannot determine next draw or cutoff.");
        return null;
      }

      return ActiveGameDisplayData(
        gameName: gameName,
        nextDrawDate: nextDrawDate,
        isCardLockedOrSubmitted: isLockedOrSubmitted, // Pass the determined status
        cutoffTime: cutoffTime,
        gameRule: rule,
        gameDrawInfo: drawInfo,
      );

    } catch (e, stacktrace) {
      _log.severe("Error processing single game $gameName: $e\nStack: $stacktrace");
      return null;
    }
  }


  /// Calculates the cutoff time (UTC). (Includes temporary +1 day for testing)
  DateTime? _calculateCutoffTime(String nextDrawDateStr, GameRule? rule) {

    if (rule == null) {
      _log.warning("Cannot calculate cutoff time without game rule for $nextDrawDateStr.");
      return null;
    }
    try {
      DateTime targetDrawDay = DateTime.parse(nextDrawDateStr);
      List<Map<String, dynamic>> possibleDraws = [];
      final dayMap = {
        'Mon': DateTime.monday, 'Tue': DateTime.tuesday, 'Wed': DateTime.wednesday,
        'Thu': DateTime.thursday, 'Fri': DateTime.friday, 'Sat': DateTime.saturday, 'Sun': DateTime.sunday
      };

      final scheduleParts = rule.drawSchedule.split(',');
      for (String part in scheduleParts) {
        final components = part.trim().split(' ');
        if (components.length == 3) {
          int? drawWeekday = dayMap[components[0]];
          final timeParts = components[1].split(':');
          final tzId = components[2];
          if (drawWeekday != null && timeParts.length == 2 && tzId.contains('/')) {
            int hour = int.parse(timeParts[0]);
            int minute = int.parse(timeParts[1]);
            possibleDraws.add({
              'weekday': drawWeekday, 'hour': hour, 'minute': minute, 'tzId': tzId
            });
          } else { _log.warning("Invalid schedule part format skipped: '$part'"); }
        } else { _log.warning("Invalid schedule part format skipped: '$part'"); }
      }
      if (possibleDraws.isEmpty) {
        _log.warning("Could not parse any valid draw schedules from: ${rule.drawSchedule}");
        return null;
      }

      tz.TZDateTime? foundDrawTime;
      int targetWeekday = targetDrawDay.weekday;
      for (var drawInfo in possibleDraws) {
        if (drawInfo['weekday'] == targetWeekday) {
          try {
            final location = tz.getLocation(drawInfo['tzId']);
            final potentialDraw = tz.TZDateTime(
                location, targetDrawDay.year, targetDrawDay.month,
                targetDrawDay.day, drawInfo['hour'], drawInfo['minute']
            );
            if (potentialDraw.year == targetDrawDay.year &&
                potentialDraw.month == targetDrawDay.month &&
                potentialDraw.day == targetDrawDay.day)
            { foundDrawTime = potentialDraw; break; }
            else { _log.warning("Potential draw time $potentialDraw does not match target date $targetDrawDay after timezone conversion."); }
          } catch (e) { _log.severe("Timezone Error processing schedule for ${drawInfo['tzId']}: $e. Ensure timezone database is initialized."); }
        }
      }

      if (foundDrawTime == null) {
        _log.severe("Could not determine the exact draw time instance for ${rule.gameName} on $nextDrawDateStr using schedule ${rule.drawSchedule}");
        return null;
      }

       DateTime cutoffTime = foundDrawTime;

      _log.fine("Calculated draw time for ${rule.gameName} on $nextDrawDateStr: $foundDrawTime, Cutoff: $cutoffTime (Timezone: ${foundDrawTime.location.name})");
      return cutoffTime.toUtc();

    } catch (e, stacktrace) {
      _log.severe("Error calculating cutoff time for ${rule?.gameName} / $nextDrawDateStr: $e\nStack: $stacktrace");
      return null;
    }
  }

  /// Formats a Duration. (Unchanged logic)
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

  /// Shows a SnackBar. (Unchanged logic)
  void _showSnackBar(String text) {

    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('The Smelter'),
        actions: [ IconButton(icon: const Icon(Icons.refresh), onPressed: _isLoading ? null : _loadSmelterData, tooltip: 'Refresh Game Status') ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToAddGame,
        icon: const Icon(Icons.add),
        label: const Text("Add Game"),
      ),
    );
  }

  /// Builds the main body content based on loading state and available games.
  Widget _buildBody() {

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text(_errorMessage!, style: TextStyle(color: Colors.red[700]), textAlign: TextAlign.center),
      ));
    }

    List<Widget> screenWidgets = [];
    if (_activeGames.isNotEmpty) {
      for (var gameData in _activeGames) {
        screenWidgets.add(_buildGameButton(gameData));
        screenWidgets.add(const SizedBox(height: 12));
      }
    } else {
      screenWidgets.add( const Center( child: Padding( padding: EdgeInsets.all(20.0), child: Text( "You haven't added any games yet. Add a game below to get started!", textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.grey), ), ), ) );
    }

    return RefreshIndicator(
      onRefresh: _loadSmelterData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20.0, 20.0, 20.0, 80.0),
        children: screenWidgets,
      ),
    );
  }

  /// Builds the button/card for navigating to the Forge for a specific game.
  Widget _buildGameButton(ActiveGameDisplayData gameData) {

    bool needsForgeOrEdit = !gameData.isCardLockedOrSubmitted;
    String mainLabel = needsForgeOrEdit ? 'Forge / Edit ${gameData.gameName} Crucible' : 'View Locked ${gameData.gameName} Crucible'; // Updated text

    bool isBeforeCutoff = false;
    String timeRemainingStr = "Cutoff time unknown";
    if (gameData.cutoffTime != null) {
      final now = DateTime.now().toUtc();
      isBeforeCutoff = now.isBefore(gameData.cutoffTime!);
      timeRemainingStr = isBeforeCutoff
          ? "Cutoff in ${_formatDuration(gameData.cutoffTime!.difference(now))}"
          : "Cutoff Passed";
    }

    bool canNavigate = gameData.nextDrawDate != null && gameData.gameRule != null && gameData.gameDrawInfo != null;
    bool isEnabled = (isBeforeCutoff || gameData.isCardLockedOrSubmitted) && canNavigate;
    bool playAnimation = needsForgeOrEdit && isBeforeCutoff && canNavigate;

    Widget buttonContent = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(mainLabel, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
        if (timeRemainingStr.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text( timeRemainingStr, style: TextStyle( fontSize: 12, color: isEnabled ? (isBeforeCutoff ? Colors.black54 : Colors.red[700]) : Colors.grey[600], ), ),
        ]
      ],
    );

    if (playAnimation) {
      buttonContent = ScaleTransition( scale: _pulseAnimation, child: buttonContent, );
    }

    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(double.infinity, 65),
        backgroundColor: isEnabled
            ? (playAnimation ? Colors.red[100] : (needsForgeOrEdit ? null : Colors.grey[400]))
            : Colors.grey[300],
        foregroundColor: isEnabled ? null : Colors.grey[600],
        disabledBackgroundColor: Colors.grey[300],
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: isEnabled ? () {
        _log.info("Navigating to Forge for ${gameData.gameName} / ${gameData.nextDrawDate}");
        Navigator.pushNamed(
          context,
          Routes.theForge,
          arguments: {
            'gameName': gameData.gameName,
            'nextDrawDate': gameData.nextDrawDate,
          },
        ).then((_) {
          _log.info("Returned from Forge screen, reloading Smelter data.");
          _loadSmelterData();
        });
      } : null,
      child: buttonContent,
    );
  }

  /// Navigates to the screen for adding/selecting a new game.
  void _navigateToAddGame() {
    Navigator.pushNamed(context, GameSelectorScreen.routeName).then((result) {
      if (result != null && result is String) {
        _log.info("Game selected from GameSelectorScreen: $result");
        _saveNewGameProgress(result);
      } else {
        _log.info("No game selected or returned from GameSelectorScreen.");
      }
    });
  }

  /// Saves initial progress for a newly added game.
  Future<void> _saveNewGameProgress(String selectedEventName) async {
    try {
      final authState = Provider.of<AuthState>(context, listen: false);
      int? currentUserId = int.tryParse(authState.userId);
      if (currentUserId == null) { _showSnackBar("Error: Could not identify user to save game."); return; }

      String? gameNameToSave;
      if (selectedEventName == "Event 6/49") gameNameToSave = "lotto649";
      else if (selectedEventName == "Event Max") gameNameToSave = "LottoMax";
      else if (selectedEventName == "Event Daily") gameNameToSave = "DailyGrand";
      else { _log.warning("Unknown game selected: '$selectedEventName'. Cannot map."); _showSnackBar("Selected game '$selectedEventName' is not recognized."); }

      if (gameNameToSave != null) {
        _log.info("Attempting to save progress for game: $gameNameToSave (User: $currentUserId)");
        final existingProgress = await dbHelper.getUserGameProgress(currentUserId, gameNameToSave);
        if (existingProgress == null) {
          await dbHelper.upsertUserGameProgress( userId: currentUserId, gameName: gameNameToSave, scoreToAdd: 0, gameAwardsToAdd: [], gameStatistics: '{}', );
          _log.info("Saved initial progress for $gameNameToSave.");
          _showSnackBar("$selectedEventName added to your active games!");
          await _loadSmelterData();
        } else {
          _log.info("Progress for $gameNameToSave already exists. Not overwriting.");
          _showSnackBar("$selectedEventName is already in your list.");
        }
      }
    } catch (e) {
      _log.severe("Error saving selected game progress: $e");
      _showSnackBar("Error adding game. Please try again.");
    }
  }

} // End of _TheSmelterState
