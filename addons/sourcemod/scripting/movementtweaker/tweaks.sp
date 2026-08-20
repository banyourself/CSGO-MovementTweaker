/*
	Tweaks

	Movement tweaks.
*/



#define SPEED_NORMAL 250.0
#define SPEED_NO_WEAPON 260.0
#define DUCK_SPEED_MINIMUM 8.0

// Prestrafe max is derived from the mt_prestrafe_max_speed convar (speed / 250).
#define PRE_VELMOD_INCREMENT 0.0014 // Per tick when prestrafing
#define PRE_VELMOD_DECREMENT 0.0021 // Per tick when not prestrafing

// The ground-cap grace period and decay rate come from the
// mt_ground_cap_grace_ticks and mt_ground_cap_decay convars.

static int oldButtons[MAXPLAYERS + 1];
static float preVelMod[MAXPLAYERS + 1];
static float prestrafeCap[MAXPLAYERS + 1]; // live prestrafe speed ceiling = 250 * prestrafe modifier
static bool isPrestrafing[MAXPLAYERS + 1]; // player is holding the prestrafe input (turn + forward/back + strafe) this tick

static char weaponNames[][] = 
{
	"weapon_knife", "weapon_hkp2000", "weapon_deagle", "weapon_elite", "weapon_fiveseven", 
	"weapon_glock", "weapon_p250", "weapon_tec9", "weapon_decoy", "weapon_flashbang", 
	"weapon_hegrenade", "weapon_incgrenade", "weapon_molotov", "weapon_smokegrenade", "weapon_taser", 
	"weapon_ak47", "weapon_aug", "weapon_awp", "weapon_bizon", "weapon_famas", 
	"weapon_g3sg1", "weapon_galilar", "weapon_m249", "weapon_m4a1", "weapon_mac10", 
	"weapon_mag7", "weapon_mp7", "weapon_mp9", "weapon_negev", "weapon_nova", 
	"weapon_p90", "weapon_sawedoff", "weapon_scar20", "weapon_sg556", "weapon_ssg08", 
	"weapon_ump45", "weapon_xm1014"
};

static int weaponRunSpeeds[sizeof(weaponNames)] = 
{
	250, 240, 230, 240, 240, 
	240, 240, 240, 245, 245, 
	245, 245, 245, 245, 220, 
	215, 220, 200, 240, 220, 
	215, 215, 195, 225, 240, 
	225, 220, 240, 150, 220, 
	230, 210, 215, 210, 230, 
	230, 215
};



// =========================  LISTENERS  ========================= //

void OnPlayerRunCmd_Tweaks(int client, int &buttons)
{
	if (!IsPlayerAlive(client))
	{
		return;
	}
	
	MovementAPIPlayer player = MovementAPIPlayer(client);
	RemoveCrouchJumpBind(player, buttons);
	TweakVelMod(player);
	oldButtons[client] = buttons;
}

void OnStartTouchGround_Tweaks(int client)
{
	MovementAPIPlayer player = MovementAPIPlayer(client);
	ReduceDuckSlowdown(player);
}

void OnStopTouchGround_Tweaks(int client, bool jumped)
{
	MovementAPIPlayer player = MovementAPIPlayer(client);
	if (jumped && TweakJump(player))
	{
		SuppressKevACMovementChecks(client);
	}
	preVelMod[player.ID] = 1.0;
}

// Horizontal velocity captured right before the engine's AirAccelerate, so
// the post hook can isolate (and scale) exactly this tick's acceleration.
static float airPreVel[MAXPLAYERS + 1][3];

void OnAirAcceleratePre_Tweaks(int client, const float velocity[3])
{
	airPreVel[client][0] = velocity[0];
	airPreVel[client][1] = velocity[1];
	airPreVel[client][2] = velocity[2];
}

Action OnAirAcceleratePost_Tweaks(int client, float velocity[3])
{
	float surfMult = gCV_SurfAccel.FloatValue;
	float gstrafeMult = gCV_GstrafeAccel.FloatValue;

	// Both at default: feature off - no state checks, no traces, no cost.
	if (surfMult == 1.0 && gstrafeMult == 1.0)
	{
		return Plugin_Continue;
	}

	float mult = 1.0;
	if (surfMult != 1.0 && IsSurfing(client))
	{
		mult = surfMult;
	}
	else if (gstrafeMult != 1.0 && RecentlyGstrafed(client))
	{
		mult = gstrafeMult;
	}

	if (mult == 1.0)
	{
		return Plugin_Continue;
	}

	// The engine already applied its acceleration this tick:
	// accel = velocity - airPreVel. To make the effective acceleration
	// mult x larger/smaller, add (mult - 1) of that same delta on top.
	for (int i = 0; i < 3; i++)
	{
		velocity[i] += (mult - 1.0) * (velocity[i] - airPreVel[client][i]);
	}
	SuppressKevACMovementChecks(client);
	return Plugin_Changed;
}

// Surfing = airborne and pressed against a ramp too steep to stand on. A
// short downward trace finds the ramp; a standable floor (normal.z >= 0.7)
// or a ceiling (normal.z <= 0) is not a surf ramp.
static bool IsSurfing(int client)
{
	if (GetEntityFlags(client) & FL_ONGROUND)
	{
		return false;
	}

	float pos[3], down[3];
	GetClientAbsOrigin(client, pos);
	down = pos;
	down[2] -= 64.0;

	Handle tr = TR_TraceRayFilterEx(pos, down, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_NotClient, client);
	bool bSurf = false;
	if (TR_DidHit(tr))
	{
		float normal[3];
		TR_GetPlaneNormal(tr, normal);
		if (normal[2] > 0.0 && normal[2] < 0.7)
		{
			bSurf = true;
		}
	}
	delete tr;
	return bSurf;
}

public bool TraceFilter_NotClient(int entity, int mask, any data)
{
	return entity != data;
}

void OnPlayerSpawn_Tweaks(int client)
{
	if (!gCV_SuppressLandingAnimation.BoolValue)
	{
		return;
	}
	
	if (GetClientTeam(client) == CS_TEAM_T)
	{
		SetEntityModel(client, gC_PlayerModelT);
	}
	else if (GetClientTeam(client) == CS_TEAM_CT)
	{
		SetEntityModel(client, gC_PlayerModelCT);
	}
}



// =========================  PRIVATE  ========================= //

static void TweakVelMod(MovementAPIPlayer player)
{
	if (!player.OnGround)
	{
		// Airborne: no prestrafe input state to enforce a ground cap against.
		isPrestrafing[player.ID] = false;
		return;
	}

	float preMod = CalcPrestrafeVelMod(player);
	float velMod = preMod * CalcWeaponVelMod(player);

	// No cap on the combined modifier: the weapon compensation exactly
	// cancels the weapon's own max speed (weaponSpeed * 250/weaponSpeed
	// = 250), so ground speed tops out at 250 * prestrafe modifier, and
	// the prestrafe modifier is already clamped to mt_prestrafe_max_speed
	// inside CalcPrestrafeVelMod. Capping the product again only broke
	// slow weapons (AK needs x1.163, Negev x1.667, both above the old
	// 1.108 cap, so rifles never reached 250 while pistols did).

	// May exceed 1.0 (prestrafe and/or weapon compensation). That's fine for
	// movement: this runs before the tick's movement code consumes it, and
	// ClampVelModForNetworking pulls it back into the SendProp's 0-1 range in
	// post-think, before snapshots are packed.
	SetEntPropFloat(player.ID, Prop_Send, "m_flVelocityModifier", velMod);

	// Live prestrafe ceiling used by CapGroundSpeedPost. Based on the PRESTRAFE
	// modifier only, so it rises toward mt_prestrafe_max_speed as you prestrafe
	// well and sits at base run speed otherwise: natural variance, not a pin.
	float cap = SPEED_NORMAL * preMod;
	if (cap < SPEED_NORMAL)
	{
		cap = SPEED_NORMAL;
	}
	prestrafeCap[player.ID] = cap;
}

// The m_flVelocityModifier SendProp networks a 0.0-1.0 range, and the engine
// packs snapshots straight from entity memory at the end of the frame, so any
// value above 1.0 still stored there makes the encoder print "DataTable
// warning: Out-of-range value ... clamping" every snapshot, no matter how the
// value was written. Movement has already consumed the real value by
// post-think (TweakVelMod rewrites it before each tick's movement runs), so
// clamping the stored value here silences the warning without changing speed
// behavior. Clients received a clamped 1.0 either way.
void ClampVelModForNetworking(int client)
{
	if (GetEntPropFloat(client, Prop_Send, "m_flVelocityModifier") > 1.0)
	{
		SetEntPropFloat(client, Prop_Send, "m_flVelocityModifier", 1.0);
	}
}

// Enforces the prestrafe ceiling on the ground (needed because the movement
// unlocker NOPs the engine's own ground clamp). Runs post-think so the tick's
// acceleration can't push past it. The cap tracks the live prestrafe modifier
// (prestrafeCap), so speed varies with technique instead of pinning at 277.
// Brief ground-touches (bhop/gstrafe) are exempt via the grace window, and
// airborne movement is never touched.
void CapGroundSpeedPost(int client)
{
	if (!IsPlayerAlive(client))
	{
		return;
	}

	MovementAPIPlayer player = MovementAPIPlayer(client);

	if (!player.OnGround)
	{
		return;
	}

	// Don't touch a player who is actively gstrafing. Their speed (up to 450)
	// legitimately exceeds the prestrafe cap and self-limits via gstrafe's logic.
	if (RecentlyGstrafed(client))
	{
		return;
	}

	if (GetGameTickCount() - player.LandingTick <= gCV_GroundCapGraceTicks.IntValue)
	{
		return;
	}

	float cap = prestrafeCap[client];
	if (cap < SPEED_NORMAL)
	{
		cap = SPEED_NORMAL;
	}

	float velocity[3];
	player.GetVelocity(velocity);

	float speed = SquareRoot(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
	if (speed <= cap)
	{
		return;
	}

	float target;
	if (isPrestrafing[client])
	{
		// Prestrafe overspeed is ALWAYS hard-capped, independent of
		// mt_ground_cap_decay. This is the prestrafe cap itself; it must not be
		// disable-able by setting the decay to 1.0. Only the speed the player is
		// actively building via prestrafe is touched here.
		target = cap;
	}
	else
	{
		// Not prestrafing: the overspeed is retained momentum (surf/bhop/gstrafe
		// carry). Only the OPTIONAL decay easing trims it, and at 1.0 the
		// momentum is left completely alone - so mt_ground_cap_decay "1" no
		// longer messes with general movement.
		float decay = gCV_GroundCapDecay.FloatValue;
		if (decay >= 1.0)
		{
			return;
		}
		target = speed * decay;
		if (target < cap)
		{
			target = cap;
		}
	}

	float scale = target / speed;
	velocity[0] *= scale;
	velocity[1] *= scale;
	player.SetVelocity(velocity);
	SuppressKevACMovementChecks(client);
}

// True if the gstrafe plugin is loaded and this player gstrafed within the
// mt_gstrafe_grace window. Safe when gstrafe isn't loaded (native is optional).
static bool RecentlyGstrafed(int client)
{
	float grace = gCV_GstrafeGrace.FloatValue;
	if (grace <= 0.0)
	{
		return false;
	}
	if (GetFeatureStatus(FeatureType_Native, "getLastDuck") != FeatureStatus_Available)
	{
		return false;
	}
	return getLastDuck(client) < grace;
}

static float CalcPrestrafeVelMod(MovementAPIPlayer player)
{
	if (!gCV_Prestrafe.BoolValue)
	{
		isPrestrafing[player.ID] = false;
		return 1.0;
	}

	// The prestrafe input: turning the aim while holding exactly one of
	// forward/back and exactly one of left/right. This same condition drives
	// the hard prestrafe cap in CapGroundSpeedPost, so the cap only ever
	// touches speed the player is actively building via prestrafe.
	bool prestrafeInput = (player.Turning
		 && ((player.Buttons & IN_FORWARD && !(player.Buttons & IN_BACK)) || (!(player.Buttons & IN_FORWARD) && player.Buttons & IN_BACK))
		 && ((player.Buttons & IN_MOVELEFT && !(player.Buttons & IN_MOVERIGHT)) || (!(player.Buttons & IN_MOVELEFT) && player.Buttons & IN_MOVERIGHT)));

	isPrestrafing[player.ID] = prestrafeInput;

	if (prestrafeInput)
	{
		preVelMod[player.ID] += gCV_PrestrafeAccel.FloatValue;
	}
	else
	{
		preVelMod[player.ID] -= PRE_VELMOD_DECREMENT;
	}
	
	// Keep prestrafe velocity modifier within range. The cap only applies to
	// ground movement. Airborne speed (bhop/airstrafe) never uses this modifier.
	float maxVelMod = gCV_PrestrafeMaxSpeed.FloatValue / SPEED_NORMAL;

	if (preVelMod[player.ID] < 1.0)
	{
		preVelMod[player.ID] = 1.0;
	}
	else if (preVelMod[player.ID] > maxVelMod)
	{
		preVelMod[player.ID] = maxVelMod;
	}

	return preVelMod[player.ID];
}

static float CalcWeaponVelMod(MovementAPIPlayer player)
{
	if (!gCV_UniversalWeaponSpeed.BoolValue)
	{
		return 1.0;
	}
	
	int weaponEnt = GetEntPropEnt(player.ID, Prop_Data, "m_hActiveWeapon");
	if (!IsValidEntity(weaponEnt))
	{
		return SPEED_NORMAL / SPEED_NO_WEAPON; // Weapon entity not found, so no weapon
	}
	
	char weaponName[64];
	GetEntityClassname(weaponEnt, weaponName, sizeof(weaponName)); // Weapon the client is holding
	
	// Get weapon speed and work out how much to scale the modifier
	int weaponCount = sizeof(weaponNames);
	for (int weaponID = 0; weaponID < weaponCount; weaponID++)
	{
		if (StrEqual(weaponName, weaponNames[weaponID]))
		{
			return SPEED_NORMAL / weaponRunSpeeds[weaponID];
		}
	}
	
	return 1.0; // If weapon isn't found (new weapon?)
}

static bool TweakJump(MovementAPIPlayer player)
{
	if (!gCV_PerfTimingTweak.BoolValue || gCV_PerfTicks.IntValue <= 1)
	{
		return false;
	}
	
	if (player.TakeoffTick - player.LandingTick <= gCV_PerfTicks.IntValue
		 && player.TakeoffTick - player.LandingTick > 1)
	{
		float velocity[3], baseVelocity[3], newVelocity[3];
		player.GetVelocity(velocity);
		player.GetBaseVelocity(baseVelocity);
		player.GetLandingVelocity(newVelocity);
		newVelocity[2] = velocity[2];
		SetVectorHorizontalLength(newVelocity, player.LandingSpeed);
		AddVectors(newVelocity, baseVelocity, newVelocity);
		player.SetVelocity(newVelocity);
		return true;
	}

	return false;
}

static void RemoveCrouchJumpBind(MovementAPIPlayer player, int &buttons)
{
	if (!gCV_NerfPerfectCrouchjump.BoolValue)
	{
		return;
	}
	
	if (player.OnGround && buttons & IN_JUMP
		 && !(oldButtons[player.ID] & IN_JUMP)
		 && !(oldButtons[player.ID] & IN_DUCK))
	{
		buttons &= ~IN_DUCK;
	}
}

static void ReduceDuckSlowdown(MovementAPIPlayer player)
{
	if (!gCV_ResetDuckSpeedOnLanding.BoolValue)
	{
		return;
	}
	
	if (player.DuckSpeed < DUCK_SPEED_MINIMUM)
	{
		player.DuckSpeed = DUCK_SPEED_MINIMUM;
	}
} 
