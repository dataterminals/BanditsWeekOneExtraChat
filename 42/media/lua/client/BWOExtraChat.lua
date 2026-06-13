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

     NOTE: female NPCs automatically get sassy emphasis layered onto every reply
     ("oh my god", "literally", ...). This is applied centrally by sassify() in
     the engine, so you never have to write it into individual lines.

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
       ctx.said       the raw lowercased message you typed (inspect what was said)
       ctx.lemma      the lemmatised message
       ctx.you        the PLAYER's status & gear, precomputed for convenience:
                        flags  .female .armed .injured .bleeding .infected
                               .sneaking .running
                        values .weapon .health .kills
                        funcs  .hasTrait("Brave") .wears("hazmat") .holding("axe")
                      (.armed/.weapon also count a weapon on your back or in your bag)
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

-- ---- Money / currency: panic and ruin (it's 1993 and it's all falling apart)
-- Any mention of money draws an in-character lament. Each NPC has a STABLE
-- "money sob-story" (picked from ctx.rnd) so a given survivor is consistent -
-- but if you specifically name banks or investments, the reply leans that way.
local moneyLines = {
    bank = {
        "My money? Locked in the bank. ATMs are dead, the doors are chained.",
        "Can't touch a cent. Knox Bank's been 'temporarily closed' for days.",
        "It's all in my account and I can't get a single dollar of it out.",
        "Tried every ATM in town. Nothing. Might as well be Monopoly money.",
        "The bank won't answer. My savings might as well be on the moon.",
    },
    lost = {
        "Lost it. All of it. Don't even ask me how.",
        "Had a wad of cash, now it's gone. Must've had a hole in my pocket.",
        "Someone cleaned me out. Woke up and my savings had just... vanished.",
        "Every bill I owned, gone. This whole week's been cursed.",
        "Don't talk to me about money. I lost the lot.",
    },
    investments = {
        "My portfolio's down ninety percent. Ninety! In a week!",
        "Everything I invested is in free-fall. Watching it tank in real time.",
        "Should've sold last month. Now my stocks aren't worth the paper.",
        "My broker stopped answering. Never a good sign for the markets.",
        "Sank my life savings into the market. The market sank right back.",
    },
    spent = {
        "Spent every last dime. Don't ask on what.",
        "Blew it all. Figured, what's the point of saving now?",
        "Gone. I've been spending like the world's ending. ...It might be.",
        "Treated myself. Repeatedly. Wallet's empty and I regret nothing.",
        "All spent. Beats leaving it to rot in a bank, right?",
    },
    broke = {
        "Money? Ha. Never had two nickels to rub together. Doesn't faze me.",
        "I'm broke and always have been. Hard times don't scare the poor.",
        "Can't lose what you never had. I'm not losing sleep over cash.",
        "Rich folks are panicking. Me? I've got nothing to panic about.",
        "Never trusted banks, never had savings. Joke's on the rest of 'em.",
    },
}

local function moneyRes(ctx)
    local s = ctx.said or ""
    local key
    if s:find("invest") or s:find("stock") or s:find("portfolio") or s:find("market") then
        key = "investments"
    elseif s:find("bank") or s:find("atm") or s:find("withdraw") or s:find("deposit") or s:find("savings") then
        key = "bank"
    else
        -- otherwise fall back to this NPC's own stable money sob-story
        local buckets = { "bank", "lost", "investments", "spent", "broke" }
        key = buckets[(ctx.rnd[3] % 5) + 1]
    end
    return ctx.pick(moneyLines[key])
end

-- One trigger per money/currency word; all share the lament above.
local moneyWords = {
    "money", "cash", "dollar", "dollars", "currency", "bank", "banks",
    "savings", "wealth", "fortune", "investment", "investments", "stocks",
    "portfolio", "wallet", "bucks", "paycheck", "salary", "loan", "debt",
    "mortgage", "retirement", "withdraw", "deposit", "atm",
}
for _, w in ipairs(moneyWords) do
    add{ query={ w }, res=moneyRes }
end

-- ---- The big picture: "what's going on?" / "do you know what's happening?" --
-- About the whole situation everyone's caught in. Each NPC has a STABLE
-- worldview (via ctx.rnd) - conspiratorial, informed, or apathetic - so the
-- paranoid stay paranoid and the burnouts stay checked-out. Naming a conspiracy
-- outright nudges anyone toward the tinfoil-hat answer.
local situationLines = {
    conspiratorial = {
        "You didn't hear it from me, but the government's known for weeks.",
        "It's a cover-up. They're calling it a 'flu.' It is not a flu.",
        "Military doesn't block roads over a cough. They're hiding something.",
        "They quarantined whole towns. You don't do that over nothing.",
        "Chemical leak, lab spill, who knows. But it's man-made, mark my words.",
        "Check the shortwave. What they're NOT saying tells you everything.",
    },
    informed = {
        "People are getting sick. Real sick. And the worst cases don't recover.",
        "The army's setting up blockades, sealing off the whole county.",
        "Radio said stay indoors and avoid anyone sick. So that's what I do.",
        "It started with that cough going around. Now it's everywhere.",
        "Hospitals are overrun. They turned my neighbor away at the door.",
        "Whatever it is, it spreads fast. Keep clear of anyone coughing.",
    },
    apathetic = {
        "No idea, and honestly? Not my problem. I keep my head down.",
        "Couldn't tell you. I stopped watching the news days ago.",
        "Something's going on, sure. Always is. I've got my own troubles.",
        "Don't know, don't care. It'll sort itself out or it won't.",
        "Beats me. Whatever it is, worrying won't help.",
        "Eh. People panic over everything lately. I'm not biting.",
    },
}

local function situationRes(ctx)
    local s = ctx.said or ""
    local key
    if s:find("conspiracy") or s:find("cover") or s:find("government") then
        key = "conspiratorial"
    else
        local buckets = { "conspiratorial", "informed", "apathetic" }
        key = buckets[(ctx.rnd[2] % 3) + 1]
    end
    return ctx.pick(situationLines[key])
end

local situationTriggers = {
    {"happening"}, {"going","on"}, {"situation"}, {"any","news"},
    {"heard","anything"}, {"know","anything"}, {"what","happened"},
    {"what","this","about"},
}
for _, q in ipairs(situationTriggers) do
    add{ query=q, res=situationRes }
end

-- ---- Player-aware: NPCs react to YOUR status and gear (via ctx.you) --------
add{ query={"can","you","fight"}, anim="Yes", res=function(ctx)
    if ctx.you.armed then
        return "With that " .. (ctx.you.weapon or "thing") .. "? Sure, lead the way."
    end
    return "You're not even armed. Find something first."
end }

add{ query={"should","i","be","worried"}, res=function(ctx)
    if ctx.you.bleeding then return "You're bleeding and asking ME if you should worry?" end
    return ctx.pick({"Always. But it keeps you sharp.",
                     "Worried's the right instinct these days.",
                     "Not yet. But soon, I think."})
end }

add{ query={"how","do","i","look"}, res=function(ctx)
    local you = ctx.you
    if you.bleeding then return "You're bleeding! Sit down before you pass out." end
    if you.wears("hazmat") then return "Why the hazmat suit? What do you KNOW?" end
    if you.wears("police") then return "A cop? Are they finally evacuating us?" end
    return "Like the rest of us. Tired and scared."
end }

add{ query={"am","i","sick"}, res=function(ctx)
    if ctx.you.infected then return "...You don't look good. Keep your distance, okay?" end
    return "You look fine. Just that cough everyone's got."
end }

add{ query={"notice","anything"}, res=function(ctx)
    if ctx.you.holding("axe") then return "That axe of yours? Smart. Keep it close." end
    if ctx.you.kills > 0 then return "You've got blood on you. What happened?" end
    return "Nothing in particular. Should I?"
end }

-- ---- NPC weapons: ask what THEY are carrying (nicer than vanilla %WEAPONS) --
local function prettyItem(fullType)
    if not fullType then return nil end
    local short = fullType:match("%.([^%.]+)$") or fullType
    return (short:gsub("_", " "))   -- "Rifle_Winchester" -> "Rifle Winchester"
end

local function npcWeaponLine(ctx)
    local w = Bandit.GetWeapons(ctx.bandit)
    local guns = {}
    if w.primary and w.primary.name then table.insert(guns, prettyItem(w.primary.name)) end
    if w.secondary and w.secondary.name then table.insert(guns, prettyItem(w.secondary.name)) end
    local melee = w.melee and prettyItem(w.melee)
    if #guns > 0 then
        return "Got my " .. table.concat(guns, " and my ") .. ". I know how to use it."
    elseif melee and melee ~= "BareHands" then
        return ctx.pick({ "Just my " .. melee .. ". It's done the job so far.",
                          "Got my " .. melee .. " on me. Better than nothing." })
    else
        return ctx.pick({ "Nothing but my bare hands. Wish I had more.",
                          "No weapon. Kind of hoping I won't need one.",
                          "Unarmed. You're not making me nervous, are you?" })
    end
end

local npcWeaponQ = {
    {"are","you","armed"}, {"do","you","have","a","gun"}, {"do","you","have","a","weapon"},
    {"what","are","you","holding"}, {"are","you","carrying"}, {"got","a","gun"},
}
for _, q in ipairs(npcWeaponQ) do
    add{ query=q, res=npcWeaponLine }
end

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

-- Pre-compute the PLAYER's status and equipment into a tidy bundle, so flavour
-- lines can write ctx.you.armed instead of digging through the raw Java API.
local function buildYou(player)
    local hand  = player:getPrimaryHandItem()
    local off   = player:getSecondaryHandItem()
    local bd    = player:getBodyDamage()

    -- Defensive getter: any missing/renamed B42 method degrades to a default
    -- instead of throwing and killing the whole chat send.
    local function safe(fn, default)
        local ok, val = pcall(fn)
        if ok and val ~= nil then return val end
        return default
    end

    local function isWep(it) return it ~= nil and it:IsWeapon() end
    local function typeHas(it, needle)
        return it ~= nil and string.find(string.lower(it:getFullType()), needle, 1, true) ~= nil
    end

    -- a weapon counts if it's in a hand, slung on the back, or in the bag
    local function invWeapon()
        local inv = player:getInventory()
        local items = inv and inv:getItems()
        if not items then return nil end
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it and it:IsWeapon() then return it end
        end
        return nil
    end

    local you = { player = player }
    local mainWep = safe(function()
        if isWep(hand) then return hand end
        if isWep(off) then return off end
        return invWeapon()
    end, nil)

    you.female   = safe(function() return player:isFemale() end, false)
    you.armed    = mainWep ~= nil
    you.weapon   = mainWep and mainWep:getName() or nil
    you.health   = safe(function() return bd:getOverallBodyHealth() end, 100)    -- 0..100
    you.injured  = you.health < 100
    you.bleeding = safe(function() return bd:getNumPartsBleeding() > 0 end, false)
    you.infected = safe(function() return bd:isInfected() end, false)
    you.kills    = safe(function() return player:getZombieKills() end, 0)
    you.sneaking = safe(function() return player:isSneaking() end, false)
    you.running  = safe(function() return player:isRunning() end, false)
    -- NOTE: panic/drunk/tired dropped - getPanic/getDrunkenness/getFatigue are
    -- not exposed on the player's Stats in this B42 build (they threw nil).

    you.hasTrait = function(t) return player:hasTrait(t) end
    you.holding  = function(needle)             -- substring match on held items
        needle = string.lower(needle)
        return typeHas(hand, needle) or typeHas(off, needle)
    end
    you.wears = function(needle)                -- substring match on worn clothing
        needle = string.lower(needle)
        local worn = player:getWornItems()
        for i = 0, worn:size() - 1 do
            if typeHas(worn:get(i):getItem(), needle) then return true end
        end
        return false
    end
    return you
end

-- Build the context table handed to res-functions and cond-functions.
local function buildCtx(player, bandit, brain)
    local p = brain.personality or {}
    return {
        player = player, bandit = bandit, brain = brain,
        you = buildYou(player),
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

-- Female NPCs layer sassy emphasis onto their replies ("oh my god", "literally",
-- ...). Applied automatically to every one of our responses when the speaker is
-- female, so individual lines never need to spell it out.
local SASS_PREFIX = { "Oh my god. ", "Ugh. ", "Okay, like... ", "Honestly? ",
                      "Oh my god, like... ", "I mean... ", "So, like... " }
local SASS_SUFFIX = { " I literally can't even.", " It's literally insane.",
                      " Like... I can't.", " Oh my god.", " Literally.", " I'm so done." }
local function sassify(text, ctx)
    if not ctx.female or not text or text == "" then return text end
    if ZombRand(100) < 65 then text = ctx.pick(SASS_PREFIX) .. text end
    if ZombRand(100) < 45 then text = text .. ctx.pick(SASS_SUFFIX) end
    return text
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

-- Runs our custom matching/handling. Returns true if it handled the message.
local function tryCustom(player, chatMessage, quiet)
    -- No NPC in range -> nothing we can do; let vanilla print the player line.
    local bandit, brain = getTarget(player)
    if not bandit then return false end
    local ctx = buildCtx(player, bandit, brain)

    -- Build raw + lemmatised copies of the message (same as vanilla).
    local cm = chatMessage:lower()
    local cm2 = ""
    for word in cm:gmatch("%S+") do
        local w = Lemmats and Lemmats.EN and Lemmats.EN[word]
        if w then cm2 = cm2 .. w .. " " end
    end
    ctx.said = cm    -- raw lowercased message, so res-functions can inspect it
    ctx.lemma = cm2  -- lemmatised message

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
            res = sassify(res, ctx)
            if res then bandit:addLineChatElement(res, 0, 1, 0) end
            return true
        end
    end

    return false
end

-- Wrapper that replaces BWOChat.Say. Never lets our code break chat: on any
-- error (or no custom match) it falls back to the original Week One handler.
local function wrappedSay(chatMessage, quiet)
    local player = getSpecificPlayer(0)
    if not player then return end
    local ok, handled = pcall(tryCustom, player, chatMessage, quiet)
    if ok and handled then return end
    if not ok then
        print("[BWOExtraChat] error in custom handler, using vanilla: " .. tostring(handled))
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
