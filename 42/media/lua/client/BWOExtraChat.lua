--[[ ============================================================================
     Bandits Week One - Extra Chat
     ----------------------------------------------------------------------------
     Standalone add-on that extends Week One's "press T and talk to an NPC"
     system WITHOUT editing the Week One mod. On game start we save the original
     BWOChat.Say and swap in a wrapper: it matches OUR table first, and on a miss
     delegates to the original so all ~700 vanilla lines/actions still work.

     Matching mirrors vanilla: lowercase + lemmatise the message, then an entry
     matches only if EVERY word in its `query` is present (whole-word) in the raw
     or lemmatised text. First matching entry wins, so put specifics up top.

     ----------------------------------------------------------------------------
     ENTRY FIELDS
       query  = { "word", ... }            -- all must be present to match
       res    = string | list | function   -- the reply. See "RESPONSES" below.
       cond   = function(ctx) -> bool       -- optional gate: entry only applies
                                               to NPCs for which this is true.
       anim   = "Yes"                       -- optional; default random Talk1..5
       action = "GIVE" | "GOTO" | "GRAB"    -- optional behaviour, see DISPATCHER
       give   = "Base.Bandage"              -- item id, required for action=GIVE

     RESPONSES - `res` can be:
       "a string"                      -> said as-is (supports %NAME %HOUR
                                          %MINUTE %MOOD %CITY interpolation)
       {"line a", "line b", "line c"}  -> one picked at RANDOM each time
       function(ctx) return "..." end  -> computed; branch on whoever is talking

     ctx (passed to res-functions and cond) holds:
       ctx.brain      the NPC's full data table
       ctx.name       brain.fullname
       ctx.female     true/false
       ctx.role       program name: "Walker","Runner","Inhabitant","Active","Babe"
       ctx.hostile    true/false
       ctx.smoker / ctx.alcoholic / ctx.polish   persistent personality flags
       ctx.rnd        array of per-NPC random numbers, STABLE for that NPC's life
                      (e.g. ctx.rnd[2] is 0-9 and never changes for them)
       ctx.pick(list) helper = pick one at random
       ctx.player / ctx.bandit   the player and the NPC zombie object
============================================================================ ]]--

BWOExtraChat = BWOExtraChat or {}
local data = {}
local function add(entry) table.insert(data, entry) end

-- ============================================================================
-- CONTENT  -- this is the part you edit. Examples of every pattern below.
-- ============================================================================

-- ---- GRAB: tell an NPC to pick up & wield a weapon lying next to them -------
-- Scans a couple of tiles around the NPC for a dropped weapon and equips it.
add{ query={"grab","that","gun"},     anim="Yes", action="GRAB" }
add{ query={"grab","the","gun"},      anim="Yes", action="GRAB" }
add{ query={"grab","that","weapon"},  anim="Yes", action="GRAB" }
add{ query={"grab","the","weapon"},   anim="Yes", action="GRAB" }
add{ query={"pick","up","that","gun"},anim="Yes", action="GRAB" }
add{ query={"pick","up","the","gun"}, anim="Yes", action="GRAB" }
add{ query={"arm","yourself"},        anim="Yes", action="GRAB" }
add{ query={"grab","a","weapon"},     anim="Yes", action="GRAB" }

-- ---- GIVE: NPC forages and drops an item for you ---------------------------
add{ query={"give","me","bandage"},   res="Here, patch yourself up.",   anim="Yes", action="GIVE", give="Base.Bandage" }
add{ query={"give","me","cigarette"}, res="Last one's yours.",          anim="Yes", action="GIVE", give="Base.Cigarettes" }
add{ query={"give","me","matches"},   res="Don't burn the place down.", anim="Yes", action="GIVE", give="Base.Matches" }
add{ query={"give","me","water"},     res="Stay hydrated out there.",   anim="Yes", action="GIVE", give="Base.WaterBottleFull" }

-- ---- GOTO: send a FOLLOWER to where your mouse is pointing ------------------
add{ query={"go","over","there"},     anim="Yes", action="GOTO" }
add{ query={"wait","over","there"},   anim="Yes", action="GOTO" }
add{ query={"move","over","there"},   anim="Yes", action="GOTO" }
add{ query={"go","there"},            anim="Yes", action="GOTO" }

-- ---- RESPONSES: the three patterns, demonstrated ---------------------------

-- (1) RANDOM variety: a list -> a different line each time you ask.
add{ query={"you","doing","okay"}, res={
        "Hanging in there. Barely.",
        "Define 'okay'.",
        "Better now that someone's talking sense.",
        "Ask me after I've slept. If I sleep.",
} }

-- (2) COMPUTED: a function branching on WHO is answering.
add{ query={"what","s","your","name"}, res=function(ctx)
        if ctx.polish then return "I'm " .. ctx.name .. ". Z Polski, jak myslisz." end
        if ctx.role == "Inhabitant" then return "Name's " .. ctx.name .. ". I live here. Or did." end
        if ctx.hostile then return "Wouldn't you like to know." end
        return "I'm " .. ctx.name .. "."
end }

-- (3) STABLE per-NPC voice: index a list by ctx.rnd[2] so each NPC is
--     consistent - the same person always gives you the same answer.
add{ query={"what","do","you","want"}, res=function(ctx)
        local lines = {
            [0]="Out. Just out of this town.", [1]="A locked door and a full clip.",
            [2]="To wake up and have this be a nightmare.", [3]="Someone I can trust. You'll do for now.",
            [4]="Quiet. Five minutes of quiet.", [5]="My family back. That's all.",
            [6]="A drink. A strong one.", [7]="To not become one of them.",
            [8]="Answers. Nobody has any.", [9]="To keep moving. Stopping gets you killed.",
        }
        return lines[ctx.rnd[2]] or "I don't know anymore."
end }

-- ---- COND: gate a line to certain NPCs (same query, different speaker) ------
-- These two share a query; the smoker version wins for smokers, the other
-- catches everyone else. (First matching entry wins, so put the gated one up top.)
add{ query={"got","a","smoke"}, cond=function(ctx) return ctx.smoker end,
     res={"Always. Here.", "Down to my last - but sure.", "A fellow addict. Take one."},
     anim="Yes", action="GIVE", give="Base.Cigarettes" }
add{ query={"got","a","smoke"},
     res={"Those things'll kill you. Faster than the rest of this.", "Quit last year. Worst timing ever.", "Nope. Try someone with worse judgment."},
     anim="No" }

-- ---- Goth / horror flavour -------------------------------------------------
add{ query={"are","you","scared"},    res="Everyone's scared. The smart ones just hide it.", anim="PainHead" }
add{ query={"what","s","coming"},     res="Something old, something hungry. Stay close to me." }
add{ query={"nice","outfit"},         res=function(ctx)
        if ctx.female then return "Black hides the bloodstains. A girl plans ahead." end
        return "Black hides the bloodstains. Practical." end, anim="Clap" }
add{ query={"tell","me","a","secret"},res={"I've seen the dead get back up.", "I stopped checking if the bites heal.", "There's no one left to call for help."} }

-- ============================================================================
-- ENGINE  -- you normally won't need to touch anything below here.
-- ============================================================================

local TARGET_PROGRAMS = { "Walker", "Runner", "Inhabitant", "Active", "Babe" }
local TALK_ANIMS = { "Talk1", "Talk2", "Talk3", "Talk4", "Talk5" }

-- Nearest NPC within 8 tiles, same rule the vanilla chat uses.
local function getTarget(player)
    local t = BanditUtils.GetClosestBanditLocationProgram(player, TARGET_PROGRAMS)
    if t and t.id and t.dist < 8 then
        local bandit = BanditZombie.GetInstanceById(t.id)
        if bandit then return bandit, BanditBrain.Get(bandit) end
    end
    return nil, nil
end

-- Build the context table handed to res-functions and cond-functions.
local function buildCtx(player, bandit, brain)
    local p = brain.personality or {}
    return {
        player = player, bandit = bandit, brain = brain,
        name = brain.fullname, female = brain.female,
        role = brain.program and brain.program.name,
        hostile = brain.hostile,
        smoker = p.smoker, alcoholic = p.alcoholic, polish = p.fromPoland,
        rnd = brain.rnd or {0,0,0,0,0},
        pick = function(t) return BanditUtils.Choice(t) end,
    }
end

-- Turn a res (string / list / function) into a final string.
local function resolveRes(res, ctx)
    if type(res) == "function" then res = res(ctx) end
    if type(res) == "table" then res = BanditUtils.Choice(res) end
    return res
end

-- Live %VAR interpolation (small mirror of vanilla's vars).
local function interpolate(res, ctx)
    if not res or not res:find("%%") then return res end
    local gt = getGameTime()
    res = res:replace("%NAME", "I'm " .. (ctx.name or "nobody") .. ".")
    res = res:replace("%HOUR", tostring(gt:getHour()))
    res = res:replace("%MINUTE", string.format("%02d", gt:getMinutes()))
    if res:find("%%MOOD") then
        local lvl = (BWOScheduler and BWOScheduler.SymptomLevel) or 0
        local moods = { [0]="I'm fine. People are acting strange though.",
            [1]="Bit of a headache, nothing serious.",
            [2]="Honestly? This cough won't quit.",
            [3]="I feel terrible. Something's wrong with me." }
        res = res:replace("%MOOD", moods[math.min(lvl, 3)])
    end
    if res:find("%%CITY") then
        local city = "around here"
        local zones = getZones(ctx.player:getX(), ctx.player:getY(), ctx.player:getZ())
        if zones then
            for i = 0, zones:size() - 1 do
                local zone = zones:get(i)
                if zone:getType() == "Region" then city = zone:getName() break end
            end
        end
        res = res:replace("%CITY", city)
    end
    return res
end

-- Find the nearest loose weapon lying on the ground near the NPC.
local function findGroundWeapon(bandit, radius)
    local cell = getCell()
    local bx, by, bz = math.floor(bandit:getX()), math.floor(bandit:getY()), math.floor(bandit:getZ())
    local bestItem, bestObj, bestSq, bestDist
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(bx + dx, by + dy, bz)
            if sq then
                local wobs = sq:getWorldObjects()
                for i = 0, wobs:size() - 1 do
                    local obj = wobs:get(i)
                    local item = obj:getItem()
                    if item and item:IsWeapon() then
                        local d = dx * dx + dy * dy
                        if not bestDist or d < bestDist then
                            bestItem, bestObj, bestSq, bestDist = item, obj, sq, d
                        end
                    end
                end
            end
        end
    end
    return bestItem, bestObj, bestSq
end

-- Equip a ground weapon onto the NPC and remove it from the world.
local function equipGroundWeapon(bandit, brain, item, obj, sq)
    local weapons = Bandit.GetWeapons(bandit)
    local wt = WeaponType.getWeaponType(item)
    local itemType = item:getFullType()

    if wt == WeaponType.FIREARM or wt == WeaponType.HANDGUN then
        local slot = (wt == WeaponType.FIREARM) and "primary" or "secondary"
        local made = BanditWeapons.Make(itemType, 1)
        if not made then return false end   -- couldn't resolve ammo/mag
        weapons[slot] = made
    else
        weapons.melee = itemType
    end

    Bandit.SetWeapons(bandit, weapons)
    Bandit.ForceSyncPart(bandit, { id = brain.id, weapons = weapons })

    -- remove the world item (mirrors the vanilla PickUp removal sequence)
    sq:removeWorldObject(obj)
    sq:transmitRemoveItemFromSquare(obj)
    sq:RecalcProperties()
    sq:RecalcAllWithNeighbours(true)
    obj:removeFromWorld()
    obj:removeFromSquare()
    obj:setSquare(nil)
    item:setWorldItem(nil)
    return true
end

-- ----------------------------------------------------------------------------
-- ACTION DISPATCHER. Returns handled(bool), optionalResponseOverride(string|nil)
-- ----------------------------------------------------------------------------
local function doAction(entry, ctx)
    local act = entry.action
    local bandit, brain = ctx.bandit, ctx.brain

    if act == "GIVE" then
        Bandit.ClearTasks(bandit)
        Bandit.AddTask(bandit, { action="Drop", anim="Forage", itemType=entry.give, time=400 })
        return true, nil

    elseif act == "GOTO" then
        if ctx.role ~= "Babe" then
            return true, "I'm not following you yet - recruit me first."
        end
        local pnum, z = ctx.player:getPlayerNum(), ctx.player:getZ()
        local wx = screenToIsoX(pnum, getMouseX(), getMouseY(), z)
        local wy = screenToIsoY(pnum, getMouseX(), getMouseY(), z)
        Bandit.ClearTasks(bandit)
        Bandit.AddTask(bandit, { action="GoTo", time=50, x=wx, y=wy, z=z, walkType="Walk", closeSlow=true })
        return true, nil

    elseif act == "GRAB" then
        local item, obj, sq = findGroundWeapon(bandit, 2)
        if not item then return true, "Grab what? I don't see a weapon." end
        Bandit.ClearTasks(bandit)
        Bandit.AddTask(bandit, { action="TimeEvent", anim="Forage",
            x=bandit:getX(), y=bandit:getY(), z=bandit:getZ(), time=200 })
        if not equipGroundWeapon(bandit, brain, item, obj, sq) then
            return true, "I can't make that one work."
        end
        return true, ctx.pick({"Got it.", "Don't mind if I do.", "Now we're talking."})
    end

    return false, nil
end

-- ----------------------------------------------------------------------------
-- The wrapper that replaces BWOChat.Say
-- ----------------------------------------------------------------------------
local origSay

local function wrappedSay(chatMessage, quiet)
    local player = getSpecificPlayer(0)
    if not player then return end

    -- No NPC in range -> nothing we can do; let vanilla print the player line.
    local bandit, brain = getTarget(player)
    if not bandit then return origSay(chatMessage, quiet) end
    local ctx = buildCtx(player, bandit, brain)

    -- Build raw + lemmatised copies of the message (same as vanilla).
    local cm = chatMessage:lower()
    local cm2 = ""
    for word in cm:gmatch("%S+") do
        local w = Lemmats and Lemmats.EN and Lemmats.EN[word]
        if w then cm2 = cm2 .. w .. " " end
    end

    for _, v in ipairs(data) do
        local allMatch = true
        for _, word in ipairs(v.query) do
            if not cm:hasword(word) and not cm2:hasword(word) then
                allMatch = false
                break
            end
        end
        -- entry must match words AND pass its optional cond gate
        if allMatch and (not v.cond or v.cond(ctx)) then
            if not quiet then
                local c = player:getSpeakColour()
                player:addLineChatElement(chatMessage, c:getR(), c:getG(), c:getB())
            end

            local anim = v.anim or BanditUtils.Choice(TALK_ANIMS)
            local override = nil
            if v.action then
                local handled
                handled, override = doAction(v, ctx)
                if not handled then
                    Bandit.ClearTasks(bandit)
                    Bandit.AddTask(bandit, { action="TimeEvent", anim=anim,
                        x=player:getX(), y=player:getY(), z=player:getZ(), time=200 })
                end
            else
                Bandit.ClearTasks(bandit)
                Bandit.AddTask(bandit, { action="TimeEvent", anim=anim,
                    x=player:getX(), y=player:getY(), z=player:getZ(), time=200 })
            end

            local res = interpolate(override or resolveRes(v.res, ctx), ctx)
            if res then bandit:addLineChatElement(res, 0, 1, 0) end
            return
        end
    end

    return origSay(chatMessage, quiet)
end

-- ----------------------------------------------------------------------------
-- Install on game start (guarantees BWOChat exists; load order irrelevant).
-- ----------------------------------------------------------------------------
local function install()
    if not BWOChat or type(BWOChat.Say) ~= "function" then
        print("[BWOExtraChat] BWOChat.Say not found - is Bandits Week One enabled?")
        return
    end
    if BWOChat.__extraChatInstalled then return end
    origSay = BWOChat.Say
    BWOChat.Say = wrappedSay
    BWOChat.__extraChatInstalled = true
    print("[BWOExtraChat] installed - " .. #data .. " custom phrases active.")
end

Events.OnGameStart.Add(install)
