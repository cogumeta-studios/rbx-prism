local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Cursor = require(script.Packages.Cursor)
local Signal = require(script.Packages.AcidSignal)
local Types = require(script.Types)
local Plugins = require(script.Plugins)

type Cursor = typeof(Cursor.new())

local MAX_PACKET_SIZE = 8000
local MAX_CALLS_PER_FRAME = 2
local IS_SERVER = RunService:IsServer()
local IS_STUDIO = RunService:IsStudio()
local TIMEOUTED = table.freeze({})

local swarn = if IS_STUDIO then warn else function() end

type Mode = "Reliable" | "Unreliable" | "Querie"

export type SendOptions = {
	Target: (Player | { Player })?,
	Except: boolean?,
}

type PrismData<T> = {
	_id: number,
	_mode: Mode,
	_schema: string,
	_middlewares: { Middleware },
	Event: typeof(Signal.new()),
	OnQuerie: ((Player, T) -> any)?,
	Send: (self: Prism<T>, data: T, options: (SendOptions | Player | { Player })?) -> (),
	Querie: (self: Prism<T>, data: T, target: Player?) -> any | typeof(TIMEOUTED),
	Use: (self: Prism<T>, middleware: Middleware) -> () -> (),
}

export type Prism<T = any> = typeof(setmetatable({} :: PrismData<T>, {}))

type MiddlewareContext = {
	Packet: Prism,
	Player: Player?,
	Data: any,
	Stage: "Incoming" | "Outgoing",
	Direction: "ClientToServer" | "ServerToClient",
	Kind: "Packet" | "Querie",
	Metadata: { [any]: any },
	Timestamp: number,
	TraceId: number,
}

type Middleware = (ctx: MiddlewareContext, next: () -> ()) -> ()

local PShared: Folder
local REvent: RemoteEvent
local URevent: UnreliableRemoteEvent
local RFunction: RemoteFunction

local nextID = 0
local nextTraceID = 0
local instances: { [number]: Prism } = {}

type PlayerCursors = { Reliable: Cursor, Unreliable: Cursor }
local serverCursors: { [Player]: PlayerCursors } = {}
local serverFrameCalls: { [Player]: number } = {}

local clientCursors: PlayerCursors = {
	Reliable = Cursor.new(),
	Unreliable = Cursor.new(),
}

local globalMiddlewares: { Middleware } = {}
local middlewareToSource: { [Middleware]: string } = {}

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

local function runMiddlewares(ctx: MiddlewareContext, middlewares: { Middleware }, handler: () -> ()): boolean
	local completed = false

	local function execute(index: number)
		local mw = middlewares[index]

		if not mw then
			completed = true
			handler()
			return
		end

		local called = false

		local thread = coroutine.create(function()
			mw(ctx, function()
				if called then
					return
				end

				called = true
				execute(index + 1)
			end)
		end)

		local ok, err = coroutine.resume(thread)

		if not ok then
			swarn(`[Prism] Middleware error: {err}, middleware declared at: {middlewareToSource[mw]}`)
			return
		end

		if coroutine.status(thread) ~= "dead" then
			swarn(`[Prism] Middleware yielded, this is not allowed, middleware declared at: {middlewareToSource[mw]}`)
			return
		end

		if not called then
			return
		end
	end

	execute(1)

	return completed
end

local function getMiddlewares(packet: Prism)
	local result = table.clone(globalMiddlewares)

	for _, mw in packet._middlewares do
		table.insert(result, mw)
	end

	return result
end

local function createMWContext(
	packet: Prism,
	player: Player?,
	data: any,
	stage: "Incoming" | "Outgoing"
): MiddlewareContext
	nextTraceID += 1

	return {
		Packet = packet,
		Player = player,
		Data = data,

		Stage = stage,

		Direction = if IS_SERVER
			then (stage == "Incoming" and "ClientToServer" or "ServerToClient")
			else (stage == "Incoming" and ("ServerToClient" :: any) or "ClientToServer"),

		Kind = if packet._mode == "Querie" then "Querie" else "Packet",

		Metadata = {},

		Timestamp = os.clock(),
		TraceId = nextTraceID,
	}
end

local function writePacket(cursor: Cursor, id: number, schema: string, data: any)
	cursor:writeU16(id)
	Types.Descriptors[schema].write(cursor, data)
end

function Prism:Use(middleware: Middleware): () -> ()
	local scr, line = debug.info(2, "sl")
	middlewareToSource[middleware] = `{scr}:{line}`
	table.insert(self._middlewares, middleware)

	return function()
		local index = table.find(self._middlewares, middleware)

		if index then
			table.remove(self._middlewares, index)
		end
	end
end

function Prism:Send<T>(data: T, options: (SendOptions | Player | { Player })?)
	assert(self._mode ~= "Querie", "[Prism] Use :Querie() for Querie packets")

	if IS_SERVER then
		assert(options ~= nil, "[Prism] :Send() on the server requires a Target")

		for _, target in resolveTargets(options :: any) do
			if target.Parent ~= Players then
				continue
			end

			local ctx = createMWContext(self, target, data, "Outgoing")

			runMiddlewares(ctx, getMiddlewares(self), function()
				writePacket((serverCursors :: any)[target][self._mode], self._id, self._schema, ctx.Data)
			end)
		end
	else
		assert(options == nil, "[Prism] :Send() on the client does not accept a Target")

		local ctx = createMWContext(self, nil, data, "Outgoing")

		runMiddlewares(ctx, getMiddlewares(self), function()
			writePacket((clientCursors :: any)[self._mode], self._id, self._schema, ctx.Data)
		end)
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

	local ctx = createMWContext(self, target, data, "Outgoing")

	local ok = runMiddlewares(ctx, getMiddlewares(self), function()
		writePacket(cursor, self._id, self._schema, ctx.Data)
	end)

	if not ok then
		return nil
	end

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
			local ctx = createMWContext(packet, sender, data, "Incoming")

			runMiddlewares(ctx, getMiddlewares(packet), function()
				if sender then
					packet.Event:Fire(sender, ctx.Data)
				else
					packet.Event:Fire(ctx.Data)
				end
			end)
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
		local ctx = createMWContext(packet, sender, data, "Incoming")
		local response

		local ok = runMiddlewares(ctx, getMiddlewares(packet), function()
			response = packet.OnQuerie(sender :: Player, ctx.Data)
		end)

		if not ok then
			return nil
		end

		return response
	end)

	if not ok then
		swarn(`[Prism] Failed to process querie: {result}`)
		return nil
	end

	return result
end

local PrismBuilder: typeof(Types.Types) & {
	Timeouted: typeof(TIMEOUTED),
	Plugins: typeof(Plugins),
	new: <T>(name: string, schema: T, mode: Mode?) -> Prism<T>,
	use: (middleware: Middleware) -> () -> (),
} =
	{
		Timeouted = TIMEOUTED,
		Plugins = Plugins,
	} :: any

for k, v in Types.Types :: { [string]: any } do
	PrismBuilder[k] = v
end

function PrismBuilder.new<T>(name: string, schema: T, mode: Mode?): Prism<T>
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
	self._mode = mode or "Reliable"
	self._schema = schema :: string
	self._middlewares = {}
	(self :: any).Event = Signal.new()

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

function PrismBuilder.use(middleware: Middleware): () -> ()
	local scr, line = debug.info(2, "sl")
	middlewareToSource[middleware] = `{scr}:{line}`
	table.insert(globalMiddlewares, middleware)

	return function()
		local index = table.find(globalMiddlewares, middleware)

		if index then
			table.remove(globalMiddlewares, index)
		end
	end
end

if IS_SERVER then
	PShared = Instance.new("Folder")
	PShared.Name = "_PrismShared"
	PShared.Parent = script

	REvent = Instance.new("RemoteEvent")
	REvent.Name = "_PrismReliable"
	REvent.Parent = script

	URevent = Instance.new("UnreliableRemoteEvent")
	URevent.Name = "_PrismUnreliable"
	URevent.Parent = script

	RFunction = Instance.new("RemoteFunction")
	RFunction.Name = "_PrismQuerie"
	RFunction.Parent = script

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
	PShared = script:WaitForChild("_PrismShared") :: Folder
	REvent = script:WaitForChild("_PrismReliable") :: RemoteEvent
	URevent = script:WaitForChild("_PrismUnreliable") :: UnreliableRemoteEvent
	RFunction = script:WaitForChild("_PrismQuerie") :: RemoteFunction

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
