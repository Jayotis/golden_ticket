import 'package:flutter/material.dart';
// Import Provider for accessing shared state like AuthState.
import 'package:provider/provider.dart';
// Import dart:async for Timer (though Timer is used in GameEventService, not directly here).
import 'dart:async';
// Import logging framework.
import 'package:logging/logging.dart';

// --- Project-Specific Imports ---
// Import named route constants.
import 'routes.dart'; // Ensure this path is correct
// Import authentication state management.
import 'auth/auth_state.dart'; // Ensure this path is correct
// Import database helper for accessing local data (GameDrawInfo, Crucible status, etc.).
import 'database_helper.dart'; // Ensure this path is correct

// Import game rules definition.
import 'game_rules.dart'; // Ensure this path is correct
// Import logging utility.
import 'logging_utils.dart'; // Ensure this path is correct
// Import the service handling game logic, API calls, and polling.
import 'game_event_service.dart'; // Ensure this path is correct

/// The main screen displayed after a user successfully signs in and verifies their email.
/// Acts as the central navigation hub for the application's core features.
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  // Route name for navigation. '/' typically represents the home/main route.
  static const routeName = '/';
  @override
  State<MainScreen> createState() => _MainScreenState();
}

/// State class for the MainScreen widget.
class _MainScreenState extends State<MainScreen> {
  // --- State Variables ---
  bool _isLoading = true;
  GameRule? _currentGameRule;
  String? _currentNextDrawDate;
  String? _calculatedLastDrawDate;
  bool _hasPlaycardForNextDraw = true;
  bool _hasAnyNewResults = false;

  final _log = Logger('MainScreen');
  final String _defaultGameName = "lotto649";
  final dbHelper = DatabaseHelper();
  GameEventService? _gameEventService;
  AuthState? _authStateInstance;

  @override
  void initState() {
    super.initState();
    LoggingUtils.setupLogger(_log);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authState = Provider.of<AuthState>(context, listen: false);

    // --- Initialization Logic (Runs only once or on auth change) ---
    final previousSignInStatus = _authStateInstance?.isSignedIn ?? false;
    bool needsInitializationOrReload = (_authStateInstance == null) || (authState.isSignedIn != previousSignInStatus);

    if (needsInitializationOrReload) {
      _log.info("AuthState changed or initial load. Re-initializing services and data.");
      _authStateInstance = authState; // Update the local AuthState instance.
      _gameEventService = GameEventService(_authStateInstance!); // Always re-initialize service with current AuthState

      if (authState.isSignedIn) {
        // If user signed in (or was already signed in on initial load), load screen data.
        _loadScreenData();
      } else {
        // If user signed out or was not signed in initially, reset the screen state and stop polling.
        _log.info("User not signed in. Resetting state and stopping polling.");
        if (mounted) {
          setState(() {
            _isLoading = false;
            _resetStateBeforeLoad(); // Clear screen data.
          });
          _gameEventService?.stopPolling(); // Ensure polling stops on sign out.
        }
      }
    }
    // --- End Initialization Logic ---
  }


  @override
  void dispose() {
    _log.info("Disposing MainScreen, stopping polling.");
    _gameEventService?.stopPolling();
    super.dispose();
  }


  void _resetStateBeforeLoad() {
    _currentGameRule = null;
    _currentNextDrawDate = null;
    _calculatedLastDrawDate = null;
    _hasPlaycardForNextDraw = true;
    _hasAnyNewResults = false;
  }


  Future<void> _loadScreenData() async {
    // ... (loadScreenData implementation remains the same) ...
    _log.info('Starting _loadScreenData...');
    if (!mounted) return;

    final authState = _authStateInstance;
    final gameService = _gameEventService;
    if (authState == null || !authState.isSignedIn || gameService == null) {
      _log.warning('User not signed in, AuthState not ready, or GameEventService not ready. Aborting load.');
      if (mounted) {
        setState(() { _isLoading = false; _resetStateBeforeLoad(); });
      }
      return;
    }

    setState(() { _isLoading = true; _resetStateBeforeLoad(); });

    int? currentUserId;
    try {
      currentUserId = int.parse(authState.userId);
    } catch (e) {
      _log.severe("Error parsing User ID from AuthState: ${authState.userId}, Error: $e");
      if (mounted) { _showSnackBar('Error: Invalid user ID.'); setState(() => _isLoading = false); }
      return;
    }

    GameRule? loadedRule;
    String? loadedNextDate;
    String? calcLastDate;
    bool loadedHasPlaycard = true;
    bool loadedAnyNewResults = false;

    try {
      loadedRule = await dbHelper.getGameRule(_defaultGameName);
      if (loadedRule == null) { throw Exception("Missing game rule for $_defaultGameName"); }
      _log.info('Fetched Game Rule: ${loadedRule.gameName}');

      final GameDrawInfo? drawInfo = await dbHelper.getGameDrawInfo(_defaultGameName);
      if (drawInfo == null || drawInfo.drawDate.isEmpty) {
        _log.warning("GameDrawInfo (including next draw date) not found in DB for $_defaultGameName. Attempting service fetch as fallback...");
        loadedNextDate = await gameService.getNextDrawDate(_defaultGameName, forceRefresh: true);
        if (loadedNextDate == null) {
          throw Exception("Next draw date unavailable from DB and Service for $_defaultGameName.");
        }
        _log.info('Fallback successful: Fetched next draw date from service: $loadedNextDate');
      } else {
        loadedNextDate = drawInfo.drawDate;
        _log.info('Using Next Draw Date from DB (GameDrawInfo): $loadedNextDate');
      }

      calcLastDate = await gameService.calculateLastDrawDate(_defaultGameName, loadedNextDate);
      _log.info('Calculated Last Draw Date: $calcLastDate');

      loadedHasPlaycard = await dbHelper.hasCrucibleForDrawDate(currentUserId, loadedNextDate);
      _log.info('Checked Crucible for User $currentUserId, Draw $loadedNextDate: Found = $loadedHasPlaycard');

      loadedAnyNewResults = await dbHelper.hasAnyNewResults();
      _log.info("Checked for any new results across all games: $loadedAnyNewResults");

    } catch (e, stacktrace) {
      _log.severe('Error loading screen data: $e\nStacktrace: $stacktrace');
      if (mounted) _showSnackBar('An error occurred loading screen data.');
      loadedRule = null; loadedNextDate = null; calcLastDate = null;
      loadedHasPlaycard = true; loadedAnyNewResults = false;
    } finally {
      if (mounted) {
        setState(() {
          _currentGameRule = loadedRule;
          _currentNextDrawDate = loadedNextDate;
          _calculatedLastDrawDate = calcLastDate;
          _hasPlaycardForNextDraw = loadedHasPlaycard;
          _hasAnyNewResults = loadedAnyNewResults;
          _isLoading = false;
        });

        if (authState.isSignedIn && calcLastDate != null && gameService != null) {
          _log.info("Checking if polling should start for $_defaultGameName (last draw: $calcLastDate)...");
          gameService.startPollingIfNeeded(_defaultGameName, calcLastDate);
        } else {
          _log.warning("Not starting polling: User signed out, last draw date unknown, or service not ready.");
          gameService?.stopPolling();
        }
      }
    }
  }


  void _showSnackBar(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use Consumer to listen to AuthState changes, including requiresUpdate
    return Consumer<AuthState>(
      builder: (context, authState, child) {
        // Build the main Scaffold structure
        return Scaffold(
          appBar: AppBar(
            title: const Text('Golden Tickets'),
            actions: [
              // Show refresh only if signed in AND update is not required
              if (authState.isSignedIn && !authState.requiresUpdate)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _isLoading ? null : _loadScreenData,
                  tooltip: 'Refresh Data',
                ),
            ],
          ),
          // Use Stack to potentially overlay an update message
          body: Stack(
            children: [
              // Main content area
              // Pass authState down to _buildMainContent
              Center(child: _buildMainContent(authState)),

              // --- Overlay Update Message ---
              // If update is required, show a semi-transparent overlay
              if (authState.requiresUpdate)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(0.7), // Dark overlay
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.system_update_alt, size: 60, color: Colors.orangeAccent),
                            const SizedBox(height: 16),
                            Text(
                              'Update Required',
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Please update the app to the latest version to continue using all features.',
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            // Optional: Add a button to open the app store
                            // ElevatedButton(
                            //   onPressed: () { /* TODO: Implement app store link */ },
                            //   child: const Text('Update Now'),
                            // ),
                            // Optional: Add a sign out button if you want to allow sign out from here
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: BorderSide(color: Colors.white54)),
                              onPressed: () {
                                _log.info("Signing out due to update requirement...");
                                _gameEventService?.stopPolling();
                                // Use the authState provided by the Consumer
                                authState.signOut();
                              },
                              child: const Text('Sign Out'),
                            )
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // --- End Overlay ---
            ],
          ),
        );
      },
    );
  }


  /// Builds the main content widget based on the current state.
  /// NOTE: Receives AuthState as a parameter now.
  Widget _buildMainContent(AuthState authState) {
    // The overlay is handled by the Stack in the main build method.
    // This content will be underneath the overlay if authState.requiresUpdate is true.

    // --- Original Content Logic ---
    if (_isLoading) {
      return const CircularProgressIndicator();
    }

    if (!authState.isSignedIn) {
      _gameEventService?.stopPolling();
      return Column( /* ... Sign In / Create Account buttons ... */
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: () => Navigator.pushNamed(context, Routes.signIn),
            child: const Text('Sign In'),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => Navigator.pushNamed(context, Routes.createAccount),
            child: const Text('Create Free Account'),
          ),
        ],
      );
    }

    if (authState.accountStatus == 'subscriber') {
      return const Padding( /* ... Verify Email message ... */
        padding: EdgeInsets.all(16.0),
        child: Text(
          'Account created! Please check your email to verify before proceeding.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_currentGameRule == null || _currentNextDrawDate == null) {
      return Column( /* ... Error loading data message ... */
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Failed to load essential game data. Please try again.'),
          const SizedBox(height: 10),
          ElevatedButton( onPressed: _loadScreenData, child: const Text('Retry'), )
        ],
      );
    }

    // Main Signed In View (only displayed if requiresUpdate is false, due to overlay)
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- MODIFICATION START: Use Selector for Welcome Message ---
          // Use Selector to listen only to membershipLevel changes
          Selector<AuthState, String>(
            selector: (context, auth) => auth.membershipLevel,
            builder: (context, membershipLevel, child) {
              _log.fine("Rebuilding Welcome Message Text. Level: $membershipLevel");
              // Return the Text widget using the selected membershipLevel
              return Text(
                _getWelcomeMessage(membershipLevel),
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              );
            },
          ),
          // --- MODIFICATION END ---
          const SizedBox(height: 32),
          _buildSmelterButton(),
          const SizedBox(height: 16),
          _buildTicketsButton(),
          const SizedBox(height: 16),
          _buildResultsHubButton(),
          const SizedBox(height: 16),
          _buildAccountButton(),
          const SizedBox(height: 24),
          // Pass the authState received by _buildMainContent
          _buildSignOutButton(authState),
        ],
      ),
    );
  }

  // --- Helper methods (_getWelcomeMessage, _buildSmelterButton, etc.) ---
  // ... (Keep your existing helper methods here, ensure they don't use context.select/watch) ...
  String _getWelcomeMessage(String membershipLevel) {
    // This method is fine as it just takes the string
    switch (membershipLevel.toLowerCase()) {
      case 'work pool': return 'Welcome, Work Pool Member!';
      case 'family': return 'Welcome, Family Member!';
      case 'subscriber':
      case 'active':
      default: return 'Welcome!';
    }
  }

  Widget _buildSmelterButton() {
    // This method is fine
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 45)),
      onPressed: () => Navigator.pushNamed(context, Routes.theSmelter),
      icon: const Icon(Icons.whatshot),
      label: const Text('The Smelter'),
    );
  }

  Widget _buildTicketsButton() {
    // This method is fine (uses state variables _hasPlaycardForNextDraw, _currentNextDrawDate)
    final bool needsAttention = !_hasPlaycardForNextDraw;
    Widget buttonLabel = const Text('Manage Tickets');
    IconData buttonIcon = Icons.confirmation_number_outlined;

    if (needsAttention) {
      buttonLabel = const Text('Get Tickets for Next Draw');
      buttonIcon = Icons.warning_amber_rounded;
    }

    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(double.infinity, 45),
        backgroundColor: needsAttention ? Colors.orange[100] : null,
        foregroundColor: needsAttention ? Colors.orange[900] : null,
      ),
      onPressed: () {
        if (_currentNextDrawDate != null) {
          _log.info("Navigating to The Forge for game: $_defaultGameName / draw: $_currentNextDrawDate");
          Navigator.pushNamed(
              context,
              Routes.theForge,
              arguments: {
                'gameName': _defaultGameName,
                'nextDrawDate': _currentNextDrawDate,
              }
          ).then((_) {
            _log.info("Returned from The Forge, reloading main screen data.");
            if (mounted) _loadScreenData();
          });
        } else {
          _log.warning('Cannot navigate to Forge: Next draw date is unknown.');
          _showSnackBar('Next draw date unknown, cannot manage tickets.');
        }
      },
      icon: Icon(buttonIcon, color: needsAttention ? Colors.orange[900] : null),
      label: buttonLabel,
    );
  }

  Widget _buildResultsHubButton() {
    // This method is fine (uses state variable _hasAnyNewResults)
    final bool needsAttention = _hasAnyNewResults;
    Widget buttonLabel = const Text('Game Results Hub');
    IconData buttonIcon = Icons.assessment_outlined;

    if (needsAttention) {
      buttonLabel = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.new_releases, color: Colors.blue[700], size: 20),
          const SizedBox(width: 8),
          const Text('Game Results Hub'),
        ],
      );
    }

    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 45)),
      onPressed: () {
        _log.info("Navigating to Results Hub.");
        Navigator.pushNamed(context, Routes.resultsHub).then((_) {
          _log.info("Returned from ResultsHubScreen, reloading main screen data.");
          if (mounted) {
            _loadScreenData();
          }
        });
      },
      icon: Icon(buttonIcon),
      label: buttonLabel,
    );
  }

  Widget _buildAccountButton() {
    // This method is fine
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 45)),
      onPressed: () { Navigator.pushNamed(context, Routes.account); },
      icon: const Icon(Icons.person_outline),
      label: const Text('My Account'),
    );
  }

  Widget _buildSignOutButton(AuthState authState) {
    // This method is fine (takes authState as parameter)
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(double.infinity, 45),
        foregroundColor: Colors.red[700],
        side: BorderSide(color: Colors.red[200]!),
      ),
      onPressed: () {
        _log.info("Signing out...");
        _gameEventService?.stopPolling();
        authState.signOut();
      },
      icon: const Icon(Icons.logout),
      label: const Text('Sign Out'),
    );
  }

} // End of _MainScreenState
