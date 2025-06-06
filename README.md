# Golden Ticket: Forge Your Fortune

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Status](https://img.shields.io/badge/Status-Open%20Beta-green.svg)]()
[![Latest Release](https://img.shields.io/badge/Latest%20Release-v3.0.0--beta.1-blue)](https://play.google.com/store/apps/details?id=org.golden_ticket.golden_ticket) <!-- Replace with your actual Play Store link when available -->

**Download the latest Android Beta from the Google Play Store!**
<!-- Add a direct link to your Play Store listing once it's live -->

## What is Golden Ticket?

Golden Ticket is a free and open-source mobile game designed to change the way you interact with lotteries. It's not just about picking numbers; it's about exploring strategies, testing ideas, and engaging your intuition in a fun, game-like environment **without spending real money.**

Our goal is to provide a **tool for exploration and experimentation**. Golden Ticket allows you to simulate lottery play, test different selection strategies, and engage with concepts like probability and intuition, all **without any financial risk**.

## The Goldsmith's Journey: How It Works

We approach this through a unique, thematic user flow that guides you through the process of crafting and testing your tickets:

1.  **The Game Foundry:** Your journey begins here. Like a goldsmith selecting the finest ore, you first enter the Foundry to choose which lottery game (e.g., Powerball, Mega Millions) you want to work with.

2.  **The Prospector's Path (Planned):** After choosing your game, you can embark on the Prospector's Path. This will be a series of intuition-based mini-games allowing you to find and generate your own unique combinations instead of using the pre-supplied pool.

3.  **The Smelter:** This is the heart of the workshop. Here, a pool of high-quality **"Gold Ingots"** (combinations) is presented. This pool will either be the default, historically optimized set or the ones you personally discovered. Against a time limit, you must select your desired Ingots and place them into your **"Crucible."**

4.  **The Refinery (Planned):** For advanced players, the Refinery will offer an optional step to further tweak or enhance your selected Ingots through another layer of strategy or mini-games before committing them.

5.  **Locking the Crucible (into the Forge Oven):** Before time expires, you must commit to your final selection. This "lock-in" action sends your Crucible to be fired in the Forge Oven.

6.  **The Forge (The Results Screen):** After locking in your Crucible, you are taken here. This screen acts as the waiting room and results area. After the official draw has passed, this is where the final, finished ticket is revealed, showing you whether you've forged a true "Golden Ticket."

## Current Status: Open Beta

This project is currently in **Open Beta**. The core functionality is in place, and the app is stable. We are now focused on gathering feedback and planning the implementation of new features like the Prospector's Path and Refinery mini-games.

## Getting Started (for Developers)

Interested in contributing? Here’s how to get the project running.

1.  **Prerequisites:**
    * Flutter SDK (see `pubspec.yaml` for version)
    * Android Studio or VS Code with the Flutter extension.
    * A Firebase project set up with Firestore and Authentication.

2.  **Clone the Repository:**
    ```bash
    git clone [https://github.com/Jayotis/Golden-Ticket.git](https://github.com/Jayotis/Golden-Ticket.git)
    cd Golden-Ticket
    ```

3.  **Setup Firebase (Android):**
    * Obtain the `google-services.json` file from your Firebase project settings.
    * Place it in the `android/app/` directory.

4.  **Install Dependencies:**
    ```bash
    flutter pub get
    ```

5.  **Run the App:**
    * Connect a device or start an emulator.
    * Run `flutter run` or use the "Run" command in your IDE.
    * **Note:** To create release builds, you will need to set up your own `android/key.properties` file with a signing key. The repository is configured to allow debug builds without it.

## We Need Your Help!

This is an open-source project, and we welcome contributions! We are actively seeking help in the following areas:

* **Flutter Development:** Implementing the Prospector/Refinery mini-games, improving UI/UX, and bug fixing.
* **UI/UX Design:** Creating a more polished and engaging visual experience.
* **Firebase/Backend:** Optimizing database queries and backend integration.
* **Testing:** Writing unit, widget, and integration tests to improve code quality.
* **Documentation:** Improving this README, code comments, and user guides.

## License

This project is licensed under the MIT License - see the `LICENSE` file for details.
