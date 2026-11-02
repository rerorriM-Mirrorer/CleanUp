# WORKFLOW — CleanUp

Adopted from the current canonical workflow at `rerorriM-Mirrorer/ffxi-NPCmirror` / `main`, reviewed 2026-11-01. Preserve the full canonical guidance in ongoing development and use this file as the CleanUp-specific entry point.

## AGATHOS
Good grows. Good widens the circle of possible benefit. Favor legible, reversible, observable changes.

## DESIGN

- Keep two item-policy layers: **home** and **inventory override**. Cleanup mode only toggles automatic enforcement, not a third rule layer.
- Fresh install must **never automatically dump inventory**. Default dump = Case, cleanup = OFF. Preview is read-only.
- Keep the addon nearly invisible in normal use; BattleStations-inspired chat-only output per the canonical shared addon standard, clear status/help, debug on demand.
- Never silently move items into a fallback bag when the requested destination is full or unavailable.
- No GearSwap requirement, and no authority over equipment sets. Future integrations should yield to gear equipment/retrieval commands.
- Prefer observed inventory confirmation over assumed success based on delay. Never issue multiple concurrent automatic transfers from this addon.
- One instance per client; do not coordinate multibox clients by shared character names. Partial successes are normal and diagnosable.

## DEVELOPMENT

1. Read `AGENTS.md` if present, this WORKFLOW, and `TESTING.md` directly from the active GitHub branch before changing code; also consult the canonical NPCMirror workflow.
2. Record the starting repository, branch, and known-good version. Do not modify trusted `main` until after in-game verification.
3. Review Windower APIs, upstream MogMover, Itemizer, Organizer, and any other involved item movers; do not assume they serialize transactions.
4. Keep coherent changes and documentation together. Include this WORKFLOW and TESTING inside testing ZIP's `CleanUp/` folder.
5. Static-check in a Lua 5.1-aware environment when available; perform mocked tests, then explicit in-game smoke/regression/live testing. Mocked tests do **not** verify real FFXI packet behavior or server acknowledgment.
6. Update TESTING without removing previous evidence. Review original request, commit/push status, changed files, and exact verification before delivery.
7. Maintain `README.md` command docs and cumulative changelog.

## TRANSFER CONTRACT

- Validate source slot, item ID, quantity, source accessibility, destination accessibility and free slots at issuance.
- After `windower.ffxi.move_item`, observe change in **both** source and destination item totals before calling it confirmed. Timeout and back off failures, never assume success from the API returning.
- A zone/logout/unload invalidates pending local state, but cannot retract a request already sent to FFXI.
- The next development milestone is interoperability: a cooperative move lock/lease, GearSwap/Organizer priority, and safer operation-state detection confirmed in game.

## SHARED ADDON CHAT STANDARD (2026-11-02)

This project adopts the BattleStations-inspired output convention from the current NPCMirror canonical `WORKFLOW.md`, **Shared Addon Standards**:

- `require('chat')`, then use `string.color(text, code)` on individual fragments.
- All user-facing output goes to `windower.add_to_chat(0, line)` (not the addon console).
- Separators **140**; headings **167**; `//cu` and `->` arrows **200**; command syntax **207**; descriptive text **0** (neutral white).
- Help must show full `//cu command` examples in stable order, with `<required>` and `[optional]` parameters.
- Bare `//cu` intentionally toggles cleanup mode as of beta 2 (documented primary-action exception); `//cu help` and invalid subcommands show the full help menu; `status`, `help`, `restart`, and `unload` are available.
- Restart/unload emit one clear announcement and dispatch exactly one Windower lifecycle command.

The initial beta 1 condensed copy omitted this specific formatting contract; the beta 1.1 patch adopts it explicitly. Consult the **full** canonical NPCMirror workflow directly on GitHub at the start of future changes; this project-specific document is not a substitute.

## ENCHANTMENT TESTING (beta 2)

- Ring use is an explicit user action, never a side effect of cleanup rules. Supported item names initially: Echad Ring, Warp Ring.
- Match only accessible owned rings, reject ambiguous fuzzy results; do not invent an unobserved state or assume `send_command` means item activation succeeded.
- If temporarily equipping a ring, save its prior equipment slot and originating bag before mutation; restore after observed activation where possible. Keep a recovery path for interrupted operations and zoning.
- Do not claim GearSwap interoperability until tested with a cooperative equip lock/handoff. The first implementation uses native Windower equipment APIs and is intended for tests with other equipment automation unloaded.
