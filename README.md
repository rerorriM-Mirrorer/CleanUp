# CleanUp — beta 1.1 (Windower 4)

**Development status:** This unverified beta lives on the `dev` branch. `main` remains documentation-only until in-game verification.

A lightweight, inventory-first item-home manager. It reconciles **two rules**: each item's home bag and an optional inventory override. A new install starts **OFF** and uses **Mog Case** as the default home for unassigned items.

**Install:** Extract the `CleanUp` folder to `Windower4/addons/CleanUp/`; then `//lua load CleanUp`. For this beta, **unload/disable MogMover and other automatic inventory movers** before enabling cleanup. They do not yet share an operation lock. This is a test build, not live-verified in FFXI; start with `//cu preview` and one harmless item.

## Commands

```text
//cu                         Help (BattleStations-style chat list)
//cu help                    Chat-only colored command list
//cu status                  Status
//cu list                    Item home and inventory override rules
//cu preview                 Show intended transfers; never moves anything
//cu dump case               Default bag for unassigned items (case, sack, satchel)
//cu cleanupmode on          Reconcile inventory automatically
//cu cleanupmode off         Stop issuing automatic transfers
//cu off                     Shortcut for cleanupmode off
//cu tidy                    Run one complete cleanup manually, even if mode is off
//cu delay 2                 Delay between issued transfers, 1–30 seconds
//cu debug on|off            Diagnostic transfer requests
//cu restart                 Restart the addon (one Windower command)
//cu unload                  Unload the addon (one Windower command)

//cu "Sole Sushi" satchel      Its home is Satchel
//cu "Sole Sushi" inventory 2  Reserve 2 in inventory and replenish from storage
//cu "Sole Sushi" inventory    Keep any copies currently in inventory (no auto-pull)
//cu "Copper Ore" sack         Its home is Sack
//cu clear "Sole Sushi" home       Remove only its named home
//cu clear "Sole Sushi" inventory  Remove its inventory override
//cu clear "Sole Sushi" all        Remove both rules

//cu get "Sole Sushi" 2       Temporarily reserve/retrieve 2 in inventory
//cu release "Sole Sushi"     Remove the session-only reserve
```

The second, **inventory override**, rule is the same for `//cu ... inventory N` and the temporary `//cu get` request. `get` does not add a permanent home or rule: it holds a session-only inventory reserve until `release`, zoning, unloading, or logout. The persisted override is preserved. A saved `inventory` rule with no number protects all copies currently in inventory instead of importing every copy from storage.

With cleanup on, items without a named home go to the dump bag. A named home affects where inventory surplus goes; an inventory quantity says how many to keep at hand. If the item falls below that quantity, CleanUp searches its home and then the other supported bags to replenish it. With cleanup off, no automatic moves happen; `tidy` or `get` may be invoked explicitly. Rules persist in Windower's normal addon `data/settings.xml`; the temporary `get` state does not.

Only **Inventory, Satchel, Sack and Case** are moved between in beta 1. No wardrobes, Safe, Locker or other inaccessible bags are touched; no actual item-use command is issued. The addon does **not** sell, equip, stack or discard items. This first beta only reconciles between inventory and the supported storage bags; it does not proactively reorganize items already in one storage bag into another.

Help and status are displayed in FFXI chat, using the shared BattleStations-style color convention: gray separators (140), highlighted headings (167), command prefix and arrows (200), command syntax (207), neutral descriptions (0). `//cu` alone and unknown commands show help. All chat uses mode 0 and Windower `chat` color controls.

## Safety and current limits

- CleanUp sends **one movement request at a time**, waits for observed source/destination quantity changes and only then sends the next. An unconfirmed request times out after 10 seconds, with that route paused for 60 seconds. This is inventory-observed confirmation, not an FFXI server transaction ID.
- Automatic movement pauses when the character is not idle, not logged in, or when Windower reports an open menu. The menu guard depends on the runtime exposing the flag. Never use this to move items while other automation is active.
- There is no coordination lock with Itemizer, Organizer, SellNPC, MogMover, or GearSwap yet. **Do not run concurrent automatic movers.** Itemizer manual movements may still race with CleanUp; switch cleanup off first.
- CleanUp requires a destination free slot according to the bag's reported count, even when a partial stack could have room. This conservative rule may skip otherwise possible transfers.
- If the dump bag is full/unavailable, items remain where they are; CleanUp won't silently choose another destination. Locked or equipped item stacks (status not zero) are not transferred.
- `//cu cleanupmode off` prevents **new** moves. A transfer already sent to the game may still finish. Zone/logout/unload cancels local pending state, not an already issued FFXI command.
- Fresh defaults are `cleanupmode = false`, `dumpbag = case`, `delay = 2`. Preview before first activation; otherwise **everything eligible and not protected** in inventory will go to Case.

## First in-game test

1. Unload MogMover and any other automatic inventory mover. Leave GearSwap unloaded for this first test. Keep unimportant test items in inventory and free space in Case/Satchel.
2. `//lua load CleanUp`, `//cu status`, `//cu preview` — nothing should move.
3. `//cu "Sole Sushi" satchel` and `//cu "Sole Sushi" inventory 2` (substitute a cheap known item) then `//cu preview`.
4. `//cu cleanupmode on`. Observe individual moves and final quantities, ensuring only intended items moved.
5. Consume/move one reserved item and verify replenishment from the named home.
6. `//cu get "Copper Ore" 1`, then `//cu release "Copper Ore"`; verify temporary pickup and return.
7. `//cu cleanupmode off`; confirm subsequent item drops are not automatically stored.
8. Report the character and Windower log with any unexpected behavior, especially if inventory quantities differ from the preview.

## Changelog

- **2026-11-02 beta 1.1:** Adopted shared BattleStations-style colored chat/help formatting, bare/invalid help, and one-shot restart/unload commands. Lua parsing and mocked regression checks passed; live FFXI colors not yet checked.
- **2026-11-01 beta 1:** Initial CleanUp design and isolated implementation; safe defaults, home and inventory rules, Case dump, preview, manual tidy, get/release, transfer confirmation and timeouts, debugging, status, and help. Static syntax check and mocked Lua tests completed; **not yet tested live in FFXI**. Based on ideas from the existing MogMover project, without changing its installed code.
