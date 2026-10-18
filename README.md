# Farm Counter - v1.0.0

A lightweight addon that automatically tracks your fishing and profession loot (herbs, ore, leather, cloth, gems, enchanting materials, ...), shows drop rates and the current auction house value (via TradeSkillMaster) in a clean, movable window.

Compatible with **WoW: Midnight** (Patch **12.1.5**).

## Features

- **Automatic Tracking:** Starts tracking the moment you loot fish or profession materials. No extra clicks needed.
- **Session & History Modes:**
  - **Session Mode:** Tracks your loot of the current session. Without `/farmcounter start`, the session automatically resets when you loot in a new zone.
  - **Previous Sessions:** The last 5 sessions are kept and can be opened from the small dropdown in the top left corner of the window (like the segment selector of a damage meter).
  - **History Mode:** Shows a combined, **global history** of every item you have ever looted with the addon, across all zones.
- **Rare Loot Sound Alert:** Plays an audible alert when you loot a **Rare (blue)** or **Epic (purple)** quality item.
- **Sound Toggle:** Sound alerts can be turned on/off, and the sound for rare (blue) items can be muted separately (saved between sessions).
- **Options Page:** Game Menu > Options > AddOns > Farm Counter, or `/farmcounter options`.
- **Manual Session Reset:** You can reset the current session at any time.
- **Clean & Movable UI:** Simple frame with a tooltip-style backdrop that you can drag around the screen.
- **Persistent Window State:** If you hide the window, it stays hidden until you explicitly show it again (data still tracks in the background).
- **Auto Hide (optional):** Hides the window after a configurable time without counted loot (default 2 minutes, off by default) and shows it again as soon as you loot something that counts.
- **Simple Slash Commands:** Easy commands for controlling the addon.

## How to Use

The addon window will automatically appear when you loot your first item. You can move the window by clicking and dragging the title bar. Click the dropdown in the top left corner to switch between the current session, the last 5 sessions and the history.

### Slash Commands

All commands start with `/farmcounter` (alias: `/farm`).

- `/farmcounter` (or `/farmcounter help`)
  - Shows help.

- `/farmcounter show`
  - Shows the addon window if it's hidden.

- `/farmcounter session`
  - Switches the display to **Session Mode**.

- `/farmcounter history`
  - Switches the display to **History Mode** (global history).

- `/farmcounter reset`
  - Resets the current **Session** data (does not affect global history).

- `/farmcounter view [current|history|1-5]`
  - Without argument lists the previous sessions; with argument shows one of them (same as the dropdown).

- `/farmcounter sound` (or `/farmcounter sound on` / `/farmcounter sound off`)
  - Toggles (or explicitly sets) the **Rare Loot Sound Alert**.

- `/farmcounter sound blue [on|off]`
  - Turns the sound for rare (blue) items on or off; epic items always play a sound while alerts are on.

- `/farmcounter options`
  - Opens the options page.

- `/farmcounter hide` or `/farmcounter exit`
  - Hides the addon window. Your data will continue to be tracked in the background.

- `/farmcounter start` / `/farmcounter stop`
  - Starts a farming session (no zone auto-reset, survives `/reload`) / ends it. History keeps counting after stop.

- `/farmcounter price [source|default]`
  - Shows or sets the TSM price source, e.g. `DBMarket` (default), `DBMinBuyout`, `DBRegionMarketAvg` or any TSM custom price string.

- `/farmcounter cat [key] [on|off]`
  - Lists or toggles the counted categories (`fish`, `cooking`, `herb`, `ore`, `leather`, `cloth`, `gem`, `enchanting`, `elemental`, `inscription`, `parts`, `reagent`, `fishing`).

- `/farmcounter fishing [on|off]`
  - Count everything from a fishing cast, including junk (default on).

- `/farmcounter zonereset [on|off]`
  - Auto sessions (without `/farmcounter start`) reset when you loot in a new zone (default on).

## Changelog for v1.0.0

- First release.
- Counts fish and profession loot: herbs, ore, leather, cloth, gems/pearls (prospecting), enchanting materials (disenchanting), elemental, pigments, parts/salvage and other reagents. Categories come from the item class/subclass.
- Only items you actually loot are counted (loot chat messages) - no bag moves, purchases, mail or crafting.
- Auction house values via TradeSkillMaster (`TSM_API`), price source configurable. Value per item, per category and session total plus gold/hour. Prices are looked up when the window is drawn, not frozen at loot time. Items without a price show `--`.
- Session start/stop, the last 5 sessions in a small dropdown, global history.
- Close button in the top right corner (same as `/farmcounter hide`).
- Options page, own addon icon and "Professions" category in the AddOns list.
- TradeSkillMaster is an optional dependency; without it everything is counted, values show `--`.

## Installation

1. Download the latest version of the addon.
2. Unzip the downloaded file.
3. Inside, you will find a folder named `FarmCounter`.
4. Copy the `FarmCounter` folder into your WoW AddOns directory:

   `World of Warcraft\_retail_\Interface\AddOns`

5. Restart World of Warcraft (a new addon folder is not picked up by `/reload`).
