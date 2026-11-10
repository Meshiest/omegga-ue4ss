# UFunction reference (generated)

UFunctions of the classes these docs use, from a UE4SS object dump of
Release-EA3-CL-16507. Regenerate with:

```sh
npm run dumpq -- data/UE4SS/UE4SS_ObjectDump.txt '^(BRLuau[A-Za-z]+Library|BCSLibrary|...)$'
```

Format: `Function(Param: Type @offset, ...)`. `Struct<X>` with no reflected fields (BrickHandle,
BRLuauBuilder, BRLuauPortRef, WireValue, BRLuauTransaction, BrickPersistentHandle,
BREntityPersistentHandle, BCSComponentHandle) must go through `BR.call`; see
[brickadia-internals.md](../brickadia-internals.md). Functions with only reflected types can
be called directly from UE4SS Lua (`obj:Function(...)`). Delegate signatures and client RPCs
are omitted.

## BCSLibrary

- `ApplyChangelist(WorldContextObject: Object<Object> @0, BrickHandle: Struct<BrickHandle> @8, ComponentType: Object<BCSComponentTypeBase> @10, Changelist: Struct<BRPropertyChangelist> @18)`
- `AttachComponent(WorldContextObject: Object<Object> @0, BrickHandle: Struct<BrickHandle> @8, ComponentType: Object<BCSComponentTypeBase> @10, Changelist: Struct<BRPropertyChangelist> @18, bCheckQuota: Bool @28, ReturnValue: Enum<EBCSAttachResult> @29)`
- `DetachComponent(WorldContextObject: Object<Object> @0, BrickHandle: Struct<BrickHandle> @8, ComponentType: Object<BCSComponentTypeBase> @10, ReturnValue: Enum<EBCSDetachResult> @18)`
- `GetAllComponentTypes(WorldContextObject: Object<Object> @0, BrickHandle: Struct<BrickHandle> @8, OutComponentTypes: Array @10)`
- `GetAllRegisteredComponentTypes(WorldContextObject: Object<Object> @0, OutComponentTypes: Array @8, bIncludeTombstones: Bool @18)`
- `GetBrickWorld(BrickHandle: Struct<BrickHandle> @0, ReturnValue: Object<World> @8)`
- `GetComponentType(WorldContextObject: Object<Object> @0, ComponentTypeClass: Class @8, ReturnValue: Object<BCSComponentTypeBase> @10)`
- `GetComponentTypeByName(WorldContextObject: Object<Object> @0, Name: Name @8, ReturnValue: Object<BCSComponentTypeBase> @10)`
- `GetComponentTypeDerivedFrom(WorldContextObject: Object<Object> @0, ComponentTypeClass: Class @8, ReturnValue: Object<BCSComponentTypeBase> @10)`
- `GetNumRegisteredComponentClasses(WorldContextObject: Object<Object> @0, ReturnValue: Int @8)`
- `HasAnyComponents(WorldContextObject: Object<Object> @0, BrickHandle: Struct<BrickHandle> @8, ReturnValue: Bool @10)`
- `HasComponent(WorldContextObject: Object<Object> @0, BrickHandle: Struct<BrickHandle> @8, ComponentType: Object<BCSComponentTypeBase> @10, ReturnValue: Bool @18)`

## BRChatCommandWorldSubsystem

- `CallChatCommand(Caller: Object<BRPlayerController> @0, Command: Name @8, ArgsString: Str @10)`
- `CallChatCommandWithArgs(Context: Struct<BRChatCommandContext> @0, Command: Name @10, Args: Array @18)`
- `ChatCommandExists(Command: Name @0, ReturnValue: Bool @8)`
- `CheckArgumentTypes(Arguments: Array @0, ArgTypesOut: Array @10)`
- `GetChatCommandList(Array: Array @0)`
- `GetChatCommandMetaDataForAllOverloads(Command: Name @0, Array: Array @8)`
- `GetCommandFormatHelpStrings(Command: Name @0, HelpStrings: Array @8)`
- `GetNumOverloadsForCommand(Command: Name @0, ReturnValue: Int @8)`
- `IsChatCommandCallableForAllOverloads(Command: Name @0, Controller: Object<BRPlayerController> @8, Array: Array @10)`
- `ShowHelpStringsForCommand(Command: Name @0, Context: Struct<BRChatCommandContext> @8, bAdvanced: Bool @18)`
- `SplitArguments(Source: Str @0, ArgumentsOut: Array @10)`

## BRGameModeBase

- `AnchorPlayerToTeam(State: Object<BRPlayerState> @0, bAnchored: Bool @8)`
- `FinishRoundWithDraw()`
- `GetCurrentRound(ReturnValue: Int @0)`
- `GetMembersOrderedByLeaderboardValue(ValueName: Name @0, ReturnValue: Array @8)`
- `GetSessionIsRunning(ReturnValue: Bool @0)`
- `GetTeamsOrderedByLeaderboardValue(ValueName: Name @0, bIncludeUnaffiliated: Bool @8, ReturnValue: Array @10)`
- `HandlePlayerReachCheckPoint(TriggeredBy: Object<BRPlayerState> @0, BrickHandle: Struct<BrickHandle> @8)`
- `HandlePlayerReachGoalPoint(TriggeredBy: Object<BRPlayerState> @0, BrickHandle: Struct<BrickHandle> @8)`
- `IsCurrentRoundForcedFinal(ReturnValue: Bool @0)`
- `IsPlayerAnchoredToTeam(State: Object<BRPlayerState> @0, ReturnValue: Bool @8)`
- `MarkCurrentRoundAsFinal()`
- `NewRound(Round: Int @0, bImmediate: Bool @4, TriggeredBy: Object<BRPlayerState> @8)`
- `NextRound(bImmediate: Bool @0)`
- `PlaySound2D(Sound: Object<SoundBase> @0, VolumeMultiplier: Float @8, PitchMultiplier: Float @C, StartTime: Float @10, ConcurrencySettings: Object<SoundConcurrency> @18)`
- `PushChatMessage(Message: Str @0)`
- `PushStatusMessage(Message: Str @0, bFlashIfUnchanged: Bool @10)`
- `ResetGameMode(TriggeredBy: Object<BRPlayerState> @0)`
- `ShouldShowDeathNotification(VictimTeam: Object<BRGameModeTeam> @0, ReturnValue: Bool @8)`
- `WinPlayer(PlayerObject: Interface @0)`
- `WinPlayers(PlayerObjects: Array @0)`
- `WinPlayersAndTeams(PlayerObjects: Array @0, TeamObjects: Array @10)`
- `WinTeam(TeamObject: Interface @0)`
- `WinTeams(TeamObjects: Array @0)`

## BRGameStateBase

- `Ban(BannedId: Struct<BRGuid> @0, Expiry: Struct<DateTime> @10, BannerId: Struct<BRGuid> @18, Reason: Str @28)`
- `CheckBans()`
- `FindClient(Name: Str @0, ReturnValue: Object<BRPlayerController> @10)`
- `FindClientByUserId(ID: Struct<BRGuid> @0, ReturnValue: Object<BRPlayerController> @10)`
- `FindClientState(Name: Str @0, ReturnValue: Object<BRPlayerState> @10)`
- `FindClientStateByUserId(ID: Struct<BRGuid> @0, ReturnValue: Object<BRPlayerState> @10)`
- `FindUserId(Name: Str @0, OutId: Struct<BRGuid> @10, ReturnValue: Bool @20)`
- `GetAllKnownPlayerGuids(inArray: Array @0, ReturnValue: Int @10)`
- `GetAllTeams(ReturnValue: Array @0)`
- `GetBan(ID: Struct<BRGuid> @0, ReturnValue: Struct<Ban> @10)`
- `GetBanList(ReturnValue: Map @0)`
- `GetBrickOwnerData(Index: Int @0, ReturnValue: Struct<BrickOwnerData> @8)`
- `GetBrickOwnerTableSize(ReturnValue: Int @0)`
- `GetBuilderTeam(ReturnValue: Object<BRGameModeTeam> @0)`
- `GetCurrentInviteCode(ReturnValue: Str @0)`
- `GetCustomTeams(ReturnValue: Array @0)`
- `GetDefaultBrickOwnerData(ReturnValue: Struct<BrickOwnerData> @0)`
- `GetLastKnownCustomRoles(ID: Struct<BRGuid> @0, ReturnValue: Array @10)`
- `GetLastKnownDisplayName(ID: Struct<BRGuid> @0, ReturnValue: Str @10)`
- `GetLastKnownHadRole(ID: Struct<BRGuid> @0, RoleId: Str @10, ReturnValue: Bool @20)`
- `GetLastKnownHasPermission(ID: Struct<BRGuid> @0, Permission: Struct<GameplayTag> @10, ReturnValue: Bool @18)`
- `GetLastKnownHighestRole(ID: Struct<BRGuid> @0, ReturnValue: Object<BRPermissionsRole> @10)`
- `GetLastKnownName(ID: Struct<BRGuid> @0, ReturnValue: Str @10)`
- `GetLastKnownNameColor(ID: Struct<BRGuid> @0, ReturnValue: Struct<Color> @10)`
- `GetLastKnownRoles(ID: Struct<BRGuid> @0, ReturnValue: Array @10)`
- `GetLastKnownUserName(ID: Struct<BRGuid> @0, ReturnValue: Str @10)`
- `GetNumTeams(ReturnValue: Int @0)`
- `GetRuleAffectedPlayerStates(ReturnValue: Array @0)`
- `GetTeam(TeamId: Int @0, ReturnValue: Object<BRGameModeTeam> @8)`
- `GetTeamId(Team: Object<BRGameModeTeam> @0, ReturnValue: Int @8)`
- `GetUnaffiliatedTeam(ReturnValue: Object<BRGameModeTeam> @0)`
- `HandleGeneralServerSettingsChanged(SettingsObject: Object<BRGameSettingsBase> @0)`
- `HandleRolesUpdated()`
- `IdBrickOwner_NotPresent(OwnerGuid: Struct<BRGuid> @0, ReturnValue: Int @10)`
- `IdOrRegisterBrickOwner(BrickOwner: Object<BRPlayerController> @0, ReturnValue: Int @8)`
- `IdOrRegisterBrickOwner_NotPresent(BrickOwnerData: Struct<BrickOwnerData> @0, ReturnValue: Int @38)`
- `IsBanned(ID: Struct<BRGuid> @0, ReturnValue: Bool @10)`
- `LoadPlayerData(Target: Object<BRPlayerState> @0)`
- `LoadSavedPlayerDataMapFromJSON()`
- `OnRep_ReplicatedPublicInviteCode()`
- `OnRep_Teams()`
- `RequestNewInviteCode()`
- `SavePlayerData(Target: Object<BRPlayerState> @0)`
- `SaveSavedPlayerDataMapToJSON()`
- `SetHasRoleOffline(ID: Struct<BRGuid> @0, RoleId: Str @10, bGrant: Bool @20, ReturnValue: Bool @21)`
- `ShouldRulesAffectPlayer(PlayerState: Object<BRPlayerState> @0, ReturnValue: Bool @8)`
- `Unban(ID: Struct<BRGuid> @0)`
- `UpdateReplicatedServerData(InviteCode: Str @0)`
- `UpdateReplicatedUserData()`

## BRLuauAssetLibrary

- `GetAssetName(Self: Object<Object> @0, ReturnValue: Struct<WireString> @8)`
- `GetHalfSize(Self: Object<BrickType> @0, ReturnValue: Struct<IntVector> @8)`
- `GetTypeAsset(Self: Object<BrickType> @0, ReturnValue: Object<BrickAsset> @8)`

## BRLuauBrickLibrary

- `ConnectJoint(Self: Struct<BrickHandle> @0, Target: Object<Actor> @8, Attach: Struct<Transform> @10, WorldContextObject: Object<Object> @70, ReturnValue: Bool @78)`
- `DeleteBrick(Self: Struct<BrickHandle> @0, WorldContextObject: Object<Object> @8)`
- `DisconnectJoint(Self: Struct<BrickHandle> @0, WorldContextObject: Object<Object> @8, ReturnValue: Bool @10)`
- `GetAsset(Self: Struct<BrickHandle> @0, ReturnValue: Object<BrickAsset> @8)`
- `GetCollisionChannels(Self: Struct<BrickHandle> @0, ReturnValue: Enum<EBrickCollisionChannels> @8)`
- `GetColor(Self: Struct<BrickHandle> @0, ReturnValue: Struct<Color> @8)`
- `GetComponents(Self: Struct<BrickHandle> @0, WorldContextObject: Object<Object> @8, ReturnValue: Array @10)`
- `GetGrid(Self: Struct<BrickHandle> @0, ReturnValue: Object<BrickGridActor> @8)`
- `GetId(Self: Struct<BrickHandle> @0, ReturnValue: Struct<BrickPersistentHandle> @8)`
- `GetIdBrick(Self: Struct<BrickPersistentHandle> @0, OutBrick: Struct<BrickHandle> @4, ReturnValue: Bool @C)`
- `GetJointTarget(Self: Struct<BrickHandle> @0, WorldContextObject: Object<Object> @8, ReturnValue: Object<Actor> @10)`
- `GetJointTransform(Self: Struct<BrickHandle> @0, OutTransform: Struct<Transform> @8, WorldContextObject: Object<Object> @68, ReturnValue: Bool @70)`
- `GetMaterial(Self: Struct<BrickHandle> @0, ReturnValue: Enum<EBrickMaterial> @8)`
- `GetMaterialAlpha(Self: Struct<BrickHandle> @0, ReturnValue: Byte @8)`
- `GetOrientation(Self: Struct<BrickHandle> @0, ReturnValue: Enum<EBrickOrientation> @8)`
- `GetOriginalOwnerId(Self: Struct<BrickHandle> @0, ReturnValue: Int @8)`
- `GetOwnerId(Self: Struct<BrickHandle> @0, ReturnValue: Int @8)`
- `GetPosition(Self: Struct<BrickHandle> @0, ReturnValue: Struct<IntVector> @8)`
- `GetType(Self: Struct<BrickHandle> @0, ReturnValue: Object<BrickType> @8)`
- `IsIdValid(Self: Struct<BrickPersistentHandle> @0, ReturnValue: Bool @4)`
- `IsValid(Self: Struct<BrickHandle> @0, ReturnValue: Bool @8)`
- `IsVisible(Self: Struct<BrickHandle> @0, ReturnValue: Bool @8)`
- `SetCollisionChannels(Self: Struct<BrickHandle> @0, NewChannels: Enum<EBrickCollisionChannels> @8, WorldContextObject: Object<Object> @10)`
- `SetColor(Self: Struct<BrickHandle> @0, NewColor: Struct<Color> @8, WorldContextObject: Object<Object> @10)`
- `SetMaterial(Self: Struct<BrickHandle> @0, NewMaterial: Enum<EBrickMaterial> @8, WorldContextObject: Object<Object> @10)`
- `SetMaterialAlpha(Self: Struct<BrickHandle> @0, NewMaterialAlpha: Int @8, WorldContextObject: Object<Object> @10)`
- `SetOriginalOwnerId(Self: Struct<BrickHandle> @0, NewOriginalOwnerId: Int @8, WorldContextObject: Object<Object> @10)`
- `SetOwnerId(Self: Struct<BrickHandle> @0, NewOwnerId: Int @8, WorldContextObject: Object<Object> @10)`
- `SetVisible(Self: Struct<BrickHandle> @0, bNewVisible: Bool @8, WorldContextObject: Object<Object> @10)`
- `TryMove(Self: Struct<BrickHandle> @0, NewPosition: Struct<IntVector> @8, WorldContextObject: Object<Object> @18, ReturnValue: Bool @20)`
- `TryMoveAndReorient(Self: Struct<BrickHandle> @0, NewPosition: Struct<IntVector> @8, NewOrientation: Enum<EBrickOrientation> @14, WorldContextObject: Object<Object> @18, ReturnValue: Bool @20)`
- `TryReorient(Self: Struct<BrickHandle> @0, NewOrientation: Enum<EBrickOrientation> @8, WorldContextObject: Object<Object> @10, ReturnValue: Bool @18)`
- `TryResize(Self: Struct<BrickHandle> @0, NewSize: Struct<IntVector> @8, NewPosition: Struct<IntVector> @14, WorldContextObject: Object<Object> @20, ReturnValue: Bool @28)`

## BRLuauBuilderLibrary

- `FromBrick(Brick: Struct<BrickHandle> @0, ReturnValue: Struct<BRLuauBuilder> @8)`
- `GetAsset(Self: Struct<BRLuauBuilder> @0, ReturnValue: Object<BrickAsset> @38)`
- `GetCollision(Self: Struct<BRLuauBuilder> @0, ReturnValue: Enum<EBrickCollisionChannels> @38)`
- `GetColor(Self: Struct<BRLuauBuilder> @0, ReturnValue: Struct<Color> @38)`
- `GetGrid(Self: Struct<BRLuauBuilder> @0, ReturnValue: Object<BrickGridActor> @38)`
- `GetMaterial(Self: Struct<BRLuauBuilder> @0, ReturnValue: Enum<EBrickMaterial> @38)`
- `GetMaterialAlpha(Self: Struct<BRLuauBuilder> @0, ReturnValue: Int @38)`
- `GetOwnerId(Self: Struct<BRLuauBuilder> @0, ReturnValue: Int @38)`
- `GetSize(Self: Struct<BRLuauBuilder> @0, OutSize: Struct<IntVector> @38, ReturnValue: Bool @44)`
- `GetType(Self: Struct<BRLuauBuilder> @0, ReturnValue: Object<BrickType> @38)`
- `GetVisible(Self: Struct<BRLuauBuilder> @0, ReturnValue: Bool @38)`
- `Place(Self: Struct<BRLuauBuilder> @0, Position: Struct<IntVector> @38, Orientation: Enum<EBrickOrientation> @44, OutBrick: Struct<BrickHandle> @48, WorldContextObject: Object<Object> @50, ReturnValue: Bool @58)`
- `SetAsset(Self: Struct<BRLuauBuilder> @0, NewAsset: Object<BrickAsset> @38)`
- `SetCollision(Self: Struct<BRLuauBuilder> @0, NewChannels: Enum<EBrickCollisionChannels> @38)`
- `SetColor(Self: Struct<BRLuauBuilder> @0, NewColor: Struct<Color> @38)`
- `SetGrid(Self: Struct<BRLuauBuilder> @0, NewGrid: Object<BrickGridActor> @38)`
- `SetMaterial(Self: Struct<BRLuauBuilder> @0, NewMaterial: Enum<EBrickMaterial> @38, WorldContextObject: Object<Object> @40)`
- `SetMaterialAlpha(Self: Struct<BRLuauBuilder> @0, NewMaterialAlpha: Int @38)`
- `SetOwnerId(Self: Struct<BRLuauBuilder> @0, NewOwnerId: Int @38, WorldContextObject: Object<Object> @40)`
- `SetSize(Self: Struct<BRLuauBuilder> @0, NewSize: Struct<IntVector> @38)`
- `SetVisible(Self: Struct<BRLuauBuilder> @0, bNewVisible: Bool @38)`

## BRLuauColorLibrary

- `ColorFromHex(Hex: Str @0, ReturnValue: Struct<Color> @10)`
- `ColorLerp(Self: Struct<Color> @0, Other: Struct<Color> @4, Alpha: Double @8, ReturnValue: Struct<Color> @10)`
- `ColorToHex(Self: Struct<Color> @0, ReturnValue: Str @8)`
- `ColorToLinear(Self: Struct<Color> @0, ReturnValue: Struct<LinearColor> @4)`
- `ColorToLinearRaw(Self: Struct<Color> @0, ReturnValue: Struct<LinearColor> @4)`
- `ColorWithAlpha(Self: Struct<Color> @0, Alpha: Byte @4, ReturnValue: Struct<Color> @8)`

## BRLuauComponentLibrary

- `Attach(Self: Object<BCSComponentTypeBase> @0, Brick: Struct<BrickHandle> @8, OutComponent: Struct<BCSComponentHandle> @10, WorldContextObject: Object<Object> @18, ReturnValue: Bool @20)`
- `Connect(Self: Struct<BCSComponentHandle> @0, Output: Struct<BRLuauPortRef> @8, Target: Struct<BCSComponentHandle> @10, Input: Struct<BRLuauPortRef> @18, WorldContextObject: Object<Object> @20, ReturnValue: Bool @28)`
- `Detach(Self: Struct<BCSComponentHandle> @0, WorldContextObject: Object<Object> @8, ReturnValue: Bool @10)`
- `Disconnect(Self: Struct<BCSComponentHandle> @0, Output: Struct<BRLuauPortRef> @8, Target: Struct<BCSComponentHandle> @10, Input: Struct<BRLuauPortRef> @18, WorldContextObject: Object<Object> @20, ReturnValue: Bool @28)`
- `Get(Self: Object<BCSComponentTypeBase> @0, Brick: Struct<BrickHandle> @8, OutComponent: Struct<BCSComponentHandle> @10, ReturnValue: Bool @18)`
- `GetBrick(Self: Struct<BCSComponentHandle> @0, ReturnValue: Struct<BrickHandle> @8)`
- `GetInputWires(Self: Struct<BCSComponentHandle> @0, WorldContextObject: Object<Object> @8, ReturnValue: Array @10)`
- `GetOutputWires(Self: Struct<BCSComponentHandle> @0, WorldContextObject: Object<Object> @8, ReturnValue: Array @10)`
- `GetPortName(Self: Struct<BRLuauPortRef> @0, ReturnValue: Str @8)`
- `GetType(Self: Struct<BCSComponentHandle> @0, ReturnValue: Object<BCSComponentTypeBase> @8)`
- `IsAlive(Self: Struct<BCSComponentHandle> @0, ReturnValue: Bool @8)`
- `IsPortOutput(Self: Struct<BRLuauPortRef> @0, ReturnValue: Bool @8)`

## BRLuauEntityLibrary

- `DeleteEntity(Self: Object<Actor> @0, ReturnValue: Bool @8)`
- `GetFrozen(Self: Object<Actor> @0, ReturnValue: Bool @8)`
- `GetId(Self: Object<Actor> @0, WorldContextObject: Object<Object> @8, ReturnValue: Struct<BREntityPersistentHandle> @10)`
- `GetIdEntity(Self: Struct<BREntityPersistentHandle> @0, WorldContextObject: Object<Object> @8, ReturnValue: Object<Actor> @10)`
- `GetOriginalOwnerId(Self: Object<Actor> @0, ReturnValue: Int @8)`
- `GetOwnerId(Self: Object<Actor> @0, ReturnValue: Int @8)`
- `GetProjectileInstigator(Self: Object<BRWeaponProjectile> @0, ReturnValue: Object<BRPlayerState> @8)`
- `GetTransform(Self: Object<Actor> @0, ReturnValue: Struct<Transform> @8)`
- `GetVelocity(Self: Object<Actor> @0, ReturnValue: Struct<Vector> @8)`
- `GetVisible(Self: Object<Actor> @0, ReturnValue: Bool @8)`
- `IsIdValid(Self: Struct<BREntityPersistentHandle> @0, WorldContextObject: Object<Object> @8, ReturnValue: Bool @10)`
- `IsObjectValid(Self: Object<Object> @0, ReturnValue: Bool @8)`
- `SetEntityColor(Self: Object<Actor> @0, Slot: Int @8, Color: Struct<Color> @C, ReturnValue: Bool @10)`
- `SetFrozen(Self: Object<Actor> @0, bNewFrozen: Bool @8, ReturnValue: Bool @9)`
- `SetTransform(Self: Object<Actor> @0, NewTransform: Struct<Transform> @8, ReturnValue: Bool @68)`
- `SetVisible(Self: Object<Actor> @0, bNewVisible: Bool @8, ReturnValue: Bool @9)`
- `ToLocal(Self: Object<Actor> @0, Position: Struct<Vector> @8, ReturnValue: Struct<Vector> @20)`
- `ToLocalVector(Self: Object<Actor> @0, Vector: Struct<Vector> @8, ReturnValue: Struct<Vector> @20)`
- `ToWorld(Self: Object<Actor> @0, Position: Struct<Vector> @8, ReturnValue: Struct<Vector> @20)`
- `ToWorldVector(Self: Object<Actor> @0, Vector: Struct<Vector> @8, ReturnValue: Struct<Vector> @20)`

## BRLuauEnvironmentLibrary

- `FindAmbienceType(Name: Str @0, ReturnValue: Class @10)`
- `FindSpaceTexture(Name: Str @0, ReturnValue: Object<BRSpaceTextureData> @10)`
- `GetAmbience(WorldContextObject: Object<Object> @0, ReturnValue: Object<BRAmbienceEnvironment> @8)`
- `GetGround(WorldContextObject: Object<Object> @0, ReturnValue: Object<BRGroundEnvironment> @8)`
- `GetSky(WorldContextObject: Object<Object> @0, ReturnValue: Object<BRSkyEnvironment> @8)`
- `GetSpace(WorldContextObject: Object<Object> @0, ReturnValue: Object<BRSpaceEnvironment> @8)`
- `GetStudio(WorldContextObject: Object<Object> @0, ReturnValue: Object<BRStudioEnvironment> @8)`
- `GetWater(WorldContextObject: Object<Object> @0, ReturnValue: Object<BRWaterEnvironment> @8)`

## BRLuauGridLibrary

- `AnyInBox(Self: Object<BrickGridActor> @0, Min: Struct<IntVector> @8, Max: Struct<IntVector> @14, ReturnValue: Bool @20)`
- `AnyInSphere(Self: Object<BrickGridActor> @0, Center: Struct<Vector> @8, Radius: Double @20, ReturnValue: Bool @28)`
- `FindInBox(Self: Object<BrickGridActor> @0, Min: Struct<IntVector> @8, Max: Struct<IntVector> @14, OutBrick: Struct<BrickHandle> @20, ReturnValue: Bool @28)`
- `FindInSphere(Self: Object<BrickGridActor> @0, Center: Struct<Vector> @8, Radius: Double @20, OutBrick: Struct<BrickHandle> @28, ReturnValue: Bool @30)`
- `GetBricks(Self: Object<BrickGridActor> @0, ReturnValue: Array @8)`
- `GetCount(Self: Object<BrickGridActor> @0, ReturnValue: Int @8)`
- `InBox(Self: Object<BrickGridActor> @0, Min: Struct<IntVector> @8, Max: Struct<IntVector> @14, MaxResults: Int @20, ReturnValue: Array @28)`
- `InSphere(Self: Object<BrickGridActor> @0, Center: Struct<Vector> @8, Radius: Double @20, MaxResults: Int @28, ReturnValue: Array @30)`
- `Raycast(Self: Object<BrickGridActor> @0, Origin: Struct<Vector> @8, Direction: Struct<Vector> @20, OutHit: Struct<BRLuauGridHit> @38, MaxDistance: Double @78, Channels: Enum<EBrickCollisionChannels> @80, ReturnValue: Bool @81)`
- `Sweep(Self: Object<BrickGridActor> @0, Origin: Struct<Vector> @8, Direction: Struct<Vector> @20, Radius: Double @38, OutHit: Struct<BRLuauGridHit> @40, MaxDistance: Double @80, Channels: Enum<EBrickCollisionChannels> @88, ReturnValue: Bool @89)`

## BRLuauLinearColorLibrary

- `LinearColorClamp(Self: Struct<LinearColor> @0, Min: Float @10, Max: Float @14, ReturnValue: Struct<LinearColor> @18)`
- `LinearColorDesaturate(Self: Struct<LinearColor> @0, Amount: Float @10, ReturnValue: Struct<LinearColor> @14)`
- `LinearColorDistance(Self: Struct<LinearColor> @0, Other: Struct<LinearColor> @10, ReturnValue: Float @20)`
- `LinearColorEquals(Self: Struct<LinearColor> @0, Other: Struct<LinearColor> @10, Tolerance: Float @20, ReturnValue: Bool @24)`
- `LinearColorFromHSV(Hue: Float @0, Saturation: Float @4, Value: Float @8, Alpha: Float @C, ReturnValue: Struct<LinearColor> @10)`
- `LinearColorFromHex(Hex: Str @0, ReturnValue: Struct<LinearColor> @10)`
- `LinearColorHsvToRgb(Self: Struct<LinearColor> @0, ReturnValue: Struct<LinearColor> @10)`
- `LinearColorIsAlmostBlack(Self: Struct<LinearColor> @0, ReturnValue: Bool @10)`
- `LinearColorLerp(Self: Struct<LinearColor> @0, Other: Struct<LinearColor> @10, Alpha: Float @20, ReturnValue: Struct<LinearColor> @24)`
- `LinearColorLerpHSV(Self: Struct<LinearColor> @0, Other: Struct<LinearColor> @10, Alpha: Float @20, ReturnValue: Struct<LinearColor> @24)`
- `LinearColorLerpOklab(Self: Struct<LinearColor> @0, Other: Struct<LinearColor> @10, Alpha: Float @20, ReturnValue: Struct<LinearColor> @24)`
- `LinearColorLuminance(Self: Struct<LinearColor> @0, ReturnValue: Float @10)`
- `LinearColorMaximum(Self: Struct<LinearColor> @0, ReturnValue: Float @10)`
- `LinearColorMinimum(Self: Struct<LinearColor> @0, ReturnValue: Float @10)`
- `LinearColorOklabToRgb(Self: Struct<LinearColor> @0, ReturnValue: Struct<LinearColor> @10)`
- `LinearColorRgbToHsv(Self: Struct<LinearColor> @0, ReturnValue: Struct<LinearColor> @10)`
- `LinearColorRgbToOklab(Self: Struct<LinearColor> @0, ReturnValue: Struct<LinearColor> @10)`
- `LinearColorToColor(Self: Struct<LinearColor> @0, SRGB: Bool @10, ReturnValue: Struct<Color> @14)`
- `LinearColorToHex(Self: Struct<LinearColor> @0, SRGB: Bool @10, ReturnValue: Str @18)`
- `LinearColorWithAlpha(Self: Struct<LinearColor> @0, Alpha: Float @10, ReturnValue: Struct<LinearColor> @14)`

## BRLuauPlayerLibrary

- `GetPlayerDisplayName(Self: Object<BRCharacter> @0, ReturnValue: Str @8)`
- `GetPlayerState(Self: Object<BRCharacter> @0, ReturnValue: Object<BRPlayerState> @8)`
- `GetPlayerUserName(Self: Object<BRCharacter> @0, ReturnValue: Str @8)`
- `GetStateDisplayName(Self: Object<BRPlayerState> @0, ReturnValue: Str @8)`
- `GetStatePlayer(Self: Object<BRPlayerState> @0, ReturnValue: Object<BRCharacter> @8)`
- `GetStateTeam(Self: Object<BRPlayerState> @0, ReturnValue: Object<BRGameModeTeam> @8)`
- `GetStateUserName(Self: Object<BRPlayerState> @0, ReturnValue: Str @8)`
- `GetTeamColor(Self: Object<BRGameModeTeam> @0, ReturnValue: Struct<Color> @8)`
- `GetTeamMembers(Self: Object<BRGameModeTeam> @0, ReturnValue: Array @8)`
- `GetTeamName(Self: Object<BRGameModeTeam> @0, ReturnValue: Str @8)`

## BRLuauQuatLibrary

- `QuatAngle(Self: Struct<Quat> @0, ReturnValue: Double @20)`
- `QuatAngularDistance(Self: Struct<Quat> @0, Other: Struct<Quat> @20, ReturnValue: Double @40)`
- `QuatAxis(Self: Struct<Quat> @0, ReturnValue: Struct<Vector> @20)`
- `QuatDot(Self: Struct<Quat> @0, Other: Struct<Quat> @20, ReturnValue: Double @40)`
- `QuatEquals(Self: Struct<Quat> @0, Other: Struct<Quat> @20, Tolerance: Double @40, ReturnValue: Bool @48)`
- `QuatEuler(Self: Struct<Quat> @0, ReturnValue: Struct<Vector> @20)`
- `QuatExp(Self: Struct<Quat> @0, ReturnValue: Struct<Quat> @20)`
- `QuatForward(Self: Struct<Quat> @0, ReturnValue: Struct<Vector> @20)`
- `QuatFromAxisAngle(Axis: Struct<Vector> @0, Angle: Double @18, ReturnValue: Struct<Quat> @20)`
- `QuatFromTo(From: Struct<Vector> @0, To: Struct<Vector> @18, ReturnValue: Struct<Quat> @30)`
- `QuatInverse(Self: Struct<Quat> @0, ReturnValue: Struct<Quat> @20)`
- `QuatIsIdentity(Self: Struct<Quat> @0, Tolerance: Double @20, ReturnValue: Bool @28)`
- `QuatIsNormalized(Self: Struct<Quat> @0, ReturnValue: Bool @20)`
- `QuatLength(Self: Struct<Quat> @0, ReturnValue: Double @20)`
- `QuatLengthSquared(Self: Struct<Quat> @0, ReturnValue: Double @20)`
- `QuatLog(Self: Struct<Quat> @0, ReturnValue: Struct<Quat> @20)`
- `QuatNormalized(Self: Struct<Quat> @0, Tolerance: Double @20, ReturnValue: Struct<Quat> @28)`
- `QuatRight(Self: Struct<Quat> @0, ReturnValue: Struct<Vector> @20)`
- `QuatRotate(Self: Struct<Quat> @0, Vector: Struct<Vector> @20, ReturnValue: Struct<Vector> @38)`
- `QuatRotationVector(Self: Struct<Quat> @0, ReturnValue: Struct<Vector> @20)`
- `QuatRotator(Self: Struct<Quat> @0, ReturnValue: Struct<Rotator> @20)`
- `QuatShortestArc(Self: Struct<Quat> @0, Other: Struct<Quat> @20, ReturnValue: Struct<Quat> @40)`
- `QuatSlerp(Self: Struct<Quat> @0, Other: Struct<Quat> @20, Alpha: Double @40, ReturnValue: Struct<Quat> @48)`
- `QuatSlerpFullPath(Self: Struct<Quat> @0, Other: Struct<Quat> @20, Alpha: Double @40, ReturnValue: Struct<Quat> @48)`
- `QuatTwistAngle(Self: Struct<Quat> @0, Axis: Struct<Vector> @20, ReturnValue: Double @38)`
- `QuatUnrotate(Self: Struct<Quat> @0, Vector: Struct<Vector> @20, ReturnValue: Struct<Vector> @38)`
- `QuatUp(Self: Struct<Quat> @0, ReturnValue: Struct<Vector> @20)`

## BRLuauRotatorLibrary

- `RotatorClamp(Self: Struct<Rotator> @0, ReturnValue: Struct<Rotator> @18)`
- `RotatorEquals(Self: Struct<Rotator> @0, Other: Struct<Rotator> @18, Tolerance: Double @30, ReturnValue: Bool @38)`
- `RotatorEqualsOrientation(Self: Struct<Rotator> @0, Other: Struct<Rotator> @18, Tolerance: Double @30, ReturnValue: Bool @38)`
- `RotatorEuler(Self: Struct<Rotator> @0, ReturnValue: Struct<Vector> @18)`
- `RotatorForward(Self: Struct<Rotator> @0, ReturnValue: Struct<Vector> @18)`
- `RotatorFromDirection(Direction: Struct<Vector> @0, ReturnValue: Struct<Rotator> @18)`
- `RotatorInverse(Self: Struct<Rotator> @0, ReturnValue: Struct<Rotator> @18)`
- `RotatorIsNearlyZero(Self: Struct<Rotator> @0, Tolerance: Double @18, ReturnValue: Bool @20)`
- `RotatorLerp(Self: Struct<Rotator> @0, Other: Struct<Rotator> @18, Alpha: Double @30, ReturnValue: Struct<Rotator> @38)`
- `RotatorLerpFullPath(Self: Struct<Rotator> @0, Other: Struct<Rotator> @18, Alpha: Double @30, ReturnValue: Struct<Rotator> @38)`
- `RotatorNormalized(Self: Struct<Rotator> @0, ReturnValue: Struct<Rotator> @18)`
- `RotatorQuat(Self: Struct<Rotator> @0, ReturnValue: Struct<Quat> @18)`
- `RotatorRight(Self: Struct<Rotator> @0, ReturnValue: Struct<Vector> @18)`
- `RotatorRotate(Self: Struct<Rotator> @0, Vector: Struct<Vector> @18, ReturnValue: Struct<Vector> @30)`
- `RotatorUnrotate(Self: Struct<Rotator> @0, Vector: Struct<Vector> @18, ReturnValue: Struct<Vector> @30)`
- `RotatorUp(Self: Struct<Rotator> @0, ReturnValue: Struct<Vector> @18)`

## BRLuauTransactionLibrary

- `Execute(Self: Struct<BRLuauTransaction> @0, Player: Object<BRPlayerState> @30, ReturnValue: Struct<BrickTransactionReport> @38)`
- `RecordAttach(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, Type: Object<BCSComponentTypeBase> @38)`
- `RecordConnect(Self: Struct<BRLuauTransaction> @0, SourceId: Struct<BrickPersistentHandle> @30, Output: Struct<BRLuauPortRef> @34, TargetId: Struct<BrickPersistentHandle> @3C, Input: Struct<BRLuauPortRef> @40)`
- `RecordConnectJoint(Self: Struct<BRLuauTransaction> @0, JointId: Struct<BrickPersistentHandle> @30, EntityID: Struct<BREntityPersistentHandle> @34, Attach: Struct<Transform> @38)`
- `RecordDelete(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30)`
- `RecordDeleteEntity(Self: Struct<BRLuauTransaction> @0, ID: Struct<BREntityPersistentHandle> @30)`
- `RecordDetach(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, Type: Object<BCSComponentTypeBase> @38)`
- `RecordDisconnect(Self: Struct<BRLuauTransaction> @0, SourceId: Struct<BrickPersistentHandle> @30, Output: Struct<BRLuauPortRef> @34, TargetId: Struct<BrickPersistentHandle> @3C, Input: Struct<BRLuauPortRef> @40)`
- `RecordDisconnectJoint(Self: Struct<BRLuauTransaction> @0, JointId: Struct<BrickPersistentHandle> @30, EntityID: Struct<BREntityPersistentHandle> @34)`
- `RecordMove(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, NewPosition: Struct<IntVector> @34, NewOrientation: Enum<EBrickOrientation> @40)`
- `RecordMoveEntity(Self: Struct<BRLuauTransaction> @0, ID: Struct<BREntityPersistentHandle> @30, NewTransform: Struct<Transform> @38)`
- `RecordPlace(Self: Struct<BRLuauTransaction> @0, Builder: Struct<BRLuauBuilder> @30, Position: Struct<IntVector> @68, Orientation: Enum<EBrickOrientation> @74, WorldContextObject: Object<Object> @78, GridId: Struct<BREntityPersistentHandle> @80, ReturnValue: Struct<BrickPersistentHandle> @84)`
- `RecordPlaceEntity(Self: Struct<BRLuauTransaction> @0, WorldContextObject: Object<Object> @30, Type: Class @38, Transform: Struct<Transform> @40, bFrozen: Bool @A0, OwnerId: Int @A4, Colors: Array @A8, ReturnValue: Struct<BREntityPersistentHandle> @B8)`
- `RecordReorient(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, NewOrientation: Enum<EBrickOrientation> @34)`
- `RecordResize(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, NewSize: Struct<IntVector> @34, NewPosition: Struct<IntVector> @40)`
- `RecordRestore(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, Builder: Struct<BRLuauBuilder> @34, Position: Struct<IntVector> @6C, Orientation: Enum<EBrickOrientation> @78, WorldContextObject: Object<Object> @80, GridId: Struct<BREntityPersistentHandle> @88)`
- `RecordSet(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, Port: Struct<BRLuauPortRef> @34, Value: Struct<WireValue> @40)`
- `RecordSetCollision(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, NewChannels: Enum<EBrickCollisionChannels> @34)`
- `RecordSetColor(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, NewColor: Struct<Color> @34)`
- `RecordSetColorAndMaterial(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, NewColor: Struct<Color> @34, NewMaterial: Enum<EBrickMaterial> @38, NewMaterialAlpha: Int @3C)`
- `RecordSetEntityColor(Self: Struct<BRLuauTransaction> @0, ID: Struct<BREntityPersistentHandle> @30, Slot: Int @34, NewColor: Struct<Color> @38)`
- `RecordSetMaterial(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, NewMaterial: Enum<EBrickMaterial> @34, NewMaterialAlpha: Int @38)`
- `RecordSetOwner(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, NewOwner: Object<BRPlayerState> @38, WorldContextObject: Object<Object> @40)`
- `RecordSetPhysicsEnabled(Self: Struct<BRLuauTransaction> @0, ID: Struct<BREntityPersistentHandle> @30, bEnabled: Bool @34)`
- `RecordSetVisibility(Self: Struct<BRLuauTransaction> @0, ID: Struct<BrickPersistentHandle> @30, bNewVisible: Bool @34)`
- `Redo(Self: Object<BRPlayerState> @0, ReturnValue: Bool @8)`
- `Undo(Self: Object<BRPlayerState> @0, ReturnValue: Bool @8)`

## BRLuauTransformLibrary

- `TransformBlend(Self: Struct<Transform> @0, Other: Struct<Transform> @60, Alpha: Double @C0, ReturnValue: Struct<Transform> @C8)`
- `TransformDeterminant(Self: Struct<Transform> @0, ReturnValue: Double @60)`
- `TransformEquals(Self: Struct<Transform> @0, Other: Struct<Transform> @60, Tolerance: Double @C0, ReturnValue: Bool @C8)`
- `TransformForward(Self: Struct<Transform> @0, ReturnValue: Struct<Vector> @60)`
- `TransformInverse(Self: Struct<Transform> @0, ReturnValue: Struct<Transform> @60)`
- `TransformInversePosition(Self: Struct<Transform> @0, Position: Struct<Vector> @60, ReturnValue: Struct<Vector> @78)`
- `TransformInversePositionNoScale(Self: Struct<Transform> @0, Position: Struct<Vector> @60, ReturnValue: Struct<Vector> @78)`
- `TransformInverseRotation(Self: Struct<Transform> @0, Rotation: Struct<Quat> @60, ReturnValue: Struct<Quat> @80)`
- `TransformInverseVector(Self: Struct<Transform> @0, Vector: Struct<Vector> @60, ReturnValue: Struct<Vector> @78)`
- `TransformInverseVectorNoScale(Self: Struct<Transform> @0, Vector: Struct<Vector> @60, ReturnValue: Struct<Vector> @78)`
- `TransformMaximumAxisScale(Self: Struct<Transform> @0, ReturnValue: Double @60)`
- `TransformMinimumAxisScale(Self: Struct<Transform> @0, ReturnValue: Double @60)`
- `TransformPosition(Self: Struct<Transform> @0, Position: Struct<Vector> @60, ReturnValue: Struct<Vector> @78)`
- `TransformPositionNoScale(Self: Struct<Transform> @0, Position: Struct<Vector> @60, ReturnValue: Struct<Vector> @78)`
- `TransformRelativeTo(Self: Struct<Transform> @0, Other: Struct<Transform> @60, ReturnValue: Struct<Transform> @C0)`
- `TransformRelativeToReverse(Self: Struct<Transform> @0, Other: Struct<Transform> @60, ReturnValue: Struct<Transform> @C0)`
- `TransformRight(Self: Struct<Transform> @0, ReturnValue: Struct<Vector> @60)`
- `TransformRotation(Self: Struct<Transform> @0, Rotation: Struct<Quat> @60, ReturnValue: Struct<Quat> @80)`
- `TransformRotator(Self: Struct<Transform> @0, ReturnValue: Struct<Rotator> @60)`
- `TransformUp(Self: Struct<Transform> @0, ReturnValue: Struct<Vector> @60)`
- `TransformVector(Self: Struct<Transform> @0, Vector: Struct<Vector> @60, ReturnValue: Struct<Vector> @78)`
- `TransformVectorNoScale(Self: Struct<Transform> @0, Vector: Struct<Vector> @60, ReturnValue: Struct<Vector> @78)`

## BRLuauWorldLibrary

- `Explode(WorldContextObject: Object<Object> @0, ExplosionClass: Str @8, Location: Struct<Vector> @18, Normal: Struct<Vector> @30, Scale: Struct<Vector> @48, DamageMultiplier: Double @60, bSpawnProjectiles: Bool @68, ReturnValue: Bool @69)`
- `FindAsset(Name: Str @0, ReturnValue: Object<BrickAsset> @10)`
- `FindEntityType(Name: Str @0, WorldContextObject: Object<Object> @10, ReturnValue: Class @18)`
- `GetEntities(WorldContextObject: Object<Object> @0, ReturnValue: Array @8)`
- `GetGlobalGrid(WorldContextObject: Object<Object> @0, ReturnValue: Object<BrickGridActor> @8)`
- `GetGrids(WorldContextObject: Object<Object> @0, ReturnValue: Array @8)`
- `GetPlayers(WorldContextObject: Object<Object> @0, ReturnValue: Array @8)`
- `OverlapBox(Center: Struct<Vector> @0, Extent: Struct<Vector> @18, WorldContextObject: Object<Object> @30, Channel: Enum<EBRLuauTraceChannel> @38, Targets: Enum<EBRLuauTraceTargets> @3C, bComplex: Bool @40, ReturnValue: Array @48)`
- `OverlapSphere(Center: Struct<Vector> @0, Radius: Double @18, WorldContextObject: Object<Object> @20, Channel: Enum<EBRLuauTraceChannel> @28, Targets: Enum<EBRLuauTraceTargets> @2C, bComplex: Bool @30, ReturnValue: Array @38)`
- `Raycast(Origin: Struct<Vector> @0, Direction: Struct<Vector> @18, OutHit: Struct<BRLuauTraceHit> @30, WorldContextObject: Object<Object> @78, MaxDistance: Double @80, Channel: Enum<EBRLuauTraceChannel> @88, Targets: Enum<EBRLuauTraceTargets> @8C, bComplex: Bool @90, ReturnValue: Bool @91)`
- `SpawnEntity(WorldContextObject: Object<Object> @0, Type: Class @8, Transform: Struct<Transform> @10, bFrozen: Bool @70, OwnerId: Int @74, Colors: Array @78, ReturnValue: Object<Actor> @88)`
- `Sweep(Origin: Struct<Vector> @0, Direction: Struct<Vector> @18, Radius: Double @30, OutHit: Struct<BRLuauTraceHit> @38, WorldContextObject: Object<Object> @80, MaxDistance: Double @88, Channel: Enum<EBRLuauTraceChannel> @90, Targets: Enum<EBRLuauTraceTargets> @94, bComplex: Bool @98, ReturnValue: Bool @99)`

## BRPermissionsManager

- `CreateOrGetPermissionsRole(RoleName: Str @0, RoleNameToCreateAfter: Str @10, ReturnValue: Object<BRPermissionsRole> @20)`
- `DestroyPermissionsRole(RoleName: Str @0, ReturnValue: Bool @10)`
- `Get(WorldContext: Object<Object> @0, ReturnValue: Object<BRPermissionsManager> @8)`
- `GetAllPermissionsRoles(ReturnValue: Array @0)`
- `GetCustomPermissionsRoles(ReturnValue: Array @0)`
- `GetDefaultPermissionsRole(ReturnValue: Object<BRPermissionsRole> @0)`
- `GetOwnerPermissionsRole(ReturnValue: Object<BRPermissionsRole> @0)`
- `GetPermissionsRole(RoleName: Str @0, ReturnValue: Object<BRPermissionsRole> @10)`
- `HandleRoleListChanged()`
- `HandleUpdated()`
- `LoadJSON(Path: Str @0, LegacyPath: Str @10)`
- `ReorderPermissionsRoles(RoleId: Str @0, RoleIdToPutAfter: Str @10, ReturnValue: Bool @20)`
- `SaveJSON(Path: Str @0)`

## BRPlayerController

- `CheckBrickPermission(Brick: Struct<BrickHandle> @0, Permission: Struct<GameplayTag> @8, NoPermissionMessage: Text @10, NoTrustMessage: Text @20, bMessageUnreliable: Bool @30, ReturnValue: Bool @31)`
- `CheckEntityPermission(Entity: Object<Actor> @0, Permission: Struct<GameplayTag> @8, NoPermissionMessage: Text @10, NoTrustMessage: Text @20, bMessageUnreliable: Bool @30, ReturnValue: Bool @31)`
- `CheckPermission(Permission: Struct<GameplayTag> @0, NoPermissionMessage: Text @8, bMessageUnreliable: Bool @18, ReturnValue: Bool @19)`
- `ClearCheckPoint()`
- `DoRedo(bButtonPressed: Bool @0)`
- `DoUndo(bButtonPressed: Bool @0)`
- `GetActorsThisControllerCanSpectate(ReturnValue: Array @0)`
- `GetBRPlayerInput(ReturnValue: Object<BRPlayerInput> @0)`
- `GetBRPlayerState(ReturnValue: Object<BRPlayerState> @0)`
- `GetCannotRespawn(ReturnValue: Bool @0)`
- `GetCheckPoint(ReturnValue: Struct<BrickHandle> @0)`
- `GetDirectGamepadBindingNames(InputName: Name @0, ReturnValue: Array @8)`
- `GetFreezeCamera(ReturnValue: Bool @0)`
- `GetGameTypeAddedComponent(Index: Int @0, ReturnValue: Object<ActorComponent> @8)`
- `GetGravityRelativeRotation(Rotation: Struct<Rotator> @0, GravityDirection: Struct<Vector> @18, ReturnValue: Struct<Rotator> @30)`
- `GetGravityWorldRotation(Rotation: Struct<Rotator> @0, GravityDirection: Struct<Vector> @18, ReturnValue: Struct<Rotator> @30)`
- `GetIsSpectator(ReturnValue: Bool @0)`
- `GetSubscribedBrick(ReturnValue: Struct<BrickHandle> @0)`
- `GetZoomLevel(ReturnValue: Float @0)`
- `HandlePossessedPawnTakePointDamage(DamagedActor: Object<Actor> @0, Damage: Float @8, InstigatedBy: Object<Controller> @10, HitLocation: Struct<Vector> @18, HitComponent: Object<PrimitiveComponent> @30, BoneName: Name @38, ShotFromDirection: Struct<Vector> @40, DamageType: Object<DamageType> @58, DamageCauser: Object<Actor> @60)`
- `HandlePossessedPawnTakeRadialDamage(DamagedActor: Object<Actor> @0, Damage: Float @8, DamageType: Object<DamageType> @10, Origin: Struct<Vector> @18, HitInfo: Struct<HitResult> @30, InstigatedBy: Object<Controller> @120, DamageCauser: Object<Actor> @128)`
- `HandleWireMessageBoxAccepted()`
- `HandleWireMessageBoxDeclined()`
- `HasLivingCharacter(ReturnValue: Bool @0)`
- `IsActuallyTrustedBy(OtherUserId: Struct<BRGuid> @0, bForSharedObject: Bool @10, bCanEditPublic: Bool @11, ReturnValue: Bool @12)`
- `IsTrustedBy(OtherUserId: Struct<BRGuid> @0, bForSharedObject: Bool @10, ReturnValue: Bool @11)`
- `IsTrustedByEveryone(ReturnValue: Bool @0)`
- `IsUsingGamepad(ReturnValue: Bool @0)`
- `IsZooming(ReturnValue: Bool @0)`
- `JoinGameModeTeam(TeamId: Int @0, bRespawn: Bool @4, bMessage: Bool @5)`
- `LocalInstigatedAccumulatedDamage(Damage: Float @0, bContainsHeadshot: Bool @4, bContainsKill: Bool @5, bContainsBlocked: Bool @6)`
- `LocalReceivedAccumulatedDamage(Damage: Float @0, bContainsHeadshot: Bool @4, Direction: Struct<Vector> @8)`
- `NotifyCameraEnterWater()`
- `NotifyCameraExitWater()`
- `OnClearSelectionPressed()`
- `OnFreeMousePressed()`
- `OnGamepadKeyPressed(Key: Struct<Key> @0)`
- `OnGamepadKeyReleased(Key: Struct<Key> @0)`
- `OnHideHUDPressed()`
- `OnPasteSelectionPressed()`
- `OnPasteWithOwnershipPressed()`
- `OnRedoPressed()`
- `OnRedoReleased()`
- `OnSpectatorStateChange(bIsSpectator: Bool @0)`
- `OnToggleBuilderModePressed()`
- `OnUndoPressed()`
- `OnUndoReleased()`
- `ReachGoalPoint(Goalpoint: Struct<BrickHandle> @0)`
- `RequestServerSaveWorld_BP(Params: Struct<BRWorldSaveParams> @0)`
- `RequestServerTravelToWorld(FilePath: Str @0, ContainerType: Enum<EBRBundleContainerType> @10, bWriteable: Bool @11, Revision: Int64 @18)`
- `RestartPlayer(bRemoveOldCharacter: Bool @0)`
- `ServerAddSubscribedBricks(BricksToAdd: Array @0)`
- `ServerAddToInventory(Template: Struct<BRInventoryEntryTemplate> @0, bQuickbar: Bool @190, bSelectNewEntry: Bool @191)`
- `ServerAdminAction_BanPlayer(VictimId: Struct<BRGuid> @0, Expiry: Struct<DateTime> @10, Reason: Str @18, bErrorsAsDialog: Bool @28)`
- `ServerAdminAction_ClearObjects(VictimId: Struct<BRGuid> @0, bClearGlobalBricks: Bool @10, bOnlyLooseEntities: Bool @11, OriginFilter: Struct<Vector> @18, MinDistance: Float @30)`
- `ServerAdminAction_FreezeObjects(VictimId: Struct<BRGuid> @0, bOnlyLooseEntities: Bool @10, OriginFilter: Struct<Vector> @18, MinDistance: Float @30)`
- `ServerAdminAction_KickPlayer(VictimId: Struct<BRGuid> @0, Reason: Str @10)`
- `ServerAdminAction_KillAllBots()`
- `ServerAdminAction_Teleport(From: Object<BRPlayerState> @0, To: Object<BRPlayerState> @8)`
- `ServerClearInventorySlot(Slot: Int @0)`
- `ServerClearInventoryTempSlot()`
- `ServerClearSelection()`
- `ServerClearSkinForBotSpawner(TargetBrick: Struct<BrickHandle> @0)`
- `ServerJoinGameModeTeam(TeamId: Int @0)`
- `ServerNotifyTrustLevelChange(OtherUserId: Struct<BRGuid> @0, bTrusted: Bool @10)`
- `ServerPastePrefab(Hash: Struct<BRPrefabHash> @0, bWithOwnership: Bool @20, bInTemp: Bool @21, PasteInfo: Struct<BRPrefabDetachedPasteInfo> @28)`
- `ServerPushChatMessage(ChatMessage: Str @0)`
- `ServerRemoveSubscribedBricks(BricksToRemove: Array @0)`
- `ServerRequestInviteCode(bGenerateNew: Bool @0)`
- `ServerRequestJoinGameModeTeam(TeamId: Int @0)`
- `ServerSetInventorySlot(Slot: Int @0, Template: Struct<BRInventoryEntryTemplate> @8)`
- `ServerSetInventoryTempSlot(Template: Struct<BRInventoryEntryTemplate> @0)`
- `ServerSetSkinForBotSpawner(TargetBrick: Struct<BrickHandle> @0)`
- `ServerSetSubscribedBricks(NewSubscribedBricks: Array @0)`
- `ServerSetTyping(bTyping: Bool @0)`
- `ServerSwapInventorySlots(SlotA: Int @0, SlotB: Int @4)`
- `ServerToggleBuilderMode(SpectatorSpawnLocation: Struct<Vector_NetQuantize> @0, SpectatorSpawnRotation: Struct<Rotator> @18, bHasSpectatorSpawn: Bool @30)`
- `ServerUpdateBrickSubscription(NewSubscribedBrickHandle: Struct<BrickHandle> @0)`
- `ServerWireMessageBoxAnswered(RequestID: UInt32 @0, bAccepted: Bool @4, Text: Str @8)`
- `ServerWireMessageBoxFailedToOpen(RequestID: UInt32 @0)`
- `SetCannotRespawn(bNewCannotRespawn: Bool @0)`
- `SetCheckPoint(CheckPoint: Struct<BrickHandle> @0)`
- `SetFreezeCamera(bFreeze: Bool @0)`
- `SetGlobalTrust(OtherUserId: Struct<BRGuid> @0, bTrusted: Bool @10)`
- `SetIsSpectator(bIsSpectator: Bool @0)`
- `SetLoadingIconEnabled(bEnabled: Bool @0)`
- `SetLoadingIconStatus(Text: Text @0, ProgressBar: Bool @10, Progress: Float @14)`
- `SetSpectatorTarget(Actor: Object<Actor> @0)`
- `TrustsUserOnServer(OtherUserId: Struct<BRGuid> @0, ReturnValue: Bool @10)`
- `UpdateZoomState()`

## BRPlayerState

- `AddTrackedProjectile(Projectile: Object<BRWeaponProjectile> @0)`
- `ClearRoles()`
- `CountBricksAndComponents(OutNumBricks: Int @0, OutNumComponents: Int @4)`
- `DestroyTrackedProjectiles_BothSides()`
- `GetChatNameColor(ReturnValue: Struct<Color> @0)`
- `GetChatNameColorFor(OtherPlayer: Object<BRPlayerState> @0, ReturnValue: Struct<Color> @8)`
- `GetCustomPermissionsRoles(ReturnValue: Array @0)`
- `GetDefaultRoleColor(ReturnValue: Struct<Color> @0)`
- `GetGameModeTeamFor(OtherPlayer: Object<BRPlayerState> @0, ReturnValue: Object<BRGameModeTeam> @8)`
- `GetHUDNameColor(ReturnValue: Struct<Color> @0)`
- `GetHasChatNameColor(ReturnValue: Bool @0)`
- `GetHasRole(PermissionsRoleIn: Str @0, ReturnValue: Bool @10)`
- `GetHighestRole(ReturnValue: Object<BRPermissionsRole> @0)`
- `GetHighestRoleColor(ReturnValue: Struct<Color> @0)`
- `GetIsOwner(ReturnValue: Bool @0)`
- `GetLeaderboardValue(ValueName: Name @0, ReturnValue: Int64 @8)`
- `GetOwnerBRPlayerController(ReturnValue: Object<BRPlayerController> @0)`
- `GetPlacerTool(ReturnValue: Object<BRTool_Placer> @0)`
- `GetRoles(ReturnValue: Array @0)`
- `GetRolesExcludingDefault(ReturnValue: Array @0)`
- `GetToolByClass(ToolClass: Class @0, ReturnValue: Object<BRToolBase> @8)`
- `GetToolInventoryEntry(Slot: Int @0, ReturnValue: Struct<BRInventoryEntry> @8)`
- `GetToolsInventory(ReturnValue: Object<BRInventoryComponent> @0)`
- `GetUserId(ReturnValue: Struct<BRGuid> @0)`
- `GetUserName(ReturnValue: Str @0)`
- `HasAnyRoles(ReturnValue: Bool @0)`
- `HasLivingCharacter(ReturnValue: Bool @0)`
- `HasPermission(Permission: Struct<GameplayTag> @0, ReturnValue: Bool @8)`
- `HasRolePermission(Permission: Struct<GameplayTag> @0, ReturnValue: Bool @8)`
- `HasToolInventoryEntry(Slot: Int @0, ReturnValue: Bool @4)`
- `IncLeaderboardValue(ValueName: Name @0, Value: Int64 @8)`
- `OnRep_BuilderMode()`
- `OnRep_CustomPermissionsRoles()`
- `OnRep_LeaderboardData()`
- `OnRep_Team()`
- `RemoveTrackedProjectile(Projectile: Object<BRWeaponProjectile> @0)`
- `ResetLeaderboardValues()`
- `ServerSetColorSelectionState(SelectionState: Struct<BRColorSelectionState> @0)`
- `SetColorSelectionState(SelectionState: Struct<BRColorSelectionState> @0)`
- `SetHasRole(RoleId: Str @0, Has: Bool @10)`
- `SetHasRoles(RoleIds: Array @0)`
- `SetLeaderboardValue(ValueName: Name @0, Value: Int64 @8)`
