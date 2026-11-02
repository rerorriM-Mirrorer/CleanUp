# CleanUp — beta 2 (Windower 4)

**Development status:** Beta 2 is published on `dev` for in-game testing; `main` remains documentation-only. Live ring use and bag restoration are not yet verified.

A lightweight, inventory-first item-home manager. It reconciles **two rules**: each item's home bag and an optional inventory override. A new install starts **OFF** and uses **Mog Case** as the default home for unassigned items.

**Install:** Extract the `CleanUp` folder to `Windower4/addons/CleanUp/`; then `//lua load CleanUp`. For this beta, **unload/disable MogMover and other automatic inventory movers** before enabling cleanup. They do not yet share an operation lock. This is a test build, not live-verified in FFXI; start with `//cu preview` and one harmless item.

## Commands

```text
//cu                         Toggle automatic cleanup ON/OFF
//cu help                    BattleStations-style chat command list
//cu cleanup                 Toggle automatic cleanup ON/OFF
//cu cleanup on|off          Set automatic cleanup explicitly
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

//cu ech ring                Fuzzy-select and use your Echad Ring
//cu warp ring               Fuzzy-select and use your Warp Ring
//cu use ech ring            Explicit ring-use command
//cu find ring               Preview owned ring name matches/scores
//cu recover                 Restore interrupted ring equipment from saved snapshot
```

The second, **inventory override**, rule is the same for `//cu ... inventory N` and the temporary `//cu get` request. `get` does not add a permanent home or rule: it holds a session-only inventory reserve until `release`, zoning, unloading, or logout. The persisted override is preserved. A saved `inventory` rule with no number protects all copies currently in inventory instead of importing every copy from storage.

With cleanup on, items without a named home go to the dump bag. A named home affects where inventory surplus goes; an inventory quantity says how many to keep at hand. If the item falls below that quantity, CleanUp searches its home and then the other supported bags to replenish it. With cleanup off, no automatic moves happen; `tidy` or `get` may be invoked explicitly. Rules persist in Windower's normal addon `data/settings.xml`; the temporary `get` state does not.

Only **Inventory, Satchel, Sack and Case** are moved between in beta 1. No wardrobes, Safe, Locker or other inaccessible bags are touched; no actual item-use command is issued. The addon does **not** sell, stack or discard items. The beta 2 ring workflow can temporarily equip and use **Echad Ring and Warp Ring only**, then restore your previous ring equipment. This first beta only reconciles between inventory and the supported storage bags; it does not proactively reorganize items already in one storage bag into another.

Help and status are displayed in FFXI chat, using the shared BattleStations-style color convention: gray separators (140), highlighted headings (167), command prefix and arrows (200), command syntax (207), neutral descriptions (0). `//cu help` and unknown commands show help; **bare `//cu` toggles cleanup mode intentionally**. All chat uses mode 0 and Windower `chat` color controls.


## Ring use — experimental in beta 2

`//cu ech ring`, `//cu warp ring`, or `//cu use <fuzzy name>` select an **owned** supported enchanted ring from accessible Inventory, Satchel, Sack, Case, or Wardrobe 1–4. The Superwarp-inspired matcher ignores punctuation and spacing, favors full/word-prefix matches, and rejects weak or close matches instead of guessing. `//cu find <name>` previews candidates without using items. This build only accepts Echad Ring and Warp Ring (future items require their own observed slot/use rules).

If the ring is in Satchel, Sack, or Case, CleanUp retrieves one to inventory; if already in Inventory or an accessible wardrobe it equips in place. It prefers an empty ring slot. Before changing equipment, it records the previous ring slot and source bag; then it waits for **observed equip** and Windower extdata enchantment readiness, issues one `/item "Exact Ring Name" <me>` command, waits for a detectable charge/recast change, and restores the original equipment. If it borrowed from another storage bag, it attempts to return the ring there even with cleanup mode OFF. Warp Ring zoning is handled by continuing the restore step when the character is idle in the destination. Interrupted equipment operations leave a saved recovery record; `//cu recover` retries the restoration and return.

**Live verification is required.** GearSwap and other equipment managers can still race with these operations: leave them unloaded for ring tests. Delays and extdata fields are based on the current Windower API and must be validated against the game's enchantment mechanics. A failed, interrupted or unconfirmed equip/use may leave the ring equipped or in inventory: check `//cu status` and inventory rather than assuming it finished. CleanUp doesn't guarantee warp or enchantment success, because it cannot infer server acknowledgment from the local `/item` command alone. Do not test with other automatic inventory movers active.

`//cu` and `//cu cleanup` intentionally toggle the persisted automatic cleanup setting; `//cu cleanup on|off` and `//cu cleanupmode on|off` are idempotent. **Bare `//cu` may start sending everything unassigned to Case**, so use `//cu help` for help and `//cu preview` before the first activation.

## Safety and current limits

- CleanUp sends **one movement request at a time**, waits for observed source/destination quantity changes and only then sends the next. An unconfirmed request times out after 10 seconds, with that route paused for 60 seconds. This is inventory-observed confirmation, not an FFXI server transaction ID.
- Automatic movement pauses when the character is not idle, not logged in, or when Windower reports an open menu. The menu guard depends on the runtime exposing the flag. Never use this to move items while other automation is active.
- There is no coordination lock with Itemizer, Organizer, SellNPC, MogMover, or GearSwap yet. Ring use currently calls the documented Windower `set_equip` API directly; it does not call a GearSwap user script. **Do not run concurrent automatic movers.** Itemizer manual movements may still race with CleanUp; switch cleanup off first.
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

- **2026-11-02 beta 2:** Bare `//cu` and `//cu cleanup` toggle cleanup, with explicit on/off retained. Superwarp-inspired fuzzy matching for owned Echad/Warp Rings; experimental observed equip/use/restore/source-return cycle, interruption recovery and `//cu find`. Mocked ring and toggle tests pass; no FFXI live verification. `main` unchanged.

- **2026-11-02 beta 1.1:** Adopted shared BattleStations-style colored chat/help formatting, bare/invalid help, and one-shot restart/unload commands. Lua parsing and mocked regression checks passed; live FFXI colors not yet checked.
- **2026-11-01 beta 1:** Initial CleanUp design and isolated implementation; safe defaults, home and inventory rules, Case dump, preview, manual tidy, get/release, transfer confirmation and timeouts, debugging, status, and help. Static syntax check and mocked Lua tests completed; **not yet tested live in FFXI**. Based on ideas from the existing MogMover project, without changing its installed code.
