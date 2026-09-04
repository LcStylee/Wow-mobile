# Touch UI coverage matrix

The definitive map of **every interactive system in Classic WoW** against what each
addon variant does with it — grounded in the module sources under
[`addon/WowMobile/`](../addon/WowMobile/) (Classic Era 1.15, Interface `11507`) and
[`addon/WowMobile_Vanilla/`](../addon/WowMobile_Vanilla/) (vanilla 1.12, Interface
`11200`, Lua 5.0). File names in the tables refer to the module that owns the row;
where the two ports differ, the notes say how.

## Status legend

| Status | Meaning |
|---|---|
| **Rebuilt** (rebuilt for touch) | The default frame is suppressed — banished with its events unregistered, or its load-on-demand Blizzard addon is kept from ever loading — and the addon renders its own thumb-sized surface, driving the flow purely through the official APIs. |
| **Boosted** (boosted default frame) | Blizzard's own frame keeps driving the flow; the addon rescales it toward touch size, re-homes it into the world square or deck, and/or pads hit rects. Logic is untouched. |
| **Default** (default UI) | Untouched Blizzard behavior at mouse scale. |

## The touch interaction model

Every surface below assumes the streaming client's gesture mapping
(ARCHITECTURE §5): the phone injects real mouse/keyboard input, one human touch →
one input.

- **Tap = left click.** Every injected tap is preceded by a pointer move, so
  `OnEnter` fires like a real mouse — tooltips work, and the addon always anchors
  them **above** the touched element, out from under the finger (`Core.lua`).
- **Long-press = right click.** The addon-wide "secondary action" convention:
  long-press picks items/spells/actions up (MoveMode), opens the unit popup menus
  (`togglemenu` / the 1.12 dropdowns, scaled to 1.6x for touch), toggles pet
  autocast, and on the Vanilla port's packed bottom row opens the Social/Raid
  panels (labels advertise both actions).
- **MoveMode — the drag & drop model** (`MoveMode.lua`, both ports): long-press on
  a bag cell, equipped slot, spellbook entry or action button lifts the payload
  onto the **real Blizzard cursor** and shows a **carry bar** above the deck
  (icon + name + a big Cancel). Valid drop targets highlight green; a **tap**
  places/swaps via the correct API for the pair (container pickup, equip,
  `PlaceAction`, the economy sheets' `Click*` slot calls). Long-pressing a
  **stack** first opens the **"Take how many?" split stepper** (−/+/Max/All/Take →
  `SplitContainerItem`). Cursor payloads picked up by Blizzard-side code are
  *adopted* into the carry bar so there is always a visible Cancel.
  - *Era:* the cursor is reconciled against `GetCursorInfo()`; all item moves are
    out-of-combat by rule — in combat a notice shows and nothing is queued;
    entering combat cancels the carry (an action-origin carry is restored to its
    home bar slot once combat ends, never silently discarded).
  - *Vanilla:* 1.12 has no combat lockdown (moves work any time) and no
    `GetCursorInfo` — item payloads reconcile via `CursorHasItem()` on a coarse
    tick, spell/action payloads are tracked on trust (documented limitation in
    the module header).
- **Steppers instead of typing for numbers.** Money and quantities are entered by
  tap steppers (hold-to-repeat is impossible when long-press means right-click):
  the Era `SheetKit` money stepper adds an x1→x10→x100 step-multiplier button;
  the Vanilla stepper steps 1 per tap and 10 per long-press.
- **Text fields use the phone keyboard.** Tapping an edit box (search, mail
  recipient/subject, add-friend) focuses it; the client's edge-rail keyboard
  (**Aa**) then injects the submission as real keystrokes **bracketed by two
  Enter taps** — the protocol the rescued chat edit box reads natively as
  "open the box / send the line" (`client/js/keyboard.js`). The addon's edit
  boxes speak the same protocol (`SheetKit.CreateTextField` on Era,
  `WM.CreateEditBox` on Vanilla): the opening Enter is consumed while focus is
  held (it only selects the field's old text so the new characters replace
  it), the typed characters land in the focused box, and the closing Enter
  commits and drops focus.
- **Confirm gates before spending or destroying.** Bid/buyout, cancel auction,
  buy bank/stable slot, pay COD, delete/return mail, abandon quest, remove
  friend/guild member all take a second confirming tap (Era: inline confirm rows;
  Vanilla: a full-sheet confirm overlay) so a stray thumb never costs money.
- **One interaction surface at a time.** Deck panels, NPC/economy sheets and the
  world map coordinate through the deck's exclusive system (opening one dismisses
  the others *and* walks away from the NPC cleanly); only the transient loot
  sheet floats above whatever is open, and it leaves the action bars tappable for
  mid-combat looting.
- **Pinch = mouse wheel** (scrollers, minimap zoom), and every scrolling surface
  also has big Up/Down page buttons.
- **Touch floor:** interactive targets are ≥90 px of the 1080-wide stream
  (ARCHITECTURE §4); layout budgets in the module headers keep every surface
  clear of the client joystick's capture zone (bottom-left of the world square).

## NPC interactions

| System | Era | Vanilla | Where / notes |
|---|---|---|---|
| Gossip dialogue | Rebuilt | Rebuilt | `BottomSheet.lua` — full-width deck sheet; options/quests as ~100 px rows. Era via `C_GossipInfo`/legacy wrappers (`Compat.lua`); Vanilla via the 1.12 flat multi-returns. |
| Quest giver (greeting, detail, progress, complete, reward choice) | Rebuilt | Rebuilt | `BottomSheet.lua` — Accept/Decline/Continue/Complete buttons, reward-choice grid with selected highlight, required-items grid, escort-quest `QUEST_ACCEPT_CONFIRM` sheet with the default 60 s timeout. |
| Merchant (buy / sell / buyback / repair) | Rebuilt | Rebuilt | `BottomSheet.lua` — Buy/Sell/Buyback tabs, repair-all button, affordability tinting; sell tab lists the bags, tap to sell (`UseContainerItem` at a merchant). |
| Class / profession trainer | Rebuilt | Rebuilt | `BottomSheet.lua` — tap to learn, cost + availability coloring; already-known services are filtered out in both ports. The LoD `Blizzard_TrainerUI` never loads (`TRAINER_SHOW` dropped from UIParent). |
| Flight master (taxi map) | Boosted | Boosted | `Blizzard.lua` — TaxiFrame fitted into the world square (capped ~1.75x); taxi node hit rects padded to ~100 px on `TAXIMAP_OPENED`. |
| Banker | Rebuilt | Rebuilt | `Bank.lua` — see Economy below. |
| Auctioneer | Rebuilt | Rebuilt | `AuctionHouse.lua` — see Economy below. |
| Mailbox | Rebuilt | Rebuilt | `Mail.lua` — see Economy below. |
| Stable master (hunter) | Rebuilt | Rebuilt | `Stable.lua` — current pet + stable slots as big cells; **tap-tap** swap (`PickupStablePet` + `ClickStablePet`), buy-slot behind a confirm; stranded pet cursors cleared defensively. |
| Readable objects, books, plaques, letters | Rebuilt | Rebuilt | `Reader.lua` — deck sheet with 34 px text and big Prev/Next page buttons over the ItemText API. Era renders HTML book markup through a themed `SimpleHTML` widget; Vanilla renders the plain 1.12 page text. |
| Guild/arena petition signing | Boosted | Boosted | `Blizzard.lua` — PetitionFrame fitted to the square, buttons hit-rect padded (Era). |
| Guild registrar (charter purchase) | Boosted | Boosted | `Blizzard.lua` — `GuildRegistrarFrame` fitted to the square with Purchase/Cancel/Goodbye hit-rect padded in both ports; another default-anchored UIPanel that would otherwise open at the window's LEFT edge, outside the landscape band crop. |
| Tabard designer | Boosted | Boosted | `Blizzard.lua` — fitted; the tiny arrow cyclers get padded hit rects (Vanilla also *shrinks* them vertically so overlapping rows hit-test deterministically). |
| Battlemaster / BG queueing | Boosted | Default | Era: `BattlefieldFrame` fitted to the square with Join/Group Join/Cancel hit-rect padded (`Blizzard.lua`) — as a default-anchored UIPanel it would open at the window's LEFT edge, outside the landscape band crop, i.e. invisible on the phone. Vanilla: deliberately untouched, the only NPC flow left at mouse scale. The BG **scoreboard** (`WorldStateScoreFrame`) is Boosted in both. |

## Character panels

| System | Era | Vanilla | Where / notes |
|---|---|---|---|
| Character sheet — gear + stats | Rebuilt | Rebuilt | `CharacterPanel.lua` Gear tab — 4x5 equipped grid with per-slot durability bars, stat column, tooltips. Long-press unequips onto the cursor; carried equippables highlight and drop here (MoveMode). |
| Reputation | Rebuilt | Rebuilt | `CharacterPanel.lua` Rep tab — collapsible faction headers, standing-colored progress bars; tap toggles the **watched** faction in both ports (the watched-faction machinery is genuine 1.12 — line-level FrameXML sources in the Vanilla module), feeding `XPBar.lua`'s rep bar. |
| Skills | Rebuilt | Rebuilt | `CharacterPanel.lua` Skills tab — collapsible headers, rank/max bars. |
| Honor / PvP rank | Rebuilt | Rebuilt | `CharacterPanel.lua` Honor tab — rank + progress bar, session/yesterday/week/lifetime stats; every row feature-guarded. |
| Spellbook | Rebuilt | Rebuilt | `Spellbook.lua` — school tabs, 3-column grid, tap = cast the exact rank (Era: rank-qualified secure `spell`; Vanilla: `CastSpell(bookSlot)`); passives dimmed/tooltip-only; long-press lifts a spell for bar placement. |
| Talents | Boosted | Boosted | `Talents.lua` — Blizzard_TalentUI reflowed into the world square (~2.1x, ~67 px talent icons) with a big X; rank buttons/learn confirms stay Blizzard's. |
| Quest log | Rebuilt | Rebuilt | `QuestLog.lua` — zone headers, difficulty-colored rows, detail view with objectives, Track toggle, two-tap Abandon. Vanilla re-finds quests by {header, title, level} (no questIDs on 1.12). |
| On-screen quest tracker | Boosted | Boosted | `QuestLog.lua` — Blizzard's QuestWatchFrame re-homed into the world square's clear lane. |
| Inspect another player | Rebuilt | Rebuilt | `Inspect.lua` — gear grid with server-backed tooltips, opened from the (boosted) unit menu's own Inspect entry. Era gates on `INSPECT_READY` for user-initiated requests only; Vanilla (no such event) repaints on a delay ladder and says so on screen. Talent/honor inspect views are deliberately out of scope. |
| Bags | Rebuilt | Rebuilt | `Bags.lua` — deck grid panel of every bag slot; tap = use/equip (sells at a merchant), long-press = MoveMode pickup with stack stepper; both ports reroute the client rail's `B` key (the bag toggles) into the deck panel. Era: one bags button + free-slot count and secure item cells; Vanilla: backpack+4 bag buttons with free counts. |
| Macro editor | Boosted | Boosted | `Blizzard.lua` — LoD MacroFrame fitted to the square on load; keyboard-centric by nature. |
| Key bindings | Boosted | Boosted | `Blizzard.lua` — LoD KeyBindingFrame fitted likewise. |
| Game options | Boosted | Boosted | `Blizzard.lua` — Era `SettingsPanel`; Vanilla `OptionsFrame`/`SoundOptionsFrame`/`UIOptionsFrame`, all square-fitted. |
| Addon's own touch settings | Rebuilt | Rebuilt | `Settings.lua` + `Config.lua` — `/wm` and the Config panel: viewport-height and UI-scale steppers, reset, reload. |

## Combat surfaces

| System | Era | Vanilla | Where / notes |
|---|---|---|---|
| Main action bar (slots 1–12, paged) | Rebuilt | Rebuilt | `ActionBars.lua` — 2x6 grid of 140 px secure buttons (Era) with a `SecureHandlerStateTemplate` page driver covering stances/bonus bars **and possession** (`[possessbar] 11`); Vanilla pages in Lua with the exact `ActionButton_GetPagedID` arithmetic (no lockdown on 1.12). Cooldown swipes + remaining text, counts, macro names, usability/range tinting. |
| Second bar (slots 61–72) | Rebuilt | Rebuilt | `ActionBars.lua` — one 84 px row. |
| Quick rail (slots 49–54) | Rebuilt | Rebuilt | `QuickBar.lua` — 6 semi-transparent buttons on the square's right edge; hides tail slots on reduced viewports so nothing overhangs the deck. |
| Stance / shapeshift bar | Rebuilt | Rebuilt | `ActionBars.lua` — left-edge column, built only for classes with forms. |
| Pet action bar + pet frame | Rebuilt | Rebuilt | `Pet.lua` — 2x5 action block on the square's left edge (tap = action, long-press = autocast toggle, green autocast chip) + pet status strip (name, happiness dot, health; tap = target, long-press = pet menu). |
| Player / target unit frames | Rebuilt | Rebuilt | `UnitFrames.lua` — big class-colored health/power bars; tap = target, long-press = unit popup menu; target buff/debuff strip (debuffs first) and combo points. |
| Unit popup menus | Boosted | Boosted | `UnitFrames.lua` — Blizzard menus scaled 1.6x for touch (Era hooks both the modern `Menu` manager and legacy dropdowns; Vanilla also fixes the cursor-anchor math the scale breaks). |
| Cast bar | Rebuilt | Rebuilt | `CastBar.lua` — fill/drain bar with 0.1 s time text and interrupt/fail flash. Vanilla is icon-less (no 1.12 API exposes the cast's texture). |
| Player buffs / debuffs | Rebuilt | Rebuilt | `Auras.lua` — big aura rows atop the square with duration text and "+N" overflow badges; **tap a buff to cancel it**. Era: secure `cancelaura` overlay hidden in combat by a state driver (no stale-index taps); Vanilla: cancel by stored buff handle, available any time (no 1.12 restriction). |
| XP / watched-rep bar | Rebuilt | Rebuilt | `XPBar.lua` — XP with rested coloring + the watched-reputation bar in both ports (`GetWatchedFactionInfo` is genuine 1.12; it stands in for the stock watch bar, whose MainMenuBar parent is banished). Hidden when nothing is watched. |
| Minimap | Boosted | Boosted | `Minimap.lua` — the Blizzard map canvas itself is reparented (ping/tracking stay native) into addon chrome: big +/− zoom, zone label, flat new-mail badge; pinch zooms. MinimapCluster's mouse-scale decorations are banished. |
| Chat | Rebuilt | Rebuilt | `Chat.lua` — compact strip fed straight from `CHAT_MSG_*` (default chat windows banished), tap to open the reader panel with Older/Newer/Latest paging; **Blizzard's chat edit box is rescued and restyled large** (typing must go through it), fed by the phone keyboard. |
| Error / info text, popup dialogs | Boosted | Boosted | `Viewport.lua` / `Blizzard.lua` — UIErrorsFrame re-anchored and enlarged; StaticPopups (release spirit, resurrect, BoP, delete-item, …) scaled ~1.75x and re-homed near the square's top. |
| Game menu (Esc) | Boosted | Boosted | `Blizzard.lua` — scaled 1.8x, centered in the square; Logout/Quit are protected flows that stay Blizzard's. |

## Group & social

| System | Era | Vanilla | Where / notes |
|---|---|---|---|
| Party frames | Boosted | Boosted | `Blizzard.lua` — Blizzard's frames (secure targeting intact) re-homed to the square's right edge at touch scale, re-solved per viewport height. Era re-asserts the anchor after every EditMode layout apply; with "Use Raid-Style Party Frames" on, Raid.lua tells the user that setting hides them. |
| Raid frames | Rebuilt | Rebuilt | `Raid.lua` — deck panel with a group-sorted grid of up to 40 cells (class-colored health, Dead/Ghost/Offline, %); tap = target, long-press = unit menu. Era cells are secure with `RegisterUnitWatch`; Vanilla cells are plain buttons (no lockdown). Default compact raid frames / raid manager banished (Era). |
| Ready check | Rebuilt | Rebuilt | `Raid.lua` — fullscreen answer overlay with huge Ready / Not Ready and a draining timer (works with the panel closed). Era adds per-member answer badges on the grid cells and offers the start button to leader+assist; Vanilla starts leader-only (matching the default 1.12 UI) and has no per-member answers (no `READY_CHECK_CONFIRM` event on 1.12). |
| Raid target markers | Rebuilt | Rebuilt | `Raid.lua` — skull…star + clear row applied to the current target, permission-gated. |
| Loot window | Rebuilt | Rebuilt | `LootSheet.lua` — big rows (icon, quality-colored name, count, coins), tap to loot, **Take all**, auto-loot pass; covers only the deck's upper band so action bars stay tappable mid-combat. BoP confirms ride boosted StaticPopups. |
| Master-loot assignment | Rebuilt | Rebuilt | `LootSheet.lua` — touch candidate picker over the loot sheet (`GiveMasterLoot`), live-updating with loot range; Vanilla mirrors the 1.12 `OPEN_MASTER_LOOT_LIST` flow (no slot arg — tracked via `selectedSlot`). |
| Group loot rolls (need/greed/pass) | Rebuilt | Rebuilt | `RollFrames.lua` — stacked rows above the deck with item tooltip, timer bar, big Need/Greed/Pass; rows dodge MoveMode's split stepper lane. BoP roll confirms go through boosted StaticPopups (Era swaps its own touch-sized dialog in). |
| Friends list | Rebuilt | Rebuilt | `Social.lua` — online-first list, add-friend field (phone keyboard), per-friend Whisper / Invite / Remove (Remove two-tap). |
| Guild roster | Rebuilt | Rebuilt | `Social.lua` — MOTD, member counts, online-first roster (offline paged); per-member Whisper / Invite / Promote / Demote gated on real permissions. Era additionally offers two-tap **Remove from guild**; Vanilla instead surfaces a guild-invite entry row for `CanGuildInvite`. |
| Whisper entry | Rebuilt | Rebuilt | `Social.lua`/`Compat.lua` — pre-fills the rescued chat edit box (`/w Name`); phone keyboard types the message. |
| Trade with another player | Rebuilt | Rebuilt | `Trade.lua` — see Economy below. |

## Economy & crafting

| System | Era | Vanilla | Where / notes |
|---|---|---|---|
| Auction house — browse | Rebuilt | Rebuilt | `AuctionHouse.lua` — search field (phone keyboard), category chips/picker, quality + usable filters, big result rows, prev/next pager; every query respects the server throttle (`CanSendAuctionQuery`). Bid and buyout each sit behind a confirm tap. |
| Auction house — sell | Rebuilt | Rebuilt | Sell slot filled via MoveMode or the in-sheet bag list; bid/buyout money steppers, duration choice, live deposit. Era posts **multi-stack** (stack-size + number-of-stacks steppers, `PostAuction` + post-warning confirm); Vanilla posts the loaded stack as-is (`StartAuction` — the 1.12 API has no stack controls; split first via MoveMode's stepper, as the sheet's hint says). |
| Auction house — my auctions | Rebuilt | Rebuilt | Owned list with per-row confirm-to-cancel (bid-forfeit warning) and, on Era, a best-effort pager. |
| Crafting (professions) | Rebuilt | Rebuilt | `Crafting.lua` — one sheet for **both** classic APIs (tradeskill + craft/enchanting): recipe list with difficulty colors and availability counts, detail view with reagent have/need, quantity stepper + Create / Create All. `DoCraft` has no repeat count on either client, so enchanting is one cast per tap (honestly hidden controls). Era shows a session picker when both APIs are open at once; 1.12 only ever has one open. |
| Bank | Rebuilt | Rebuilt | `Bank.lua` — one sheet with the bank grid, every bank bag, **and your own bags**, so items move both directions without leaving it; tap = auto-move across, long-press = MoveMode (split stepper), tap-while-carrying = place/swap into that exact slot; buy bag slot behind a confirm; empty purchased slots equip a carried bag. |
| Mail — inbox | Rebuilt | Rebuilt | `Mail.lua` — big rows (sender, subject, money/items/COD, expiry), letter view with body text, per-attachment Take / Take money / Take everything, COD behind a confirm, Delete vs Return following the server rule, **Collect all** (skips COD/GM mail, stops on full bags; Era mirrors the client's OpenAllMail model, Vanilla steps one take per server round-trip). |
| Mail — send | Rebuilt | Rebuilt | Recipient/subject fields via phone keyboard, attachments via MoveMode or the bag list, money-vs-COD toggle with steppers, postage line, validation. Era: up to 12 attachments + a body field; Vanilla: the 1.12 single attachment slot, and no body composer (subject carries short notes — documented trade-off). |
| Trade | Rebuilt | Rebuilt | `Trade.lua` — your 6 offer slots + the "will not be traded" slot, partner's offer mirrored read-only, money stepper, partner-accept state shown loud, Accept ⇄ Un-accept, Cancel; embedded bag list for adding items. |
| Vendor buy/sell/repair | Rebuilt | Rebuilt | Part of the merchant bottom sheet (see NPC interactions). |

## World objects & system UI

| System | Era | Vanilla | Where / notes |
|---|---|---|---|
| World tap-to-target / camera / movement | Default | Default | Client-side gesture layer (taps, drag, joystick, pinch) — the addon leaves WorldFrame input untouched. |
| Loot a corpse / chest / herb / vein | Rebuilt | Rebuilt | `LootSheet.lua` (above) — the loot session opens as the touch sheet. |
| Readable world objects / signs / books | Rebuilt | Rebuilt | `Reader.lua` (above). |
| Mailbox / auctioneer / banker objects | Rebuilt | Rebuilt | Their sessions open the rebuilt sheets above. |
| World map | Boosted | Boosted | `WorldMap.lua` — Blizzard's map reflowed over the deck (map taps land as clean left clicks), big X, POI/pin hit rects padded toward touch size; joins the exclusive system. |
| Flight map | Boosted | Boosted | Taxi row under NPC interactions. |
| Static popups (release, resurrect, summon, duel, bind, delete-item…) | Boosted | Boosted | `Blizzard.lua` — scaled and re-homed; logic untouched. |
| Tooltips | Boosted | Boosted | Default tooltips parked just above the deck; addon-owned surfaces anchor tooltips above the touched element. |
| Battleground scoreboard | Boosted | Boosted | `WorldStateScoreFrame` fitted to the square (read-only rows). |
| Battleground queueing | Boosted | Default | See NPC interactions — Era fits `BattlefieldFrame` to the square; Vanilla is the acknowledged gap. |

## Known honest gaps and platform limits

- **BG queueing** frames are untouched default UI on Vanilla (the scoreboard is
  boosted; Era boosts the `BattlefieldFrame` queue panel too, since a
  default-anchored panel would open outside the landscape band crop).
  Everything else interactive is rebuilt or boosted.
- **Rolls in flight across `/reload`** cannot be re-rendered (no roll-ID
  enumerator on classic clients) — same limitation as the default UI.
- **Vanilla (1.12) API ceilings**, all noted in module headers and, where
  user-visible, on screen: one mail attachment and no body composer; single-stack
  auction posting; `DoCraft` without a repeat count; no `INSPECT_READY` (repaint
  ladder); no per-member ready-check answers; icon-less cast bar; spell/action
  carries tracked without a cursor query.
- **Era combat rule:** item moves never run in combat — MoveMode refuses with a
  notice, and secure grid rebuilds queue for combat end (the panels say so
  instead of rendering blank).
