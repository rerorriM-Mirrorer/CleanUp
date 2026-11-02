# TESTING — CleanUp

## Current Development Status — 2026-11-02 (beta 2)

- **Repository / branch:** `rerorriM-Mirrorer/CleanUp` / `dev` beta 2 publication; trusted `main` remains documentation-only pending FFXI acceptance.
- **Source checkpoint:** beta 1.1 on `dev` (CleanUp.lua blob `ecb7914f1e106ad8406fb7f8eebef917c04bf7e9`). No live-confirmed known-good code version. Beta 2 is published to `dev`; final remote HEAD is reported at delivery, not embedded in its own TESTING file.
- **Requested functionality:** Bare `//cu` and `//cu cleanup` toggle, explicit `on/off`; owned-ring fuzzy match; use Echad/Warp Ring via temporary retrieve/equip/activation, restore original ring and return to original bag, recover interruption.
- **Local checks:** Lua 5.4 C-library parser PASS; simulated Windower event/bag/equipment harness covers bare toggle, cleanup aliases, fuzzy `ech ring`/`warp ring`, one item command per ring, and successful return of ring to its original bag, and a simulated Warp Ring zone change. Tests run against mock state; no actual FFXI/Windower action verified.
- **External dependencies:** Windower 4 native `set_equip`, `get_items().equipment`, `extdata.decode` and the game's `/item` command. GearSwap (and its user-script re-equip behavior) not integrated or tested.
- **Live status:** NOT TESTED. Strongest concerns: enchantment activation/cooldown timing, detecting charge use, Warp Ring zoning, restoration after partial failure, gear equipment competition, missing storage capacity, and actual chat coloring.
- **Next:** With other movers/GearSwap unloaded, `//cu help`, `//cu status`, `//cu preview`; use `//cu find ech ring`, `//cu ech ring` then check original ring slot and original bag. Test Warp Ring separately after confirming Echad, including zoning and `//cu recover` if needed. Record exact observed state, logs, and items.

---

## Beta 2 test record — 2026-11-02

- User requested intentional bare-command toggle despite default shared help convention; also `//cu cleanup` and Superwarp-inspired fuzzy item name matching for Echad Ring/Warp Ring, temporary equip/use and returning ring/equipment to original locations.
- No new settings defaults are activated automatically on startup. The toggle is **interactive**, never load-time.
- Match scoring is local to owned supported rings, with confidence/ambiguity rejection. Item home and reserve rules remain separate.
- New `ring_recovery` saved only for an in-flight equipment replacement; not an additional permanent item policy. A ring run suspends ordinary cleanup transfers until finished. No shared operation lock with external addons.
- Mocked tests include a simulated Warp Ring zone change and ambiguity rejection. These are static/simulation, not live acceptance. `tests/mock_test.lua` captures the scenarios; Lua 5.1 runtime compatibility still requires direct verification.

---

## Current Development Status — 2026-11-02 (beta 1.1)

- **Repository / branch:** `rerorriM-Mirrorer/CleanUp` / `main` exists but is empty as checked on 2026-11-02; the test ZIP is a local working artifact, not a published Git commit. MogMover remains unchanged.
- **Change:** BattleStations-inspired chat-only formatting per the canonical NPCMirror workflow: colored separators/headings/`//cu`/arrows/command syntax/descriptions; bare and invalid command help; restart/unload.
- **Starting tested source:** local CleanUp beta 1 package; no known-good live version is recorded.
- **Verification:** Lua 5.4 parser accepted code and test script; mocked Lua execution passed original inventory scenarios plus exact chat-mode and color checks, bare/invalid help, and one-shot lifecycle dispatch. Lua 5.1 compiler and Windower/FFXI live tests not performed.
- **Live status:** Nothing is confirmed live in FFXI yet; do not enable concurrent auto-movers.
- **Next:** Unload competing movers; test `//cu`, `//cu help`, `//cu status`, `//cu preview`, then harmless item moves. Check rendering of in-game colors, especially neutral descriptions and multi-column lines.

---

## Beta 1.1 testing — 2026-11-02

- User observed that beta 1 missed the shared BattleStations-inspired chat formatting convention.
- Updated all CleanUp messages from mode 207 + plain `[CleanUp]` to mode 0 + `require('chat')` and fragment-level `string.color()`.
- Help now uses stable grouped full commands, `140` separators, `167` headers, `200` prefix/arrows, `207` syntax, and neutral `0` descriptions.
- Bare `//cu` and invalid commands show help. Added `//cu restart` and `//cu unload` with one-shot Windower dispatch.
- Static parse and mocked regression passed. No actual in-game test; treat format rendering and transfer logic as unverified live.

---

## Current development status — 2026-11-01

- **Source baseline:** `rerorriM-Mirrorer/MogMover` / `main` (`MogMover.lua`, version 1.0.0) was reviewed. It is not modified in this test package. The canonical `rerorriM-Mirrorer/ffxi-NPCmirror` / `main` workflow and testing guide were also reviewed; MogMover lacks these root documents.
- **Scope:** New separate `CleanUp` addon beta 1, with homes, inventory reserves, default Case dump, automatic/manual reconciliation, preview, temporary get/release, serialized transfer requests and source/destination confirmation.
- **Defaults:** `cleanupmode=false`, `dumpbag=case`, `delay=2`, empty home/override maps.
- **Static check:** The Lua source passed a syntax load through locally available Lua 5.4 C-library parser. Lua 5.1/Windower compatibility **has not been independently compiler-verified**.
- **Mocked execution:** A simulated Windower environment and bag inventory passed checks for default-off, non-mutating preview, home assignment, keeping 2 food in inventory, moving unassigned items to Case, reserve replenishment, temporary get/release, explicit mode-off, busy state suppression, and manually triggered tidy. These are simulated, not FFXI server tests.
- **Live test:** **NOT PERFORMED.** No real-game behavior or conflict safety confirmed.
- **Commits/pushes:** Local test package created; see delivery message for actual remote status. No known-good release tag assigned.

## Priority live test

1. Unload MogMover and other automated item movers; use only cheap test items and free slots. Back up settings before testing.
2. Load `CleanUp` and verify `//cu status` displays OFF and Case; preview must not move anything.
3. Configure a home and a quantity override; preview should list expected transfers.
4. Enable cleanup, observe transfers one by one, and verify source/destination quantities after each.
5. Verify replenishment after consuming/removing an inventory-reserved item; verify `get` and `release`.
6. Check behavior when Case is full, when a bag is inaccessible, when menus/cutscenes/combat are active, during zone change, and after toggling OFF mid-transfer.
7. Confirm that an equipped/locked item is not moved and there is no movement loop or unsolicited fallback destination.
8. Retest across 2–4 clients independently, checking that per-client saved rules do not interfere.

## Open questions / outstanding work

- Does the Windower 4 runtime reliably expose `info.menu_open` and does `player.status==0` cover all safe contexts? Probe live.
- Do `get_items(bag_id)` item counts and `move_item` update timing suffice to confirm moves under high packet traffic? Verify live logs.
- Bag slot capacity uses strict free-slot checks, not stack-space detection. Improve after live validation.
- Itemizer, MogMover, Organizer, SellNPC and later GearSwap are **not** coordinated. Build an explicit shared transfer lease and/or mover exclusivity checks before recommending concurrent operation.
- Policy currently reorganizes items through inventory only, not storage-to-storage; no automatic item-use function exists.
- Verify actual BattleStations-style chat colors and spacing in FFXI, and consider diagnostics of rejected moves and per-character logs.

## Cumulative changelog

- **2026-11-01 beta 1:** New isolated CleanUp addon and initial documentation. Simulation succeeded; live testing pending.

- **2026-11-02 beta 1.1:** Corrected shared chat/help conventions and added lifecycle commands; local ZIP only, static/mock verified, not live tested.
