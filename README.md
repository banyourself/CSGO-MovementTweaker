# MovementTweaker (fork)

Movement cvar tweaks for CS:GO surf and bhop style servers. My fork of **MovementTweaker** by
danzayau, mostly with additions that make the settings actually hold.

Upstream is 122 lines, this is 234, and almost all of the difference is new code rather than
rewritten code.

## Install

Drop the `addons` folder into your `csgo` folder:

```
addons/sourcemod/plugins/MovementTweaker.smx           the compiled plugin
addons/sourcemod/scripting/MovementTweaker.sp          source
addons/sourcemod/scripting/movementtweaker/tweaks.sp   sub-module, needed to compile
```

Convars go to `cfg/sourcemod/MovementTweaker.cfg` on first run.

## What I added

**sv_airaccelerate pinning that actually holds.** Map configs, gamemode configs and rcon all
like to reset it, and the original just set it once. Here the pinned value is re-applied after
`server.cfg` and the map and gamemode configs run on every map change, which is after whatever
was resetting it, so the pin wins.

There is also a change hook, so if anything touches `sv_airaccelerate` mid-map it gets put
back. That hook needs an equality guard, otherwise it re-enters itself when the pin is what
changed the value.

Use `mt_airaccelerate` to actually change it.

**Velocity modifier clamping in the right place.** It runs after this tick's movement code has
used the value but before the engine packs the snapshot, so out-of-range values never reach the
network encoder. That is what kills the `DataTable warning ... clamping` console spam.

It deliberately does **not** check whether the player is alive. Someone who dies while their
stored value is above 1.0 still needs clamping.

**Air acceleration hooks.** Velocity is recorded just before the engine's `AirAccelerate`, then
if the player is surfing or gstrafing, exactly that tick's acceleration is scaled afterwards.

**Optional gstrafe integration.** If gstrafe.sp is loaded, the prestrafe ground cap is skipped
while a player is actively gstrafing, so their gstrafe speed is not slammed back down to the
prestrafe cap.

**Anti-cheat integration.** MovementTweaker changes velocity in a few defined places, so it
tells KevAC to ignore only the immediate server-authored outcome. Without that, deliberate
server-side velocity changes read as injected movement to the anti-cheat.

## Credits

Original **MovementTweaker** by **danzayau**:
[github.com/danzayau/MovementTweaker](https://github.com/danzayau/MovementTweaker)

GPL-3.0 upstream, so this fork stays GPL-3.0.

## License

GPL-3.0, see `LICENSE`.
