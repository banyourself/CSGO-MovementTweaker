#if defined _KevAC_Movement_included
  #endinput
#endif
#define _KevAC_Movement_included

/**
 * Marks a short interval in which a trusted server plugin deliberately changes
 * a player's origin or velocity. KevAC skips only outcome-based movement checks
 * during that interval; it does not exempt command, angle, or cvar detections.
 *
 * This native is optional for callers. Use GetFeatureStatus before calling it.
 */
native void KevAC_IgnoreMovement(int client, int ticks = 2);
