# Farm Counter

**How much gold did that farm session actually make?** Farm Counter counts everything you gather with your professions and shows what it is worth on the auction house right now - per item, per category and for the whole session, including gold per hour.

Fishing, herbalism, mining, skinning, prospecting, disenchanting - just start farming. The window appears with your first loot.

## Features

- **Counts all profession loot automatically**
  - Fish, herbs, ore & stone, leather & hides, cloth
  - Gems and pearls from prospecting
  - Enchanting materials from disenchanting (dust, essences, shards)
  - Elemental materials, pigments, parts & salvage and other reagents
  - Optionally everything from fishing casts, including junk and treasures
- **Only real loot is counted** - no bag moves, auction house purchases, mail or crafted items.
- **Auction house values via TradeSkillMaster**
  - Value per item, total per category and total for the session
  - Gold per hour for the current session
  - Prices are looked up live when the window is drawn, so values always reflect the current market
  - Choose your price source: Market Value, Minimum Buyout, Region Market Average, ... or any TSM custom price
- **Sessions**
  - Start and stop farming sessions; they survive a `/reload`
  - The last 5 sessions are kept and can be opened from a small dropdown, like the segment selector of a damage meter
  - A global history of everything you have ever farmed
- **Reagent quality** is shown next to the item name
- **Sound alert** for rare and epic loot (the sound for rare/blue items can be turned off separately)
- **Optional auto hide** after a few minutes without loot - the window comes back with the next counted loot
- **Options page** under Game Menu > Options > AddOns > Farm Counter
- Small, movable window with drop chance, count and value columns

## Requirements

- World of Warcraft Retail (Midnight)
- [TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master) is **optional**. Without it everything is still counted; values are shown as `--`. For up-to-date prices, keep your AuctionDB data current with the TSM Desktop Application.

## Commands

All commands start with `/farmcounter` (short: `/farm`).

| Command | Description |
|---|---|
| `/farm` | Shows all commands |
| `/farm show` / `hide` | Shows or hides the window |
| `/farm start` / `stop` | Starts or ends a farming session |
| `/farm reset` | Starts a new session (the old one stays in the dropdown) |
| `/farm session` / `history` | Switches between session and global history |
| `/farm view [1-5]` | Lists or opens previous sessions |
| `/farm price [source]` | Shows or sets the TSM price source, e.g. `DBMinBuyout` |
| `/farm cat [key] [on\|off]` | Lists or toggles counted categories |
| `/farm sound [on\|off]` | Sound alerts on/off |
| `/farm sound blue [on\|off]` | Sound for rare (blue) items on/off |
| `/farm options` | Opens the options |

## Good to know

- Sessions without `/farm start` automatically begin anew when you loot in a different zone (can be turned off in the options).
- During boss encounters in instances, WoW does not let addons read loot messages, so loot there is not counted.

## Feedback

Found a bug or have an idea? Please open an issue on GitHub or leave a comment here.
