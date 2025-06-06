import 'package:flutter/material.dart';
// Import Provider for accessing shared state like AuthState.
import 'package:provider/provider.dart';
// Import the authentication state management class.
import 'auth/auth_state.dart';
// Import named route constants for navigation.
import 'routes.dart';

/// A StatelessWidget that displays information about the user's account
/// and provides a sign-out option.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  // Route name used for navigation to this screen.
  static const routeName = '/account';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account'), // Title for the screen.
      ),
      // Center the content vertically and horizontally.
      body: Center(
        // Consumer widget listens to changes in AuthState.
        // When AuthState calls notifyListeners(), the builder function rebuilds
        // the part of the UI that depends on AuthState.
        child: Consumer<AuthState>(
          // The builder function receives the current context, the AuthState instance,
          // and an optional child widget (not used here).
          builder: (context, authState, child) {
            // Display account details in a Column.
            return Column(
              mainAxisAlignment: MainAxisAlignment.center, // Center column content vertically.
              children: [
                // Display the username (retrieved via the getUsername helper method).
                // TODO: Implement proper username retrieval in getUsername.
                Text('Username: ${getUsername(authState)}'),
                // Display the membership level from AuthState.
                Text('Membership Level: ${authState.membershipLevel}'),
                // Display the account status from AuthState.
                Text('Account Status: ${authState.accountStatus}'),
                // Add vertical spacing.
                const SizedBox(height: 20),
                // Sign Out button.
                ElevatedButton(
                  onPressed: () {
                    // Call the signOut method on the AuthState instance.
                    // This clears the auth state and notifies listeners.
                    authState.signOut();
                    // Navigate back to the main screen (usually '/') after signing out.
                    // pushNamedAndRemoveUntil removes all routes below the new route,
                    // preventing the user from navigating back to the account screen
                    // or other authenticated screens using the back button.
                    Navigator.pushNamedAndRemoveUntil(
                      context,
                      Routes.main, // Navigate to the main route.
                          (route) => false, // Predicate always returns false to remove all previous routes.
                    );
                  },
                  child: const Text('Sign Out'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Helper method to get a displayable username.
  ///
  /// NOTE: This currently returns a placeholder "User".
  /// TODO: Implement actual username retrieval. This might involve:
  ///   - Adding a username field to AuthState, populated during sign-in.
  ///   - Fetching the username from SharedPreferences if stored there separately.
  ///   - Making an API call to get user details (less ideal for just username).
  String getUsername(AuthState authState) {
    // Check if the user is signed in according to AuthState.
    if (authState.isSignedIn) {
      // Placeholder: Returns a generic username. Replace with actual implementation.
      return "User";
    } else {
      // Return "Not Signed In" if the user is not authenticated.
      return "Not Signed In";
    }
  }
}