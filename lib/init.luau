local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Cursor = require(script.Packages.Cursor)
local Signal = require(script.Packages.AcidSignal)
local Types = require(script.Types)

type Cursor = typeof(Cursor.new())

local MAX_PACKET_SIZE = 8000
local MAX_CALLS_PER_FRAME = 2
local IS_SERVER = RunService:IsServer()
local IS_STUDIO = RunService:IsStudio()
local TIMEOUTED = table.freeze({})

local swarn = if IS_STUDIO then warn else function() end

type Mode = "Reliable" | "Unreliable" | "Querie"

type PrismOptions = {
	Mode: Mode?,
}

export type SendOptions = {
	Target: (Player | { Player })?,
	Except: boolean?,
}

type PrismData<T> = {
	_id: number,
	_mode: Mode,
	_schema: string,
	Event: typeof(Signal.new()),
	OnQuerie: ((Player, T) -> any)?,
	Send: (self: Prism<T>, data: T, options: (SendOptions | Player | { Player })?) -> (),
	Querie: (self: Prism<T>, data: T, target: Player?) -> any | typeof(TIMEOUTED)),
}

export type Prism<T = any> = typeof(setmetatable({} :: PrismData<T>, {} :: { __index: {} }))

local PShared: Folder
local REvent: RemoteEvent
local URevent: UnreliableRemoteEvent
local RFunction: RemoteFunction

local nextID = 0
local instances: { [number]: Prism } = {}

type PlayerCursors = { Reliable: Cursor, Unreliable: Cursor }
local serverCursors: { [Player]: PlayerCursors } = {}
local serverFrameCalls: { [Player]: number } = {}

local clientCursors: PlayerCursors = {
	Reliable = Cursor.new(),
	Unreliable = Cursor.new(),
}

local Prism = {}
Prism.__index = Prism

local function resolveTargets(options: SendOptions | Player | { Player }): { Player }
	local sendOptions: SendOptions

	if typeof(options) == "Instance" then
		sendOptions = { Target = options :: Player } :: SendOptions
	elseif typeof(options) == "table" and (options :: any)[1] then
		sendOptions = { Target = options :: { Player } } :: SendOptions
	else
		sendOptions = options :: SendOptions
	end

	if sendOptions.Except then
		local exceptSet: { [Player]: boolean } = {}

		if typeof(sendOptions.Target) == "table" then
			for _, p in sendOptions.Target :: { Player } do
				exceptSet[p] = true
			end
		elseif sendOptions.Target then
			exceptSet[sendOptions.Target :: Player] = true
		end

		local result: { Player } = {}
		for _, p in Players:GetPlayers() do
			if not exceptSet[p] then
				table.insert(result, p)
			end
		end
		return result
	end

	if typeof(sendOptions.Target) == "table" then
		return sendOptions.Target :: { Player }
	end

	return { sendOptions.Target :: Player }
end

local function writePacket(cursor: Cursor, id: number, schema: string, data: any)
	cursor:writeU16(id)
	Types.Descriptors[schema].write(cursor, data)
end

function Prism:Send<T>(data: T, options: (SendOptions | Player | { Player })?)
	assert(self._mode ~= "Querie", "[Prism] Use :Querie() for Querie packets")

	if IS_SERVER then
		assert(options ~= nil, "[Prism] :Send() on the server requires a Target")

		for _, target in resolveTargets(options :: any) do
			if target.Parent ~= Players then
				continue
			end
			writePacket((serverCursors :: any)[target][self._mode], self._id, self._schema, data)
		end
	else
		assert(options == nil, "[Prism] :Send() on the client does not accept a Target")
		writePacket((clientCursors :: any)[self._mode], self._id, self._schema, data)
	end
end

function Prism:Querie<T>(data: T, target: Player?, timeout: number?): any
	assert(self._mode == "Querie", "[Prism] Only Querie packets can use :Querie()")

	if IS_SERVER then
		assert(target ~= nil, "[Prism] :Querie() on the server requires a target")
	else
		assert(target == nil, "[Prism] :Querie() on the client does not accept a target")
	end

	local cursor = Cursor.new()
	writePacket(cursor, self._id, self._schema, data)
	local buf, unbuf = cursor:flush()
	local thread = coroutine.running()
	local finished = false

	task.spawn(function()
		local result
		if IS_SERVER then
			result = RFunction:InvokeClient(target :: Player, buf, unbuf)
		else
			result = RFunction:InvokeServer(buf, unbuf)
		end
		if finished then
			return
		end

		finished = true
		coroutine.resume(thread, result)
	end)

	if timeout then
		task.delay(timeout, function()
			if finished then
				return
			end

			finished = true
			coroutine.resume(thread, TIMEOUTED)
		end)
	end

	return coroutine.yield()
end

local function processBuffer(buf: buffer, unbuf: { any }, sender: Player?)
	local ok, err = pcall(function()
		local cursor = Cursor.from(buf, unbuf)

		while not cursor:ended() do
			local id = cursor:readU16()
			local packet = instances[id]

			if not packet then
				swarn(
					`[Prism] Unknown packet ID {id}`
						.. (sender and ` (from {(sender :: Player).Name})` or "")
						.. `. Aborting.`
				)
				break
			end

			local data = Types.Descriptors[packet._schema].read(cursor)

			if sender then
				packet.Event:Fire(sender, data)
			else
				packet.Event:Fire(data)
			end
		end
	end)

	if not ok then
		swarn(`[Prism] Failed to process buffer` .. (sender and ` from {sender.Name}` or "") .. `: {err}`)
	end
end

local function processQuerie(buf: buffer, unbuf: { any }, sender: Player?): any
	local ok, result = pcall(function()
		local cursor = Cursor.from(buf, unbuf)
		local id = cursor:readU16()
		local packet = instances[id]

		if not packet then
			swarn(`[Prism] Unknown querie ID {id}.`)
			return nil
		end

		if not packet.OnQuerie then
			swarn(`[Prism] Querie ID {id} has no OnQuerie defined.`)
			return nil
		end

		local data = Types.Descriptors[packet._schema].read(cursor)
		return packet.OnQuerie(sender :: Player, data)
	end)

	if not ok then
		swarn(`[Prism] Failed to process querie: {result}`)
		return nil
	end

	return result
end

local PrismBuilder: typeof(Types.Types) & {
	Timeouted: typeof(TIMEOUTED),
	new: <T>(name: string, schema: T, options: PrismOptions?) -> Prism<T>,
} =
	{
		Timeouted = TIMEOUTED,
	} :: any

for k, v in Types.Types :: { [string]: any } do
	PrismBuilder[k] = v
end

function PrismBuilder.new<T>(name: string, schema: T, options: PrismOptions?): Prism<T>
	options = options or {}

	if typeof(schema) == "table" then
		local t: any = schema
		if t[1] then
			assert(t[2] == nil, "[Prism] Arrays only support a single type")
			schema = PrismBuilder.Array(t[1])
		else
			schema = PrismBuilder.Struct(t)
		end
	end

	local self = setmetatable({} :: PrismData<T>, Prism) :: Prism<T>
	self._mode = (options :: PrismOptions).Mode or "Reliable"
	self._schema = schema :: string
	self.Event = Signal.new()

	if IS_SERVER then
		nextID += 1
		self._id = nextID
		PShared:SetAttribute(name, nextID)
	else
		local id: number? = PShared:GetAttribute(name) :: any
		if not id then
			PShared:GetAttributeChangedSignal(name):Wait()
			id = PShared:GetAttribute(name) :: number
		end
		self._id = id :: number
	end

	instances[self._id] = self

	return self
end

if IS_SERVER then
	PShared = Instance.new("Folder")
	PShared.Name = "_PrismShared"
	PShared.Parent = ReplicatedStorage

	REvent = Instance.new("RemoteEvent")
	REvent.Name = "_PrismReliable"
	REvent.Parent = ReplicatedStorage

	URevent = Instance.new("UnreliableRemoteEvent")
	URevent.Name = "_PrismUnreliable"
	URevent.Parent = ReplicatedStorage

	RFunction = Instance.new("RemoteFunction")
	RFunction.Name = "_PrismQuerie"
	RFunction.Parent = ReplicatedStorage

	Players.PlayerAdded:Connect(function(player)
		serverCursors[player] = { Reliable = Cursor.new(), Unreliable = Cursor.new() }
		serverFrameCalls[player] = 0
	end)

	Players.PlayerRemoving:Connect(function(player)
		serverCursors[player] = nil
		serverFrameCalls[player] = nil
	end)

	local function onReceive(player: Player, buf: buffer, unbuf: { any })
		local calls = (serverFrameCalls[player] or 0) + 1
		serverFrameCalls[player] = calls

		if calls > MAX_CALLS_PER_FRAME then
			swarn(`[Prism] Rate limit exceeded for {player.Name} ({calls} calls this frame), packet dropped.`)
			return
		end

		if buffer.len(buf) > MAX_PACKET_SIZE then
			swarn(`[Prism] Oversized packet from {player.Name} ({buffer.len(buf)} bytes), packet dropped.`)
			return
		end

		processBuffer(buf, unbuf, player)
	end

	REvent.OnServerEvent:Connect(onReceive)
	URevent.OnServerEvent:Connect(onReceive)

	RFunction.OnServerInvoke = function(player: Player, buf: buffer, unbuf: { any })
		return processQuerie(buf, unbuf, player)
	end

	RunService.Heartbeat:Connect(function()
		for player, cursors in serverCursors do
			if cursors.Reliable._offset > 0 then
				local buf, unbuf = cursors.Reliable:flush()
				REvent:FireClient(player, buf, unbuf)
				serverCursors[player].Reliable = Cursor.new()
			end

			if cursors.Unreliable._offset > 0 then
				local buf, unbuf = cursors.Unreliable:flush()
				URevent:FireClient(player, buf, unbuf)
				serverCursors[player].Unreliable = Cursor.new()
			end

			serverFrameCalls[player] = 0
		end
	end)
else
	PShared = ReplicatedStorage:WaitForChild("_PrismShared") :: Folder
	REvent = ReplicatedStorage:WaitForChild("_PrismReliable") :: RemoteEvent
	URevent = ReplicatedStorage:WaitForChild("_PrismUnreliable") :: UnreliableRemoteEvent
	RFunction = ReplicatedStorage:WaitForChild("_PrismQuerie") :: RemoteFunction

	REvent.OnClientEvent:Connect(function(buf: buffer, unbuf: { any })
		processBuffer(buf, unbuf, nil)
	end)

	URevent.OnClientEvent:Connect(function(buf: buffer, unbuf: { any })
		processBuffer(buf, unbuf, nil)
	end)

	RFunction.OnClientInvoke = function(buf: buffer, unbuf: { any })
		return processQuerie(buf, unbuf, nil)
	end

	RunService.Heartbeat:Connect(function()
		if clientCursors.Reliable._offset > 0 then
			local buf, unbuf = clientCursors.Reliable:flush()
			REvent:FireServer(buf, unbuf)
			clientCursors.Reliable = Cursor.new()
		end

		if clientCursors.Unreliable._offset > 0 then
			local buf, unbuf = clientCursors.Unreliable:flush()
			URevent:FireServer(buf, unbuf)
			clientCursors.Unreliable = Cursor.new()
		end
	end)
end

return PrismBuilder
