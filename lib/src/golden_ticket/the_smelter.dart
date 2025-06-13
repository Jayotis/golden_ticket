import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math';
import 'package:confetti/confetti.dart';
import 'package:logging/logging.dart';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import 'ingot_crucible.dart';
import 'logging_utils.dart';
import 'auth/auth_state.dart';
import 'database_helper.dart';
import 'game_rules.dart';
import 'routes.dart';

class SmelterScreen extends StatefulWidget {
  const SmelterScreen({super.key});

  @override
  State<SmelterScreen> createState() => _SmelterScreenState();
}

class _SmelterScreenState extends State<SmelterScreen> {
  final _log = Logger('SmelterScreen');
  final dbHelper = DatabaseHelper();

  // Crucible/Game selection
  List<GameRule> _availableGames = [];
  GameRule? _selectedGameRule;

  // State variables
  bool _isLoading = true;
  String? _errorMessage;
  String? _targetDrawDate;
  int? _totalCombinations;
  int? _requestsUsed;
  int? _requestLimit;
  String? _archiveChecksum;
  int _calculatedRequestsRemaining = 0;
  DateTime? _cutoffTimeUtc;
  bool _isPastCutoff = false;
  Timer? _timer;

  IngotCrucible? _currentCrucible;
  List<CombinationWithId> _ingotCollection = [];
  CombinationWithId? _selectedIngotFromCollection;
  CombinationWithId? _selectedIngotInCrucible;

  bool _isCrucibleLocked = false;
  bool _isForging = false;
  bool _isSmelting = false;

  // Confetti controllers
  late ConfettiController _confettiController;
  late ConfettiController _sparksController;

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
    _loadAvailableGames();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _confettiController.dispose();
    _sparksController.dispose();
    super.dispose();
  }

  /// Loads the games that the current user has activated in their profile.
  Future<void> _loadAvailableGames() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final authState = Provider.of<AuthState>(context, listen: false);
      print('DEBUG: SmelterScreen userId: ${authState.userId}');
      int? currentUserId;
      try {
        currentUserId = int.parse(authState.userId);
      } catch (_) {
        throw Exception("Invalid user ID.");
      }
      final games = await dbHelper.getActiveGameRulesForUser(currentUserId);
      if (games.isEmpty) {
        throw Exception("No active games found in your profile. Go to Profile or Account to add games.");
      }
      setState(() {
        _availableGames = games;
        _selectedGameRule = games.first;
      });
      await _onGameRuleChanged(_selectedGameRule!);
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = "Error loading games: ${e.toString()}";
      });
    }
  }

  Future<void> _onGameRuleChanged(GameRule newRule) async {
    setState(() {
      _isLoading = true;
      _selectedGameRule = newRule;
      _errorMessage = null;
      _ingotCollection.clear();
      _selectedIngotFromCollection = null;
      _selectedIngotInCrucible = null;
      _currentCrucible = null;
      _isCrucibleLocked = false;
      _targetDrawDate = null;
    });
    try {
      final latestDrawInfo = await dbHelper.getGameDrawInfo(newRule.gameName);
      if (latestDrawInfo == null) {
        throw Exception("No draw info found for ${newRule.gameName}.");
      }
      _targetDrawDate = latestDrawInfo.drawDate;
      await _loadGameData();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = "Error changing crucible/game: ${e.toString()}";
      });
    }
  }

  Future<void> _loadGameData() async {
    final rule = _selectedGameRule;
    if (rule == null) return;
    final authState = Provider.of<AuthState>(context, listen: false);
    int? currentUserId;
    try {
      currentUserId = int.parse(authState.userId);
    } catch (_) {
      setState(() {
        _isLoading = false;
        _errorMessage = "Invalid user ID.";
      });
      return;
    }
    final drawDate = _targetDrawDate!;
    try {
      final drawInfoFuture = dbHelper.getGameDrawInfo(rule.gameName, drawDate);
      final crucibleFuture =
          dbHelper.getUserCrucibleForDraw(currentUserId, drawDate);
      final ingotCollectionFuture =
          dbHelper.getIngotCollection(currentUserId, rule.gameName, drawDate);

      final results = await Future.wait(
        [drawInfoFuture, crucibleFuture, ingotCollectionFuture],
      );
      final GameDrawInfo? drawInfo = results[0] as GameDrawInfo?;
      final IngotCrucible? loadedCrucible = results[1] as IngotCrucible?;
      _ingotCollection = results[2] as List<CombinationWithId>;

      if (drawInfo == null) {
        throw Exception("Draw info not found.");
      }

      _totalCombinations = drawInfo.totalCombinations;
      _requestsUsed = drawInfo.userCombinationsRequested;
      _requestLimit = drawInfo.userRequestLimit;
      _archiveChecksum = drawInfo.archiveChecksum;
      int limit = _requestLimit ?? 0;
      int used = _requestsUsed ?? 0;
      _calculatedRequestsRemaining = (limit - used) < 0 ? 0 : (limit - used);

      _currentCrucible = loadedCrucible ??
          IngotCrucible(
            combinations: [],
            status: 'draft',
            submittedDate: DateTime.now(),
            drawDate: DateTime.parse(drawDate),
            userId: currentUserId,
            name: "${rule.gameName} Crucible",
          );
      _cutoffTimeUtc = _calculateCutoffTime(drawDate, rule);
      _updateCutoffStatus();
      _isCrucibleLocked = (_currentCrucible?.status == 'locked' ||
          _currentCrucible?.status == 'submitted');
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = "Error loading game data: ${e.toString()}";
      });
    }
  }

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
          }
        }
      }
      if (possibleDraws.isEmpty) return null;
      tz.TZDateTime? foundDrawTime;
      int targetWeekday = targetDrawDay.weekday;
      for (var drawInfo in possibleDraws) {
        if (drawInfo['weekday'] == targetWeekday) {
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
          }
        }
      }
      if (foundDrawTime == null) return null;
      DateTime cutoffTime = foundDrawTime.subtract(const Duration(hours: 1));
      return cutoffTime.toUtc();
    } catch (_) {
      return null;
    }
  }

  void _updateCutoffStatus() {
    if (_cutoffTimeUtc != null) {
      final nowUtc = DateTime.now().toUtc();
      final newStatus = nowUtc.isAfter(_cutoffTimeUtc!);
      if (newStatus != _isPastCutoff && mounted) {
        setState(() {
          _isPastCutoff = newStatus;
        });
      }
    } else if (!_isPastCutoff && mounted) {
      if (!_isLoading) {
        setState(() => _isPastCutoff = true);
      }
    }
  }

  // ---- Business Logic from previous TheForgeScreen ----

  Future<void> _smeltIngot() async {
    if (_interactionsDisabled || _isSmelting) return;
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
          'game_name': _selectedGameRule!.gameName,
          'draw_date': _targetDrawDate,
          'combination_number': randomNumber,
        }),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final ingotId = responseData['combination_sequence_id'];
        final combinationNumbersRaw = responseData['combination_numbers'];
        final int? updatedRequestsUsed =
            responseData['user_requests_count'] as int?;
        if (ingotId is! int) throw FormatException('Invalid Ingot ID received');
        if (updatedRequestsUsed == null) throw FormatException('Missing updated request count from server');
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
          gameName: _selectedGameRule!.gameName,
          drawDate: _targetDrawDate!,
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
          });
        }
        _showSnackBar("Ingot #$ingotId added to collection!");
        _sparksController.play();
      } else {
        String message =
            'Failed to smelt ingot (Status: ${response.statusCode})';
        try {
          message = json.decode(response.body)['message'] ?? message;
        } catch (_) {}
        _showSnackBar(message);
      }
    } catch (e) {
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

  Future<void> _updateDbRequestCount(int newRequestCount) async {
    if (!mounted) return;
    try {
      final existingInfo =
          await dbHelper.getGameDrawInfo(_selectedGameRule!.gameName, _targetDrawDate!);
      final infoToUpdate = GameDrawInfo(
        gameName: _selectedGameRule!.gameName,
        drawDate: _targetDrawDate!,
        userCombinationsRequested: newRequestCount,
        userRequestLimit: existingInfo?.userRequestLimit ?? _requestLimit,
        totalCombinations: existingInfo?.totalCombinations ?? _totalCombinations,
        archiveChecksum: existingInfo?.archiveChecksum ?? _archiveChecksum,
      );
      await dbHelper.upsertGameDrawInfo(infoToUpdate);
    } catch (e) {
      _showSnackBar("Error saving request count update.");
    }
  }

  Future<void> _addSelectedIngotToCrucible() async {
    if (_interactionsDisabled) {
      _showSnackBar("Cannot modify crucible now.");
      return;
    }
    if (_selectedIngotFromCollection == null) {
      _showSnackBar("Select an ingot from your collection first.");
      return;
    }
    if (_currentCrucible == null) {
      _showSnackBar("Error: Crucible data not available.");
      return;
    }
    final maxSlots = _selectedGameRule?.regularBallsDrawn ?? 6;
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
        await _saveDraftCrucible();
        _confettiController.play();
        _showSnackBar("Ingot #${ingotToAdd.ingotId} added to crucible.");
      }
    } catch (e) {
      _currentCrucible!.combinations.remove(ingotToAdd);
      _showSnackBar("Error updating collection.");
      if (mounted) setState(() {});
    }
  }

  Future<void> _swapCrucibleAndCollectionIngots() async {
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
      _showSnackBar("Error: Crucible data not available.");
      return;
    }

    final ingotFromCollection = _selectedIngotFromCollection!;
    final ingotInCrucible = _selectedIngotInCrucible!;
    int indexInCrucible = _currentCrucible!.combinations
        .indexWhere((c) => c.ingotId == ingotInCrucible.ingotId);

    if (indexInCrucible == -1) {
      setState(() {
        _selectedIngotInCrucible = null;
      });
      _showSnackBar("Error: Could not find the selected crucible slot.");
      return;
    }

    setState(() {
      _currentCrucible!.combinations[indexInCrucible] = ingotFromCollection;
      _ingotCollection
          .removeWhere((ingot) => ingot.ingotId == ingotFromCollection.ingotId);
      _ingotCollection.insert(0, ingotInCrucible);
      _selectedIngotFromCollection = null;
      _selectedIngotInCrucible = null;
    });

    try {
      await dbHelper.removeIngotFromCollection(ingotFromCollection.ingotId);
      await dbHelper.addIngotToCollection(
          userId: _currentCrucible!.userId!,
          gameName: _selectedGameRule!.gameName,
          drawDate: _targetDrawDate!,
          ingotId: ingotInCrucible.ingotId,
          numbers: ingotInCrucible.numbers);
      await _saveDraftCrucible();
      _confettiController.play();
      _showSnackBar(
          "Ingot #${ingotFromCollection.ingotId} placed in crucible, Ingot #${ingotInCrucible.ingotId} returned to collection.");
    } catch (e) {
      setState(() {
        _currentCrucible!.combinations[indexInCrucible] = ingotInCrucible;
        _ingotCollection.removeWhere(
            (ingot) => ingot.ingotId == ingotInCrucible.ingotId);
        _ingotCollection.insert(0, ingotFromCollection);
      });
      _showSnackBar("Error updating collection during swap.");
    }
  }

  Future<void> _saveDraftCrucible(
      {bool showSnackbar = true, bool bypassLoadingCheck = false}) async {
    if (_currentCrucible == null || (!bypassLoadingCheck && _isLoading)) return;
    if (_isCrucibleLocked) return;

    _currentCrucible!.status = 'draft';
    _currentCrucible!.submittedDate = DateTime.now();

    try {
      int resultId = await dbHelper.insertIngotCrucible(_currentCrucible!);
      if (resultId > 0) {
        if (mounted && _currentCrucible!.id == null) {
          _currentCrucible!.id = resultId;
        }
        if (showSnackbar) _showSnackBar('Draft saved.');
      } else {
        if (showSnackbar) _showSnackBar('Failed to save draft.');
      }
    } catch (e) {
      if (showSnackbar) _showSnackBar('Error saving draft.');
    }
  }

  Future<void> _forgeTickets() async {
    if (_interactionsDisabled || _isForging) return;
    if (_currentCrucible == null) return;
    final maxSlots = _selectedGameRule?.regularBallsDrawn ?? 6;
    if (_currentCrucible!.combinations.length < maxSlots) {
      _showSnackBar("Please fill all $maxSlots crucible slots before forging.");
      return;
    }
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
    if (confirmed != true) return;

    setState(() {
      _isForging = true;
    });

    _currentCrucible!.status = 'submitted';
    _currentCrucible!.submittedDate = DateTime.now();
    try {
      await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true);
    } catch (_) {
      _showSnackBar("Error saving crucible status locally.");
      if (mounted) {
        setState(() {
          _isForging = false;
        });
      }
      return;
    }

    final authState = Provider.of<AuthState>(context, listen: false);
    final List<int> ingotIdsToSend =
        _currentCrucible!.combinations.map((c) => c.ingotId).toList();
    final requestBody = jsonEncode({
      'user_id': _currentCrucible!.userId,
      'game_name': _selectedGameRule!.gameName,
      'draw_date': _targetDrawDate,
      'play_card_id': _currentCrucible!.id,
      'ingot_ids': ingotIdsToSend,
    });

    try {
      final url = Uri.https('governance.page', '/wp-json/apigold/v1/submit-playcard');
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
      if (!mounted) return;
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
        } catch (_) {
          success = true;
        }
        if (success) {
          _showSnackBar(message);
          if (mounted) {
            setState(() {
              _isCrucibleLocked = true;
            });
            try {
              int userId = int.parse(authState.userId);
              await dbHelper.clearIngotCollectionForDraw(
                  userId, _selectedGameRule!.gameName, _targetDrawDate!);
              setState(() {
                _ingotCollection = [];
                _selectedIngotFromCollection = null;
              });
            } catch (_) {}
          }
        } else {
          _showSnackBar(message);
          _currentCrucible!.status = 'draft';
          await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true);
          if (mounted) {
            setState(() => _isCrucibleLocked = false);
          }
        }
      } else {
        String errorMessage = "Failed to forge tickets.";
        try {
          final responseData = json.decode(response.body);
          errorMessage =
              responseData['message'] ?? "Server error ${response.statusCode}";
        } catch (_) {
          errorMessage =
              "Server error ${response.statusCode}. Could not parse response.";
        }
        _showSnackBar(errorMessage);
        _currentCrucible!.status = 'draft';
        await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true);
        if (mounted) {
          setState(() {
            _isCrucibleLocked = false;
          });
        }
      }
    } on TimeoutException catch (_) {
      _showSnackBar("Network timeout forging tickets. Please try again.");
      _currentCrucible!.status = 'draft';
      await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true);
      if (mounted) {
        setState(() {
          _isCrucibleLocked = false;
        });
      }
    } catch (_) {
      _showSnackBar("Network error forging tickets.");
      _currentCrucible!.status = 'draft';
      await _saveDraftCrucible(showSnackbar: false, bypassLoadingCheck: true);
      if (mounted) {
        setState(() {
          _isCrucibleLocked = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isForging = false;
        });
      }
    }
  }

  void _showSnackBar(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
    }
  }

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

  String _truncateChecksum(String checksum, {int length = 16}) {
    if (checksum.length <= length) {
      return checksum;
    }
    int endIndex = length < checksum.length ? length : checksum.length;
    return '${checksum.substring(0, endIndex)}...';
  }

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
      } else if (_targetDrawDate != null && _targetDrawDate!.isNotEmpty) {
        timeRemainingStr = "Cutoff time unknown";
      } else {
        timeRemainingStr = "Draw info unavailable";
      }
    }

    String crucibleStatusText = "";
    Color crucibleStatusColor = Colors.grey;
    IconData crucibleStatusIcon = Icons.info_outline;
    int currentSlots = _currentCrucible?.combinations.length ?? 0;
    int maxSlots = _selectedGameRule?.regularBallsDrawn ?? 6;
    bool isCrucibleFull =
        !_isLoading && _currentCrucible != null && currentSlots >= maxSlots;

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
        title: const Text('The Smelter', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _isLoading = true;
                            _errorMessage = null;
                          });
                          _loadAvailableGames();
                        },
                        child: const Text('Retry Load'),
                      ),
                    ],
                  ),
                ))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // --- Crucible (Game) Selector ---
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<GameRule>(
                              value: _selectedGameRule,
                              isExpanded: true,
                              onChanged: (game) {
                                if (game != null) _onGameRuleChanged(game);
                              },
                              items: _availableGames.map<DropdownMenuItem<GameRule>>((GameRule rule) {
                                return DropdownMenuItem<GameRule>(
                                  value: rule,
                                  child: Text(rule.gameName),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // --- Status Info ---
                      Card(
                        elevation: 1,
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Game: ${_selectedGameRule?.gameName ?? "..."}',
                                style: Theme.of(context).textTheme.headlineSmall,
                              ),
                              Text(
                                'Draw Date: ${_targetDrawDate != null ? DateFormat('EEEE, MMMM d, yyyy').format(DateTime.parse(_targetDrawDate!)) : "..."}',
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
                      // --- Smelt Button ---
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
                            icon:
                                const Icon(Icons.add_box_outlined, size: 18),
                            label: const Text("Add to Crucible"),
                            onPressed: canAdd ? _addSelectedIngotToCrucible : null,
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
                      // Crucible Slots Grid
                      SizedBox(
                        height: 120,
                        child: (_currentCrucible?.combinations.isEmpty ?? true)
                            ? Container(
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade300),
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
                                        backgroundBlendMode: _interactionsDisabled
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
                                                    color: _interactionsDisabled
                                                        ? Colors.grey[600]
                                                        : Colors.black,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                Text(
                                                  'ID# ${combination.ingotId}',
                                                  style: TextStyle(
                                                    color: _interactionsDisabled
                                                        ? Colors.grey[500]
                                                        : Colors.black54,
                                                    fontSize: 10,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
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
                        child: const Text('Back'),
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