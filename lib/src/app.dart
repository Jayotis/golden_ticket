import 'package:flutter/material.dart';
// Import generated localization delegates for handling translations.
import '../l10n/app_localizations.dart';
// Import Flutter's localization support.
import 'package:flutter_localizations/flutter_localizations.dart';
// Import Provider package for state management (used here to provide AuthState).
import 'package:provider/provider.dart';

// --- Project-Specific Screen Imports ---
// Import the various screens used within the application.
import 'golden_ticket/the_smelter.dart';   // Screen for forging tickets.
import 'golden_ticket/auth/auth_state.dart';     // Authentication state management class.
import 'golden_ticket/main_screen.dart';         // The main screen shown after sign-in or as default.
import 'settings/settings_controller.dart';      // Controller for managing app settings (like theme).
import 'settings/settings_view.dart';            // Screen for displaying and changing settings.
import 'golden_ticket/sign_in_screen.dart';      // Screen for user sign-in.
import 'golden_ticket/game_selector_screen.dart';// Screen for selecting a game.
import 'golden_ticket/smelter.dart';             // Screen for managing active game crucibles (The Smelter).
import 'golden_ticket/verify_results_screen.dart';// Screen potentially used for result verification (may be unused/future).
import 'golden_ticket/create_account_screen.dart';// Screen for new user account creation.
import 'golden_ticket/routes.dart';              // Class defining named route constants.
import 'golden_ticket/account_screen.dart';      // Screen for viewing user account details.
import 'golden_ticket/results_hub_screen.dart';  // Screen showing a hub of game results.
import 'golden_ticket/Results_Screen.dart';      // Screen displaying detailed results for a specific game draw.


/// The root widget of the application.
/// It sets up the MaterialApp, themes, localization, and routing.
class MyApp extends StatelessWidget {
  /// Constructor for MyApp.
  /// Requires [settingsController] for theme management and
  /// the pre-initialized [authState] instance from main.dart.
  const MyApp({
    super.key,
    required this.settingsController,
    required this.authState, // Accept the initialized AuthState instance.
  });

  // Controller for managing application settings (e.g., theme mode).
  final SettingsController settingsController;
  // The single, initialized instance of AuthState passed from main.dart.
  final AuthState authState;

  @override
  Widget build(BuildContext context) {
    // ListenableBuilder rebuilds the MaterialApp whenever SettingsController notifies listeners
    // (e.g., when the theme mode changes).
    return ListenableBuilder(
      listenable: settingsController,
      builder: (BuildContext context, Widget? child) {
        // ChangeNotifierProvider.value is used to provide the *existing* authState instance
        // down the widget tree. This makes AuthState accessible to any descendant widget
        // using Provider.of<AuthState>(context) or context.watch<AuthState>(), etc.
        // Using .value is crucial here because authState is created and initialized *before* MyApp.
        return ChangeNotifierProvider<AuthState>.value(
          value: authState, // Provide the instance received from main.dart.
          child: MaterialApp(
            // restorationScopeId enables state restoration for the navigator stack.
            // Allows the app to potentially restore its navigation state after being killed.
            restorationScopeId: 'app',

            // --- Localization Setup ---
            // Delegates required for Flutter's localization features.
            localizationsDelegates: const [
              AppLocalizations.delegate, // Generated localizations delegate.
              GlobalMaterialLocalizations.delegate, // Built-in material localizations.
              GlobalWidgetsLocalizations.delegate, // Built-in widget localizations.
              GlobalCupertinoLocalizations.delegate, // Built-in cupertino localizations.
            ],
            // Define the locales supported by the application.
            supportedLocales: const [
              Locale('en', ''), // English, no country code specified.
            ],

            // Dynamically set the application title based on the current locale.
            // Uses the generated AppLocalizations class.
            onGenerateTitle: (BuildContext context) =>
            AppLocalizations.of(context)!.appTitle,

            // --- Theme Setup ---
            // Define the light and dark themes for the application.
            theme: ThemeData(), // Default light theme.
            darkTheme: ThemeData.dark(), // Default dark theme.
            // Set the active theme mode based on the value from SettingsController.
            themeMode: settingsController.themeMode,

            // --- Navigation Setup (Named Routes) ---
            // The onGenerateRoute callback is triggered when Navigator.pushNamed is called.
            // It's responsible for creating the correct screen widget based on the route name.
            onGenerateRoute: (RouteSettings routeSettings) {
              // Return a MaterialPageRoute, which handles the visual transition between screens.
              return MaterialPageRoute<void>(
                settings: routeSettings, // Pass route settings (name, arguments) to the page route.
                builder: (BuildContext context) {
                  // Extract arguments passed during navigation (if any).
                  final args = routeSettings.arguments;

                  // Use a switch statement to determine which screen to build based on the route name.
                  // Route names are constants defined in the Routes class (e.g., Routes.settings).
                  switch (routeSettings.name) {
                    case Routes.settings:
                    // Navigate to the Settings screen, passing the controller.
                      return SettingsView(controller: settingsController);
                    case Routes.signIn:
                    // Navigate to the Sign In screen.
                      return const SignInScreen();
                    case Routes.resultsHub:
                    // Navigate to the Results Hub screen.
                      return const ResultsHubScreen();
                    case Routes.gameSelector:
                    // Navigate to the Game Selector screen.
                      return const GameSelectorScreen();
                    case Routes.forge:
                    // Navigate to The Forge screen.
                    // Arguments ('gameName', 'nextDrawDate') are expected to be passed via routeSettings.arguments
                    // and are handled internally within TheForgeScreen's initState/didChangeDependencies.
                     // return const TheForgeScreen();
                    case Routes.theSmelter:
                    // Navigate to The Smelter screen.
                      return const SmelterScreen();
                    case Routes.verifyResults:
                    // Navigate to the Verify Results screen (purpose might be specific/future).
                      return const VerifyResultsScreen();
                    case Routes.createAccount:
                    // Navigate to the Create Account screen.
                      return const CreateAccountScreen();
                    case Routes.account:
                    // Navigate to the Account screen.
                      return const AccountScreen();
                    case Routes.gameResult:
                    // Navigate to the detailed Game Result screen.
                    // This route expects 'gameName' and 'drawDate' arguments.
                      String gameName = 'Error'; // Default error value.
                      String drawDate = 'Error'; // Default error value.
                      // Safely extract arguments, providing defaults if missing or wrong type.
                      if (args is Map<String, dynamic>) {
                        gameName = args['gameName'] as String? ?? 'Missing Game';
                        drawDate = args['drawDate'] as String? ?? 'Missing Date';
                      } else {
                        // Log an error if arguments are not the expected type.
                        print("Error: Invalid arguments type for ResultsScreen: ${args?.runtimeType}");
                        // Fallback to MainScreen if arguments are invalid.
                        return const MainScreen();
                      }
                      // Return the ResultsScreen, passing the extracted/defaulted arguments.
                      return ResultsScreen(gameName: gameName, drawDate: drawDate);
                    case Routes.main: // The root route ('/').
                    default: // Fallback for any unknown route names.
                    // Navigate to the Main Screen. It has access to AuthState via Provider.
                      return const MainScreen();
                  }
                },
              );
            },
          ),
        );
      },
    );
  }
}