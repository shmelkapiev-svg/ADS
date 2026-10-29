--[[
    ADS — Absolute Doors Script
    Version: 1.0.0

    Supported baseline: a Roblox LocalScript using documented Roblox APIs.
    Recommended installation: StarterPlayer > StarterPlayerScripts in a place
    you own or in a DOORS-compatible Studio test environment.

    No HTTP loaders, executor functions, remote-event automation, object
    deletion, movement exploits, anticheat bypasses, or telemetry are used.
    Configuration is stored locally in PlayerGui for the current session only.
]]

local Services = {
    Players = game:GetService("Players"),
    RunService = game:GetService("RunService"),
    UserInputService = game:GetService("UserInputService"),
    TweenService = game:GetService("TweenService"),
    HttpService = game:GetService("HttpService"),
    Lighting = game:GetService("Lighting"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    GuiService = game:GetService("GuiService"),
    SoundService = game:GetService("SoundService"),
}

local Workspace = workspace
local Players = Services.Players
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    error("ADS must run as a client LocalScript.")
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
if not PlayerGui then
    error("ADS: PlayerGui was not available within 10 seconds.")
end

local APP_ID = "ADS_AbsoluteDoors"
local VERSION = "1.0.0"
local State = {
    Alive = true,
    StartedAt = os.clock(),
    Character = nil,
    Humanoid = nil,
    RootPart = nil,
    CurrentRoom = nil,
    Floor = "Unknown",
    Unloading = false,
}

-- Stop a previous copy without relying on getgenv/shared or other executor APIs.
local previousGui = PlayerGui:FindFirstChild(APP_ID)
if previousGui then
    local previousShutdown = previousGui:FindFirstChild("Shutdown")
    if previousShutdown and previousShutdown:IsA("BindableEvent") then
        previousShutdown:Fire()
        task.wait(0.15)
    end
    previousGui:Destroy()
end

local Diagnostics = {
    Entries = {},
    Errors = 0,
    Warnings = 0,
    MaxEntries = 100,
}

local function trimLogText(value)
    local text = tostring(value)
    if #text > 600 then
        return string.sub(text, 1, 597) .. "..."
    end
    return text
end

function Diagnostics.Log(level, message)
    local entry = {
        Time = os.clock(),
        Level = level,
        Message = trimLogText(message),
    }
    table.insert(Diagnostics.Entries, entry)
    if #Diagnostics.Entries > Diagnostics.MaxEntries then
        table.remove(Diagnostics.Entries, 1)
    end
    if level == "ERROR" then
        Diagnostics.Errors = Diagnostics.Errors + 1
        warn("[ADS] " .. entry.Message)
    elseif level == "WARN" then
        Diagnostics.Warnings = Diagnostics.Warnings + 1
        warn("[ADS] " .. entry.Message)
    else
        print("[ADS] " .. entry.Message)
    end
end

local function safeCall(context, callback, ...)
    local results = table.pack(pcall(callback, ...))
    if not results[1] then
        Diagnostics.Log("ERROR", context .. ": " .. trimLogText(results[2]))
        return false, results[2]
    end
    return true, table.unpack(results, 2, results.n)
end

local ResourceStats = {Connections = 0, Instances = 0, Scopes = 0}
local Scope = {}
Scope.__index = Scope

function Scope.new(name)
    ResourceStats.Scopes = ResourceStats.Scopes + 1
    return setmetatable({
        Name = name,
        Connections = {},
        Instances = {},
        Dead = false,
    }, Scope)
end

function Scope:Connect(signal, callback)
    if self.Dead then
        return nil
    end
    local connection = signal:Connect(callback)
    table.insert(self.Connections, connection)
    ResourceStats.Connections = ResourceStats.Connections + 1
    return connection
end

function Scope:Own(instance)
    if self.Dead then
        instance:Destroy()
        return instance
    end
    table.insert(self.Instances, instance)
    ResourceStats.Instances = ResourceStats.Instances + 1
    return instance
end

function Scope:Spawn(callback)
    task.spawn(function()
        if self.Dead or not State.Alive then
            return
        end
        local ok, err = pcall(callback, self)
        if not ok and not self.Dead and State.Alive then
            Diagnostics.Log("ERROR", self.Name .. " task: " .. trimLogText(err))
            if self.OnError then
                self.OnError(trimLogText(err))
            end
        end
    end)
end

function Scope:Loop(interval, callback)
    self:Spawn(function()
        local failures = 0
        while not self.Dead and State.Alive do
            local ok, err = pcall(callback)
            if ok then
                failures = 0
            elseif not self.Dead and State.Alive then
                failures = failures + 1
                local message = self.Name .. " loop: " .. trimLogText(err)
                Diagnostics.Log("ERROR", message)
                if self.OnError then
                    self.OnError(trimLogText(err))
                end
                if failures >= 5 then
                    Diagnostics.Log("ERROR", self.Name .. " loop stopped after five consecutive failures; restart the module from Debug.")
                    return
                end
            end
            local delayTime = interval
            if type(interval) == "function" then
                delayTime = interval()
            end
            task.wait(math.max(0.05, tonumber(delayTime) or 0.25))
        end
    end)
end

function Scope:Destroy()
    if self.Dead then
        return
    end
    self.Dead = true
    ResourceStats.Scopes = math.max(0, ResourceStats.Scopes - 1)
    ResourceStats.Connections = math.max(0, ResourceStats.Connections - #self.Connections)
    ResourceStats.Instances = math.max(0, ResourceStats.Instances - #self.Instances)
    for _, connection in ipairs(self.Connections) do
        if connection.Connected then
            connection:Disconnect()
        end
    end
    for _, instance in ipairs(self.Instances) do
        if typeof(instance) == "Instance" then
            instance:Destroy()
        elseif type(instance) == "table" and type(instance.Destroy) == "function" then
            instance:Destroy()
        end
    end
    table.clear(self.Connections)
    table.clear(self.Instances)
end

local RootScope = Scope.new("ADS root")

local Session = {
    UI = {},
    SavePending = false,
    Available = false,
}
local sessionFolder = PlayerGui:FindFirstChild("ADS_SessionData")
if not sessionFolder then
    sessionFolder = Instance.new("Folder")
    sessionFolder.Name = "ADS_SessionData"
    sessionFolder.Parent = PlayerGui
end
local sessionValue = sessionFolder:FindFirstChild("Payload")
if not sessionValue then
    sessionValue = Instance.new("StringValue")
    sessionValue.Name = "Payload"
    sessionValue.Parent = sessionFolder
end
Session.Available = true

local Config = {
    Definitions = {},
    Values = {},
    Listeners = {},
}

local function define(key, kind, default, minimum, maximum, choices)
    Config.Definitions[key] = {
        Kind = kind,
        Default = default,
        Min = minimum,
        Max = maximum,
        Choices = choices,
    }
    Config.Values[key] = default
end

-- Visuals
define("visuals.master", "boolean", true)
define("visuals.entities", "boolean", true)
define("visuals.items", "boolean", true)
define("visuals.objectives", "boolean", true)
define("visuals.doors", "boolean", false)
define("visuals.hiding", "boolean", false)
define("visuals.players", "boolean", false)
define("visuals.highlights", "boolean", true)
define("visuals.labels", "boolean", true)
define("visuals.distance", "boolean", true)
define("visuals.hideLooted", "boolean", true)
define("visuals.maxDistance", "number", 750, 50, 3000)
define("visuals.maxObjects", "number", 80, 10, 200)
define("visuals.maxHighlights", "number", 24, 0, 80)
define("visuals.textSize", "number", 14, 10, 22)
define("visuals.fillTransparency", "number", 80, 0, 100)
define("color.entities", "choice", "Red", nil, nil, {"Red", "Orange", "Purple", "White"})
define("color.items", "choice", "Cyan", nil, nil, {"Cyan", "Green", "White", "Purple"})
define("color.objectives", "choice", "Gold", nil, nil, {"Gold", "Green", "Cyan", "White"})
define("color.doors", "choice", "Green", nil, nil, {"Green", "Cyan", "White", "Purple"})
define("color.hiding", "choice", "Purple", nil, nil, {"Purple", "Cyan", "White", "Green"})
define("color.players", "choice", "White", nil, nil, {"White", "Cyan", "Green", "Purple"})

-- Alerts and direct objective guidance
define("alerts.entities", "boolean", true)
define("alerts.items", "boolean", false)
define("alerts.objectives", "boolean", true)
define("alerts.sound", "boolean", false)
define("alerts.duration", "number", 4, 2, 10)
define("alerts.cooldown", "number", 5, 0, 30)
define("alerts.style", "choice", "Toast", nil, nil, {"Toast", "Caption"})
define("guidance.enabled", "boolean", false)
define("guidance.includeItems", "boolean", false)
define("guidance.line", "boolean", true)

-- Local accessibility settings
define("player.fullbright", "boolean", false)
define("player.noFog", "boolean", false)
define("player.customFOV", "boolean", false)
define("player.fov", "number", 70, 50, 100)

-- Interface and performance
define("ui.accent", "choice", "Cyan", nil, nil, {"Cyan", "Purple", "Lime", "Amber"})
define("ui.opacity", "number", 4, 0, 35)
define("ui.toggleKey", "choice", "RightShift", nil, nil, {"RightShift", "RightControl", "Insert", "Home", "F6", "F8"})
define("ui.showOpenButton", "boolean", true)
define("ui.showQuickButtons", "boolean", Services.UserInputService.TouchEnabled)
define("ui.quick1", "choice", "Entities", nil, nil, {"Entities", "Items", "Objectives", "Guidance", "Panic", "None"})
define("ui.quick2", "choice", "Items", nil, nil, {"Entities", "Items", "Objectives", "Guidance", "Panic", "None"})
define("ui.quick3", "choice", "Panic", nil, nil, {"Entities", "Items", "Objectives", "Guidance", "Panic", "None"})
define("performance.lowPower", "boolean", Services.UserInputService.TouchEnabled)
define("performance.refreshHz", "number", 5, 1, 10)
define("performance.monitor", "boolean", false)

local function validateValue(key, value)
    local definition = Config.Definitions[key]
    if not definition then
        return nil, "unknown setting"
    end
    if definition.Kind == "boolean" then
        if type(value) ~= "boolean" then
            return nil, "expected boolean"
        end
        return value
    end
    if definition.Kind == "number" then
        if type(value) ~= "number" or value ~= value then
            return nil, "expected finite number"
        end
        return math.clamp(value, definition.Min, definition.Max)
    end
    if definition.Kind == "choice" then
        if type(value) ~= "string" then
            return nil, "expected choice"
        end
        for _, choice in ipairs(definition.Choices) do
            if value == choice then
                return value
            end
        end
        return nil, "unsupported choice"
    end
    return nil, "unsupported setting type"
end

function Config.OnChange(keys, callback)
    local listener = {Callback = callback, Active = true}
    for _, key in ipairs(keys) do
        if not Config.Listeners[key] then
            Config.Listeners[key] = {}
        end
        table.insert(Config.Listeners[key], listener)
    end
    return {
        Disconnect = function()
            listener.Active = false
        end,
    }
end

function Config.Set(key, value, quiet)
    local valid, err = validateValue(key, value)
    if valid == nil then
        if not quiet then
            Diagnostics.Log("WARN", "Rejected setting " .. tostring(key) .. ": " .. tostring(err))
        end
        return false
    end
    if Config.Values[key] == valid then
        return true
    end
    Config.Values[key] = valid
    local listeners = Config.Listeners[key]
    if listeners then
        for _, listener in ipairs(listeners) do
            if listener.Active then
                safeCall("Setting callback " .. key, listener.Callback, valid)
            end
        end
    end
    if Session.ScheduleSave then
        Session.ScheduleSave()
    end
    return true
end

function Config.Get(key)
    return Config.Values[key]
end

function Config.Reset()
    for key, definition in pairs(Config.Definitions) do
        Config.Set(key, definition.Default, true)
    end
    Diagnostics.Log("INFO", "Settings reset to defaults.")
end

function Session.SaveNow()
    if not Session.Available then
        return
    end
    local payload = {
        Version = 1,
        Config = Config.Values,
        UI = Session.UI,
    }
    local ok, encoded = pcall(Services.HttpService.JSONEncode, Services.HttpService, payload)
    if not ok then
        Diagnostics.Log("WARN", "Could not encode session settings: " .. trimLogText(encoded))
        return
    end
    local writeOk, writeErr = pcall(function()
        sessionValue.Value = encoded
    end)
    if not writeOk then
        Session.Available = false
        Diagnostics.Log("WARN", "Session settings are unavailable: " .. trimLogText(writeErr))
    end
end

function Session.ScheduleSave()
    if Session.SavePending or not Session.Available then
        return
    end
    Session.SavePending = true
    task.delay(0.35, function()
        Session.SavePending = false
        if State.Alive then
            Session.SaveNow()
        end
    end)
end

do
    local raw = sessionValue.Value
    if type(raw) == "string" and #raw > 0 and #raw < 200000 then
        local ok, decoded = pcall(Services.HttpService.JSONDecode, Services.HttpService, raw)
        if ok and type(decoded) == "table" and decoded.Version == 1 then
            if type(decoded.Config) == "table" then
                for key, value in pairs(decoded.Config) do
                    Config.Set(key, value, true)
                end
            end
            if type(decoded.UI) == "table" then
                Session.UI = decoded.UI
            end
            Diagnostics.Log("INFO", "Session settings loaded and validated.")
        elseif #raw > 0 then
            Diagnostics.Log("WARN", "Invalid saved session data was ignored.")
        end
    end
end

local Modules = {
    Records = {},
    Order = {},
}

function Modules.Define(name, start, stop)
    Modules.Records[name] = {
        Name = name,
        StartCallback = start,
        StopCallback = stop,
        Running = false,
        Status = "Stopped",
        LastError = nil,
        Scope = nil,
        Restarts = 0,
    }
    table.insert(Modules.Order, name)
end

function Modules.Start(name)
    local record = Modules.Records[name]
    if not record or record.Running or not State.Alive then
        return false
    end
    record.Running = true
    record.Status = "Starting"
    record.LastError = nil
    record.Scope = Scope.new(name)
    record.Scope.OnError = function(message)
        record.Status = "Error"
        record.LastError = message
    end
    local ok, err = pcall(record.StartCallback, record.Scope)
    if not ok then
        record.LastError = trimLogText(err)
        record.Status = "Error"
        record.Running = false
        if record.StopCallback then
            local cleanupOk, cleanupErr = pcall(record.StopCallback, record.Scope)
            if not cleanupOk then
                Diagnostics.Log("ERROR", name .. " rollback: " .. trimLogText(cleanupErr))
            end
        end
        record.Scope:Destroy()
        record.Scope = nil
        Diagnostics.Log("ERROR", name .. " failed to start: " .. record.LastError)
        return false
    end
    record.Status = "Running"
    return true
end

function Modules.Stop(name)
    local record = Modules.Records[name]
    if not record or not record.Running then
        return false
    end
    record.Running = false
    if record.StopCallback then
        local ok, err = pcall(record.StopCallback, record.Scope)
        if not ok then
            Diagnostics.Log("ERROR", name .. " cleanup: " .. trimLogText(err))
            record.LastError = trimLogText(err)
        end
    end
    if record.Scope then
        record.Scope:Destroy()
    end
    record.Scope = nil
    record.Status = record.LastError and "Error" or "Stopped"
    return true
end

function Modules.Restart(name)
    local record = Modules.Records[name]
    if not record then
        return false
    end
    Modules.Stop(name)
    record.Restarts = record.Restarts + 1
    return Modules.Start(name)
end

function Modules.StopAll()
    for index = #Modules.Order, 1, -1 do
        Modules.Stop(Modules.Order[index])
    end
end

-- ---------------------------------------------------------------------------
-- Object and entity detection
-- ---------------------------------------------------------------------------

local Palette = {
    Cyan = Color3.fromRGB(76, 214, 255),
    Purple = Color3.fromRGB(177, 126, 255),
    Lime = Color3.fromRGB(143, 230, 128),
    Amber = Color3.fromRGB(255, 190, 92),
    Red = Color3.fromRGB(255, 91, 110),
    Orange = Color3.fromRGB(255, 145, 77),
    Gold = Color3.fromRGB(255, 210, 92),
    Green = Color3.fromRGB(88, 220, 151),
    White = Color3.fromRGB(235, 240, 248),
}

local function normalizeName(value)
    return string.lower(string.gsub(tostring(value or ""), "[^%w]", ""))
end

local function cleanName(value)
    local text = string.gsub(tostring(value or "Object"), "_", " ")
    text = string.gsub(text, "(%l)(%u)", "%1 %2")
    if #text > 48 then
        text = string.sub(text, 1, 45) .. "..."
    end
    return text
end

local ITEM_NAMES = {
    "Alarm Clock", "Aloe", "Bandage", "Bandage Pack", "Battery", "Battery Pack",
    "Bulklight", "Bread", "Candle", "Compass", "Crucifix", "Flashlight",
    "Glowstick", "Green Herb", "Lighter", "Lockpicks", "Lantern", "Laser Pointer",
    "Moonlight Candle", "Moonlight Float", "Multitool", "NVCS-3000", "Rift Jar",
    "Shakelight", "Shears", "Skeleton Key", "Smoothie", "Spotlight",
    "Starlight Bottle", "Starlight Jug", "Starlight Vial", "Straplight",
    "Tip Jar", "Vitamins", "Fuel Can", "Scanner", "Large Screw", "Briefcase",
    "Broken Monitor", "Broken Lamp", "Bottle Crate", "Coin Roll", "Glitch Fragment",
    "Lotus Petal", "Scanner Module", "Stardust", "Pocket Mirror", "Pizza",
    "Gween Soda", "Pack of Gween Soda", "Candy", "Iron Key", "Waiting Ticket",
}

local ITEM_ALIASES = {
    lockpick = "Lockpicks",
    vitamin = "Vitamins",
    bandages = "Bandage",
    glowsticks = "Glowstick",
    starbottle = "Starlight Bottle",
    starjug = "Starlight Jug",
    starvial = "Starlight Vial",
    jerrycan = "Fuel Can",
    dinkylamp = "Broken Lamp",
    objectscanner = "Scanner",
    glitchcube = "Glitch Fragment",
    stardustpickup = "Stardust",
    modulescanner = "Scanner Module",
    gweensodapack = "Pack of Gween Soda",
    aloevera = "Aloe",
    holygrenade = "Holy Hand Grenade",
}

local ITEM_LOOKUP = {}
for _, name in ipairs(ITEM_NAMES) do
    ITEM_LOOKUP[normalizeName(name)] = name
end
for alias, name in pairs(ITEM_ALIASES) do
    ITEM_LOOKUP[alias] = name
end

local OBJECTIVE_LOOKUP = {
    keyobtain = "Key",
    electricalkeyobtain = "Electrical Room Key",
    fuseobtain = "Fuse",
    leverforgate = "Lever",
    timerlever = "Timer Lever",
    livehintbook = "Library Book",
    livebreakerpolepickup = "Breaker Pole",
    stairwellfirealarm = "Fire Alarm Lever",
    sallystoy = "Sally's Toy",
    sallytoy = "Sally's Toy",
    waterpump = "Water Pump",
    libraryhintpaper = "Hint Paper",
    breakerbox = "Breaker Box",
    anchor = "Anchor",
    powerbox = "Power Box",
}

local ENTITY_LOOKUP = {
    rush = "Rush", rushmoving = "Rush",
    ambush = "Ambush", ambushmoving = "Ambush",
    eyes = "Eyes", halt = "Halt", screech = "Screech",
    seek = "Seek", seekmoving = "Seek", seekrig = "Seek",
    figure = "Figure", figurerig = "Figure", figureragdoll = "Figure",
    timothy = "Timothy", void = "Void", dread = "Dread",
    snare = "Snare", giggle = "Giggle", gloombat = "Gloombat",
    grumble = "Grumble", queengrumble = "Queen Grumble",
    blitz = "Blitz", backdoorrush = "Blitz",
    lookman = "Lookman", backdoorlookman = "Lookman", haste = "Haste",
    groundskeeper = "Groundskeeper", thegroundskeeper = "Groundskeeper",
    caw = "Caw", monument = "Monument", surge = "Surge",
    mandrake = "Mandrake", eyestalk = "Eyestalk", bramble = "Bramble",
    grampy = "Grampy", worldlotus = "World Lotus", theworldlotus = "World Lotus",
    honcho = "Honcho", drone = "Drone", drones = "Drone",
    forgetmenot = "Forget-Me-Nots", forgetmenots = "Forget-Me-Nots",
    teller = "Teller", alma = "Alma", portrait = "Portrait",
    a60 = "A-60", bash = "A-60", bashmoving = "A-60", bashrig = "A-60",
    a120 = "A-120", scribbles = "A-120",
    discoloration = "Discoloration", currents = "Currents",
    creak = "Creak", stem = "Stem", stemmoving = "Stem", stemrig = "Stem",
    meld = "Meld", cobbler = "Cobbler", hijack = "Hijack",
    glitch = "Glitch", glitchedrush = "Glitched Rush",
    glitchedambush = "Glitched Ambush", jeff = "Jeff", jeffthekiller = "Jeff the Killer",
    elgoblino = "El Goblino", goblino = "El Goblino", bob = "Bob",
}

local HIDING_LOOKUP = {
    wardrobe = "Closet", closet = "Closet", locker = "Locker",
    cupboard = "Cupboard", toolshed = "Tool Shed", bed = "Bed",
}

local CATEGORY_PRIORITY = {
    players = 10,
    items = 30,
    hiding = 40,
    doors = 50,
    objectives = 70,
    entities = 100,
}

local Detection = {
    Targets = {},
    TargetAdded = RootScope:Own(Instance.new("BindableEvent")),
    TargetRemoved = RootScope:Own(Instance.new("BindableEvent")),
    ScanCount = 0,
    LastScanDuration = 0,
}

local function resolvePart(instance)
    if not instance or not instance.Parent then
        return nil
    end
    if instance:IsA("BasePart") then
        return instance
    end
    if instance:IsA("Model") then
        if instance.PrimaryPart and instance.PrimaryPart.Parent then
            return instance.PrimaryPart
        end
        return instance:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local function roomFor(instance)
    local currentRooms = Workspace:FindFirstChild("CurrentRooms")
    if not currentRooms then
        return nil
    end
    local node = instance
    while node and node ~= Workspace do
        if node.Parent == currentRooms then
            return node
        end
        node = node.Parent
    end
    return nil
end

function Detection.Remove(instance)
    local record = Detection.Targets[instance]
    if not record then
        return
    end
    Detection.Targets[instance] = nil
    Detection.TargetRemoved:Fire(instance, record)
end

function Detection.Register(instance, category, label, options)
    if not instance or not instance.Parent or not instance:IsDescendantOf(Workspace) then
        return nil
    end
    if not (instance:IsA("Model") or instance:IsA("BasePart")) then
        return nil
    end
    if Players:GetPlayerFromCharacter(instance) == LocalPlayer then
        return nil
    end
    options = options or {}
    local existing = Detection.Targets[instance]
    if existing then
        local oldPriority = CATEGORY_PRIORITY[existing.Category] or 0
        local newPriority = CATEGORY_PRIORITY[category] or 0
        if oldPriority > newPriority then
            return existing
        end
        if existing.Category == category then
            existing.Label = label or existing.Label
            existing.Prompt = options.Prompt or existing.Prompt
            existing.Part = resolvePart(instance) or existing.Part
            return existing
        end
        Detection.Remove(instance)
    end
    local room = roomFor(instance)
    local roomNumber = room and tonumber(string.match(room.Name, "%d+")) or nil
    local record = {
        Instance = instance,
        Category = category,
        Label = label or cleanName(instance.Name),
        Prompt = options.Prompt,
        Part = resolvePart(instance),
        NextPartRetry = 0,
        RoomNumber = roomNumber,
        AddedAt = os.clock(),
        Known = options.Known ~= false,
    }
    Detection.Targets[instance] = record
    Detection.TargetAdded:Fire(instance, record)
    return record
end

local function classifyKnown(instance)
    local normalized = normalizeName(instance.Name)
    if instance:IsA("Model") and ENTITY_LOOKUP[normalized] then
        return "entities", ENTITY_LOOKUP[normalized]
    end
    if OBJECTIVE_LOOKUP[normalized] then
        return "objectives", OBJECTIVE_LOOKUP[normalized]
    end
    if ITEM_LOOKUP[normalized] then
        return "items", ITEM_LOOKUP[normalized]
    end
    if instance:IsA("Model") and HIDING_LOOKUP[normalized] then
        return "hiding", HIDING_LOOKUP[normalized]
    end
    return nil, nil
end

local function promptTarget(prompt)
    local target = prompt.Parent
    if target and target:IsA("Attachment") then
        target = target.Parent
    end
    if not target then
        return nil
    end
    local directCategory = classifyKnown(target)
    if directCategory then
        return target
    end
    if target:IsA("BasePart") and target.Parent and target.Parent:IsA("Model") then
        local parent = target.Parent
        if parent.Name ~= "CurrentRooms" then
            return parent
        end
    end
    return target
end

local function processPrompt(prompt)
    local target = promptTarget(prompt)
    if not target or target == Workspace then
        return
    end
    if prompt.Name == "HidePrompt" then
        local model = prompt:FindFirstAncestorWhichIsA("Model")
        if model and model.Parent then
            local normalized = normalizeName(model.Name)
            Detection.Register(model, "hiding", HIDING_LOOKUP[normalized] or cleanName(model.Name), {Prompt = prompt})
        end
        return
    end
    local category, label = classifyKnown(target)
    if category then
        Detection.Register(target, category, label, {Prompt = prompt})
        return
    end
    if prompt.Name == "ModulePrompt" or prompt.Name == "HerbPrompt" then
        local objectText = tostring(prompt.ObjectText or "")
        local displayAttribute = target:GetAttribute("DisplayName")
        local candidate = ITEM_LOOKUP[normalizeName(objectText)] or ITEM_LOOKUP[normalizeName(displayAttribute)]
        if candidate then
            Detection.Register(target, "items", candidate, {Prompt = prompt})
        elseif prompt.Name == "HerbPrompt" then
            Detection.Register(target, "items", "Green Herb", {Prompt = prompt})
        elseif objectText ~= "" and #objectText <= 48 then
            Detection.Register(target, "items", cleanName(objectText), {Prompt = prompt, Known = false})
        end
    end
end

local function processInstance(instance)
    if instance:IsA("ProximityPrompt") then
        processPrompt(instance)
        return
    end
    if not (instance:IsA("Model") or instance:IsA("BasePart")) then
        return
    end
    local category, label = classifyKnown(instance)
    if category then
        Detection.Register(instance, category, label)
        return
    end
    if instance.Name == "Door" and roomFor(instance) then
        local room = roomFor(instance)
        local number = room and string.match(room.Name, "%d+")
        Detection.Register(instance, "doors", number and ("Door " .. number) or "Door")
    end
end

function Detection.Counts()
    local counts = {
        entities = 0, items = 0, objectives = 0,
        doors = 0, hiding = 0, players = 0,
    }
    for _, record in pairs(Detection.Targets) do
        counts[record.Category] = (counts[record.Category] or 0) + 1
    end
    return counts
end

function Detection.Clear()
    local instances = {}
    for instance in pairs(Detection.Targets) do
        table.insert(instances, instance)
    end
    for _, instance in ipairs(instances) do
        Detection.Remove(instance)
    end
end

Modules.Define("Detection", function(scope)
    Detection.Clear()
    scope:Connect(Workspace.DescendantAdded, function(instance)
        processInstance(instance)
    end)
    scope:Connect(Workspace.DescendantRemoving, function(instance)
        if Detection.Targets[instance] then
            Detection.Remove(instance)
        else
            for _, record in pairs(Detection.Targets) do
                if record.Part == instance then
                    record.Part = nil
                    record.NextPartRetry = 0
                end
            end
        end
    end)

    local playerScopes = {}
    local function removePlayer(player)
        local playerScope = playerScopes[player]
        if playerScope then
            playerScope:Destroy()
            playerScopes[player] = nil
        end
    end
    local function trackPlayer(player)
        if player == LocalPlayer or playerScopes[player] then
            return
        end
        local playerScope = Scope.new("Player detection " .. player.Name)
        scope:Own(playerScope)
        playerScopes[player] = playerScope
        playerScope:Connect(player.CharacterAdded, function(character)
            task.defer(function()
                if not playerScope.Dead and character.Parent then
                    Detection.Register(character, "players", player.DisplayName)
                end
            end)
        end)
        playerScope:Connect(player.CharacterRemoving, function(character)
            Detection.Remove(character)
        end)
        if player.Character then
            Detection.Register(player.Character, "players", player.DisplayName)
        end
    end
    for _, player in ipairs(Players:GetPlayers()) do
        trackPlayer(player)
    end
    scope:Connect(Players.PlayerAdded, trackPlayer)
    scope:Connect(Players.PlayerRemoving, function(player)
        if player.Character then
            Detection.Remove(player.Character)
        end
        removePlayer(player)
    end)

    scope:Spawn(function()
        local started = os.clock()
        local descendants = Workspace:GetDescendants()
        for index, instance in ipairs(descendants) do
            if scope.Dead or not State.Alive then
                return
            end
            processInstance(instance)
            if index % 250 == 0 then
                task.wait()
            end
        end
        Detection.ScanCount = Detection.ScanCount + 1
        Detection.LastScanDuration = os.clock() - started
        Diagnostics.Log("INFO", string.format("Detection scan: %d instances in %.3f s.", #descendants, Detection.LastScanDuration))
    end)
end, function()
    Detection.Clear()
end)

Modules.Start("Detection")

-- ---------------------------------------------------------------------------
-- Shared GUI layers (the main window is built later)
-- ---------------------------------------------------------------------------

local UnloadADS
local Gui = RootScope:Own(Instance.new("ScreenGui"))
Gui.Name = APP_ID
Gui.ResetOnSpawn = false
Gui.IgnoreGuiInset = false
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.DisplayOrder = 50
Gui.Parent = PlayerGui

local Shutdown = Instance.new("BindableEvent")
Shutdown.Name = "Shutdown"
Shutdown.Parent = Gui
RootScope:Connect(Shutdown.Event, function()
    if UnloadADS then
        UnloadADS()
    end
end)

local WorldLayer = Instance.new("Folder")
WorldLayer.Name = "WorldVisuals"
WorldLayer.Parent = Gui

local GuideLayer = Instance.new("Frame")
GuideLayer.Name = "Guidance"
GuideLayer.Size = UDim2.fromScale(1, 1)
GuideLayer.BackgroundTransparency = 1
GuideLayer.ZIndex = 4
GuideLayer.Parent = Gui

local NotificationCenter = {Handler = nil}
function NotificationCenter.Notify(title, body, kind)
    if NotificationCenter.Handler then
        safeCall("Notification", NotificationCenter.Handler, title, body, kind)
    else
        Diagnostics.Log("INFO", tostring(title) .. ": " .. tostring(body))
    end
end

-- ---------------------------------------------------------------------------
-- ESP renderer: one update loop, shared target registry, lazy visuals
-- ---------------------------------------------------------------------------

local ESP = {
    Visuals = {},
    VisibleCount = 0,
    LastUpdateMs = 0,
    AverageUpdateMs = 0,
    MaxUpdateMs = 0,
}

local CATEGORY_SETTING = {
    entities = "visuals.entities",
    items = "visuals.items",
    objectives = "visuals.objectives",
    doors = "visuals.doors",
    hiding = "visuals.hiding",
    players = "visuals.players",
}

local function categoryEnabled(category)
    local key = CATEGORY_SETTING[category]
    return key ~= nil and Config.Get(key) == true
end

local function anyESPEnabled()
    if not Config.Get("visuals.master") then
        return false
    end
    for category in pairs(CATEGORY_SETTING) do
        if categoryEnabled(category) then
            return true
        end
    end
    return false
end

local function syncDetection()
    local needed = anyESPEnabled()
        or Config.Get("alerts.entities") or Config.Get("alerts.items") or Config.Get("alerts.objectives")
        or Config.Get("guidance.enabled")
    if needed then
        Modules.Start("Detection")
    else
        Modules.Stop("Detection")
    end
end

local function destroyESPVisual(instance)
    local visual = ESP.Visuals[instance]
    if not visual then
        return
    end
    ESP.Visuals[instance] = nil
    if visual.Highlight then
        visual.Highlight:Destroy()
    end
    if visual.Billboard then
        visual.Billboard:Destroy()
    end
end

local function hideESPVisual(visual, now)
    if visual.Highlight then
        visual.Highlight.Enabled = false
    end
    if visual.Billboard then
        visual.Billboard.Enabled = false
    end
    if visual.Visible then
        visual.HiddenSince = now
    end
    visual.Visible = false
end

local function buildESPVisual(instance, record)
    local existing = ESP.Visuals[instance]
    if existing then
        return existing
    end
    local highlight = Instance.new("Highlight")
    highlight.Name = "ADS_Highlight"
    highlight.Adornee = instance
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.OutlineTransparency = 0
    highlight.Enabled = false
    highlight.Parent = WorldLayer

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "ADS_Label"
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.Size = UDim2.fromOffset(200, 44)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0)
    billboard.Enabled = false
    billboard.Parent = WorldLayer

    local label = Instance.new("TextLabel")
    label.Name = "Text"
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamMedium
    label.TextStrokeColor3 = Color3.new(0, 0, 0)
    label.TextStrokeTransparency = 0.35
    label.TextWrapped = true
    label.Parent = billboard

    local visual = {
        Highlight = highlight,
        Billboard = billboard,
        Label = label,
        Visible = false,
        HiddenSince = nil,
    }
    ESP.Visuals[instance] = visual
    return visual
end

local function updateESP()
    local started = os.clock()
    local camera = Workspace.CurrentCamera
    if not camera then
        return
    end
    local now = os.clock()
    local cameraPosition = camera.CFrame.Position
    local maximumDistance = Config.Get("visuals.maxDistance")
    local candidates = {}

    for instance, record in pairs(Detection.Targets) do
        local visual = ESP.Visuals[instance]
        if not instance.Parent then
            if visual then
                destroyESPVisual(instance)
            end
        else
            local part = record.Part
            if not part or not part.Parent then
                if now >= (record.NextPartRetry or 0) then
                    record.Part = resolvePart(instance)
                    record.NextPartRetry = now + 1
                    part = record.Part
                end
            end
            local allowed = part ~= nil and categoryEnabled(record.Category)
            if allowed and Config.Get("visuals.hideLooted") and record.Prompt then
                if not record.Prompt.Parent or not record.Prompt.Enabled then
                    allowed = false
                end
            end
            if allowed and record.Category == "doors" and record.RoomNumber and State.CurrentRoom then
                if record.RoomNumber < State.CurrentRoom then
                    allowed = false
                end
            end
            local distance = math.huge
            if allowed then
                distance = (part.Position - cameraPosition).Magnitude
                allowed = distance <= maximumDistance
            end
            if allowed then
                table.insert(candidates, {
                    Instance = instance,
                    Record = record,
                    Part = part,
                    Distance = distance,
                })
            elseif visual then
                hideESPVisual(visual, now)
                if visual.HiddenSince and now - visual.HiddenSince > 20 then
                    destroyESPVisual(instance)
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        local aEntity = a.Record.Category == "entities" and 0 or 1
        local bEntity = b.Record.Category == "entities" and 0 or 1
        if aEntity ~= bEntity then
            return aEntity < bEntity
        end
        return a.Distance < b.Distance
    end)

    local maximumObjects = math.floor(Config.Get("visuals.maxObjects"))
    local maximumHighlights = math.floor(Config.Get("visuals.maxHighlights"))
    local showHighlight = Config.Get("visuals.highlights")
    local showLabels = Config.Get("visuals.labels")
    local showDistance = Config.Get("visuals.distance")
    local textSize = math.floor(Config.Get("visuals.textSize"))
    local fillTransparency = 1 - Config.Get("visuals.fillTransparency") / 100
    local visibleSet = {}

    for index, candidate in ipairs(candidates) do
        if index > maximumObjects then
            break
        end
        local instance = candidate.Instance
        local record = candidate.Record
        local part = candidate.Part
        local visual = buildESPVisual(instance, record)
        visibleSet[instance] = true
        local colorName = Config.Get("color." .. record.Category) or "White"
        local color = Palette[colorName] or Palette.White
        local labelText = record.Label
        if record.Category == "doors" and instance:FindFirstChild("Lock") then
            labelText = labelText .. " [Locked]"
        end
        if showLabels and showDistance then
            labelText = string.format("%s\n%d m", labelText, math.floor(candidate.Distance * 0.28 + 0.5))
        elseif showDistance then
            labelText = string.format("%d m", math.floor(candidate.Distance * 0.28 + 0.5))
        elseif not showLabels then
            labelText = ""
        end

        visual.Highlight.Adornee = instance
        visual.Highlight.FillColor = color
        visual.Highlight.OutlineColor = color
        visual.Highlight.FillTransparency = fillTransparency
        visual.Highlight.Enabled = showHighlight and index <= maximumHighlights
        visual.Billboard.Adornee = part
        visual.Billboard.MaxDistance = maximumDistance
        visual.Label.TextColor3 = color
        visual.Label.TextSize = textSize
        if visual.Label.Text ~= labelText then
            visual.Label.Text = labelText
        end
        visual.Billboard.Enabled = labelText ~= ""
        visual.Visible = true
        visual.HiddenSince = nil
    end

    for instance, visual in pairs(ESP.Visuals) do
        if not visibleSet[instance] and visual.Visible then
            hideESPVisual(visual, now)
        end
    end
    ESP.VisibleCount = 0
    for _ in pairs(visibleSet) do
        ESP.VisibleCount = ESP.VisibleCount + 1
    end
    local elapsed = (os.clock() - started) * 1000
    ESP.LastUpdateMs = elapsed
    ESP.MaxUpdateMs = math.max(ESP.MaxUpdateMs, elapsed)
    if ESP.AverageUpdateMs == 0 then
        ESP.AverageUpdateMs = elapsed
    else
        ESP.AverageUpdateMs = ESP.AverageUpdateMs * 0.9 + elapsed * 0.1
    end
end

Modules.Define("ESP", function(scope)
    scope:Connect(Detection.TargetRemoved.Event, function(instance)
        destroyESPVisual(instance)
    end)
    scope:Loop(function()
        local hz = Config.Get("performance.refreshHz")
        if Config.Get("performance.lowPower") then
            hz = math.max(1, hz * 0.5)
        end
        return 1 / hz
    end, updateESP)
end, function()
    for instance in pairs(ESP.Visuals) do
        destroyESPVisual(instance)
    end
    ESP.VisibleCount = 0
end)

local function syncESP()
    syncDetection()
    if anyESPEnabled() then
        Modules.Start("ESP")
    else
        Modules.Stop("ESP")
    end
end
local espConfigListener = Config.OnChange({
    "visuals.master", "visuals.entities", "visuals.items", "visuals.objectives",
    "visuals.doors", "visuals.hiding", "visuals.players",
}, syncESP)

-- ---------------------------------------------------------------------------
-- Alerts with per-instance and per-label de-duplication
-- ---------------------------------------------------------------------------

local ENTITY_TIPS = {
    Rush = "Find a hiding place.",
    Ambush = "Hide; it may return several times.",
    Screech = "Look around and find it quickly.",
    Eyes = "Avoid looking at it.",
    Halt = "Follow its movement cues.",
    Seek = "Prepare for a chase.",
    Figure = "Stay quiet and keep your distance.",
    Giggle = "Watch the ceiling.",
    Snare = "Watch the floor.",
    Dread = "Keep moving toward the exit.",
}

local Alerts = {
    Seen = setmetatable({}, {__mode = "k"}),
    LastByLabel = {},
}

Modules.Define("Alerts", function(scope)
    scope:Connect(Detection.TargetAdded.Event, function(instance, record)
        local enabled = false
        if record.Category == "entities" then
            enabled = Config.Get("alerts.entities")
        elseif record.Category == "items" then
            enabled = Config.Get("alerts.items")
        elseif record.Category == "objectives" then
            enabled = Config.Get("alerts.objectives")
        end
        if not enabled or Alerts.Seen[instance] then
            return
        end
        Alerts.Seen[instance] = true
        local now = os.clock()
        local key = record.Category .. ":" .. record.Label
        if now - (Alerts.LastByLabel[key] or -math.huge) < Config.Get("alerts.cooldown") then
            return
        end
        Alerts.LastByLabel[key] = now
        local body = record.Label .. " detected."
        if record.Category == "entities" and ENTITY_TIPS[record.Label] then
            body = record.Label .. " — " .. ENTITY_TIPS[record.Label]
        end
        NotificationCenter.Notify(record.Category == "entities" and "Entity alert" or "ADS", body, record.Category)
    end)
end, function()
    table.clear(Alerts.LastByLabel)
    Alerts.Seen = setmetatable({}, {__mode = "k"})
end)

local function syncAlerts()
    syncDetection()
    if Config.Get("alerts.entities") or Config.Get("alerts.items") or Config.Get("alerts.objectives") then
        Modules.Start("Alerts")
    else
        Modules.Stop("Alerts")
    end
end
local alertsConfigListener = Config.OnChange({"alerts.entities", "alerts.items", "alerts.objectives"}, syncAlerts)

-- ---------------------------------------------------------------------------
-- Direct nearest-objective guidance (not a pathfinding promise)
-- ---------------------------------------------------------------------------

local GuideLine = Instance.new("Frame")
GuideLine.Name = "DirectLine"
GuideLine.AnchorPoint = Vector2.new(0.5, 0.5)
GuideLine.BorderSizePixel = 0
GuideLine.BackgroundColor3 = Palette.Gold
GuideLine.ZIndex = 5
GuideLine.Visible = false
GuideLine.Parent = GuideLayer

local GuideText = Instance.new("TextLabel")
GuideText.Name = "Status"
GuideText.AnchorPoint = Vector2.new(0.5, 0)
GuideText.Position = UDim2.new(0.5, 0, 0, 62)
GuideText.Size = UDim2.new(1, -24, 0, 38)
GuideText.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
GuideText.BackgroundTransparency = 0.15
GuideText.TextColor3 = Palette.White
GuideText.Font = Enum.Font.GothamMedium
GuideText.TextSize = 14
GuideText.ZIndex = 5
GuideText.Visible = false
GuideText.Parent = GuideLayer
local guideCorner = Instance.new("UICorner")
guideCorner.CornerRadius = UDim.new(0, 8)
guideCorner.Parent = GuideText

local Guidance = {Target = nil, StatusText = "Guidance is off."}

local function clearGuidanceTarget()
    Guidance.Target = nil
    GuideLine.Visible = false
end

local function updateGuidanceTarget()
    local bestRecord, bestPart, bestDistance = nil, nil, math.huge
    local camera = Workspace.CurrentCamera
    local origin = State.RootPart and State.RootPart.Position or camera and camera.CFrame.Position
    if not origin then
        Guidance.StatusText = "Waiting for character..."
        GuideText.Text = Guidance.StatusText
        return
    end
    for _, record in pairs(Detection.Targets) do
        local allowed = record.Category == "objectives"
        if Config.Get("guidance.includeItems") and record.Category == "items" then
            allowed = true
        end
        if allowed and record.Instance.Parent then
            local part = record.Part or resolvePart(record.Instance)
            record.Part = part
            if part then
                local distance = (part.Position - origin).Magnitude
                if distance < bestDistance and distance <= Config.Get("visuals.maxDistance") then
                    bestRecord, bestPart, bestDistance = record, part, distance
                end
            end
        end
    end
    Guidance.Target = bestRecord
    if bestRecord then
        Guidance.StatusText = string.format("Nearest: %s · %d m", bestRecord.Label, math.floor(bestDistance * 0.28 + 0.5))
    else
        Guidance.StatusText = "No matching objective in range."
    end
    GuideText.Text = Guidance.StatusText
end

Modules.Define("Guidance", function(scope)
    GuideText.Visible = true
    scope:Connect(Detection.TargetRemoved.Event, function(_, record)
        if Guidance.Target == record then
            clearGuidanceTarget()
        end
    end)
    scope:Loop(function()
        return Config.Get("performance.lowPower") and 1 or 0.5
    end, updateGuidanceTarget)
    scope:Connect(Services.RunService.RenderStepped, function()
        local record = Guidance.Target
        local camera = Workspace.CurrentCamera
        if not record or not record.Instance.Parent or not camera or not Config.Get("guidance.line") then
            GuideLine.Visible = false
            return
        end
        local part = record.Part
        if not part or not part.Parent then
            GuideLine.Visible = false
            return
        end
        local screenPoint, onScreen = camera:WorldToViewportPoint(part.Position)
        if not onScreen or screenPoint.Z <= 0 then
            GuideLine.Visible = false
            return
        end
        local viewport = camera.ViewportSize
        local origin = Vector2.new(viewport.X * 0.5, viewport.Y - 80)
        local destination = Vector2.new(screenPoint.X, screenPoint.Y)
        local delta = destination - origin
        local length = delta.Magnitude
        if length < 12 then
            GuideLine.Visible = false
            return
        end
        GuideLine.Size = UDim2.fromOffset(length, 2)
        GuideLine.Position = UDim2.fromOffset((origin.X + destination.X) * 0.5, (origin.Y + destination.Y) * 0.5)
        GuideLine.Rotation = math.deg(math.atan2(delta.Y, delta.X))
        GuideLine.Visible = true
    end)
end, function()
    clearGuidanceTarget()
    GuideText.Visible = false
    Guidance.StatusText = "Guidance is off."
end)

local function syncGuidance()
    syncDetection()
    if Config.Get("guidance.enabled") then
        Modules.Start("Guidance")
    else
        Modules.Stop("Guidance")
    end
end
local guidanceConfigListener = Config.OnChange({"guidance.enabled"}, syncGuidance)

-- ---------------------------------------------------------------------------
-- Local lighting/camera accessibility and player lifecycle
-- ---------------------------------------------------------------------------

local Environment = {LightingSnapshot = nil}

Modules.Define("Fullbright", function()
    Environment.LightingSnapshot = {
        Ambient = Services.Lighting.Ambient,
        OutdoorAmbient = Services.Lighting.OutdoorAmbient,
        Brightness = Services.Lighting.Brightness,
        GlobalShadows = Services.Lighting.GlobalShadows,
    }
    Services.Lighting.Ambient = Color3.fromRGB(95, 95, 95)
    Services.Lighting.OutdoorAmbient = Color3.fromRGB(110, 110, 110)
    Services.Lighting.Brightness = 2
    Services.Lighting.GlobalShadows = false
end, function()
    local snapshot = Environment.LightingSnapshot
    if snapshot then
        Services.Lighting.Ambient = snapshot.Ambient
        Services.Lighting.OutdoorAmbient = snapshot.OutdoorAmbient
        Services.Lighting.Brightness = snapshot.Brightness
        Services.Lighting.GlobalShadows = snapshot.GlobalShadows
    end
    Environment.LightingSnapshot = nil
end)

local Fog = {LightingSnapshot = nil, Atmospheres = {}}
local function applyNoFog()
    Services.Lighting.FogStart = 0
    Services.Lighting.FogEnd = 100000
    for _, descendant in ipairs(Services.Lighting:GetDescendants()) do
        if descendant:IsA("Atmosphere") then
            if Fog.Atmospheres[descendant] == nil then
                Fog.Atmospheres[descendant] = descendant.Density
            end
            descendant.Density = 0
        end
    end
end

Modules.Define("NoFog", function(scope)
    Fog.LightingSnapshot = {
        FogStart = Services.Lighting.FogStart,
        FogEnd = Services.Lighting.FogEnd,
    }
    Fog.Atmospheres = {}
    applyNoFog()
    scope:Connect(Services.Lighting.DescendantAdded, function(descendant)
        if descendant:IsA("Atmosphere") then
            Fog.Atmospheres[descendant] = descendant.Density
            descendant.Density = 0
        end
    end)
end, function()
    if Fog.LightingSnapshot then
        Services.Lighting.FogStart = Fog.LightingSnapshot.FogStart
        Services.Lighting.FogEnd = Fog.LightingSnapshot.FogEnd
    end
    for atmosphere, density in pairs(Fog.Atmospheres) do
        if atmosphere.Parent then
            atmosphere.Density = density
        end
    end
    Fog.LightingSnapshot = nil
    Fog.Atmospheres = {}
end)

local CameraFOV = {Originals = setmetatable({}, {__mode = "k"})}
local function applyCameraFOV()
    local camera = Workspace.CurrentCamera
    if camera and CameraFOV.Originals[camera] == nil then
        CameraFOV.Originals[camera] = camera.FieldOfView
    end
    if camera then
        camera.FieldOfView = Config.Get("player.fov")
    end
end

Modules.Define("CameraFOV", function(scope)
    applyCameraFOV()
    scope:Connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), applyCameraFOV)
end, function()
    for camera, original in pairs(CameraFOV.Originals) do
        if camera.Parent then
            camera.FieldOfView = original
        end
    end
    CameraFOV.Originals = setmetatable({}, {__mode = "k"})
end)

local function syncEnvironment()
    if Config.Get("player.fullbright") then Modules.Start("Fullbright") else Modules.Stop("Fullbright") end
    if Config.Get("player.noFog") then Modules.Start("NoFog") else Modules.Stop("NoFog") end
    if Config.Get("player.customFOV") then Modules.Start("CameraFOV") else Modules.Stop("CameraFOV") end
end
local environmentConfigListener = Config.OnChange({"player.fullbright", "player.noFog", "player.customFOV"}, syncEnvironment)
local fovConfigListener = Config.OnChange({"player.fov"}, function()
    if Modules.Records.CameraFOV.Running then
        applyCameraFOV()
    end
end)

local PlayerLifecycle = {Status = "Waiting for character"}
local function refreshCharacter(character)
    State.Character = character
    State.Humanoid = nil
    State.RootPart = nil
    PlayerLifecycle.Status = "Loading character"
    task.spawn(function()
        if not State.Alive then return end
        local humanoid = character:WaitForChild("Humanoid", 6)
        local rootPart = character:WaitForChild("HumanoidRootPart", 6)
        if State.Character ~= character or not State.Alive then
            return
        end
        State.Humanoid = humanoid
        State.RootPart = rootPart
        if humanoid and rootPart then
            PlayerLifecycle.Status = "Character ready"
        else
            PlayerLifecycle.Status = "Character components unavailable"
            Diagnostics.Log("WARN", "Character loaded without Humanoid or HumanoidRootPart.")
        end
    end)
end

Modules.Define("PlayerLifecycle", function(scope)
    scope:Connect(LocalPlayer.CharacterAdded, refreshCharacter)
    scope:Connect(LocalPlayer.CharacterRemoving, function(character)
        if State.Character == character then
            State.Character = nil
            State.Humanoid = nil
            State.RootPart = nil
            PlayerLifecycle.Status = "Respawning"
        end
    end)
    scope:Connect(LocalPlayer:GetAttributeChangedSignal("CurrentRoom"), function()
        State.CurrentRoom = tonumber(LocalPlayer:GetAttribute("CurrentRoom"))
    end)
    State.CurrentRoom = tonumber(LocalPlayer:GetAttribute("CurrentRoom"))
    if LocalPlayer.Character then
        refreshCharacter(LocalPlayer.Character)
    end
    local gameData = Services.ReplicatedStorage:FindFirstChild("GameData")
    local floorValue = gameData and gameData:FindFirstChild("Floor")
    if floorValue and floorValue:IsA("ValueBase") then
        local function updateFloor()
            State.Floor = tostring(floorValue.Value)
        end
        scope:Connect(floorValue.Changed, updateFloor)
        updateFloor()
    end
end)
Modules.Start("PlayerLifecycle")

-- ---------------------------------------------------------------------------
-- Adaptive native UI (Obsidian-inspired, no external GUI library)
-- ---------------------------------------------------------------------------

local UI = {
    Tabs = {},
    TabOrder = {},
    Refreshers = {},
    ThemeBindings = {},
    CurrentTab = nil,
    Open = true,
}

local Theme = {
    Background = Color3.fromRGB(14, 17, 23),
    Panel = Color3.fromRGB(21, 25, 33),
    Control = Color3.fromRGB(27, 32, 42),
    ControlHover = Color3.fromRGB(34, 41, 53),
    Border = Color3.fromRGB(47, 55, 68),
    Text = Color3.fromRGB(232, 237, 245),
    Subtext = Color3.fromRGB(145, 155, 170),
    Danger = Color3.fromRGB(255, 91, 110),
}

local function create(className, properties, parent)
    local instance = Instance.new(className)
    for property, value in pairs(properties or {}) do
        instance[property] = value
    end
    instance.Parent = parent
    return instance
end

local function addCorner(parent, radius)
    return create("UICorner", {CornerRadius = UDim.new(0, radius or 7)}, parent)
end

local function addStroke(parent, color, thickness)
    return create("UIStroke", {
        Color = color or Theme.Border,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, parent)
end

local function bindAccent(instance, property)
    table.insert(UI.ThemeBindings, {Instance = instance, Property = property})
    instance[property] = Palette[Config.Get("ui.accent")] or Palette.Cyan
end

local Window = create("Frame", {
    Name = "MainWindow",
    BackgroundColor3 = Theme.Background,
    BackgroundTransparency = Config.Get("ui.opacity") / 100,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Active = true,
    ZIndex = 20,
    Parent = Gui,
})
addCorner(Window, 11)
addStroke(Window, Theme.Border, 1)

local Header = create("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundColor3 = Theme.Panel,
    BorderSizePixel = 0,
    ZIndex = 21,
    Parent = Window,
})
create("Frame", {
    Size = UDim2.new(1, 0, 0, 1),
    Position = UDim2.new(0, 0, 1, -1),
    BackgroundColor3 = Theme.Border,
    BorderSizePixel = 0,
    ZIndex = 22,
    Parent = Header,
})
local DragZone = create("TextLabel", {
    Name = "DragZone",
    Size = UDim2.new(1, -100, 1, 0),
    BackgroundTransparency = 1,
    Text = "",
    Active = true,
    ZIndex = 22,
    Parent = Header,
})
create("TextLabel", {
    Size = UDim2.new(1, -110, 0, 21),
    Position = UDim2.fromOffset(14, 5),
    BackgroundTransparency = 1,
    Text = "ADS",
    TextColor3 = Theme.Text,
    Font = Enum.Font.GothamBold,
    TextSize = 17,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 23,
    Parent = Header,
})
create("TextLabel", {
    Size = UDim2.new(1, -110, 0, 17),
    Position = UDim2.fromOffset(14, 26),
    BackgroundTransparency = 1,
    Text = "ABSOLUTE DOORS SCRIPT  ·  " .. VERSION,
    TextColor3 = Theme.Subtext,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 23,
    Parent = Header,
})

local MinimizeButton = create("TextButton", {
    Size = UDim2.fromOffset(38, 34),
    Position = UDim2.new(1, -84, 0, 7),
    BackgroundColor3 = Theme.Control,
    Text = "—",
    TextColor3 = Theme.Text,
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    AutoButtonColor = true,
    ZIndex = 24,
    Parent = Header,
})
addCorner(MinimizeButton, 7)
local CloseButton = create("TextButton", {
    Size = UDim2.fromOffset(38, 34),
    Position = UDim2.new(1, -42, 0, 7),
    BackgroundColor3 = Theme.Control,
    Text = "×",
    TextColor3 = Theme.Subtext,
    Font = Enum.Font.GothamBold,
    TextSize = 18,
    AutoButtonColor = true,
    ZIndex = 24,
    Parent = Header,
})
addCorner(CloseButton, 7)

local TabBar = create("ScrollingFrame", {
    Name = "Tabs",
    Position = UDim2.fromOffset(8, 54),
    Size = UDim2.new(1, -16, 0, 36),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.X,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = Theme.Border,
    ScrollingDirection = Enum.ScrollingDirection.X,
    ZIndex = 21,
    Parent = Window,
})
create("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 5),
    Parent = TabBar,
})

local Content = create("Frame", {
    Name = "Content",
    Position = UDim2.fromOffset(8, 96),
    Size = UDim2.new(1, -16, 1, -124),
    BackgroundTransparency = 1,
    ZIndex = 21,
    Parent = Window,
})
local Footer = create("TextLabel", {
    Name = "Footer",
    Position = UDim2.new(0, 12, 1, -24),
    Size = UDim2.new(1, -24, 0, 18),
    BackgroundTransparency = 1,
    Text = "Starting modules...",
    TextColor3 = Theme.Subtext,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 22,
    Parent = Window,
})

local function viewportSize()
    local camera = Workspace.CurrentCamera
    return camera and camera.ViewportSize or Vector2.new(800, 600)
end

local function clampObjectPosition(object, x, y)
    local viewport = viewportSize()
    local size = object.AbsoluteSize
    local width = math.max(size.X, 40)
    local height = math.max(size.Y, 40)
    local maximumX = math.max(4, viewport.X - width - 4)
    local maximumY = math.max(4, viewport.Y - height - 4)
    return math.clamp(x, 4, maximumX), math.clamp(y, 4, maximumY)
end

local function saveObjectPosition(key, object, x, y)
    local viewport = viewportSize()
    local size = object.AbsoluteSize
    Session.UI[key] = {
        X = (x + size.X * 0.5) / math.max(1, viewport.X),
        Y = (y + size.Y * 0.5) / math.max(1, viewport.Y),
    }
    Session.ScheduleSave()
end

local function positionFromSession(object, key, defaultX, defaultY)
    local viewport = viewportSize()
    local saved = Session.UI[key]
    local x, y = defaultX, defaultY
    if type(saved) == "table" and type(saved.X) == "number" and type(saved.Y) == "number" then
        x = saved.X * viewport.X - object.AbsoluteSize.X * 0.5
        y = saved.Y * viewport.Y - object.AbsoluteSize.Y * 0.5
    end
    x, y = clampObjectPosition(object, x, y)
    object.Position = UDim2.fromOffset(x, y)
end

local function makeDraggable(handle, object, sessionKey, onTap)
    local dragging = false
    local moved = false
    local dragInput = nil
    local startPoint = Vector2.new()
    local startPosition = Vector2.new()
    RootScope:Connect(handle.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            moved = false
            dragInput = input
            startPoint = Vector2.new(input.Position.X, input.Position.Y)
            startPosition = object.AbsolutePosition
        end
    end)
    RootScope:Connect(Services.UserInputService.InputChanged, function(input)
        if not dragging then
            return
        end
        local valid = input.UserInputType == Enum.UserInputType.MouseMovement
        if dragInput and dragInput.UserInputType == Enum.UserInputType.Touch then
            valid = input == dragInput
        end
        if not valid then
            return
        end
        local current = Vector2.new(input.Position.X, input.Position.Y)
        local delta = current - startPoint
        if delta.Magnitude > 7 then
            moved = true
        end
        if moved then
            local x, y = clampObjectPosition(object, startPosition.X + delta.X, startPosition.Y + delta.Y)
            object.Position = UDim2.fromOffset(x, y)
        end
    end)
    RootScope:Connect(Services.UserInputService.InputEnded, function(input)
        if not dragging then
            return
        end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        if dragInput and dragInput.UserInputType == Enum.UserInputType.Touch and input ~= dragInput then
            return
        end
        dragging = false
        if moved then
            saveObjectPosition(sessionKey, object, object.AbsolutePosition.X, object.AbsolutePosition.Y)
        elseif onTap then
            safeCall("Floating button", onTap)
        end
        dragInput = nil
    end)
end

makeDraggable(DragZone, Window, "Window")

local OpenButton = create("TextButton", {
    Name = "OpenADS",
    Size = UDim2.fromOffset(50, 50),
    BackgroundColor3 = Theme.Panel,
    BackgroundTransparency = 0.08,
    Text = "ADS",
    TextColor3 = Theme.Text,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    AutoButtonColor = false,
    Visible = false,
    ZIndex = 45,
    Parent = Gui,
})
addCorner(OpenButton, 25)
local openStroke = addStroke(OpenButton, Palette.Cyan, 2)
bindAccent(openStroke, "Color")

local function refreshOpenVisibility()
    OpenButton.Visible = not UI.Open and Config.Get("ui.showOpenButton")
end

function UI.SetOpen(open)
    UI.Open = open
    Window.Visible = open
    refreshOpenVisibility()
    if UI.RefreshQuickButtons then
        UI.RefreshQuickButtons()
    end
end

makeDraggable(OpenButton, OpenButton, "OpenButton", function()
    UI.SetOpen(true)
end)
OpenButton.Active = true

RootScope:Connect(MinimizeButton.Activated, function()
    UI.SetOpen(false)
end)
local closeArmed = false
RootScope:Connect(CloseButton.Activated, function()
    if closeArmed then
        if UnloadADS then
            UnloadADS()
        end
        return
    end
    closeArmed = true
    CloseButton.Text = "!"
    CloseButton.TextColor3 = Theme.Danger
    NotificationCenter.Notify("ADS", "Tap ! again to unload and clean up all resources.", "warning")
    task.delay(3, function()
        if State.Alive then
            closeArmed = false
            CloseButton.Text = "×"
            CloseButton.TextColor3 = Theme.Subtext
        end
    end)
end)

local Modal = create("Frame", {
    Name = "ChoiceModal",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.35,
    Visible = false,
    Active = true,
    ZIndex = 90,
    Parent = Window,
})
local ModalPanel = create("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(310, 280),
    BackgroundColor3 = Theme.Panel,
    BorderSizePixel = 0,
    ZIndex = 91,
    Parent = Modal,
})
addCorner(ModalPanel, 10)
addStroke(ModalPanel, Theme.Border, 1)
local ModalTitle = create("TextLabel", {
    Position = UDim2.fromOffset(14, 8),
    Size = UDim2.new(1, -58, 0, 34),
    BackgroundTransparency = 1,
    Text = "Select",
    TextColor3 = Theme.Text,
    Font = Enum.Font.GothamSemibold,
    TextSize = 15,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 92,
    Parent = ModalPanel,
})
local ModalClose = create("TextButton", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -8, 0, 8),
    Size = UDim2.fromOffset(36, 34),
    BackgroundColor3 = Theme.Control,
    Text = "×",
    TextColor3 = Theme.Text,
    Font = Enum.Font.GothamBold,
    TextSize = 17,
    ZIndex = 93,
    Parent = ModalPanel,
})
addCorner(ModalClose, 7)
local ModalList = create("ScrollingFrame", {
    Position = UDim2.fromOffset(10, 48),
    Size = UDim2.new(1, -20, 1, -58),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness = 3,
    ZIndex = 92,
    Parent = ModalPanel,
})
create("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 5),
    Parent = ModalList,
})
RootScope:Connect(ModalClose.Activated, function()
    Modal.Visible = false
end)

local ModalChoiceScope = nil
function UI.OpenChoices(title, choices, current, onPick)
    if ModalChoiceScope then
        ModalChoiceScope:Destroy()
    end
    ModalChoiceScope = Scope.new("Choice modal")
    ModalTitle.Text = title
    for _, child in ipairs(ModalList:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end
    for index, choice in ipairs(choices) do
        local option = create("TextButton", {
            Size = UDim2.new(1, -4, 0, 42),
            BackgroundColor3 = choice == current and Theme.ControlHover or Theme.Control,
            Text = tostring(choice),
            TextColor3 = choice == current and (Palette[Config.Get("ui.accent")] or Palette.Cyan) or Theme.Text,
            Font = Enum.Font.GothamMedium,
            TextSize = 14,
            LayoutOrder = index,
            ZIndex = 93,
            Parent = ModalList,
        })
        addCorner(option, 7)
        ModalChoiceScope:Connect(option.Activated, function()
            Modal.Visible = false
            onPick(choice)
        end)
    end
    local windowWidth = math.max(260, Window.AbsoluteSize.X)
    local width = math.min(330, windowWidth - 20)
    local height = math.min(math.max(150, 64 + #choices * 47), math.max(150, Window.AbsoluteSize.Y - 24))
    ModalPanel.Size = UDim2.fromOffset(width, height)
    Modal.Visible = true
end

local function addPage(name, icon)
    local button = create("TextButton", {
        Name = name .. "Tab",
        Size = UDim2.fromOffset(88, 32),
        BackgroundColor3 = Theme.Control,
        Text = icon .. "  " .. name,
        TextColor3 = Theme.Subtext,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        AutoButtonColor = false,
        LayoutOrder = #UI.TabOrder + 1,
        ZIndex = 22,
        Parent = TabBar,
    })
    addCorner(button, 7)
    local page = create("ScrollingFrame", {
        Name = name,
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Border,
        Visible = false,
        ZIndex = 21,
        Parent = Content,
    })
    create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 8),
        Parent = page,
    })
    create("UIPadding", {
        PaddingBottom = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 4),
        Parent = page,
    })
    local tab = {Name = name, Button = button, Page = page}
    UI.Tabs[name] = tab
    table.insert(UI.TabOrder, tab)
    RootScope:Connect(button.Activated, function()
        UI.SelectTab(name)
    end)
    return page
end

function UI.SelectTab(name)
    local selected = UI.Tabs[name]
    if not selected then
        return
    end
    UI.CurrentTab = name
    for _, tab in ipairs(UI.TabOrder) do
        local active = tab == selected
        tab.Page.Visible = active
        tab.Button.BackgroundColor3 = active and Theme.ControlHover or Theme.Control
        tab.Button.TextColor3 = active and (Palette[Config.Get("ui.accent")] or Palette.Cyan) or Theme.Subtext
    end
end

local function section(parent, title, description)
    local group = create("Frame", {
        Size = UDim2.new(1, -2, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Parent = parent,
    })
    addCorner(group, 9)
    addStroke(group, Theme.Border, 1)
    create("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 5),
        Parent = group,
    })
    create("UIPadding", {
        PaddingTop = UDim.new(0, 10),
        PaddingBottom = UDim.new(0, 10),
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
        Parent = group,
    })
    create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = 1,
        Parent = group,
    })
    if description and description ~= "" then
        create("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Text = description,
            TextColor3 = Theme.Subtext,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            LayoutOrder = 2,
            Parent = group,
        })
    end
    return group
end

local function controlBase(parent, height, order)
    return create("Frame", {
        Size = UDim2.new(1, 0, 0, height or 46),
        BackgroundTransparency = 1,
        LayoutOrder = order or 10,
        Parent = parent,
    })
end

local function addParagraph(parent, text, order)
    return create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = Theme.Subtext,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = order or 10,
        Parent = parent,
    })
end

local function addInfo(parent, title, initial, order)
    local row = controlBase(parent, 30, order)
    create("TextLabel", {
        Size = UDim2.new(0.46, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Theme.Subtext,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    local value = create("TextLabel", {
        Position = UDim2.fromScale(0.46, 0),
        Size = UDim2.new(0.54, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = initial or "—",
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })
    return value
end

local function addButton(parent, text, callback, danger, order)
    local button = create("TextButton", {
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundColor3 = danger and Color3.fromRGB(73, 32, 41) or Theme.Control,
        Text = text,
        TextColor3 = danger and Theme.Danger or Theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        AutoButtonColor = true,
        LayoutOrder = order or 20,
        Parent = parent,
    })
    addCorner(button, 7)
    addStroke(button, danger and Color3.fromRGB(120, 52, 65) or Theme.Border, 1)
    RootScope:Connect(button.Activated, function()
        safeCall("Button " .. text, callback)
    end)
    return button
end

local function addToggle(parent, title, key, description, callback, order)
    local row = create("TextButton", {
        Size = UDim2.new(1, 0, 0, description and 60 or 46),
        BackgroundColor3 = Theme.Control,
        Text = "",
        AutoButtonColor = false,
        LayoutOrder = order or 10,
        Parent = parent,
    })
    addCorner(row, 7)
    create("TextLabel", {
        Position = UDim2.fromOffset(12, description and 8 or 0),
        Size = UDim2.new(1, -76, 0, 24),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })
    if description then
        create("TextLabel", {
            Position = UDim2.fromOffset(12, 31),
            Size = UDim2.new(1, -76, 0, 22),
            BackgroundTransparency = 1,
            Text = description,
            TextColor3 = Theme.Subtext,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = row,
        })
    end
    local switch = create("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(44, 24),
        BackgroundColor3 = Theme.Border,
        Parent = row,
    })
    addCorner(switch, 12)
    local knob = create("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 3, 0.5, 0),
        Size = UDim2.fromOffset(18, 18),
        BackgroundColor3 = Theme.Text,
        BorderSizePixel = 0,
        Parent = switch,
    })
    addCorner(knob, 9)
    local function refresh()
        local enabled = Config.Get(key)
        switch.BackgroundColor3 = enabled and (Palette[Config.Get("ui.accent")] or Palette.Cyan) or Theme.Border
        knob.Position = enabled and UDim2.new(1, -21, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
    end
    table.insert(UI.Refreshers, refresh)
    Config.OnChange({key, "ui.accent"}, refresh)
    RootScope:Connect(row.Activated, function()
        local enabled = not Config.Get(key)
        Config.Set(key, enabled)
        if callback then
            safeCall("Toggle " .. title, callback, enabled)
        end
    end)
    refresh()
    return row
end

local function addChoice(parent, title, key, choices, order)
    local row = controlBase(parent, 44, order)
    create("TextLabel", {
        Size = UDim2.new(0.52, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    local button = create("TextButton", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        Size = UDim2.new(0.48, 0, 0, 42),
        BackgroundColor3 = Theme.Control,
        Text = "",
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        AutoButtonColor = true,
        Parent = row,
    })
    addCorner(button, 7)
    addStroke(button, Theme.Border, 1)
    local function refresh()
        button.Text = tostring(Config.Get(key)) .. "  ▾"
    end
    table.insert(UI.Refreshers, refresh)
    Config.OnChange({key}, refresh)
    RootScope:Connect(button.Activated, function()
        UI.OpenChoices(title, choices or Config.Definitions[key].Choices, Config.Get(key), function(choice)
            Config.Set(key, choice)
        end)
    end)
    refresh()
    return button
end

local function addSlider(parent, title, key, step, suffix, order)
    step = step or 1
    local row = controlBase(parent, 66, order)
    create("TextLabel", {
        Size = UDim2.new(1, -70, 0, 24),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    local valueLabel = create("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.fromScale(1, 0),
        Size = UDim2.fromOffset(80, 24),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Theme.Subtext,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = row,
    })
    local minus = create("TextButton", {
        Position = UDim2.fromOffset(0, 30),
        Size = UDim2.fromOffset(34, 32),
        BackgroundColor3 = Theme.Control,
        Text = "−",
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamBold,
        TextSize = 16,
        Parent = row,
    })
    addCorner(minus, 6)
    local plus = create("TextButton", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, 30),
        Size = UDim2.fromOffset(34, 32),
        BackgroundColor3 = Theme.Control,
        Text = "+",
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamBold,
        TextSize = 16,
        Parent = row,
    })
    addCorner(plus, 6)
    local bar = create("TextButton", {
        Position = UDim2.new(0, 42, 0, 39),
        Size = UDim2.new(1, -84, 0, 18),
        BackgroundColor3 = Theme.Control,
        Text = "",
        AutoButtonColor = false,
        Parent = row,
    })
    addCorner(bar, 6)
    local fill = create("Frame", {
        Size = UDim2.fromScale(0.5, 1),
        BackgroundColor3 = Palette.Cyan,
        BorderSizePixel = 0,
        Parent = bar,
    })
    addCorner(fill, 6)
    bindAccent(fill, "BackgroundColor3")
    local definition = Config.Definitions[key]
    local function refresh()
        local value = Config.Get(key)
        valueLabel.Text = tostring(value) .. (suffix or "")
        fill.Size = UDim2.fromScale((value - definition.Min) / math.max(0.0001, definition.Max - definition.Min), 1)
    end
    local function setFromPosition(x)
        local ratio = math.clamp((x - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X), 0, 1)
        local raw = definition.Min + (definition.Max - definition.Min) * ratio
        local value = math.floor(raw / step + 0.5) * step
        Config.Set(key, math.clamp(value, definition.Min, definition.Max))
    end
    table.insert(UI.Refreshers, refresh)
    Config.OnChange({key}, refresh)
    RootScope:Connect(minus.Activated, function()
        Config.Set(key, Config.Get(key) - step)
    end)
    RootScope:Connect(plus.Activated, function()
        Config.Set(key, Config.Get(key) + step)
    end)
    local sliding = false
    RootScope:Connect(bar.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            setFromPosition(input.Position.X)
        end
    end)
    RootScope:Connect(Services.UserInputService.InputChanged, function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            setFromPosition(input.Position.X)
        end
    end)
    RootScope:Connect(Services.UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            sliding = false
        end
    end)
    refresh()
    return row
end

-- ---------------------------------------------------------------------------
-- Features, floating actions and notifications
-- ---------------------------------------------------------------------------

local Features = {}
function Features.Panic()
    local keys = {
        "visuals.master", "visuals.entities", "visuals.items", "visuals.objectives",
        "visuals.doors", "visuals.hiding", "visuals.players",
        "alerts.entities", "alerts.items", "alerts.objectives",
        "guidance.enabled", "player.fullbright", "player.noFog", "player.customFOV",
        "performance.monitor",
    }
    for _, key in ipairs(keys) do
        Config.Set(key, false, true)
    end
    syncESP()
    syncAlerts()
    syncGuidance()
    syncEnvironment()
    NotificationCenter.Notify("Emergency stop", "All active ADS features were disabled.", "warning")
end

function Features.Action(action)
    if action == "Entities" or action == "Items" or action == "Objectives" then
        local suffix = string.lower(action)
        local key = "visuals." .. suffix
        local enabled = not Config.Get(key)
        Config.Set(key, enabled)
        if enabled then
            Config.Set("visuals.master", true)
        end
        syncESP()
    elseif action == "Guidance" then
        Config.Set("guidance.enabled", not Config.Get("guidance.enabled"))
    elseif action == "Panic" then
        Features.Panic()
    end
end

local QuickButtons = {}
for index = 1, 3 do
    local button = create("TextButton", {
        Name = "Quick" .. index,
        Size = UDim2.fromOffset(48, 48),
        BackgroundColor3 = Theme.Panel,
        BackgroundTransparency = 0.1,
        Text = "",
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        AutoButtonColor = false,
        ZIndex = 44,
        Parent = Gui,
    })
    addCorner(button, 24)
    local stroke = addStroke(button, Theme.Border, 2)
    QuickButtons[index] = {Button = button, Stroke = stroke}
    makeDraggable(button, button, "Quick" .. index, function()
        Features.Action(Config.Get("ui.quick" .. index))
    end)
end

local QUICK_SHORT = {Entities = "ENT", Items = "ITEM", Objectives = "GOAL", Guidance = "GUIDE", Panic = "STOP", None = "—"}
local function refreshQuickButtons()
    for index, quick in ipairs(QuickButtons) do
        local action = Config.Get("ui.quick" .. index)
        quick.Button.Text = QUICK_SHORT[action] or action
        quick.Button.Visible = Config.Get("ui.showQuickButtons") and action ~= "None" and not UI.Open
        local active = false
        if action == "Entities" then active = Config.Get("visuals.entities") and Config.Get("visuals.master") end
        if action == "Items" then active = Config.Get("visuals.items") and Config.Get("visuals.master") end
        if action == "Objectives" then active = Config.Get("visuals.objectives") and Config.Get("visuals.master") end
        if action == "Guidance" then active = Config.Get("guidance.enabled") end
        if action == "Panic" then
            quick.Stroke.Color = Theme.Danger
        else
            quick.Stroke.Color = active and (Palette[Config.Get("ui.accent")] or Palette.Cyan) or Theme.Border
        end
    end
end
UI.RefreshQuickButtons = refreshQuickButtons
Config.OnChange({
    "ui.showQuickButtons", "ui.quick1", "ui.quick2", "ui.quick3", "ui.accent",
    "visuals.master", "visuals.entities", "visuals.items", "visuals.objectives", "guidance.enabled",
}, refreshQuickButtons)
table.insert(UI.Refreshers, refreshQuickButtons)

local NotificationContainer = create("Frame", {
    Name = "Notifications",
    BackgroundTransparency = 1,
    Size = UDim2.fromOffset(330, 300),
    ZIndex = 60,
    Parent = Gui,
})
create("UIListLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, 7),
    Parent = NotificationContainer,
})
local NotificationPool = {}
local notificationSequence = 0
for index = 1, 3 do
    local frame = create("Frame", {
        Size = UDim2.new(1, 0, 0, 70),
        BackgroundColor3 = Theme.Panel,
        BackgroundTransparency = 0.06,
        BorderSizePixel = 0,
        Visible = false,
        LayoutOrder = index,
        ZIndex = 61,
        Parent = NotificationContainer,
    })
    addCorner(frame, 9)
    local stroke = addStroke(frame, Theme.Border, 1)
    local title = create("TextLabel", {
        Position = UDim2.fromOffset(12, 8),
        Size = UDim2.new(1, -24, 0, 18),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Theme.Text,
        Font = Enum.Font.GothamSemibold,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 62,
        Parent = frame,
    })
    local body = create("TextLabel", {
        Position = UDim2.fromOffset(12, 29),
        Size = UDim2.new(1, -24, 0, 34),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Theme.Subtext,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        ZIndex = 62,
        Parent = frame,
    })
    NotificationPool[index] = {Frame = frame, Stroke = stroke, Title = title, Body = body, Generation = 0, LastUsed = 0}
end

local notificationSound = create("Sound", {
    Name = "ADSNotification",
    SoundId = "rbxassetid://8784885431",
    Volume = 0.35,
    Parent = Gui,
})

local function layoutNotifications()
    local viewport = viewportSize()
    local caption = Config.Get("alerts.style") == "Caption"
    local width = math.min(caption and 470 or 340, viewport.X - 16)
    NotificationContainer.Size = UDim2.fromOffset(width, 260)
    NotificationContainer.AnchorPoint = Vector2.new(caption and 0.5 or 1, 0)
    NotificationContainer.Position = caption and UDim2.new(0.5, 0, 0, 12) or UDim2.new(1, -8, 0, 58)
    for _, notification in ipairs(NotificationPool) do
        local alignment = caption and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left
        notification.Title.TextXAlignment = alignment
        notification.Body.TextXAlignment = alignment
    end
end
Config.OnChange({"alerts.style"}, layoutNotifications)

NotificationCenter.Handler = function(title, body, kind)
    notificationSequence = notificationSequence + 1
    local selected = NotificationPool[((notificationSequence - 1) % #NotificationPool) + 1]
    for _, notification in ipairs(NotificationPool) do
        if not notification.Frame.Visible then
            selected = notification
            break
        end
    end
    selected.Generation = selected.Generation + 1
    selected.LastUsed = os.clock()
    selected.Title.Text = tostring(title)
    selected.Body.Text = tostring(body)
    local color = Palette[Config.Get("ui.accent")] or Palette.Cyan
    if kind == "entities" or kind == "warning" then color = Theme.Danger end
    if kind == "objectives" then color = Palette.Gold end
    if kind == "items" then color = Palette.Cyan end
    selected.Stroke.Color = color
    selected.Frame.Visible = true
    if Config.Get("alerts.sound") then
        notificationSound:Stop()
        notificationSound:Play()
    end
    local generation = selected.Generation
    task.delay(Config.Get("alerts.duration"), function()
        if State.Alive and selected.Generation == generation then
            selected.Frame.Visible = false
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Window/floating layout and keyboard support
-- ---------------------------------------------------------------------------

local function applyLayout()
    if not State.Alive then
        return
    end
    local viewport = viewportSize()
    local width, height
    if viewport.X < 540 then
        width = math.max(240, viewport.X - 12)
        height = math.max(260, viewport.Y - 16)
    elseif viewport.Y < 520 then
        width = math.max(360, math.min(760, viewport.X - 16))
        height = math.max(270, viewport.Y - 12)
    else
        width = math.max(480, math.min(820, viewport.X * 0.78))
        height = math.max(360, math.min(600, viewport.Y * 0.84))
    end
    width = math.min(width, math.max(200, viewport.X - 8))
    height = math.min(height, math.max(220, viewport.Y - 8))
    Window.Size = UDim2.fromOffset(width, height)
    positionFromSession(Window, "Window", (viewport.X - width) * 0.5, (viewport.Y - height) * 0.5)
    positionFromSession(OpenButton, "OpenButton", 18, viewport.Y * 0.42)
    for index, quick in ipairs(QuickButtons) do
        positionFromSession(quick.Button, "Quick" .. index, viewport.X - 62, viewport.Y * 0.30 + (index - 1) * 56)
    end
    layoutNotifications()
end

local viewportScope = nil
local function bindViewport()
    if viewportScope then
        viewportScope:Destroy()
    end
    viewportScope = Scope.new("Viewport")
    local camera = Workspace.CurrentCamera
    if camera then
        viewportScope:Connect(camera:GetPropertyChangedSignal("ViewportSize"), function()
            task.defer(applyLayout)
        end)
    end
    task.defer(applyLayout)
end
RootScope:Connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), bindViewport)
RootScope:Connect(Services.UserInputService.InputBegan, function(input, gameProcessed)
    if gameProcessed or Services.UserInputService:GetFocusedTextBox() then
        return
    end
    local keyCode = Enum.KeyCode[Config.Get("ui.toggleKey")]
    if keyCode and input.KeyCode == keyCode then
        UI.SetOpen(not UI.Open)
    end
end)
Config.OnChange({"ui.showOpenButton"}, refreshOpenVisibility)
Config.OnChange({"ui.accent", "ui.opacity"}, function()
    Window.BackgroundTransparency = Config.Get("ui.opacity") / 100
    for _, binding in ipairs(UI.ThemeBindings) do
        if binding.Instance.Parent then
            binding.Instance[binding.Property] = Palette[Config.Get("ui.accent")] or Palette.Cyan
        end
    end
    if UI.CurrentTab then
        UI.SelectTab(UI.CurrentTab)
    end
    refreshQuickButtons()
end)

-- ---------------------------------------------------------------------------
-- Performance sampler (opt-in, Debug tab)
-- ---------------------------------------------------------------------------

local Performance = {FPS = 0, FrameMs = 0}
Modules.Define("PerformanceMonitor", function(scope)
    local frames = 0
    local elapsed = 0
    scope:Connect(Services.RunService.RenderStepped, function(delta)
        frames = frames + 1
        elapsed = elapsed + delta
        if elapsed >= 1 then
            Performance.FPS = frames / elapsed
            Performance.FrameMs = elapsed * 1000 / math.max(1, frames)
            frames = 0
            elapsed = 0
        end
    end)
end, function()
    Performance.FPS = 0
    Performance.FrameMs = 0
end)
Config.OnChange({"performance.monitor"}, function()
    if Config.Get("performance.monitor") then Modules.Start("PerformanceMonitor") else Modules.Stop("PerformanceMonitor") end
end)

-- ---------------------------------------------------------------------------
-- Tabs and real controls
-- ---------------------------------------------------------------------------

local HomePage = addPage("Home", "⌂")
local VisualsPage = addPage("Visuals", "◉")
local PlayerPage = addPage("Player", "◇")
local AutomationPage = addPage("Automation", "◎")
local AlertsPage = addPage("Alerts", "!")
local SettingsPage = addPage("Settings", "⚙")
local DebugPage = addPage("Debug", "□")

local homeAbout = section(HomePage, "Absolute Doors Script", "Self-contained client visuals, alerts and direct guidance. No server automation or external libraries.")
addParagraph(homeAbout, "Status: loaded. Use the quick switches below or Panic to disable every active feature.", 3)
local homePlayer = addInfo(homeAbout, "Player", LocalPlayer.DisplayName, 4)
local homeSession = addInfo(homeAbout, "Session", "0:00", 5)
local homePlace = addInfo(homeAbout, "Floor / room", "—", 6)
local homeStatus = addInfo(homeAbout, "Modules", "Starting", 7)

local homeQuick = section(HomePage, "Quick switches", "The same settings are available in their full tabs.")
addToggle(homeQuick, "Entity ESP", "visuals.entities", nil, syncESP, 10)
addToggle(homeQuick, "Item ESP", "visuals.items", nil, syncESP, 11)
addToggle(homeQuick, "Objective ESP", "visuals.objectives", nil, syncESP, 12)
addToggle(homeQuick, "Direct guidance", "guidance.enabled", nil, syncGuidance, 13)
addButton(homeQuick, "PANIC — disable all active features", Features.Panic, true, 20)

local visualsCategories = section(VisualsPage, "ESP categories", "Targets are detected from live Workspace objects and ProximityPrompts. Unknown game structures are ignored safely.")
addToggle(visualsCategories, "Master ESP", "visuals.master", nil, syncESP, 10)
addToggle(visualsCategories, "Entities", "visuals.entities", "Rush, Ambush, Figure, Seek and other known entities.", syncESP, 11)
addToggle(visualsCategories, "Items", "visuals.items", "Tools, consumables and prompt-identified pickups.", syncESP, 12)
addToggle(visualsCategories, "Objectives", "visuals.objectives", "Keys, books, fuses, levers and progression objects.", syncESP, 13)
addToggle(visualsCategories, "Doors", "visuals.doors", "Current and upcoming numbered room doors.", syncESP, 14)
addToggle(visualsCategories, "Hiding spots", "visuals.hiding", "Closets, lockers, beds and HidePrompt owners.", syncESP, 15)
addToggle(visualsCategories, "Players", "visuals.players", "Other player characters only.", syncESP, 16)

local visualsAppearance = section(VisualsPage, "Appearance", "Labels and highlights are updated together in one throttled renderer.")
addToggle(visualsAppearance, "Highlights", "visuals.highlights", nil, nil, 10)
addToggle(visualsAppearance, "Names", "visuals.labels", nil, nil, 11)
addToggle(visualsAppearance, "Distance", "visuals.distance", "Approximate metres (studs × 0.28).", nil, 12)
addToggle(visualsAppearance, "Hide collected objects", "visuals.hideLooted", "Hides targets whose tracked prompt is disabled or removed.", nil, 13)
addSlider(visualsAppearance, "Maximum distance", "visuals.maxDistance", 25, " studs", 14)
addSlider(visualsAppearance, "Maximum visible objects", "visuals.maxObjects", 5, "", 15)
addSlider(visualsAppearance, "Highlight budget", "visuals.maxHighlights", 2, "", 16)
addSlider(visualsAppearance, "Text size", "visuals.textSize", 1, " px", 17)
addSlider(visualsAppearance, "Fill opacity", "visuals.fillTransparency", 5, "%", 18)

local visualsColors = section(VisualsPage, "Category colors")
addChoice(visualsColors, "Entities", "color.entities", nil, 10)
addChoice(visualsColors, "Items", "color.items", nil, 11)
addChoice(visualsColors, "Objectives", "color.objectives", nil, 12)
addChoice(visualsColors, "Doors", "color.doors", nil, 13)
addChoice(visualsColors, "Hiding spots", "color.hiding", nil, 14)
addChoice(visualsColors, "Players", "color.players", nil, 15)

local playerAccessibility = section(PlayerPage, "Local accessibility", "These switches change only the local camera or lighting. Original values are restored on disable and unload.")
addToggle(playerAccessibility, "Fullbright", "player.fullbright", "Raises local ambient light and disables local shadows.", nil, 10)
addToggle(playerAccessibility, "Remove fog", "player.noFog", "Restores Lighting and Atmosphere values when disabled.", nil, 11)
addToggle(playerAccessibility, "Custom field of view", "player.customFOV", nil, nil, 12)
addSlider(playerAccessibility, "Field of view", "player.fov", 1, "°", 13)
local playerStatus = section(PlayerPage, "Character lifecycle", "References are refreshed after death and respawn. ADS does not modify speed, collision, health or server state.")
local characterStatus = addInfo(playerStatus, "Character", "Waiting", 10)
local humanoidStatus = addInfo(playerStatus, "Humanoid", "—", 11)
local rootStatus = addInfo(playerStatus, "Root part", "—", 12)

local automationGuide = section(AutomationPage, "Direct objective guidance", "Selects the nearest detected objective. The optional 2D line is direct, not an obstacle-aware path or auto-walk.")
addToggle(automationGuide, "Enable guidance", "guidance.enabled", nil, syncGuidance, 10)
addToggle(automationGuide, "Include regular items", "guidance.includeItems", "Otherwise only keys, books, fuses and other objectives are considered.", nil, 11)
addToggle(automationGuide, "Show direct screen line", "guidance.line", nil, nil, 12)
local guidanceStatus = addInfo(automationGuide, "Nearest target", "Guidance is off", 13)
addParagraph(automationGuide, "No RemoteEvent, ProximityPrompt or character movement is triggered by this module.", 14)

local alertsSettings = section(AlertsPage, "Event notifications", "Each Instance is announced once; a separate per-label cooldown suppresses repeated events.")
addToggle(alertsSettings, "Entity alerts", "alerts.entities", nil, syncAlerts, 10)
addToggle(alertsSettings, "Item alerts", "alerts.items", nil, syncAlerts, 11)
addToggle(alertsSettings, "Objective alerts", "alerts.objectives", nil, syncAlerts, 12)
addToggle(alertsSettings, "Notification sound", "alerts.sound", nil, nil, 13)
addChoice(alertsSettings, "Visual style", "alerts.style", nil, 14)
addSlider(alertsSettings, "Duration", "alerts.duration", 1, " s", 15)
addSlider(alertsSettings, "Per-label cooldown", "alerts.cooldown", 1, " s", 16)
addButton(alertsSettings, "Test notification", function()
    NotificationCenter.Notify("ADS test", "Notifications are working. Current style: " .. Config.Get("alerts.style"), "objectives")
end, false, 20)

local settingsInterface = section(SettingsPage, "Interface", "Window and floating-button positions are clamped after rotation and saved for this session.")
addChoice(settingsInterface, "Accent", "ui.accent", nil, 10)
addSlider(settingsInterface, "Background transparency", "ui.opacity", 1, "%", 11)
addChoice(settingsInterface, "PC open/close key", "ui.toggleKey", nil, 12)
addToggle(settingsInterface, "Floating reopen button", "ui.showOpenButton", nil, nil, 13)
addToggle(settingsInterface, "Quick action buttons", "ui.showQuickButtons", nil, nil, 14)
addChoice(settingsInterface, "Quick button 1", "ui.quick1", nil, 15)
addChoice(settingsInterface, "Quick button 2", "ui.quick2", nil, 16)
addChoice(settingsInterface, "Quick button 3", "ui.quick3", nil, 17)

local settingsPerformance = section(SettingsPage, "Performance", "Low power halves ESP/guidance update frequency. The monitor measures actual frame rate only when enabled.")
addToggle(settingsPerformance, "Low power mode", "performance.lowPower", nil, nil, 10)
addSlider(settingsPerformance, "ESP refresh rate", "performance.refreshHz", 1, " Hz", 11)
addToggle(settingsPerformance, "Debug performance monitor", "performance.monitor", nil, nil, 12)

local settingsProfiles = section(SettingsPage, "Session profiles and cleanup", "Storage is a validated JSON StringValue in PlayerGui. It does not persist after the Roblox session ends.")
addButton(settingsProfiles, "Apply recommended profile", function()
    Config.Set("visuals.master", true)
    Config.Set("visuals.entities", true)
    Config.Set("visuals.items", true)
    Config.Set("visuals.objectives", true)
    Config.Set("visuals.maxObjects", 80)
    Config.Set("visuals.maxHighlights", 24)
    Config.Set("performance.refreshHz", 5)
    syncESP()
    NotificationCenter.Notify("Profile", "Recommended visual profile applied.", "objectives")
end, false, 10)
addButton(settingsProfiles, "Apply minimal mobile profile", function()
    Config.Set("visuals.master", true)
    Config.Set("visuals.entities", true)
    Config.Set("visuals.items", false)
    Config.Set("visuals.objectives", true)
    Config.Set("visuals.doors", false)
    Config.Set("visuals.hiding", false)
    Config.Set("visuals.players", false)
    Config.Set("visuals.maxObjects", 35)
    Config.Set("visuals.maxHighlights", 12)
    Config.Set("performance.lowPower", true)
    Config.Set("performance.refreshHz", 3)
    syncESP()
    NotificationCenter.Notify("Profile", "Minimal mobile profile applied.", "objectives")
end, false, 11)
addButton(settingsProfiles, "Save session settings now", function()
    Session.SaveNow()
    NotificationCenter.Notify("Settings", Session.Available and "Session settings saved." or "Session storage unavailable.", "objectives")
end, false, 12)
addButton(settingsProfiles, "Reset all settings to defaults", function()
    Config.Reset()
    syncESP(); syncAlerts(); syncGuidance(); syncEnvironment()
    NotificationCenter.Notify("Settings", "Defaults restored.", "objectives")
end, false, 13)
addButton(settingsProfiles, "Unload ADS and clean up", function()
    if UnloadADS then UnloadADS() end
end, true, 20)

local debugDependencies = section(DebugPage, "Dependencies", "Missing DOORS objects are reported honestly; ADS does not replace them with mock functions.")
local dependencyRooms = addInfo(debugDependencies, "Workspace.CurrentRooms", "—", 10)
local dependencyData = addInfo(debugDependencies, "ReplicatedStorage.GameData", "—", 11)
local dependencyCharacter = addInfo(debugDependencies, "Local character", "—", 12)
local dependencyStorage = addInfo(debugDependencies, "Session storage", Session.Available and "Available" or "Unavailable", 13)

local debugModules = section(DebugPage, "Module lifecycle", "Restart affects only the selected module. Feature-disabled modules remain stopped after synchronization.")
local moduleLabels = {}
for index, name in ipairs({"Detection", "ESP", "Alerts", "Guidance", "Fullbright", "NoFog", "CameraFOV", "PerformanceMonitor"}) do
    moduleLabels[name] = addInfo(debugModules, name, "Stopped", 10 + index)
end
addButton(debugModules, "Rescan / restart Detection", function()
    Modules.Restart("Detection")
    NotificationCenter.Notify("Debug", "Detection restarted; initial scan is running in batches.", "objectives")
end, false, 30)
addButton(debugModules, "Restart active ESP", function()
    Modules.Stop("ESP"); syncESP()
end, false, 31)
addButton(debugModules, "Restart active Alerts", function()
    Modules.Stop("Alerts"); syncAlerts()
end, false, 32)
addButton(debugModules, "Restart active Guidance", function()
    Modules.Stop("Guidance"); syncGuidance()
end, false, 33)

local debugStats = section(DebugPage, "Counters and reproducible performance checks", "Compare FPS and ESP update cost with the same scene, object cap and refresh rate. No fixed FPS is promised.")
local debugTargets = addInfo(debugStats, "Tracked targets", "0", 10)
local debugVisible = addInfo(debugStats, "Visible ESP", "0", 11)
local debugFPS = addInfo(debugStats, "Measured FPS", "Monitor off", 12)
local debugESPTime = addInfo(debugStats, "ESP update avg / max", "0 / 0 ms", 13)
local debugScan = addInfo(debugStats, "Last initial scan", "Not finished", 14)
local debugResources = addInfo(debugStats, "Live scopes / connections / owned", "—", 15)
addButton(debugStats, "Reset ESP maximum timing", function()
    ESP.MaxUpdateMs = 0
end, false, 20)

local debugLog = section(DebugPage, "Diagnostics", "Latest entries appear here; warnings and errors are also printed to the Roblox output.")
local debugLogText = addParagraph(debugLog, "No diagnostics yet.", 10)

-- ---------------------------------------------------------------------------
-- Status updates, startup and complete cleanup
-- ---------------------------------------------------------------------------

local function formatDuration(seconds)
    seconds = math.max(0, math.floor(seconds))
    local minutes = math.floor(seconds / 60)
    local remainder = seconds % 60
    return string.format("%d:%02d", minutes, remainder)
end

local function updateStatusUI()
    local counts = Detection.Counts()
    local targetTotal = 0
    for _, count in pairs(counts) do targetTotal = targetTotal + count end
    local running = 0
    for _, record in pairs(Modules.Records) do
        if record.Running then running = running + 1 end
    end
    homePlayer.Text = LocalPlayer.DisplayName .. " (@" .. LocalPlayer.Name .. ")"
    homeSession.Text = formatDuration(os.clock() - State.StartedAt)
    homePlace.Text = tostring(State.Floor) .. " / " .. tostring(State.CurrentRoom or "—")
    homeStatus.Text = running .. " running · " .. Diagnostics.Errors .. " errors"
    characterStatus.Text = PlayerLifecycle.Status
    humanoidStatus.Text = State.Humanoid and State.Humanoid.Parent and "Available" or "Unavailable"
    rootStatus.Text = State.RootPart and State.RootPart.Parent and "Available" or "Unavailable"
    guidanceStatus.Text = Guidance.StatusText
    dependencyRooms.Text = Workspace:FindFirstChild("CurrentRooms") and "Detected" or "Not detected"
    dependencyData.Text = Services.ReplicatedStorage:FindFirstChild("GameData") and "Detected" or "Not detected"
    dependencyCharacter.Text = State.Character and State.Character.Parent and "Available" or "Unavailable"
    dependencyStorage.Text = Session.Available and "Available (session only)" or "Unavailable"
    for name, label in pairs(moduleLabels) do
        local record = Modules.Records[name]
        label.Text = record.Status .. (record.LastError and " · " .. record.LastError or "")
    end
    debugTargets.Text = string.format("%d · E%d I%d O%d D%d H%d P%d", targetTotal, counts.entities, counts.items, counts.objectives, counts.doors, counts.hiding, counts.players)
    debugVisible.Text = tostring(ESP.VisibleCount)
    debugFPS.Text = Config.Get("performance.monitor") and string.format("%.1f · %.2f ms/frame", Performance.FPS, Performance.FrameMs) or "Monitor off"
    debugESPTime.Text = string.format("%.3f / %.3f ms", ESP.AverageUpdateMs, ESP.MaxUpdateMs)
    debugScan.Text = Detection.ScanCount > 0 and string.format("%.3f s · %d scans", Detection.LastScanDuration, Detection.ScanCount) or "Not finished"
    debugResources.Text = string.format("%d / %d / %d", ResourceStats.Scopes, ResourceStats.Connections, ResourceStats.Instances)
    Footer.Text = string.format("%s · room %s · %d targets · %d ESP", tostring(State.Floor), tostring(State.CurrentRoom or "—"), targetTotal, ESP.VisibleCount)
    if UI.CurrentTab == "Debug" then
        local first = math.max(1, #Diagnostics.Entries - 7)
        local rows = {}
        for index = first, #Diagnostics.Entries do
            local entry = Diagnostics.Entries[index]
            table.insert(rows, string.format("[%s] %s", entry.Level, entry.Message))
        end
        debugLogText.Text = #rows > 0 and table.concat(rows, "\n\n") or "No diagnostics yet."
    end
end
RootScope:Loop(1, updateStatusUI)

function UnloadADS()
    if State.Unloading then
        return
    end
    State.Unloading = true
    State.Alive = false
    Session.SaveNow()
    Modules.StopAll()
    espConfigListener.Disconnect()
    alertsConfigListener.Disconnect()
    guidanceConfigListener.Disconnect()
    environmentConfigListener.Disconnect()
    fovConfigListener.Disconnect()
    if ModalChoiceScope then
        ModalChoiceScope:Destroy()
    end
    if viewportScope then
        viewportScope:Destroy()
    end
    Diagnostics.Log("INFO", "ADS unloaded; module resources cleaned up.")
    RootScope:Destroy()
    if Gui.Parent then
        Gui:Destroy()
    end
end
RootScope:Connect(Gui.Destroying, function()
    if State.Alive then
        task.defer(UnloadADS)
    end
end)

UI.SelectTab("Home")
applyLayout()
bindViewport()
refreshQuickButtons()
refreshOpenVisibility()
syncESP()
syncAlerts()
syncGuidance()
syncEnvironment()
if Config.Get("performance.monitor") then Modules.Start("PerformanceMonitor") end
updateStatusUI()
Diagnostics.Log("INFO", "ADS " .. VERSION .. " loaded with native adaptive UI.")
task.defer(function()
    if State.Alive then
        NotificationCenter.Notify("ADS loaded", "Native UI ready. " .. (Services.UserInputService.TouchEnabled and "Drag the header or floating buttons to reposition them." or "Toggle with " .. Config.Get("ui.toggleKey") .. "."), "objectives")
    end
end)
