import 'package:flutter/material.dart';

// Define the list of available game events (display names) that the user can select from.
// This is currently hardcoded. In a future version, this might be loaded dynamically.
// NOTE: Only 'Event 6/49' is currently listed.
const List<String> gameEvents = <String>['Event 6/49'];

/// A StatefulWidget that presents a screen for selecting a game event.
/// Users choose an event from a dropdown list.
class GameSelectorScreen extends StatefulWidget {
  const GameSelectorScreen({super.key});

  // Route name used for navigation to this screen.
  static const routeName = '/game-selector';

  @override
  State<GameSelectorScreen> createState() => _GameSelectorScreenState();
}

/// The State class for the GameSelectorScreen widget.
/// Manages the currently selected event.
class _GameSelectorScreenState extends State<GameSelectorScreen> {
  // State variable to hold the string value of the currently selected game event.
  // It's initialized to null, meaning no selection has been made initially.
  String? selectedEvent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Title for the screen.
        title: const Text('Select Event'),
      ),
      // Center the main content.
      body: Center(
        // Add padding around the content.
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center, // Center the column vertically.
            children: [
              // Instructional text for the user.
              const Text(
                'Choose the event you want to add:',
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30), // Vertical spacing.

              // --- Dropdown Button Section ---
              // Wrap the DropdownButton in a Container for custom styling (border, padding).
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400, width: 1), // Add a border.
                  borderRadius: BorderRadius.circular(8.0), // Rounded corners.
                  // Optional background color:
                  // color: Colors.grey[50],
                ),
                // Hide the default underline of the DropdownButton for a cleaner look.
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    // The currently selected value in the dropdown. Binds to the state variable.
                    value: selectedEvent,
                    // Make the dropdown button expand to fill the available width.
                    isExpanded: true,
                    // Text displayed when no item is selected (value is null).
                    hint: const Text("Select a game event..."),
                    // Style the dropdown icon.
                    icon: const Icon(Icons.arrow_drop_down, color: Colors.deepPurple),
                    // Shadow effect for the dropdown menu.
                    elevation: 16,
                    // Style for the text items within the dropdown menu.
                    style: const TextStyle(color: Colors.deepPurple, fontSize: 16),
                    // Callback function executed when the user selects a new item.
                    onChanged: (String? newValue) {
                      // Update the state variable with the newly selected value.
                      // setState triggers a rebuild to reflect the change in the UI.
                      setState(() {
                        selectedEvent = newValue;
                      });
                      // Optional: Show a temporary message confirming the selection.
                      // ScaffoldMessenger.of(context).showSnackBar(
                      //   SnackBar(content: Text('Selected event: $newValue')),
                      // );
                    },
                    // Generate the list of dropdown menu items from the global `gameEvents` list.
                    items: gameEvents.map<DropdownMenuItem<String>>((String value) {
                      // Create a DropdownMenuItem for each string in the gameEvents list.
                      return DropdownMenuItem<String>(
                        value: value, // The value that will be assigned to `selectedEvent` when chosen.
                        child: Text(value), // The text displayed for this item in the dropdown.
                      );
                    }).toList(), // Convert the mapped iterable to a List.
                  ),
                ),
              ),
              // --- End Dropdown Button Section ---

              const SizedBox(height: 40), // More vertical spacing.

              // --- Confirmation Button Section ---
              ElevatedButton(
                // Apply styling, ensuring a minimum button size.
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(200, 45),
                  // Foreground/background colors are handled automatically based on enabled state.
                ),
                // The `onPressed` callback is set to null if `selectedEvent` is null,
                // which automatically disables the button.
                onPressed: selectedEvent == null ? null : () {
                  // When the button is pressed (and enabled):
                  // Pop the current screen off the navigation stack and return the
                  // `selectedEvent` string as the result to the previous screen
                  // (the one that called Navigator.pushNamed for this screen).
                  Navigator.pop(context, selectedEvent);
                },
                child: const Text('Confirm Selection'),
              )
              // --- End Confirmation Button Section ---
            ],
          ),
        ),
      ),
    );
  }
}