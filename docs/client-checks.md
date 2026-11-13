# Checks that need a real client

The acceptance suite (`npm run acceptance`) drives the server with bots, which have no client.
Anything a player sees, hears or does through their own client can only be checked by a person
on a test server. Each item says what to do and what should happen; tick it off with the game
version it was seen on.

## Screen and sound

- [x] **BR.ui text and panels**: show text and a panel to yourself, then `el:set` with a
  `transition` (move, resize, recolour, fade alpha). Expect smooth animation, correct anchors
  and pivots, fonts by name. Seen on CL16507.
- [x] **BR.ui.ask**: one dialog of each kind (`ok`, `yes_no`, `ok_cancel`, `text`). Expect the
  answer in the callback, `false` on cancel, the typed text for `text`, and the timeout firing
  when left open. Seen on CL16507; a timed-out dialog stays on screen (the game can't close it
  from the server) and its late answer is dropped.
- [x] **Display text limit**: show 33 different texts. Expect the oldest to disappear,
  `BR.ui.count` to stay at 32, and one console line (not one per text, and at most one a
  minute). Seen on CL16507.
- [ ] **Display text sources**: place a Display Text gate that shows text to you. Expect
  `BR.ui.texts(ps, { sources = true })` to list it as `world`, with the gate's brick and owner.
  On CL16507 BR.ui listed only its own texts after a gate fired: the gate's text doesn't reach
  the ClientDisplayText hook BR.ui counts with (whether it showed for the player wasn't
  confirmed). Open.
- [ ] **BR.player.hint**: a card in game, in the pause menu, and both. On CL16507 the in-game
  card shows, but `pause` and `both` never appear in the Esc menu, and opening it closes the
  card: the client seems to ignore `WhereToShow` for a pushed hint.
- [x] **BR.player messages**: `whisper`, `status`, `message_box`, `error_dialog`,
  `display_text`, `remove_text`. Seen on CL16507.
- [x] **BR.player.set_view and spectate_target**: your view turns; while spectating, you follow
  the target. Seen on CL16507.
- [x] **BR.player.fade, view_from and view_reset**: the screen fades and comes back; your view
  moves to another actor, blending, and back. Seen on CL16507.
- [x] **BR.mover**: a moving platform moves smoothly for a client, and you can ride it. Seen on
  CL16507: rideable; 30 moves a second looked choppy, 60 (now the default) good enough.
- [x] **BR.sound**: `play` to you, `play` to "all", and `at` a position (fades with distance).
  Seen on CL16507, alive and dead; fading with distance not judged yet. A looping sound
  (`BA_AMB_*`, duration 10000) never stopped on clients until they rejoined, so `play` and `at`
  now refuse looping sounds.
- [x] **BR.chat**: `send` reaches only the chosen players, shown as the sender's own line;
  `route` keeps a staff or team channel to its members. Seen on CL16507, after a fix: the
  client shows the formatted line as it is, so `send` now builds it with the sender's name in
  the colour the recipient sees (`GetChatNameColorFor`), as the game does.

## Inventory and building

- [ ] **BR.prefab.set_slot and set_template**: a brick, an entity, an item and a prefab, given
  to you. Expect each in the hotbar or on the template, ready to place. On CL16507 the brick,
  the entity and the prefab work. An item doesn't: from the template's bytes the server kept
  the slot empty while the client held a model-less pistol it couldn't put away; through the
  reflected `ServerSetInventorySlot` (now what `set_slot` uses for items) the server has the
  pistol, attached to the character when wielded, as one taken from the game's own menu is,
  yet the client still shows no model in hand. A pistol from the menu works. Open.
- [x] **BR.prefab.copy and give**: copy a region onto your template; give a saved prefab file.
  Seen on CL16507, after a fix: `copy` passed the grid actor where the selector takes its
  BrickGridComponent.
- [x] **BR.act.place_prefab** on a connected player (it works for bots): the paste appears for
  everyone, oriented as asked. Seen on CL16507 (default orientation).
- [ ] **BR.player.tune**: a tuned weapon shows its new name and colours. On CL16507 the name
  reached the client (a couple of minutes late), but the scale and colours never did; the
  server holds them all. Those fields may only be read when the item is first sent. Open.

## Build regions

On a test server with a region you don't own, and one you do:

- [x] Placing a single brick, and dragging a volume across the border. Expect a refusal, and the
  status line message. Seen on CL16507 for a single brick (the drag and the message not
  confirmed). The server owner has every permission, `region.bypass` included, so test as
  someone else or deny it first (`BR.perm.set(ps, "region.bypass", false)`).
- [x] Building right up to the border of your own plot from inside. Expect it to work. Seen on
  CL16507.
- [ ] Pasting a prefab from your own client that reaches from outside into the forbidden region
  (tested with a bot). Expect it placed, then removed whole, with the message.
- [x] Selecting in the forbidden region, then cut, copy and delete. Expect the selection refused.
  Seen on CL16507.
- [x] Wiring to a gate in the forbidden region with the Connector. Seen on CL16507 (refused).
- [x] Resizing a brick of yours so it grows into the forbidden region. Seen on CL16507
  (refused, moving it in too).
- [ ] Applicator: adding a banned component, and pasting a brick state that has one. Expect the
  first refused and the second stripped. On CL16507 the applicator could still change a brick
  in a forbidden region (visibility, collision, component edits, adding a component): only
  four of its calls were guarded. All nine are now, and a retry was refused. Bans not tried.
- [ ] `region.bypass` through a role (`BR.perm.set_role`), and `BR.region.bypass(ps)`. On CL16507
  `BR.region.bypass(ps)` let a player build in a forbidden region; through a role not tried.

## Players

- [x] **BR.pickup.gate**: walk into a gated pickup (a TTT dropped item). Expect nothing picked
  up, the pickup still there for others, and a pickup once you step out and back in after the
  gate allows it. Seen on CL16507 after two fixes: a Lua-spawned pickup didn't replicate
  (`pickup.spawn` now turns it on), and a connected player's pickup never reaches
  HandlePickupAttempt (only bots' do), so gates now also run at the overlap callback. Still
  open: `once` didn't remove the pickup and `BR.pickup.on` likely misses real players too,
  both being tied to HandlePickupAttempt.
- [ ] **Status effects**: `size` visibly changes the character; `regen` and `poison` show in
  the health bar. On CL16507 `size` (CharacterScale) changed nothing other players saw; the
  sized player saw a grid attached to them scale with them. Open; `regen` and `poison` not
  tried.
- [ ] **Key event**: pressing primary, secondary, reload, inspect and the custom binds fires
  `BR.event.on("key")`. On CL16507 primary and reload fire (down and up); secondary didn't with
  a pistol; inspect and the custom binds not tried. Retested: primary and reload again fire
  down and up. Pressed in a seat (held items off), nothing fires: a seated player's input goes
  to the seat's wire controls, not the character's weapon keys. Secondary did fire (down and
  up) with a weapon that has a secondary action: the client only sends the bit when the held
  weapon uses it (a pistol has none). Inspect and the custom binds still not seen.
- [ ] **BR.guard speed**: a player sped up without a team rule (or with a mismatched one)
  raises `speed`. A teleporter brick raises `teleport` (expected, documented). On CL16507,
  raising MaxWalkSpeed on the server didn't reach the client (it simulates its own movement),
  so nothing ran faster and no signal came; needs a speed-up the client takes.
- [ ] **Join event and gating**, permission overrides shown in the client's UI, spectator mode,
  bot voice playback and voice recording (carried over from earlier lists). On CL16507
  `BR.mod.on_join` fired for a real client rejoining (chat reaches a joining player at once);
  refusing a real join and the permission UI not tried. Spectator follows a target
  (see set_view and spectate_target).
  Voice: `BR.voice.say` spoken as a real player reaches others (heard, though "very grainy"
  and loud at a -8 dB peak); spoken as a bot it sends every frame with no error and nobody
  hears anything, so bot voice is broken. Recording not tried.

## World and environment

- [x] **BR.env.set**: time of day, rain, fog colour and ground colour change for a client
  without reconnecting. Seen on CL16507 (sky: time of day, rain, fog, clouds); ground colour
  not tried.
- [x] **BR.world.spawn_projectile**: a rocket fired from the sky is seen flying and
  exploding, and a pistol bullet is seen too (they're replicated actors here, not the
  weapon's own messages). Seen on CL16507.
- [ ] **BR.entity.set_gravity_direction**: a player falls along the new direction and lands
  on a wall, and their camera turns with it; `{0, 0, -1}` puts them back. On CL16507 the
  gravity reaches the owning client (a jump goes along the new up), but the character and its
  camera don't turn to it; the Set Gravity Direction gate turns them, so it does something
  more (a rotation of the character or its view). Open.
- [x] **BR.label**: a label shows at its point, faces you with `billboard = "full"`, in its
  colour and outline; `l:set` and `l:remove` update it. Seen on CL16507, rich text included
  (`<icon>check</>`, `<color="f00">`); `material = "unlit"` added.
- [x] **Seat event**: sitting in and leaving a seat fire `seat` with `active` true, then false.
  Seen on CL16507.

## Web

- [x] **HTTP routes** at `/api/v1/plugin/ue4ss/...` while logged in to the web UI. Expect
  `request.user` filled for a login-only route. A POST from another site's page should be
  refused (403).
  Result: a GET to `/api/v1/plugin/ue4ss/claude/ping` answered while logged in and gave 401
  when logged out. The cross-origin 403 is covered by omegga's pluginHttp unit test, not
  tried from a browser. Without `plugin/` in the path, the web UI's catch-all answers with
  its 404 page.
