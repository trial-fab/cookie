-- Net: the single client<->server remote facade for ClickGame.
--
-- Replaces the ~8 copy-pasted `getOrCreateFolder`/`getOrCreateRemoteEvent` helpers on the
-- server and the ~7 `WaitForChild("Remotes")` + per-remote `WaitForChild` blocks on the
-- client. Remote creation, naming, and access all live here.
--
-- Design notes (see docs/shared-modules-design.md):
--   * Named per-feature remotes are KEPT (not multiplexed onto one E/F) so channels can be
--     secured/disabled independently and stay multi-subscriber.
--   * `Net.event` is get-or-create: a service using Net and another still using its own
--     getOrCreate resolve to the SAME RemoteEvent, so migration can be incremental.
--   * Names come from `Net.Names`; a bad key is `nil` and errors here, never a silent hang.
--   * Server `Net.on` pcall-isolates each handler so one erroring subscriber can't poison
--     the channel, and multiple subscribers can connect to the same remote.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}
Net.Names = require(script.Parent.RemoteNames)

local IS_SERVER = RunService:IsServer()
local REMOTES_FOLDER_NAME = "Remotes"

local eventCache = {}
local fnCache = {}
local remotesFolder

local function validateName(name)
	if typeof(name) ~= "string" then
		error(
			("Net: remote name must be a string, got %s. Use Net.Names.<Key> "):format(typeof(name))
				.. "(a misspelled key resolves to nil).",
			3
		)
	end
end

local function getRemotesFolder()
	if remotesFolder then
		return remotesFolder
	end
	if IS_SERVER then
		remotesFolder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
		if not remotesFolder then
			remotesFolder = Instance.new("Folder")
			remotesFolder.Name = REMOTES_FOLDER_NAME
			remotesFolder.Parent = ReplicatedStorage
		end
	else
		-- Get-or-create on the server means a client that boots first WaitForChilds
		-- rather than assuming existence (remotes are created lazily at service init).
		remotesFolder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME)
	end
	return remotesFolder
end

-- Returns the RemoteEvent for `name`, creating it on the server and waiting for it on the
-- client. Cached per name.
function Net.event(name)
	validateName(name)
	local cached = eventCache[name]
	if cached then
		return cached
	end

	local folder = getRemotesFolder()
	local remote
	if IS_SERVER then
		remote = folder:FindFirstChild(name)
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	else
		remote = folder:WaitForChild(name)
	end

	eventCache[name] = remote
	return remote
end

-- Returns the RemoteFunction for `name` (Phase 2 request/response), creating it on the server
-- and waiting for it on the client. Cached per name.
--
-- A RemoteFunction and a RemoteEvent must never share a name, so a `name` is either an event or
-- a function for its whole lifetime. The server guards the get-or-create against a stale
-- wrong-class instance left in a long-lived Studio DataModel (e.g. a previous session created a
-- RemoteEvent under this name): it destroys the impostor and creates the RemoteFunction, so a
-- type flip during migration can't hand back the wrong class.
function Net.fn(name)
	validateName(name)
	local cached = fnCache[name]
	if cached then
		return cached
	end

	local folder = getRemotesFolder()
	local remote
	if IS_SERVER then
		remote = folder:FindFirstChild(name)
		if remote and not remote:IsA("RemoteFunction") then
			warn(("Net.fn(%q): found a %s under that name; replacing it with a RemoteFunction."):format(name, remote.ClassName))
			remote:Destroy()
			remote = nil
		end
		if not remote then
			remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = folder
		end
	else
		remote = folder:WaitForChild(name)
	end

	fnCache[name] = remote
	return remote
end

-- Registers a handler for `name`.
--   Server: connects to OnServerEvent; handler(player, ...). pcall-isolated, multi-subscriber.
--   Client: connects to OnClientEvent; handler(...).
-- Returns the RBXScriptConnection.
function Net.on(name, handler)
	local remote = Net.event(name)
	if IS_SERVER then
		return remote.OnServerEvent:Connect(function(player, ...)
			local ok, err = pcall(handler, player, ...)
			if not ok then
				warn(("Net.on(%q) handler error: %s"):format(name, tostring(err)))
			end
		end)
	end
	return remote.OnClientEvent:Connect(handler)
end

-- Server -> one client.
function Net.fireClient(name, player, ...)
	assert(IS_SERVER, "Net.fireClient is server-only")
	Net.event(name):FireClient(player, ...)
end

-- Server -> all clients.
function Net.fireAll(name, ...)
	assert(IS_SERVER, "Net.fireAll is server-only")
	Net.event(name):FireAllClients(...)
end

-- Client -> server.
function Net.fireServer(name, ...)
	assert(not IS_SERVER, "Net.fireServer is client-only")
	Net.event(name):FireServer(...)
end

-- Server: registers the single OnServerInvoke handler for `name` (RemoteFunctions allow only
-- one). handler(player, ...) -> result. The handler is pcall-isolated so an erroring handler
-- can't reject/poison the channel: on error it warns and returns a safe failure table, matching
-- the project's "always send a result, even on failure" resilience.
function Net.onInvoke(name, handler)
	assert(IS_SERVER, "Net.onInvoke is server-only")
	Net.fn(name).OnServerInvoke = function(player, ...)
		local ok, result = pcall(handler, player, ...)
		if not ok then
			warn(("Net.onInvoke(%q) handler error: %s"):format(name, tostring(result)))
			return { success = false, message = "Something went wrong." }
		end
		return result
	end
end

-- Client -> server request/response. Blocks the calling thread until the server replies, so
-- call sites that must stay responsive should wrap this in task.spawn.
function Net.invoke(name, ...)
	assert(not IS_SERVER, "Net.invoke is client-only")
	return Net.fn(name):InvokeServer(...)
end

return Net
