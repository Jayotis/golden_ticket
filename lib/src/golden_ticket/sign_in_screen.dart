import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:provider/provider.dart';
import 'dart:async';
import 'package:logging/logging.dart';

import 'auth/auth_state.dart';
import 'logging_utils.dart';
import 'routes.dart';
import 'database_helper.dart';
import '../../push_notification_service.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});
  static const routeName = '/sign-in';

  @override
  SignInScreenState createState() => SignInScreenState();
}

class SignInScreenState extends State<SignInScreen> {
  final _log = Logger('SignInScreen');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSigningIn = false;
  final PushNotificationService _pushNotificationService = PushNotificationService();

  @override
  void initState() {
    super.initState();
    LoggingUtils.setupLogger(_log);
  }

  Future<void> _signIn() async {
    if (!mounted || _isSigningIn) return;
    setState(() { _isSigningIn = true; });

    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      _showSnackBar('Please enter both username and password.');
      setState(() => _isSigningIn = false);
      return;
    }

    final url = Uri.https('governance.page', '/wp-json/apigold/v1/login');

    try {
      _log.info("Attempting sign in for user: $username");
      final response = await http.post(
        url,
        headers: { 'Content-Type': 'application/json' },
        body: jsonEncode({ 'username': username, 'password': password }),
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return;

      final responseData = json.decode(response.body);

      if (response.statusCode == 200 && responseData['code'] == 'success') {
        _log.info('Sign in successful: $responseData');
        final data = responseData['data'];
        if (data == null || data is! Map) {
          _log.severe('Sign in response missing or invalid "data" field.');
          _showSnackBar('Sign in failed: Invalid response from server.');
          setState(() => _isSigningIn = false);
          return;
        }

        final userId = data['user_id'];
        final accountStatus = data['account_status'];
        final membershipLevel = data['membership_level'];
        final authToken = data['auth_token'];
        final minimumRequiredVersionStr = data['app_version'];
        _log.fine("Extracted minimum required version from API: $minimumRequiredVersionStr");

        if (userId == null || userId is! int ||
            accountStatus == null || accountStatus is! String || accountStatus.isEmpty ||
            membershipLevel == null || membershipLevel is! String || membershipLevel.isEmpty ||
            authToken == null || authToken is! String || authToken.isEmpty ||
            minimumRequiredVersionStr == null || minimumRequiredVersionStr is! String || minimumRequiredVersionStr.isEmpty)
        {
          _log.severe('Sign in response data invalid.');
          _showSnackBar('Sign in failed: Invalid response data.');
          setState(() => _isSigningIn = false);
          return;
        }
        final String userIdStr = userId.toString();

        final authState = context.read<AuthState>();
        await authState.setSignInStatus(
          signedIn: true,
          accountStatus: accountStatus,
          membershipLevel: membershipLevel,
          userId: userIdStr,
          authToken: authToken,
          gameDrawData: [],
          minimumRequiredVersionStr: minimumRequiredVersionStr,
        );
        _log.info("AuthState updated. Requires update flag set to: ${authState.requiresUpdate}");

        if (accountStatus == "subscriber") {
          if (mounted) {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (context) => AlertDialog(
                title: Text('Account Not Verified'),
                content: Text('Your account is not verified. Please check your email. You will be logged out.'),
              ),
            );
            Future.delayed(Duration(seconds: 2), () async {
              Navigator.of(context, rootNavigator: true).pop(); // close dialog
              final authState = context.read<AuthState>();
              await authState.signOut();
              if (mounted) {
                Navigator.of(context).pushNamedAndRemoveUntil(
                  SignInScreen.routeName,
                  (route) => false,
                );
              }
            });
          }
          setState(() => _isSigningIn = false);
          return;
        }
        try {
          final dbHelper = DatabaseHelper();
          await Future.delayed(const Duration(milliseconds: 200));
          await _createEnhancedProfileFromUserCache(
            dbHelper: dbHelper,
            userId: userId,
            membershipLevel: membershipLevel,
            authToken: authToken,
          );
          _log.info('Local user profile created/updated for user ID: $userId upon sign-in.');
        } catch (dbError) {
          _log.severe('Error setting up local profile/progress for user ID $userId during sign-in: $dbError');
          _showSnackBar('Warning: Could not update local profile/game data.');
        }
        _log.info('Local profile/progress updated.');

        try {
          _log.info("Attempting to get/send FCM token after login...");
          String? fcmToken = await _pushNotificationService.getToken();
          if (fcmToken != null) {
            await _pushNotificationService.sendTokenToServer(userIdStr, fcmToken, authToken);
          } else {
            _log.warning("Could not get FCM token after login to send to server.");
            _showSnackBar("Push notifications might not be enabled.");
          }
        } catch (e) {
          _log.severe("Error getting or sending FCM token after login: $e");
          _showSnackBar("Error setting up push notifications.");
        }

        // --- Profile completeness and onboarding navigation ---
       // await _navigateBasedOnProfileCompleteness(userId);
        _navigateToHomeScreen();
        return;
      } else {
        final errorMessage = responseData['message'] ?? 'Sign in failed.';
        _log.warning('Failed to sign in. Status: ${response.statusCode}, Message: $errorMessage');
        _showSnackBar(errorMessage);
      }
    } on TimeoutException {
      _log.warning('Sign in timed out.');
      if (mounted) _showSnackBar('Sign in request timed out. Please try again.');
    } catch (e, stacktrace) {
      _log.severe('Error signing in: $e', e, stacktrace);
      if (mounted) _showSnackBar('An unexpected error occurred during sign in.');
    } finally {
      if (mounted) {
        setState(() { _isSigningIn = false; });
      }
    }
  }

  Future<void> _createEnhancedProfileFromUserCache({
    required DatabaseHelper dbHelper,
    required int userId,
    required String membershipLevel,
    required String authToken,
  }) async {
    String? primaryGameName = await _getPrimaryGameFromUserData(dbHelper, userId);
    if (primaryGameName == null) {
      await dbHelper.insertOrUpdateUserProfile(
        userId: userId,
        membershipLevel: membershipLevel,
        globalAwards: [],
        globalStatistics: jsonEncode({
          'profile_created': DateTime.now().toIso8601String(),
          'profile_version': '1.0',
          'fallback_profile': true,
        }),
      );
      return;
    }
    final gameDrawInfo = await dbHelper.getGameDrawInfo(primaryGameName);
    final gameRule = await dbHelper.getGameRule(primaryGameName);
    final gameProgress = await dbHelper.getUserGameProgress(userId, primaryGameName);

    final profileData = {
      'primary_game': primaryGameName,
      'next_draw_date': gameDrawInfo?.drawDate,
      'total_combinations': gameDrawInfo?.totalCombinations,
      'user_request_limit': gameDrawInfo?.userRequestLimit,
      'user_score': gameProgress?['game_score'] ?? 0,
      'profile_created': DateTime.now().toIso8601String(),
      'cache_populated': gameDrawInfo != null,
      'profile_version': '2.0',
      'game_context': {
        'draw_schedule': gameRule?.drawSchedule,
        'has_cached_results': await _hasRecentCachedResults(dbHelper, primaryGameName),
      }
    };
    await dbHelper.insertOrUpdateUserProfile(
      userId: userId,
      membershipLevel: membershipLevel,
      globalAwards: [],
      globalStatistics: jsonEncode(profileData),
    );
  }

  Future<String?> _getPrimaryGameFromUserData(DatabaseHelper dbHelper, int userId) async {
    try {
      final userProgress = await dbHelper.getAllUserGameProgress(userId);
      if (userProgress.isNotEmpty) {
        userProgress.sort((a, b) => (b['game_score'] ?? 0).compareTo(a['game_score'] ?? 0));
        return userProgress.first['game_name'] as String?;
      }
      final activeGames = await dbHelper.getActiveGamesForUser(userId);
      if (activeGames.isNotEmpty) return activeGames.first;
      final db = await dbHelper.database;
      final recentCacheEntries = await db.query(
        'game_results_cache',
        columns: ['game_name'],
        orderBy: 'fetched_at DESC',
        limit: 1,
      );
      if (recentCacheEntries.isNotEmpty) {
        return recentCacheEntries.first['game_name'] as String?;
      }
      final drawInfoEntries = await db.query(
        'game_draw_info',
        columns: ['game_name'],
        orderBy: 'last_updated DESC',
        limit: 1,
      );
      if (drawInfoEntries.isNotEmpty) {
        return drawInfoEntries.first['game_name'] as String?;
      }
      return null;
    } catch (e) {
      _log.warning('Error determining primary game from user data: $e');
      return null;
    }
  }

  Future<bool> _hasRecentCachedResults(DatabaseHelper dbHelper, String gameName) async {
    try {
      final db = await dbHelper.database;
      final recentResults = await db.query(
        'game_results_cache',
        where: 'game_name = ? AND fetched_at > ?',
        whereArgs: [
          gameName,
          DateTime.now().subtract(const Duration(days: 7)).toIso8601String()
        ],
        limit: 1,
      );
      return recentResults.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // --- Profile Completeness Check and Navigation ---
  Future<void> _navigateBasedOnProfileCompleteness(int userId) async {
    final completeness = await _getProfileCompleteness(userId);

    if (completeness.isComplete) {
      _log.info('Profile complete, navigating to main screen');
      _navigateToHomeScreen();
    } 
    // else {
    //  _log.info('Profile incomplete, navigating to onboarding/profile completion');
    //  _navigateToProfileCompletion(completeness);
    // }
  }

  Future<ProfileCompleteness> _getProfileCompleteness(int userId) async {
    final dbHelper = DatabaseHelper();
    final profile = await dbHelper.getUserProfile(userId);
    if (profile == null) {
      return ProfileCompleteness.empty();
    }
    Map<String, dynamic>? profileData;
    try {
      final statsJson = profile['global_statistics'] as String?;
      profileData = statsJson != null ? jsonDecode(statsJson) : null;
    } catch (_) {
      profileData = null;
    }
    final userProgress = await dbHelper.getAllUserGameProgress(userId);
    final activeGames = await dbHelper.getActiveGamesForUser(userId);
    bool hasGameData = userProgress.isNotEmpty || activeGames.isNotEmpty;
    bool hasCachedData = false;
    if (hasGameData) {
      for (final progress in userProgress) {
        final gameName = progress['game_name'] as String;
        final drawInfo = await dbHelper.getGameDrawInfo(gameName);
        if (drawInfo != null) {
          hasCachedData = true;
          break;
        }
      }
    }
    return ProfileCompleteness(
      hasBasicInfo: profile['membership_level']?.isNotEmpty ?? false,
      hasGameSelection: hasGameData,
      hasCachedGameData: hasCachedData,
      profileVersion: profileData?['profile_version'] as String?,
      primaryGame: profileData?['primary_game'] as String?,
      isDataDriven: profileData?['fallback_profile'] != true,
    );
  }

  void _navigateToHomeScreen() {
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        Routes.main,
        (Route<dynamic> route) => false,
      );
    }
  }

  // void _navigateToProfileCompletion(ProfileCompleteness completeness) {
  //  if (mounted) {
  //    Navigator.pushReplacementNamed(
  //      context,
  //      Routes.completeProfile,
  //      arguments: completeness,
  //    );
  //  }
  // }

  Future<void> _navigateToCreateAccount() async {
    Navigator.pushNamed(context, Routes.createAccount);
    _log.info("Navigated to Create Account screen.");
  }

  void _showSnackBar(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign In')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Username or Email'),
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _signIn(),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isSigningIn ? null : _signIn,
              child: _isSigningIn
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                    )
                  : const Text('Sign In'),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _isSigningIn ? null : _navigateToCreateAccount,
              child: const Text('Create Free Account'),
            ),
          ],
        ),
      ),
    );
  }
}

class ProfileCompleteness {
  final bool hasBasicInfo;
  final bool hasGameSelection;
  final bool hasCachedGameData;
  final String? profileVersion;
  final String? primaryGame;
  final bool isDataDriven;

  ProfileCompleteness({
    required this.hasBasicInfo,
    required this.hasGameSelection,
    required this.hasCachedGameData,
    this.profileVersion,
    this.primaryGame,
    this.isDataDriven = false,
  });

  bool get isComplete => hasBasicInfo && hasGameSelection && hasCachedGameData;
  bool get isRichProfile => isDataDriven && primaryGame != null;

  double get completionPercentage {
    int score = 0;
    if (hasBasicInfo) score++;
    if (hasGameSelection) score++;
    if (hasCachedGameData) score++;
    if (isDataDriven) score++;
    return score / 4.0;
  }

  factory ProfileCompleteness.empty() => ProfileCompleteness(
    hasBasicInfo: false,
    hasGameSelection: false,
    hasCachedGameData: false,
  );
}