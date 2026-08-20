#include <sourcemod>

#include <cstrike>
#include <sdktools>
#include <sdkhooks>

#include <movementapi>
#include <kevac_movement>

#pragma newdecls required
#pragma semicolon 1



public Plugin myinfo = 
{
	name = "Movement Tweaker", 
	author = "DanZay + Kevin", 
	description = "tweaks up the CS:GO movement mechanics", 
	version = "2.0.0", 
	url = "mtweaker"
};

ConVar gCV_AccelerateUseWeaponSpeed;
ConVar gCV_SvAirAccelerate;
ConVar gCV_AirAccelerate;
ConVar gCV_Prestrafe;
ConVar gCV_PrestrafeMaxSpeed;
ConVar gCV_PrestrafeAccel;
ConVar gCV_GroundCapGraceTicks;
ConVar gCV_GroundCapDecay;
ConVar gCV_GstrafeGrace;
ConVar gCV_UniversalWeaponSpeed;
ConVar gCV_SurfAccel;
ConVar gCV_GstrafeAccel;

// Optional native from gstrafe.sp: seconds since the last gstrafe boost. Skips the
// prestrafe ground cap while gstrafing, so 450 speed isn't slammed to the cap.
native float getLastDuck(int client);
ConVar gCV_PerfTimingTweak;
ConVar gCV_PerfTicks;
ConVar gCV_ResetDuckSpeedOnLanding;
ConVar gCV_NerfPerfectCrouchjump;
ConVar gCV_SuppressLandingAnimation;
ConVar gCV_PlayerModelT;
ConVar gCV_PlayerModelCT;

char gC_PlayerModelT[256];
char gC_PlayerModelCT[256];

// MovementTweaker changes velocity in defined places; KevAC ignores only that outcome.
void SuppressKevACMovementChecks(int client, int ticks = 3)
{
	if (GetFeatureStatus(FeatureType_Native, "KevAC_IgnoreMovement") == FeatureStatus_Available)
		KevAC_IgnoreMovement(client, ticks);
}

// Must come AFTER the globals: tweaks.sp uses gCV_*/gC_* and spcomp resolves top-down.
#include "movementtweaker/tweaks.sp"

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// gstrafe may or may not be loaded; don't hard-require its native.
	MarkNativeAsOptional("getLastDuck");
	MarkNativeAsOptional("KevAC_IgnoreMovement");
	return APLRes_Success;
}

public void OnPluginStart()
{
	if (GetEngineVersion() != Engine_CSGO)
	{
		SetFailState("This plugin is for CS:GO.");
	}

	RegisterConVars();

	AutoExecConfig(true, "MovementTweaker");

	HookEvent("player_spawn", OnPlayerSpawn);

	// Late load: hook players already on the server.
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			OnClientPutInServer(client);
		}
	}
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
}

public void OnPostThinkPost(int client)
{
	CapGroundSpeedPost(client);

	// After this tick's movement code, before the engine packs the snapshot, so
	// out-of-range values never reach the encoder (kills the DataTable clamp spam).
	// Not gated on IsPlayerAlive: a player who dies above 1.0 still needs clamping.
	ClampVelModForNetworking(client);
}

public void OnConfigsExecuted()
{
	UpdateAccelerateUseWeaponSpeed();

	// Runs after server.cfg and the map/gamemode configs, i.e. after whatever resets
	// sv_airaccelerate to 100, so the pinned value wins.
	ApplyAirAccelerate();
}

public void OnMapStart()
{
	// Setup and precache player models
	GetConVarString(gCV_PlayerModelT, gC_PlayerModelT, sizeof(gC_PlayerModelT));
	GetConVarString(gCV_PlayerModelCT, gC_PlayerModelCT, sizeof(gC_PlayerModelCT));
	
	PrecacheModel(gC_PlayerModelT, true);
	AddFileToDownloadsTable(gC_PlayerModelT);
	PrecacheModel(gC_PlayerModelCT, true);
	AddFileToDownloadsTable(gC_PlayerModelCT);
}



// =========================  CONVARS  ========================= //

void RegisterConVars()
{
	gCV_AccelerateUseWeaponSpeed = FindConVar("sv_accelerate_use_weapon_speed");
	gCV_SvAirAccelerate = FindConVar("sv_airaccelerate");

	gCV_AirAccelerate = CreateConVar("mt_airaccelerate", "300", "Pins sv_airaccelerate to this value: reapplied on every map change and whenever anything else changes it. 0 = leave sv_airaccelerate alone.", _, true, 0.0, true, 10000.0);
	gCV_AirAccelerate.AddChangeHook(AirAccelerateChanged);
	gCV_SvAirAccelerate.AddChangeHook(SvAirAccelerateChanged);

	gCV_Prestrafe = CreateConVar("mt_prestrafe", "1", "Sets whether prestrafe is enabled.", _, true, 0.0, true, 1.0);
	gCV_PrestrafeMaxSpeed = CreateConVar("mt_prestrafe_max_speed", "277", "Max ground speed prestrafe can build toward. The cap follows your live prestrafe modifier, so speed varies (~276-278) with technique instead of pinning exactly here. Airborne (bhop/gstrafe) is never affected.", _, true, 250.0, true, 500.0);
	gCV_PrestrafeAccel = CreateConVar("mt_prestrafe_accel", "0.0017", "How fast prestrafe builds toward the cap per tick. Lower = requires more sustained prestrafe to reach 277 (less 'free' speed).", _, true, 0.0002, true, 0.01);
	gCV_GroundCapGraceTicks = CreateConVar("mt_ground_cap_grace_ticks", "12", "Ground ticks after landing before the prestrafe cap applies. Keeps bhop/gstrafe ground-touches (which are brief) exempt so their speed is retained.", _, true, 0.0, true, 128.0);
	gCV_GroundCapDecay = CreateConVar("mt_ground_cap_decay", "1", "Per-tick multiplier easing NON-prestrafe grounded overspeed (retained surf/bhop/gstrafe momentum) toward the prestrafe cap. 1.0 = leave retained momentum alone. NOTE: the prestrafe cap (mt_prestrafe_max_speed) is hard-enforced regardless of this value.", _, true, 0.5, true, 1.0);
	gCV_GstrafeGrace = CreateConVar("mt_gstrafe_grace", "0.5", "Seconds after a gstrafe boost during which the ground cap is skipped, so gstrafe speed isn't trimmed to the prestrafe cap. (0 = always cap; needs the gstrafe plugin)", _, true, 0.0, true, 3.0);
	gCV_SurfAccel = CreateConVar("mt_surf_accel", "1.0", "Air-acceleration multiplier applied ONLY while surfing (airborne on a ramp too steep to stand on). 1.0 = engine default, >1 = accelerate faster, <1 = slower. Only this tick's air-accel is scaled; nothing else about movement changes.", _, true, 0.1, true, 5.0);
	gCV_GstrafeAccel = CreateConVar("mt_gstrafe_accel", "1.0", "Air-acceleration multiplier applied ONLY during the gstrafe window (needs the gstrafe plugin's getLastDuck native). 1.0 = engine default, >1 = faster, <1 = slower.", _, true, 0.1, true, 5.0);
	gCV_UniversalWeaponSpeed = CreateConVar("mt_universal_weapon_speed", "1", "Sets whether all weapons should have the same speed.", _, true, 0.0, true, 1.0);
	gCV_PerfTimingTweak = CreateConVar("mt_perf_timing_tweak", "1", "Sets whether to adjust the number of ticks after landing that jumping is considered a perfect b-hop.", _, true, 0.0, true, 1.0);
	gCV_PerfTicks = CreateConVar("mt_perf_ticks", "1", "Number of ticks after landing that jumping counts as a perfect bunnyhop.", _, true, 1.0, false);
	gCV_ResetDuckSpeedOnLanding = CreateConVar("mt_reset_duck_speed_on_landing", "0", "Sets whether to reset duckspeed upon landing.", _, true, 0.0, true, 1.0);
	gCV_NerfPerfectCrouchjump = CreateConVar("mt_nerf_perfect_crouchjump", "0", "Sets whether to disable perfect crouch jumps.", _, true, 0.0, true, 1.0);
	gCV_SuppressLandingAnimation = CreateConVar("mt_suppress_landing_animation", "0", "Sets whether to change player models on spawn to suppress the landing animations.", _, true, 0.0, true, 1.0);
	gCV_PlayerModelT = CreateConVar("mt_player_model_t", "models/player/tm_leet_varianta.mdl", "The model to change Terrorists to (applies after map change).");
	gCV_PlayerModelCT = CreateConVar("mt_player_model_ct", "models/player/ctm_idf_variantc.mdl", "The model to change Counter-Terrorists to (applies after map change).");
	
	gCV_UniversalWeaponSpeed.AddChangeHook(UniversalWeaponSpeedChanged);
}

public void UniversalWeaponSpeedChanged(Handle convar, const char[] oldValue, const char[] newValue)
{
	UpdateAccelerateUseWeaponSpeed();
}

void UpdateAccelerateUseWeaponSpeed()
{
	gCV_AccelerateUseWeaponSpeed.IntValue = gCV_UniversalWeaponSpeed.IntValue;
}

public void AirAccelerateChanged(Handle convar, const char[] oldValue, const char[] newValue)
{
	// mt_airaccelerate was changed (e.g. via rcon or cfg), apply it right away.
	ApplyAirAccelerate();
}

public void SvAirAccelerateChanged(Handle convar, const char[] oldValue, const char[] newValue)
{
	// Something else touched sv_airaccelerate mid-map, so pin it back. Use mt_airaccelerate.
	ApplyAirAccelerate();
}

void ApplyAirAccelerate()
{
	float desired = gCV_AirAccelerate.FloatValue;
	if (desired <= 0.0)
	{
		return;
	}

	// Equality guard stops the change hook re-entering when the pin itself fired it.
	if (gCV_SvAirAccelerate.FloatValue != desired)
	{
		gCV_SvAirAccelerate.FloatValue = desired;
	}
}



// =========================  CLIENT  ========================= //

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
	OnPlayerRunCmd_Tweaks(client, buttons);
	return Plugin_Continue;
}

public void Movement_OnStartTouchGround(int client)
{
	OnStartTouchGround_Tweaks(client);
}

public void Movement_OnStopTouchGround(int client, bool jumped, bool ladderJump, bool jumpbug)
{
	OnStopTouchGround_Tweaks(client, jumped);
}

// Air-acceleration hooks: record velocity before the engine's AirAccelerate, then
// scale that tick's acceleration afterwards if surfing or gstrafing.
public Action Movement_OnAirAcceleratePre(int client, float origin[3], float velocity[3])
{
	OnAirAcceleratePre_Tweaks(client, velocity);
	return Plugin_Continue;
}

public Action Movement_OnAirAcceleratePost(int client, float origin[3], float velocity[3])
{
	return OnAirAcceleratePost_Tweaks(client, velocity);
}


public void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	OnPlayerSpawn_Tweaks(GetClientOfUserId(GetEventInt(event, "userid")));
} 
