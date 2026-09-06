local Players=game:GetService("Players")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local RunService=game:GetService("RunService")
local Workspace=game:GetService("Workspace")

local LocalPlayer=Players.LocalPlayer
local Shared=ReplicatedStorage:WaitForChild("Shared")
local GameConfig=require(Shared:WaitForChild("GameConfig"))
local PetDefinitions=require(Shared:WaitForChild("PetDefinitions"))
local PetVisuals=require(script.Parent.Parent.Modules:WaitForChild("PetVisuals"))

local FollowerController={}

type ManifestEntry={
	Uid:string,
	PetId:string,
	Slot:number,
}

type Visual={
	Uid:string,
	PetId:string,
	Model:Model,
	Current:CFrame?,
	Phase:number,
	GroundY:number?,
	NextGroundSample:number,
}

type PlayerState={
	Player:Player,
	Visuals:{Visual},
	Connections:{RBXScriptConnection},
	ManifestConnections:{RBXScriptConnection},
	EntryConnections:{[Instance]:{RBXScriptConnection}},
	Manifest:Folder?,
	Raycast:RaycastParams,
	RaycastCharacter:Model?,
	SyncQueued:boolean,
}

local PET_SCALE=0.82
local PETS_PER_ROW=3
local BASE_FOLLOW_DISTANCE=5
local GROUND_CAST_HEIGHT=8
local GROUND_CAST_DEPTH=20
local GROUND_HEIGHT_OFFSET=1.15
local GROUND_FALLBACK_OFFSET=2.1
local IDLE_BOUNCE_SPEED=2.2
local IDLE_BOUNCE_HEIGHT=0.1
local MOVEMENT_THRESHOLD_SQ=0.75^2
local WARP_DISTANCE_SQ=25^2
local TILT_ANGLE=math.rad(9)
local TILT_SIDE_SCALE=0.35
local FOLLOWER_SPACING=GameConfig.FollowerSpacing
local FOLLOWER_ROW_SPACING=GameConfig.FollowerRowSpacing
local FOLLOWER_RESPONSIVENESS=GameConfig.FollowerResponsiveness
local FOLLOWER_BOUNCE_HEIGHT=GameConfig.FollowerBounceHeight
local FOLLOWER_BOUNCE_SPEED=GameConfig.FollowerBounceSpeed
local GROUND_SAMPLE_INTERVAL=GameConfig.FollowerGroundSampleInterval
local RENDER_DISTANCE_SQ=GameConfig.FollowerRenderDistance^2
local GROUND_CAST_OFFSET=Vector3.new(0,GROUND_CAST_HEIGHT,0)
local GROUND_CAST_DIRECTION=Vector3.new(0,-GROUND_CAST_DEPTH,0)

local rootFolder:Folder?=nil
local initialized=false
local playerStates:{[Player]:PlayerState}={}
local controllerConnections:{RBXScriptConnection}={}
local syncPlayer:(PlayerState)->()

local function disconnectAll(connections:{RBXScriptConnection})
	for _,connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function phaseFromUid(uid:string):number
	local total=0
	for index=1,#uid do
		total+=string.byte(uid,index)
	end
	return(total%628)/100
end

local function squaredMagnitude(vector:Vector3):number
	return vector:Dot(vector)
end

local function resetVisualMotion(visual:Visual)
	visual.Current=nil
	visual.GroundY=nil
	visual.NextGroundSample=0
end

local function hideVisuals(state:PlayerState)
	for _,visual in ipairs(state.Visuals) do
		if visual.Model.Parent then
			visual.Model.Parent=nil
		end
		resetVisualMotion(visual)
	end
end

local function destroyVisuals(state:PlayerState)
	for _,visual in ipairs(state.Visuals) do
		visual.Model:Destroy()
	end
	table.clear(state.Visuals)
end

local function clearEntryConnection(state:PlayerState,entry:Instance)
	local connections=state.EntryConnections[entry]
	if not connections then
		return
	end
	disconnectAll(connections)
	state.EntryConnections[entry]=nil
end

local function clearEntryConnections(state:PlayerState)
	for _,connections in pairs(state.EntryConnections) do
		disconnectAll(connections)
	end
	table.clear(state.EntryConnections)
end

local function queueSync(state:PlayerState)
	if state.SyncQueued then
		return
	end
	state.SyncQueued=true
	task.defer(function()
		if playerStates[state.Player]~=state then
			return
		end
		state.SyncQueued=false
		syncPlayer(state)
	end)
end

local function collectManifestEntries(manifest:Folder?):{ManifestEntry}
	if not manifest then
		return{}
	end
	local children=manifest:GetChildren()
	local entries=table.create(#children)
	for _,child in ipairs(children) do
		if not child:IsA("StringValue") then
			continue
		end
		if not PetDefinitions[child.Value] then
			continue
		end
		local slot=child:GetAttribute("Slot")
		if type(slot)~="number" then
			slot=999
		end
		entries[#entries+1]={
			Uid=child.Name,
			PetId=child.Value,
			Slot=slot,
		}
	end
	table.sort(entries,function(a:ManifestEntry,b:ManifestEntry)
		if a.Slot==b.Slot then
			return a.Uid<b.Uid
		end
		return a.Slot<b.Slot
	end)
	return entries
end

local function createVisual(state:PlayerState,entry:ManifestEntry):Visual
	local model=PetVisuals.CreateModel(entry.PetId,PET_SCALE)
	model.Name=string.format("%s_%s",state.Player.Name,entry.Uid)
	model.Parent=rootFolder
	return{
		Uid=entry.Uid,
		PetId=entry.PetId,
		Model=model,
		Current=nil,
		Phase=phaseFromUid(entry.Uid),
		GroundY=nil,
		NextGroundSample=0,
	}
end

syncPlayer=function(state:PlayerState)
	local entries=collectManifestEntries(state.Manifest)
	local previous:{[string]:Visual}={}
	for _,visual in ipairs(state.Visuals) do
		previous[visual.Uid]=visual
	end
	local nextVisuals=table.create(#entries)
	for _,entry in ipairs(entries) do
		local visual=previous[entry.Uid]
		if visual and visual.PetId==entry.PetId then
			previous[entry.Uid]=nil
		else
			if visual then
				visual.Model:Destroy()
			end
			visual=createVisual(state,entry)
		end
		nextVisuals[#nextVisuals+1]=visual
	end
	for _,visual in pairs(previous) do
		visual.Model:Destroy()
	end
	state.Visuals=nextVisuals
end

local function watchManifestEntry(state:PlayerState,child:Instance)
	if not child:IsA("StringValue") then
		return
	end
	clearEntryConnection(state,child)
	local connections:{RBXScriptConnection}={}
	connections[#connections+1]=child:GetPropertyChangedSignal("Value"):Connect(function()
		queueSync(state)
	end)
	connections[#connections+1]=child:GetAttributeChangedSignal("Slot"):Connect(function()
		queueSync(state)
	end)
	state.EntryConnections[child]=connections
end

local function bindManifest(state:PlayerState,manifest:Folder?)
	disconnectAll(state.ManifestConnections)
	clearEntryConnections(state)
	state.Manifest=manifest
	if manifest then
		for _,child in ipairs(manifest:GetChildren()) do
			watchManifestEntry(state,child)
		end
		state.ManifestConnections[#state.ManifestConnections+1]=manifest.ChildAdded:Connect(function(child)
			watchManifestEntry(state,child)
			queueSync(state)
		end)
		state.ManifestConnections[#state.ManifestConnections+1]=manifest.ChildRemoved:Connect(function(child)
			clearEntryConnection(state,child)
			queueSync(state)
		end)
		state.ManifestConnections[#state.ManifestConnections+1]=manifest:GetAttributeChangedSignal("Revision"):Connect(function()
			queueSync(state)
		end)
	end
	queueSync(state)
end

local function resetPlayerVisuals(state:PlayerState)
	for _,visual in ipairs(state.Visuals) do
		resetVisualMotion(visual)
	end
end

local function setRaycastCharacter(state:PlayerState,character:Model?)
	if state.RaycastCharacter==character then
		return
	end
	state.RaycastCharacter=character
	if character and rootFolder then
		state.Raycast.FilterDescendantsInstances={character,rootFolder}
	else
		state.Raycast.FilterDescendantsInstances={}
	end
end

local function resolveManifest(player:Player):Folder?
	local manifest=player:FindFirstChild("EquippedPetManifest")
	if manifest and manifest:IsA("Folder") then
		return manifest
	end
	return nil
end

local function watchPlayer(player:Player)
	if playerStates[player] then
		return
	end
	local raycast=RaycastParams.new()
	raycast.FilterType=Enum.RaycastFilterType.Exclude
	raycast.IgnoreWater=true
	local state:PlayerState={
		Player=player,
		Visuals={},
		Connections={},
		ManifestConnections={},
		EntryConnections={},
		Manifest=nil,
		Raycast=raycast,
		RaycastCharacter=nil,
		SyncQueued=false,
	}
	playerStates[player]=state
	state.Connections[#state.Connections+1]=player.ChildAdded:Connect(function(child)
		if child.Name=="EquippedPetManifest" and child:IsA("Folder") then
			bindManifest(state,child)
		end
	end)
	state.Connections[#state.Connections+1]=player.ChildRemoved:Connect(function(child)
		if child~=state.Manifest then
			return
		end
		task.defer(function()
			if playerStates[player]==state then
				bindManifest(state,resolveManifest(player))
			end
		end)
	end)
	state.Connections[#state.Connections+1]=player.CharacterAdded:Connect(function(character)
		setRaycastCharacter(state,character)
		resetPlayerVisuals(state)
	end)
	state.Connections[#state.Connections+1]=player.CharacterRemoving:Connect(function(character)
		if state.RaycastCharacter==character then
			setRaycastCharacter(state,nil)
		end
		resetPlayerVisuals(state)
	end)
	if player.Character then
		setRaycastCharacter(state,player.Character)
	end
	bindManifest(state,resolveManifest(player))
end

local function unwatchPlayer(player:Player)
	local state=playerStates[player]
	if not state then
		return
	end
	playerStates[player]=nil
	disconnectAll(state.Connections)
	disconnectAll(state.ManifestConnections)
	clearEntryConnections(state)
	destroyVisuals(state)
end

local function getViewerRoot():BasePart?
	local character=LocalPlayer.Character
	if not character then
		return nil
	end
	local root=character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isOutOfRange(state:PlayerState,root:BasePart,viewerRoot:BasePart?):boolean
	if state.Player==LocalPlayer or not viewerRoot then
		return false
	end
	return squaredMagnitude(root.Position-viewerRoot.Position)>RENDER_DISTANCE_SQ
end

local function getCharacterParts(state:PlayerState):(Model?,BasePart?,Humanoid?)
	local character=state.Player.Character
	if not character then
		return nil,nil,nil
	end
	local root=character:FindFirstChild("HumanoidRootPart")
	local humanoid=character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") then
		return character,nil,humanoid
	end
	return character,root,humanoid
end

local function sampleGround(state:PlayerState,desiredPoint:Vector3):number
	local result=Workspace:Raycast(desiredPoint+GROUND_CAST_OFFSET,GROUND_CAST_DIRECTION,state.Raycast)
	if result then
		return result.Position.Y+GROUND_HEIGHT_OFFSET
	end
	return desiredPoint.Y-GROUND_FALLBACK_OFFSET
end

local function updateVisuals(state:PlayerState,root:BasePart,deltaTime:number,now:number)
	local total=#state.Visuals
	if total==0 then
		return
	end
	local folder=rootFolder
	if not folder then
		return
	end
	local rootCFrame=root.CFrame
	local rootRotation=rootCFrame.Rotation
	local velocity=root.AssemblyLinearVelocity
	local horizontalVelocity=Vector3.new(velocity.X,0,velocity.Z)
	local moving=squaredMagnitude(horizontalVelocity)>MOVEMENT_THRESHOLD_SQ
	local alpha=1-math.exp(-FOLLOWER_RESPONSIVENESS*deltaTime)
	for index,visual in ipairs(state.Visuals) do
		if visual.Model.Parent~=folder then
			visual.Model.Parent=folder
		end
		local gridIndex=index-1
		local row=math.floor(gridIndex/PETS_PER_ROW)
		local column=gridIndex%PETS_PER_ROW
		local rowStart=row*PETS_PER_ROW
		local rowCount=math.min(PETS_PER_ROW,total-rowStart)
		local x=(column-(rowCount-1)/2)*FOLLOWER_SPACING
		local z=BASE_FOLLOW_DISTANCE+row*FOLLOWER_ROW_SPACING
		local desiredPoint=rootCFrame.Position+rootCFrame.RightVector*x-rootCFrame.LookVector*z
		if visual.GroundY==nil or now>=visual.NextGroundSample then
			visual.GroundY=sampleGround(state,desiredPoint)
			visual.NextGroundSample=now+GROUND_SAMPLE_INTERVAL+(visual.Phase%0.025)
		end
		local wave=math.sin(now*FOLLOWER_BOUNCE_SPEED+visual.Phase)
		local bounce:number
		local tilt=0
		if moving then
			bounce=math.abs(wave)*FOLLOWER_BOUNCE_HEIGHT
			tilt=wave*TILT_ANGLE
		else
			bounce=math.sin(now*IDLE_BOUNCE_SPEED+visual.Phase)*IDLE_BOUNCE_HEIGHT
		end
		local targetPosition=Vector3.new(desiredPoint.X,(visual.GroundY::number)+bounce,desiredPoint.Z)
		local target=CFrame.new(targetPosition)*rootRotation
		if tilt~=0 then
			target*=CFrame.Angles(tilt,0,tilt*TILT_SIDE_SCALE)
		end
		local current=visual.Current
		if not current or squaredMagnitude(current.Position-targetPosition)>WARP_DISTANCE_SQ then
			current=target
		else
			current=current:Lerp(target,alpha)
		end
		visual.Current=current
		visual.Model:PivotTo(current)
	end
end

local function updatePlayer(state:PlayerState,deltaTime:number,now:number,viewerRoot:BasePart?)
	local character,root,humanoid=getCharacterParts(state)
	if not character or not root or not humanoid or humanoid.Health<=0 then
		hideVisuals(state)
		return
	end
	if isOutOfRange(state,root,viewerRoot) then
		hideVisuals(state)
		return
	end
	setRaycastCharacter(state,character)
	updateVisuals(state,root,deltaTime,now)
end

local function renderStep(deltaTime:number)
	local now=os.clock()
	local viewerRoot=getViewerRoot()
	for _,state in pairs(playerStates) do
		updatePlayer(state,deltaTime,now,viewerRoot)
	end
end

function FollowerController.Init()
	if initialized then
		return
	end
	initialized=true
	local folder=Instance.new("Folder")
	folder.Name=string.format("ClientPetVisuals_%d",LocalPlayer.UserId)
	folder.Parent=Workspace
	rootFolder=folder
	controllerConnections[#controllerConnections+1]=Players.PlayerAdded:Connect(watchPlayer)
	controllerConnections[#controllerConnections+1]=Players.PlayerRemoving:Connect(unwatchPlayer)
	controllerConnections[#controllerConnections+1]=RunService.RenderStepped:Connect(renderStep)
	for _,player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end
end

function FollowerController.Destroy()
	if not initialized then
		return
	end
	initialized=false
	disconnectAll(controllerConnections)
	local player=next(playerStates)
	while player do
		unwatchPlayer(player)
		player=next(playerStates)
	end
	if rootFolder then
		rootFolder:Destroy()
		rootFolder=nil
	end
end

return FollowerController
