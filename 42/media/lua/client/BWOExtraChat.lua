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
       action = "GIVE"|"GOTO"|"GRAB"|"JOIN" -- optional behaviour, see DISPATCHER
       give   = "Base.Bandage"              -- item id, required for action=GIVE
       nosass = true                        -- skip the female sass layer for this line

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

-- ---- High-priority lines (added first so they outrank the generic flavour) -

-- Realistic "how are you" - grounded in the spreading sickness, not "Excellent!"
local function moodRealistic(ctx)
    local lvl = (BWOScheduler and BWOScheduler.SymptomLevel) or 0
    if lvl >= 3 then
        return ctx.pick({ "Honestly? Awful. I can barely keep my head up.",
            "Not good. Whatever's going around, I think I caught it.",
            "I've been better. A lot better. Something's wrong with me." })
    elseif lvl == 2 then
        return ctx.pick({ "Rough. Can't shake this cough.",
            "Been better - my chest feels tight and I'm wiped out.",
            "Hanging in there, but I feel like hell, truthfully." })
    elseif lvl == 1 then
        return ctx.pick({ "Bit of a headache, otherwise alright I guess.",
            "Tired. Uneasy. Can't put my finger on why.",
            "Okay, I think. Just a little off today." })
    else
        return ctx.pick({ "Getting by. That's about all anyone can say lately.",
            "Holding up. On edge, but holding up.",
            "I'm alright. Tired, mostly. It's been a strange few days." })
    end
end

-- The "captivated" case: a female player carrying the charming + magnetizing +
-- Brave traits, talking to a female NPC. She is powerfully drawn to the player -
-- calmed, radiance-struck, aching to come along. It unfolds in three stages:
--   (1) asking how she IS - general wellbeing, or specifically about fear &
--       safety (its own pool, 1b) - only deepens the pull (no recruiting),
--   (2) the player reassuring her melts her further (still no recruiting),
--   (3) an explicit invite ("c'mon", "come along") is what finally - eagerly -
--       makes her join (action=JOIN).
-- Sincere throughout, so the female sass layer is skipped (nosass).
-- B42's hasTrait() takes a CharacterTrait OBJECT, never a string. Custom Bandits
-- traits live on BWORegistries (registered as "BWO:charming" etc.); vanilla ones
-- are static CharacterTrait constants. Resolve name -> object lazily (these
-- globals only exist once in-world) and cache positives. Returns nil if not yet
-- resolvable, so callers fail safe instead of throwing on every tick.
local traitCache = {}
local function resolveTrait(name)
    local cached = traitCache[name]
    if cached then return cached end
    local obj
    local reg = BWORegistries and BWORegistries.CharacterTraits
    local key = tostring(name):lower()
    if     reg and key == "charming"    then obj = reg.CHARMING
    elseif reg and key == "magnetizing" then obj = reg.MAGNETIZING
    elseif reg and key == "ugly"        then obj = reg.UGLY
    elseif key == "brave"               then obj = CharacterTrait and CharacterTrait.BRAVE
    elseif CharacterTrait and ResourceLocation then
        -- best effort for any other vanilla trait a content line might name
        local ok, t = pcall(function() return CharacterTrait.get(ResourceLocation.of(name)) end)
        if ok then obj = t end
    end
    if obj then traitCache[name] = obj end   -- cache positives only; the registry
    return obj                               -- may simply not be loaded yet
end

local CAPTIVATE_TRAITS = { "charming", "magnetizing", "Brave" }
-- The PLAYER half of the gate, factored out so the proximity-bark engine (far
-- below) can reuse it without building a full chat ctx: a female player wearing
-- all three traits.
local function playerCanCaptivate(player)
    if not player or not player:isFemale() then return false end
    for _, name in ipairs(CAPTIVATE_TRAITS) do
        local t = resolveTrait(name)
        if not t or not player:hasTrait(t) then return false end
    end
    return true
end

local function isCaptivated(ctx)
    return ctx.female and playerCanCaptivate(ctx.player)
end

-- helper: register a batch of captivated triggers sharing one response pool
local function addCaptivated(triggers, opts)
    for _, q in ipairs(triggers) do
        add{ query=q, cond=isCaptivated, nosass=true, anim="Yes",
             action=opts.action, res=function(ctx) return ctx.pick(opts.lines) end }
    end
end

-- (1) Presence / wellbeing - drawn in, calmed, radiance-struck. No recruiting.
addCaptivated({
    {"are","you","okay"}, {"are","you","ok"}, {"you","okay"}, {"are","u","okay"},
    {"are","u","ok"}, {"u","okay"}, {"u","ok"}, {"you","good"}, {"u","good"},
    {"you","alright"}, {"u","alright"}, {"how","are","you"}, {"how","are","you","doing"},
    {"how","r","u"}, {"how","r","u","doing"}, {"how","you","doing"}, {"how","u","doing"},
    {"how","do","you","feel"}, {"how","do","u","feel"}, {"how","you","feeling"},
    {"how","u","feeling"}, {"are","you","hurt"}, {"are","u","hurt"}, {"you","hurt"},
    {"u","hurt"}, {"are","you","alone"}, {"are","u","alone"}, {"you","alone"}, {"u","alone"},
}, { lines = {
    "Honestly? Better, now that you're close. You make the air feel... safe.",
    "I keep losing my train of thought around you. There's just this warmth.",
    "Scared? Strange - the fear dims when you're near, like you're shielding me from it.",
    "More than okay. I feel steady for the first time in days, and it's because of you.",
    "Alone, until you walked over. I don't think I want to be anywhere you aren't.",
    "There's a light about you. I noticed it the second you spoke. I can't look away.",
    "I barely know you, and yet I'd trust you with everything. Is that crazy?",
    "Hurt, tired, frightened - it all goes quiet when you look at me like that.",
    "You feel like the calm in the middle of all this. I just want to stand in it.",
    "Safe. Genuinely safe. I'd forgotten what that even felt like.",
    "Something about you settles me right down. My heart isn't racing anymore.",
    "You're glowing - I can't explain it. I just want to stay near it. Near you.",
    "If anyone's making it through this, it's you. And I want to be wherever you are.",
    "I'm alright. You have this way of making everything feel survivable.",
}})

-- (1b) Fear & safety - "are you scared / safe?" given its own pool. Here she's
-- raw and honest: the full range from real fear and half-buried trauma, through
-- not-wanting-to-talk, to - because YOU are the one asking - a fragile, growing
-- hope that together it might be survivable. Still no recruiting.
addCaptivated({
    {"are","you","scared"}, {"are","u","scared"}, {"you","scared"}, {"u","scared"},
    {"are","you","afraid"}, {"are","u","afraid"}, {"you","afraid"}, {"u","afraid"},
    {"are","you","frightened"}, {"you","frightened"}, {"u","frightened"},
    {"are","you","terrified"}, {"you","terrified"}, {"u","terrified"},
    {"are","you","worried"}, {"you","worried"}, {"u","worried"},
    {"are","you","nervous"}, {"you","nervous"}, {"u","nervous"},
    {"are","you","safe"}, {"are","u","safe"}, {"u","safe"}, {"feel","safe"},
    {"you","feel","safe"}, {"do","you","feel","safe"}, {"are","we","safe"},
    {"we","safe"}, {"you","in","danger"}, {"in","danger"},
}, { lines = {
    "Safe? No - none of us are, not really. But the fear loosens its grip when you're standing here.",
    "Of course I'm not safe. Nobody is. I won't lie to you, of all people - we're in a bad way.",
    "I don't know. I honestly don't know anymore. I stopped being able to tell up from down.",
    "Truthfully? No idea. I just keep moving and praying. It helps that you're moving with me.",
    "I'm freaked out. Completely. My hands haven't stopped shaking in two days.",
    "Terrified. Every shadow, every sound out there. I'm scared right down to my bones.",
    "I saw something. Back there. I can't get it out of my head - people I knew, just... gone.",
    "I watched it happen to someone. Up close. You don't walk away from a thing like that unchanged.",
    "There were people on my street. I heard them through the walls. I ran. God help me, I ran.",
    "I don't want to talk about what I've seen. Please. Not yet. Maybe not ever.",
    "Don't ask me what's out there. I can't say it out loud - not even to you, and I'd tell you anything.",
    "...Can we not? If I start, I'll come apart. Just - stay near me instead. That helps more.",
    "It's awful. It is. But - and maybe this is you - it's started to feel like it might get better.",
    "I'm scared. But when you're close, I actually believe we come through this. I didn't, before you.",
    "I don't know what tomorrow brings. I only know that with you beside me, I think we manage it.",
    "Things are bad, I won't pretend otherwise. But I'm starting to believe we'll see the other side.",
    "For the first time, I don't feel like I'm facing it alone. You've no idea what that does for me.",
    "An hour ago I was falling apart. Now, with you here, the fear has somewhere to go. It's quieter.",
    "Scared, yes. Less of it by the minute, though. You do that to a person - to me.",
    "Safe is a strange word these days. The nearest I've come to it is right here, next to you.",
    "Some nights I'm sure we won't make it. Then you look at me like that, and I'm sure we will.",
    "I hold it together because I have to. But with you, I can admit I'm frightened - and feel lighter for it.",
}})

-- (2) Reassurance from the player - she melts, trusts, all but asks to be taken.
addCaptivated({
    {"trust","me"}, {"you","re","safe"}, {"you","are","safe"}, {"ur","safe"},
    {"your","safe"}, {"got","you"}, {"got","u"}, {"i","got","you"}, {"i","got","u"},
    {"protect","you"}, {"protect","u"}, {"i","ll","protect"}, {"don","t","be","scared"},
    {"dont","be","scared"}, {"don","t","be","afraid"}, {"dont","be","afraid"},
    {"stay","close"}, {"i","won","t","let"}, {"i","wont","let"}, {"i","m","here"},
    {"im","here"}, {"i","m","with","you"}, {"im","with","u"},
}, { lines = {
    "I do trust you. Completely - like I've known you my whole life.",
    "When you say it, I actually believe it. The knot in my chest just... loosens.",
    "I'm not scared. Not with you saying that. You make it sound so certain.",
    "I'd go anywhere you told me to. You know that already, don't you?",
    "Something in me just let go. I'd put my life in your hands.",
    "Stay close? I wasn't planning to leave your side for a second.",
    "You don't even have to ask. I'm yours to look after.",
    "Keep talking like that and I'll never want to be more than a step from you.",
    "I feel it - that pull. Like I was always meant to find you.",
    "Okay. Okay. I feel safe. Just... don't go anywhere without me, alright?",
}})

-- (3) The invitation - eager, unhesitating yes, and she actually joins.
addCaptivated({
    {"come","along"}, {"come","with","me"}, {"come","w","me"}, {"come","with","us"},
    {"come","here"}, {"come","on"}, {"c'mon"}, {"cmon"}, {"c'mere"}, {"cmere"},
    {"let","s","go"}, {"lets","go"}, {"let","s","move"}, {"lets","move"},
    {"let","s","roll"}, {"lets","roll"}, {"stay","with","me"}, {"join","me"},
    {"join","us"}, {"follow","me"}, {"stick","with","me"}, {"by","my","side"},
}, { action="JOIN", lines = {
    "Yes. God, yes - I thought you'd never ask. Lead the way.",
    "You don't have to tell me twice. I'm with you, all of it.",
    "I'm coming. I'd follow you into anything - I mean that.",
    "Finally. I've been waiting for you to say it. Let's go.",
    "Right behind you. Wherever you go, I go. That's settled now.",
    "Yes - wherever this leads, I want to be at your side for it.",
    "Took you long enough. I'm yours. Let's get out of here.",
    "Of course. Honestly? I'd have followed you even if you hadn't asked.",
    "Without a second thought. You lead, I'm right there.",
    "I'm coming - and I'm not letting you out of my sight again.",
    "Say no more. I'm with you now, for whatever comes.",
    "Yes. It feels right, being near you. Let's go - together.",
}})

-- Captivated PROXIMITY barks: when a captivating player simply walks near a
-- female NPC, the NPC speaks FIRST - unprompted, before any key-press (see the
-- PROXIMITY BARKS engine block far below). Sincere, drawn-in, noticing-you-
-- approach lines. Edit this pool freely; it is the content half of the feature.
local barkLines = {
    "Oh - it's you. I was hoping you'd come this way.",
    "There you are... I keep finding my eyes drawn to you.",
    "You're back. The whole room feels warmer when you're near.",
    "I don't even know your name, and somehow I've been waiting for you.",
    "Hey - don't go far, okay? It's easier to breathe when you're close.",
    "I saw you coming and my heart just... settled. Strange, isn't it?",
    "Something about you pulls me right in. I'm not even fighting it.",
    "You walked over and the fear went quiet. How do you do that?",
    "I keep telling myself to look away. I never quite manage it.",
    "Stay a moment? I feel safe the second you're standing near me.",
    "Funny - I was dreading today, and then you appeared.",
    "I'd follow you out of here in a heartbeat, if you asked me to.",
}

-- Follower CAR-ENTRY barks: when a follower runs to your car and climbs in. Our
-- override of Week One's Babe program (see ENGINE) emits these instead of its two
-- hardcoded lines, throttled so the "wait" line doesn't repeat every tick. A
-- captivating player gets the warmer pools. Edit freely.
local carRunLines = {              -- running to catch the car
    "Wait for me!", "Hold on - I'm coming!", "Don't leave without me!",
    "Right behind you - give me a second!", "Coming, coming!",
    "Wait up! I'm getting in.",
}
local carRunLinesCaptivated = {
    "Wait for me - don't you dare drive off without me!",
    "I'm coming! You're not going anywhere without me.",
    "Right behind you, always - hold on!",
    "Give me a second - I'd run a lot further than this for you.",
    "Coming! Wherever you're headed, I'm headed.",
}
local carInLines = {               -- seated and ready
    "I'm in!", "Okay, let's roll.", "Buckled up - go.",
    "Got it, I'm in. Drive.", "All set.", "In! Let's move.",
}
local carInLinesCaptivated = {
    "I'm in - and right where I want to be.",
    "All yours. Drive us anywhere.",
    "In. Honestly? I love riding beside you.",
    "Settled in next to you. Let's go - together.",
    "Buckled up beside you. Lead on.",
}

-- Generic realistic versions of those questions (when not captivated)
add{ query={"how","are","you"},         res=moodRealistic }
add{ query={"are","you","okay"},        res=moodRealistic }
add{ query={"are","you","ok"},          res=moodRealistic }
add{ query={"you","okay"},              res=moodRealistic }
add{ query={"how","are","you","doing"}, res=moodRealistic }
add{ query={"how","do","you","feel"},   res=moodRealistic }
add{ query={"are","you","scared"}, res={
        "Terrified, if I'm honest. Everyone is.",
        "Trying not to be. Not doing a great job of it.",
        "A little. Something feels wrong out there.",
        "You'd be a fool not to be, the way things are." } }
add{ query={"are","you","alone"}, res={
        "For now. Wasn't always.",
        "Just me. Safer that way, maybe.",
        "Yeah. It's nice to have someone to talk to, actually.",
        "Alone enough that I'm glad you stopped." } }
add{ query={"are","you","hurt"}, res={
        "Not yet. Planning to keep it that way.",
        "A few scrapes. Nothing that'll kill me.",
        "I'm in one piece. For now." } }

-- "What do you do?" - occupation from their AI role, else a stable civilian job
local jobByProgram = {
    Gardener    = "Groundskeeping, landscaping - that kind of thing.",
    Janitor     = "I'm a janitor. Somebody's got to keep the place clean.",
    Postal      = "Mail carrier. Rain, snow, or... whatever this is.",
    Medic       = "I'm a paramedic. God knows they need us right now.",
    Fireman     = "Firefighter. Twenty years on the job.",
    Police      = "Police officer - though good luck reaching dispatch.",
    Entertainer = "I perform on the street. Folks could use a smile lately.",
    ArmyGuard   = "National Guard. They called us all up.",
    Patrol      = "Military. Don't ask me what we're guarding against.",
    RiotPolice  = "Riot police. It's been... a long week.",
}
local civilianJobs = {
    "I work retail over at the strip mall.",
    "Accountant. Numbers don't care about the end of the world.",
    "Schoolteacher - was, anyway, before they closed everything.",
    "I drive a delivery truck.",
    "I tend bar downtown. Quiet shifts lately.",
    "Construction. Honest work.",
    "I'm a nurse over at the clinic.",
    "Mechanic. I can fix anything but this mess.",
    "I work at the bank. Can't even get my own money out - ironic, huh.",
    "Office job. Cubicle, coffee, the whole nine yards.",
}
local function jobRes(ctx)
    return jobByProgram[ctx.role] or civilianJobs[(ctx.rnd[3] % #civilianJobs) + 1]
end
local jobTriggers = {
    {"what","do","you","do"}, {"what","s","your","job"}, {"whats","your","job"},
    {"what","your","job"}, {"what","s","your","occupation"}, {"what","your","occupation"},
    {"what","s","your","profession"}, {"where","do","you","work"},
    {"what","do","you","do","for","a","living"},
}
for _, q in ipairs(jobTriggers) do
    add{ query=q, res=jobRes }
end

-- Conversational back-channels (the player's "second message" continuers)
add{ query={"oh","yeah"},      res={"Yeah. Dead serious.", "Mhm. Believe it.", "Wish I wasn't.", "Yeah, for real."} }
add{ query={"i","feel","you"}, res={"Yeah. Good to know someone gets it.", "Right? Nobody else seems to.", "Means something, hearing that."} }
add{ query={"i","hear","you"}, res={"We're on the same page, then.", "Glad someone does.", "Right back at you."} }
add{ query={"no","way"},       res={"Way.", "I know, right?", "Swear to God.", "Wish I was making it up."} }
add{ query={"for","real"},     res={"For real.", "Dead serious.", "I wouldn't joke about this.", "Real as it gets."} }
add{ query={"makes","sense"},  res={"Right? Glad someone thinks so.", "Took me a while to see it too.", "It's the only thing that does."} }
add{ query={"i","guess"},      res={"You don't sound sure.", "'I guess' is about all any of us have.", "Mm. Don't overthink it."} }
add{ query={"fair","enough"},  res={"Damn right.", "Glad you see it that way.", "Thought you'd understand."} }
add{ query={"damn"},           res={"Yeah. Tell me about it.", "I know.", "Crazy times, huh."} }
add{ query={"no","kidding"},   res={"Kid you not.", "Swear it.", "Dead serious."} }
add{ query={"go","on"},        res={"That's... about all I've got, honestly.", "Then we survive. Somehow.", "That's the part that scares me."} }
add{ query={"then","what"},    res={"Then we figure it out. Together, ideally.", "Then? I genuinely don't know.", "Then we keep moving."} }
add{ query={"huh"},            res={"Right?", "Yeah. Chew on that.", "Stuck with me too."} }

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

-- ---- GETOUT: order squatters out of YOUR claimed home (no traits needed) ----
-- Only does anything when the NPC is standing in your registered player base
-- (i.e. a home you've claimed - e.g. via the Homestead mod). Then she stops
-- squatting and walks out the nearest exit; once outside, the game turns her
-- back into a wanderer. If it ISN'T your base, she just tells you off. See the
-- GETOUT branch in the DISPATCHER for the actual behaviour.
local evictTriggers = {
    {"get","out","of","my","house"}, {"out","of","my","house"}, {"out","my","house"},
    {"outta","my","house"}, {"leave","my","house"}, {"get","out","of","my","home"},
    {"out","of","my","home"}, {"outta","my","home"}, {"leave","my","home"},
    {"this","is","my","house"}, {"this","is","my","home"}, {"off","my","property"},
    {"my","property"}, {"get","off","my","lawn"},
}
for _, q in ipairs(evictTriggers) do
    add{ query=q, action="GETOUT", res="Alright - I'm going." }
end

-- ---- DISMISS: send a FOLLOWER away (un-joins + opens her a way out) ----------
-- Overrides Week One's own "leave me" / "go away" so a dismissed follower walks
-- out through your (locked) door cleanly instead of pacing at it. Non-followers
-- just get a shrug. See the DISMISS branch in the DISPATCHER.
local dismissTriggers = {
    {"leave","me"}, {"go","away"}, {"dismissed"}, {"you","re","dismissed"},
    {"you","are","dismissed"}, {"we","re","done"}, {"part","ways"},
    {"take","off"}, {"on","your","way"}, {"get","lost"},
}
for _, q in ipairs(dismissTriggers) do
    add{ query=q, action="DISMISS", res="Alright." }
end

-- ---- FOLLOWER GEAR: control what a follower wields and carries (Babe only) ---
-- All six route through dispatcher branches that gate on ctx.role == "Babe".
-- GEAR (equip/holster/switch) parses the message; the rest are direct.

-- equip / draw / switch / holster
local gearTriggers = {
    {"draw","your","weapon"}, {"draw","your","gun"}, {"draw","your","pistol"},
    {"draw","your","rifle"}, {"draw","your","melee"}, {"draw","your","knife"},
    {"draw","your","blade"}, {"weapons","out"}, {"weapon","out"}, {"ready","up"},
    {"ready","your","weapon"}, {"arm","up"}, {"gear","up"}, {"equip","your"},
    {"equip","the"}, {"equip","a"}, {"wield","your"}, {"use","your","gun"},
    {"use","your","rifle"}, {"use","your","pistol"}, {"use","your","shotgun"},
    {"use","your","melee"}, {"use","your","knife"}, {"use","your","fists"},
    {"switch","to","your","gun"}, {"switch","to","your","rifle"},
    {"switch","to","your","pistol"}, {"switch","to","melee"},
    {"switch","to","your","melee"}, {"pull","out","your"},
    {"put","it","away"}, {"put","that","away"}, {"put","your","weapon","away"},
    {"weapons","down"}, {"weapon","down"}, {"lower","your","weapon"},
    {"stand","down"}, {"at","ease"}, {"holster","it"}, {"holster","your","weapon"},
    {"go","barehanded"},
}
for _, q in ipairs(gearTriggers) do add{ query=q, action="GEAR", res="Okay." } end

-- ARM: hand the follower the weapon in YOUR hand (added before CARRY so
-- "take this gun" wins over the bare "take this")
local armTriggers = {
    {"use","this"}, {"use","this","one"}, {"wield","this"}, {"here","use","this"},
    {"take","this","gun"}, {"take","this","weapon"}, {"equip","this"},
    {"use","this","instead"}, {"try","this","one"},
}
for _, q in ipairs(armTriggers) do add{ query=q, action="ARM", res="Okay." } end

-- DISARM: take the follower's weapon (she drops it for you)
local disarmTriggers = {
    {"give","me","your","gun"}, {"give","me","your","weapon"}, {"give","me","your","rifle"},
    {"give","me","your","pistol"}, {"hand","over","your","weapon"}, {"hand","over","your","gun"},
    {"hand","me","your","weapon"}, {"drop","your","weapon"}, {"drop","your","gun"}, {"disarm"},
}
for _, q in ipairs(disarmTriggers) do add{ query=q, action="DISARM", res="Okay." } end

-- CARRY: stash the item in your hand into her bag
local carryTriggers = {
    {"hold","this"}, {"carry","this"}, {"hold","onto","this"}, {"hold","this","for","me"},
    {"carry","this","for","me"}, {"can","you","hold","this"}, {"can","you","carry","this"},
    {"take","this"}, {"hold","it","for","me"},
}
for _, q in ipairs(carryTriggers) do add{ query=q, action="CARRY", res="Okay." } end

-- BAGCHECK: list what she's carrying
local bagTriggers = {
    {"what","s","in","your","bag"}, {"what","is","in","your","bag"}, {"in","your","bag"},
    {"check","your","bag"}, {"your","inventory"}, {"show","me","your","inventory"},
    {"what","supplies","do","you","have"}, {"got","any","supplies"}, {"what","s","in","your","pack"},
}
for _, q in ipairs(bagTriggers) do add{ query=q, action="BAGCHECK", res="Okay." } end

-- DROPALL: dump her whole bag at her feet
local dropTriggers = {
    {"drop","everything"}, {"drop","it","all"}, {"empty","your","bag"}, {"empty","your","pockets"},
    {"hand","over","everything"}, {"give","me","everything"}, {"drop","your","stuff"},
    {"drop","the","loot"}, {"drop","your","gear"},
}
for _, q in ipairs(dropTriggers) do add{ query=q, action="DROPALL", res="Okay." } end

-- WEAR: swap her into clothing you've dropped beside her (slot inferred from the
-- item; whatever she had in that slot is dropped). Clothing can't be hand-given,
-- so it must be on the ground - if nothing's there she'll ask you for it.
local wearTriggers = {
    {"wear","this"}, {"wear","these"}, {"wear","that"}, {"put","this","on"},
    {"put","these","on"}, {"put","that","on"}, {"put","on","this"},
    {"try","this","on"}, {"change","into","this"}, {"get","dressed"},
    {"change","your","clothes"}, {"change","clothes"}, {"swap","clothes"},
}
for _, q in ipairs(wearTriggers) do add{ query=q, action="WEAR", res="Okay." } end

-- STRIP: follower removes a named garment (or everything) and drops it - the
-- other half of "take your <slot> off". Gated to followers, so a stranger's
-- "undress" still hits Week One's own (hostile) reaction.
local function isFollower(ctx) return ctx.role == "Babe" end
local stripTriggers = {
    {"take","off","your"}, {"remove","your"}, {"take","that","off"},
    {"take","off","that"}, {"take","it","off"}, {"lose","the"}, {"ditch","the"},
    {"strip"}, {"undress"}, {"get","naked"}, {"take","everything","off"},
    {"take","off","everything"},
}
for _, q in ipairs(stripTriggers) do add{ query=q, cond=isFollower, action="STRIP", res="Okay." } end

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

-- ----------------------------------------------------------------------------
-- PROXIMITY BARKS: captivated-only, unprompted speech as the player approaches.
-- When the player is the captivating build (female + charming + magnetizing +
-- Brave), a nearby FEMALE, non-hostile NPC speaks first as she nears them - the
-- captivated arc bleeding into the world. Purely cosmetic: a floating line, no
-- recruiting and no AI change (typed chat still drives all of that). Lines live
-- in `barkLines` up in the content section; the four knobs here are behaviour
-- and are all safe to tune after seeing it in-game.
--
-- She must also be in the SAME SPACE as the player (both outside, or the same
-- room) with a clear line of sight - so she never barks through a wall or out a
-- window at someone in the street. "Once per approach" is approximated cheaply:
-- a per-NPC cooldown stops the same survivor repeating, and a global gap keeps
-- two NPCs barking on top of each other. We only inspect the single CLOSEST NPC.
-- ----------------------------------------------------------------------------
local BARK_RANGE        = 6        -- tiles: how close before she speaks
local BARK_SCAN_MS      = 1000     -- real ms between proximity scans (throttle)
local BARK_NPC_COOLDOWN = 120000   -- real ms before the SAME NPC barks again
local BARK_GLOBAL_GAP   = 18000    -- real ms minimum gap between ANY two barks

local barkNextOk       = {}   -- [bandit id] -> earliest real-ms it may bark again
local barkGlobalNextOk = 0
local barkNextScan     = 0

local function proximityBark(player)
    if not player then return end
    local now = getTimestampMs()
    if now < barkNextScan then return end           -- throttle the scan itself
    barkNextScan = now + BARK_SCAN_MS

    if not playerCanCaptivate(player) then return end -- cheap gate, bail early
    if player:getVehicle() then return end            -- not while you're driving past
    if now < barkGlobalNextOk then return end

    local t = BanditUtils.GetClosestBanditLocationProgram(player, TARGET_PROGRAMS)
    if not (t and t.id and t.dist < BARK_RANGE) then return end

    local bandit = BanditZombie.GetInstanceById(t.id)
    if not bandit then return end
    local brain = BanditBrain.Get(bandit)
    if not brain or not brain.female or brain.hostile then return end
    if now < (barkNextOk[t.id] or 0) then return end

    -- Same-space + line of sight: she only speaks up when you're genuinely
    -- TOGETHER. getRoom() is nil outdoors, so this one compare means "same room,
    -- or both outside" - and rejects the immersion-breaker the player flagged: an
    -- NPC holed up inside leaning out a window to a stranger in the street (her
    -- room vs the player's nil). getCanSee then blocks a solid wall between two
    -- outdoor squares, and folds in the player's vision so she won't pipe up from
    -- off-screen behind you. Checked last, so a blocked attempt doesn't burn her
    -- cooldown.
    local sq  = bandit:getCurrentSquare()
    local psq = player:getCurrentSquare()
    if not sq or not psq then return end
    if sq:getRoom() ~= psq:getRoom() then return end           -- not the same space
    if not sq:getCanSee(player:getPlayerNum()) then return end  -- wall between us

    bandit:addLineChatElement(BanditUtils.Choice(barkLines), 0, 1, 0)
    barkNextOk[t.id]   = now + BARK_NPC_COOLDOWN
    barkGlobalNextOk   = now + BARK_GLOBAL_GAP
end

-- ----------------------------------------------------------------------------
-- FOLLOWER CAR ENTRY: a follower (Babe) hops into your car when you're driving.
-- Week One's Babe program already does this, but with two hardcoded lines and
-- "Wait for me!" spammed every tick. We override ONLY that car block (varied +
-- throttled + captivating-aware barks) and delegate everything else - following,
-- combat, idle - to the original program. Installed at game start.
-- ----------------------------------------------------------------------------
local origBabeMain
local carBarkNextOk = {}     -- [bandit id] -> next real-ms it may say a "wait" line

-- Returns a program-result table if it handled the car-entry case, else nil.
local function babeCarEntry(bandit)
    local master  = BanditPlayer.GetMasterPlayer(bandit)
    local vehicle = master and master:getVehicle()
    if not (master and vehicle and vehicle:isDriver(master)) then return nil end
    local pos = BanditUtils.GetSeatPosition(vehicle, 1)   -- front passenger seat
    if not pos then return nil end

    local d = BanditUtils.DistTo(bandit:getX(), bandit:getY(), pos.x, pos.y)
    local captivated = playerCanCaptivate(master)
    local brain = BanditBrain.Get(bandit)

    if d < 1 then
        -- climb in (mirrors Week One's fake-passenger handling)
        if brain then
            brain.vehicleId = vehicle:getId()
            Bandit.ForceSyncPart(bandit, brain)
            vehicle:getModData().passengerId = brain.id
            carBarkNextOk[brain.id] = nil
        end
        bandit:addLineChatElement(BanditUtils.Choice(captivated and carInLinesCaptivated or carInLines), 0, 1, 0)
        master:playSound("VehicleDoorOpen")
        bandit:removeFromSquare()
        bandit:removeFromWorld()
        return { status=true, next="Main", tasks={} }
    else
        -- still running for it - say a "wait" line, but throttled (not every tick)
        local id = brain and brain.id
        local now = getTimestampMs()
        if id and now >= (carBarkNextOk[id] or 0) then
            bandit:addLineChatElement(BanditUtils.Choice(captivated and carRunLinesCaptivated or carRunLines), 0, 1, 0)
            carBarkNextOk[id] = now + 3000
        end
        return { status=true, next="Main", tasks={ BanditUtils.GetMoveTask(-0.07, pos.x, pos.y, pos.z, "Run", d) } }
    end
end

-- The replacement Babe.Main: try our car-entry (guarded); otherwise the original.
local function babeMainEnhanced(bandit)
    local ok, res = pcall(babeCarEntry, bandit)
    if ok and res then return res end
    return origBabeMain(bandit)
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

    you.hasTrait = function(t)              -- accepts a trait NAME (string) and
        local obj = resolveTrait(t)         -- resolves it to a B42 CharacterTrait
        if not obj then return false end
        return player:hasTrait(obj)
    end
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

-- Female NPCs get a light sassy inflection. Kept subtle on purpose: only a
-- minority of lines are touched, never both ends at once, and prefixes flow into
-- the sentence (comma + lowercased continuation) so it reads as natural speech
-- rather than a canned phrase bolted on. Tune SASS_CHANCE_* to taste.
local SASS_PREFIX = { "Honestly, ", "Okay, ", "I mean, ", "Ugh, ", "Like, ", "Oh my god, " }
local SASS_SUFFIX = { " Like, seriously.", " I swear.", " ...honestly.", " Literally." }
local SASS_CHANCE_PREFIX = 28   -- % of female lines that get a leading inflection
local SASS_CHANCE_SUFFIX = 12   -- % that get a trailing tic instead (mutually exclusive)

-- Lowercase the first letter so a comma-prefix flows, but leave a lone "I" alone.
local function lcfirst(s)
    if s:match("^I%f[%A]") then return s end   -- "I", "I'm", "I'll", ...
    return s:sub(1, 1):lower() .. s:sub(2)
end

local function sassify(text, ctx)
    if not ctx.female or not text or text == "" then return text end
    local roll = ZombRand(100)
    if roll < SASS_CHANCE_PREFIX then
        text = ctx.pick(SASS_PREFIX) .. lcfirst(text)
    elseif roll < SASS_CHANCE_PREFIX + SASS_CHANCE_SUFFIX then
        text = text .. ctx.pick(SASS_SUFFIX)
    end
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

-- Strip a loose world item off a square (same sequence equipGroundWeapon uses).
local function removeWorldItem(sq, obj, item)
    sq:removeWorldObject(obj)
    sq:transmitRemoveItemFromSquare(obj)
    sq:RecalcProperties()
    sq:RecalcAllWithNeighbours(true)
    obj:removeFromWorld()
    obj:removeFromSquare()
    obj:setSquare(nil)
    item:setWorldItem(nil)
end

-- All loose CLOTHING items lying within `radius` tiles of the NPC. Returns a
-- list of { item=, obj=, sq=, loc= } where loc is the body-location string.
local function findGroundClothing(bandit, radius)
    local cell = getCell()
    local bx, by, bz = math.floor(bandit:getX()), math.floor(bandit:getY()), math.floor(bandit:getZ())
    local found = {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(bx + dx, by + dy, bz)
            if sq then
                local wobs = sq:getWorldObjects()
                for i = 0, wobs:size() - 1 do
                    local obj = wobs:get(i)
                    local item = obj:getItem()
                    if item and instanceof(item, "Clothing") then
                        local loc = item:getBodyLocation()
                        if loc and loc ~= "" then
                            found[#found + 1] = { item = item, obj = obj, sq = sq, loc = loc }
                        end
                    end
                end
            end
        end
    end
    return found
end

-- Best-effort: read a clothing item's dye tint -> packed dec (nil if undyed),
-- so a swapped-in garment keeps its colour. pcall-guarded: if the visual API
-- isn't shaped as expected it just returns nil and the item renders default.
local function captureTint(item)
    local ok, dec = pcall(function()
        local vis = item:getVisual()
        if not vis then return nil end
        local tint = vis:getTint()
        if not tint then return nil end
        local r, g, b = tint:getRedFloat(), tint:getGreenFloat(), tint:getBlueFloat()
        if r > 0.97 and g > 0.97 and b > 0.97 then return nil end   -- white == undyed
        return BanditUtils.rgb2dec(r, g, b)
    end)
    if ok then return dec end
    return nil
end

-- STRIP support: which worn garment did the player name, are they asking for a
-- full strip, and a readout of what she's wearing. Garment word -> a term that
-- appears in the body-location key or item type.
local garmentAliases = {
    coat="jacket", parka="jacket", overcoat="jacket", blazer="jacket",
    trousers="pants", jeans="pants", slacks="pants",
    boots="shoes", sneakers="shoes", footwear="shoes",
    cap="hat", helmet="hat", beanie="hat",
    hoodie="sweater", pullover="sweater", jumper="sweater",
    glove="hands", gloves="hands", mittens="hands",
    shades="eyes", glasses="eyes", sunglasses="eyes", goggles="eyes", scarf="neck",
}
local function findWornGarment(brain, said)
    if not brain.clothing then return nil end
    local terms = {}
    for w in said:gmatch("%a+") do terms[#terms + 1] = garmentAliases[w] or w end
    for loc, itemType in pairs(brain.clothing) do
        local hay = (tostring(loc) .. " " .. (itemType:match("%.([^%.]+)$") or itemType)):lower():gsub("_", " ")
        for _, term in ipairs(terms) do
            if #term >= 3 and hay:find(term, 1, true) then return loc, itemType end
        end
    end
    return nil
end
local function wantsFullStrip(said)
    return said:find("everything") or said:find("naked") or said:find("undress")
        or said:find("strip") or said:find("all off") or said:find("it all")
        or said:find("your clothes")
end
local function wearingList(brain)
    if not brain.clothing then return "barely anything." end
    local parts = {}
    for _, itemType in pairs(brain.clothing) do
        parts[#parts + 1] = (prettyItem(itemType) or "something")
        if #parts >= 6 then break end
    end
    if #parts == 0 then return "honestly, not much." end
    return "my " .. table.concat(parts, ", ") .. "."
end

-- Make a bandit leave the player's home ON FOOT and stop squatting: open AND
-- unlock the nearest exterior door (the player's Homestead claim keys doors shut,
-- which otherwise traps a plain Walker pacing at the door), then queue a LOCKED
-- walk to just outside it. Once outside, the game flips her back into a wanderer.
-- Shared by GETOUT (evicting a squatter) and DISMISS (sending a follower away).
local function walkBanditOut(bandit, player)
    local bx, by, bz = bandit:getX(), bandit:getY(), bandit:getZ()
    local bsq = bandit:getCurrentSquare()
    local def = bsq and bsq:getBuilding() and bsq:getBuilding():getDef()
    local tx, ty = bx, by

    if def then
        -- open her a way out: nearest exterior door, unlocked + swung open
        local door = BWOObjects and BWOObjects.FindExteriorDoor
                     and BWOObjects.FindExteriorDoor(bandit, def)
        if door then
            pcall(function() door:setLockedByKey(false) end)
            if not door:IsOpen() then pcall(function() door:ToggleDoorSilent() end) end
            local s1, s2 = door:getSquare(), door:getOppositeSquare()
            local outSq = (s1 and s1:isOutside() and s1) or (s2 and s2:isOutside() and s2)
            if outSq then tx, ty = outSq:getX(), outSq:getY() end
        end
        if tx == bx and ty == by then
            -- no usable door: aim a few tiles past the nearest wall instead
            local x1, y1, x2, y2 = def:getX(), def:getY(), def:getX2(), def:getY2()
            local dW, dE, dN, dS = bx - x1, x2 - bx, by - y1, y2 - by
            local m, nearest = 4, math.min(dW, dE, dN, dS)
            if     nearest == dW then tx = x1 - m
            elseif nearest == dE then tx = x2 + m
            elseif nearest == dN then ty = y1 - m
            else                      ty = y2 + m end
        end
    else
        tx, ty = bx + (bx - player:getX()), by + (by - player:getY())
    end

    Bandit.SetHostileP(bandit, false)
    Bandit.SetProgram(bandit, "Walker", {})       -- un-joins a follower / stops squatting
    Bandit.ClearTasks(bandit)
    local dist = BanditUtils.DistTo(bx, by, tx, ty)
    local moveTask = BanditUtils.GetMoveTask(0, tx, ty, bz, "Walk", dist, true)
    moveTask.lock = true                          -- survive the program's ClearTasks
    Bandit.AddTask(bandit, moveTask)
    local b = BanditBrain.Get(bandit)
    Bandit.ForceSyncPart(bandit, { id = b.id, program = b.program })
end

-- Does the player's message name one of this NPC's actual weapons (slots or
-- bag)? Returns the matching itemType, so "equip the winchester" / "draw the axe"
-- find the right gun even when it isn't a generic gun/melee keyword.
local function matchNamedWeapon(said, weapons, bandit)
    local cand = {}
    if weapons.primary   and weapons.primary.name   then cand[#cand+1] = weapons.primary.name end
    if weapons.secondary and weapons.secondary.name then cand[#cand+1] = weapons.secondary.name end
    if weapons.melee and weapons.melee ~= "Base.BareHands" then cand[#cand+1] = weapons.melee end
    local inv = bandit:getInventory()
    local items = inv and inv:getItems()
    if items then
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it and it:IsWeapon() then cand[#cand+1] = it:getFullType() end
        end
    end
    for _, ft in ipairs(cand) do
        for word in (prettyItem(ft) or ""):lower():gmatch("%a+") do
            if #word > 2 and said:find(word, 1, true) then return ft end
        end
    end
    return nil
end

-- Make a weapon ITEM the bandit's weapon (slot chosen by type) and draw it.
-- Returns the itemType on success. Mirrors equipGroundWeapon's slot logic.
local function armBanditWith(bandit, brain, item)
    if not (item and item:IsWeapon()) then return nil end
    local weapons = Bandit.GetWeapons(bandit)
    if not weapons then return nil end
    local wt = WeaponType.getWeaponType(item)
    local itemType = item:getFullType()
    if wt == WeaponType.FIREARM or wt == WeaponType.HANDGUN then
        local slot = (wt == WeaponType.FIREARM) and "primary" or "secondary"
        local made = BanditWeapons.Make(itemType, 1)
        if not made then return nil end
        weapons[slot] = made
    else
        weapons.melee = itemType
    end
    Bandit.SetWeapons(bandit, weapons)
    Bandit.ForceSyncPart(bandit, { id = brain.id, weapons = weapons })
    Bandit.ClearTasks(bandit)
    Bandit.AddTask(bandit, { action="Equip", itemPrimary=itemType })
    return itemType
end

-- ----------------------------------------------------------------------------
-- ACTION DISPATCHER. Returns handled(bool), optionalResponseOverride(string|nil)
-- ----------------------------------------------------------------------------
local function doAction(entry, ctx)
    local act = entry.action
    local bandit, brain = ctx.bandit, ctx.brain

    if act == "JOIN" then
        -- recruit as a follower (mirrors Week One's own JOIN)
        Bandit.SetProgram(bandit, "Babe", {})
        Bandit.SetHostileP(bandit, false)
        brain.permanent = true
        if ctx.you.hasTrait("magnetizing") then brain.loyal = true end
        return true, nil

    elseif act == "GIVE" then
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

    elseif act == "GETOUT" then
        -- Eviction only means something inside the player's claimed home: the NPC
        -- must be standing in a registered player base (set when you claim a home).
        -- Otherwise it isn't "your" house and she won't budge.
        local inBase = BanditPlayerBase and BanditPlayerBase.GetBase
                       and BanditPlayerBase.GetBase(bandit)
        if not inBase then
            return true, ctx.pick({
                "This isn't your house. I'll stand where I please.",
                "Your place? I don't see your name on the deed.",
                "Funny - I don't recall this being yours." })
        end
        if ctx.role == "Babe" then          -- she's with you: "get out" isn't dismiss
            return true, ctx.pick({
                "Leave? But I'm with you... say 'go away' if you really mean it.",
                "You want ME to go? Just tell me to leave and I will." })
        end
        if brain.hostile then return true, nil end   -- past talking

        walkBanditOut(bandit, ctx.player)
        return true, ctx.pick({
            "Alright, alright - I'm going. Didn't mean to impose.",
            "Fine. Your place, your rules. I'll find somewhere else.",
            "Okay, no need to get heated. I'm out.",
            "Didn't realize someone had claimed it. I'll go.",
            "Easy - I'm leaving. Wasn't looking for trouble." })

    elseif act == "DISMISS" then
        -- Send a follower away cleanly. Overrides Week One's own "leave me" so she
        -- walks out through your (locked) door instead of pacing at it.
        if ctx.role ~= "Babe" then
            return true, ctx.pick({
                "I'm not following you anyway.",
                "We weren't travelling together, but alright." })
        end
        brain.permanent = false
        brain.loyal = false
        walkBanditOut(bandit, ctx.player)
        return true, ctx.pick({
            "Alright - take care of yourself out there.",
            "Understood. I'll make my own way from here.",
            "Okay. Thanks for everything - I'll go.",
            "If that's what you want. Stay safe." })

    elseif act == "GEAR" then
        -- Equip / holster / switch weapons. Parses the message to decide.
        if ctx.role ~= "Babe" then return true, "I'm not following you - recruit me first." end
        local s = ctx.said or ""
        local weapons = Bandit.GetWeapons(bandit) or {}
        -- holster / put away / barehanded
        if s:find("away") or s:find("down") or s:find("holster") or s:find("sheath")
           or s:find("at ease") or s:find("lower") or s:find("fist") or s:find("barehand") then
            local held = bandit:getVariableString("BanditPrimary")
            if not held or held == "" or held == "Base.BareHands" then
                return true, "Already empty-handed."
            end
            Bandit.ClearTasks(bandit)
            Bandit.AddTask(bandit, { action="Unequip", itemPrimary=held })
            return true, ctx.pick({ "Lowering it.", "Weapon away.", "At ease." })
        end
        -- equip: pick a weapon by keyword, named item, or best
        local prim = weapons.primary and weapons.primary.name
        local sec  = weapons.secondary and weapons.secondary.name
        local mel  = weapons.melee
        if mel == "Base.BareHands" then mel = nil end
        local pick
        if s:find("pistol") or s:find("handgun") or s:find("sidearm") or s:find("revolver") then
            pick = sec
        elseif s:find("rifle") or s:find("shotgun") or s:find("firearm") or s:find("gun") or s:find("shoot") then
            pick = prim or sec
        elseif s:find("melee") or s:find("knife") or s:find("blade") or s:find("axe")
            or s:find("bat") or s:find("machete") or s:find("hammer") or s:find("spear")
            or s:find("club") or s:find("crowbar") then
            pick = mel
        else
            pick = matchNamedWeapon(s, weapons, bandit) or Bandit.GetBestWeapon(bandit)
        end
        if not pick or pick == "Base.BareHands" then
            return true, ctx.pick({ "I've nothing like that on me.", "Nothing to draw, sorry." })
        end
        Bandit.ClearTasks(bandit)
        Bandit.AddTask(bandit, { action="Equip", itemPrimary=pick })
        local nm = prettyItem(pick) or "it"
        return true, ctx.pick({ nm .. " out.", "Drawing my " .. nm .. ".", nm .. " ready." })

    elseif act == "ARM" then
        -- Take the weapon in the player's hand and make it the NPC's weapon.
        if ctx.role ~= "Babe" then return true, "I'm not following you - recruit me first." end
        local item = ctx.player:getPrimaryHandItem() or ctx.player:getSecondaryHandItem()
        if not item then return true, "Hand me what? Your hands are empty." end
        if not item:IsWeapon() then return true, "That's not a weapon I can use." end
        local itemType = armBanditWith(bandit, brain, item)
        if not itemType then return true, "I can't make that one work." end
        pcall(function()
            if ctx.player:getPrimaryHandItem() == item then ctx.player:setPrimaryHandItem(nil) end
            if ctx.player:getSecondaryHandItem() == item then ctx.player:setSecondaryHandItem(nil) end
            local src = item:getContainer() or ctx.player:getInventory()
            src:DoRemoveItem(item)
        end)
        local nm = prettyItem(itemType) or "it"
        return true, ctx.pick({ "Thanks - " .. nm .. " it is.", nm .. ", I'll put it to use.", "Good. " .. nm .. " ready." })

    elseif act == "DISARM" then
        -- Hand the NPC's weapon over to the player (dropped at her feet).
        if ctx.role ~= "Babe" then return true, "I'm not following you - recruit me first." end
        local weapons = Bandit.GetWeapons(bandit) or {}
        local s = ctx.said or ""
        local slot, itemType
        if (s:find("pistol") or s:find("handgun") or s:find("sidearm")) and weapons.secondary and weapons.secondary.name then
            slot, itemType = "secondary", weapons.secondary.name
        elseif (s:find("rifle") or s:find("gun") or s:find("firearm")) and weapons.primary and weapons.primary.name then
            slot, itemType = "primary", weapons.primary.name
        elseif weapons.primary and weapons.primary.name then
            slot, itemType = "primary", weapons.primary.name
        elseif weapons.secondary and weapons.secondary.name then
            slot, itemType = "secondary", weapons.secondary.name
        elseif weapons.melee and weapons.melee ~= "Base.BareHands" then
            slot, itemType = "melee", weapons.melee
        end
        if not itemType then return true, "I've no weapon to give you." end
        Bandit.ClearTasks(bandit)
        Bandit.AddTask(bandit, { action="Drop", anim="Loot", itemType=itemType, time=150 })
        if slot == "melee" then
            weapons.melee = "Base.BareHands"
        else
            weapons[slot].name = nil
            weapons[slot].bulletsLeft = 0
        end
        -- If she's actually WIELDING this weapon, clear the hand model too.
        -- Bandit.SetWeapons only updates the loadout (brain.weapons); the held
        -- item is a separate model (setPrimaryHandItem / BanditPrimary var). Skip
        -- this and the Drop task spawns a ground copy while she keeps the one in
        -- her hands = the duplication. (A holstered weapon she isn't holding is
        -- left as-is, which is correct - only the drawn weapon is handed over.)
        if bandit:getVariableString("BanditPrimary") == itemType then
            Bandit.SetHands(bandit, "Base.BareHands")
        end
        Bandit.SetWeapons(bandit, weapons)
        Bandit.ForceSyncPart(bandit, { id = brain.id, weapons = weapons })
        return true, ctx.pick({ "Here - take it.", "It's yours.", "Fine. Have it." })

    elseif act == "CARRY" then
        -- Move the item in the player's hand into the NPC's bag (pack mule).
        if ctx.role ~= "Babe" then return true, "I'm not following you - recruit me first." end
        local item = ctx.player:getPrimaryHandItem()
        if item then ctx.player:setPrimaryHandItem(nil)
        else item = ctx.player:getSecondaryHandItem(); if item then ctx.player:setSecondaryHandItem(nil) end end
        if not item then return true, "Hold what? Your hands are empty." end
        local ok = pcall(function()
            local src = item:getContainer() or ctx.player:getInventory()
            src:DoRemoveItem(item)
            bandit:getInventory():AddItem(item)
            Bandit.UpdateItemsToSpawnAtDeath(bandit, brain)
        end)
        if not ok then return true, "I couldn't take that, sorry." end
        return true, ctx.pick({ "Got it - I'll carry it.", "On me. It's safe.", "I've got it." })

    elseif act == "BAGCHECK" then
        -- Read out what the NPC is carrying in their inventory.
        if ctx.role ~= "Babe" then return true, "I'm not following you - recruit me first." end
        local inv = bandit:getInventory()
        local items = inv and inv:getItems()
        local counts, order = {}, {}
        if items then
            for i = 0, items:size() - 1 do
                local nm = items:get(i):getName()
                if not counts[nm] then counts[nm] = 0; order[#order+1] = nm end
                counts[nm] = counts[nm] + 1
            end
        end
        if #order == 0 then return true, ctx.pick({ "Nothing but lint, I'm afraid.", "My pockets are empty." }) end
        local parts = {}
        for _, nm in ipairs(order) do
            parts[#parts+1] = (counts[nm] > 1 and (counts[nm] .. "x ") or "") .. nm
            if #parts >= 8 then parts[#parts+1] = "..."; break end
        end
        return true, "I've got: " .. table.concat(parts, ", ") .. "."

    elseif act == "DROPALL" then
        -- Dump the NPC's whole inventory onto their tile.
        if ctx.role ~= "Babe" then return true, "I'm not following you - recruit me first." end
        local inv = bandit:getInventory()
        local items = inv and inv:getItems()
        local sq = bandit:getCurrentSquare()
        local n = 0
        if items and sq then
            for i = items:size() - 1, 0, -1 do
                local it = items:get(i)
                pcall(function() inv:Remove(it); sq:AddWorldInventoryItem(it, 0.0, 0.0, 0.0) end)
                n = n + 1
            end
        end
        Bandit.UpdateItemsToSpawnAtDeath(bandit, brain)
        if n == 0 then return true, "I've nothing to drop." end
        return true, ctx.pick({ "There - all of it.", "Dropped. Take what you need.", "It's all yours." })

    elseif act == "WEAR" then
        -- Swap a follower into clothing the player dropped beside her. Clothing
        -- isn't hand-equippable (unlike ARM), so it must come off the ground.
        if ctx.role ~= "Babe" then return true, "I'm not following you - recruit me first." end
        local found = findGroundClothing(bandit, 2)
        if #found == 0 then
            return true, ctx.pick({
                "Wear what? Drop something by me and I'll put it on.",
                "I don't see anything to change into - set it at my feet.",
                "Hand me an outfit first; drop it here and I'll swap." })
        end
        brain.clothing = brain.clothing or {}
        brain.tint     = brain.tint or {}
        local sq = bandit:getCurrentSquare()
        local changed = 0
        for _, c in ipairs(found) do
            -- drop whatever she's wearing in that slot first, so it's a true swap
            local old = brain.clothing[c.loc]
            if old and sq then
                local oldItem = BanditCompatibility.InstanceItem(old)
                if oldItem then
                    sq:AddWorldInventoryItem(oldItem, ZombRandFloat(0.1, 0.8), ZombRandFloat(0.1, 0.8), 0)
                end
            end
            brain.clothing[c.loc] = c.item:getFullType()
            brain.tint[c.loc]     = captureTint(c.item)   -- keep its dye, if any
            removeWorldItem(c.sq, c.obj, c.item)
            changed = changed + 1
        end
        if changed == 0 then return true, "That's not something I can wear." end
        Bandit.ClearTasks(bandit)
        Bandit.AddTask(bandit, { action="TimeEvent", anim="Loot",
            x=bandit:getX(), y=bandit:getY(), z=bandit:getZ(), time=300 })
        Bandit.ApplyVisuals(bandit, brain)
        Bandit.ForceSyncPart(bandit, { id = brain.id, clothing = brain.clothing, tint = brain.tint })
        return true, ctx.pick({ "There - how do I look?", "Better. Thanks for this.",
            "Good fit, I'll keep it on.", "Mm, much better. Thank you." })

    elseif act == "STRIP" then
        -- Take a named garment off (or everything) and drop it - no replacement.
        if ctx.role ~= "Babe" then return true, "I'm not following you - recruit me first." end
        brain.clothing = brain.clothing or {}
        brain.tint     = brain.tint or {}
        local s  = ctx.said or ""
        local sq = bandit:getCurrentSquare()
        local function shed(loc, itemType)
            if itemType and sq then
                local it = BanditCompatibility.InstanceItem(itemType)
                if it then sq:AddWorldInventoryItem(it, ZombRandFloat(0.1, 0.8), ZombRandFloat(0.1, 0.8), 0) end
            end
            brain.clothing[loc] = nil
            brain.tint[loc]     = nil
        end

        if wantsFullStrip(s) then
            local locs = {}
            for loc in pairs(brain.clothing) do locs[#locs + 1] = loc end
            if #locs == 0 then return true, "I'm already down to nothing." end
            for _, loc in ipairs(locs) do shed(loc, brain.clothing[loc]) end
            Bandit.ApplyVisuals(bandit, brain)
            Bandit.ForceSyncPart(bandit, { id = brain.id, clothing = brain.clothing, tint = brain.tint })
            return true, ctx.pick({ "...All of it? For you - fine.", "Okay. Don't make it weird.", "There. Happy now?" })
        end

        local loc, itemType = findWornGarment(brain, s)
        if not loc then
            return true, "Take off what, exactly? I've got " .. wearingList(brain)
        end
        shed(loc, itemType)
        Bandit.ClearTasks(bandit)
        Bandit.AddTask(bandit, { action="TimeEvent", anim="Loot",
            x=bandit:getX(), y=bandit:getY(), z=bandit:getZ(), time=250 })
        Bandit.ApplyVisuals(bandit, brain)
        Bandit.ForceSyncPart(bandit, { id = brain.id, clothing = brain.clothing, tint = brain.tint })
        local nm = prettyItem(itemType) or "it"
        return true, ctx.pick({ nm .. " off. Here you go.", "Alright, " .. nm .. " coming off.",
            "Fine - my " .. nm .. ", all yours." })
    end

    return false, nil
end

-- ----------------------------------------------------------------------------
-- The wrapper that replaces BWOChat.Say
-- ----------------------------------------------------------------------------
local origSay

-- Does cm/cm2 satisfy ANY of these trigger word-lists? (same rule as the matcher)
local function matchesAny(cm, cm2, triggers)
    for _, q in ipairs(triggers) do
        local all = true
        for _, word in ipairs(q) do
            if not cm:hasword(word) and not cm2:hasword(word) then all = false; break end
        end
        if all then return true end
    end
    return false
end

-- Restore a (world-removed) vehicle passenger beside the car via Week One's own
-- Spawner/Restore path, already converted to a Walker so she's dismissed and
-- won't just climb back in. Returns true if a passenger record was found.
local function restoreAndDismissPassenger(player, vehicle, pid)
    local gmd = GetBanditClusterData(pid)
    if not (gmd and gmd[pid]) then
        vehicle:getModData().passengerId = nil    -- stale record; clear it
        return false
    end
    local pos = BanditUtils.GetSeatPosition(vehicle, 1)
    if pos then gmd[pid].bornCoords = { x = pos.x, y = pos.y, z = pos.z } end
    gmd[pid].vehicleId = nil
    gmd[pid].permanent = false
    gmd[pid].loyal     = false
    gmd[pid].program   = { name = "Walker", stage = "Prepare" }   -- un-joined
    sendClientCommand(player, 'Spawner', 'Restore', gmd[pid])
    vehicle:getModData().passengerId = nil
    return true
end

-- A follower RIDING in the car is removed from the world (fake passenger), so
-- getTarget can't see them. If the driver says a dismiss phrase, handle it here:
-- respawn her beside the car, already dismissed. (An OUTSIDE follower is a normal
-- target and goes through the usual DISMISS branch.)
local function tryVehiclePassengerCommand(player, cm, cm2, chatMessage, quiet)
    local vehicle = player:getVehicle()
    if not vehicle then return false end
    local pid = vehicle:getModData().passengerId
    if not pid then return false end
    if not matchesAny(cm, cm2, dismissTriggers) then return false end
    if not quiet then
        local c = player:getSpeakColour()
        player:addLineChatElement(chatMessage, c:getR(), c:getG(), c:getB())
    end
    restoreAndDismissPassenger(player, vehicle, pid)
    return true   -- we own this command either way (stale state is cleared)
end

-- Runs our custom matching/handling. Returns true if it handled the message.
local function tryCustom(player, chatMessage, quiet)
    -- Build raw + lemmatised copies up front (the seated-passenger pre-check and
    -- the main matcher both need them).
    local cm = chatMessage:lower()
    local cm2 = ""
    for word in cm:gmatch("%S+") do
        local w = Lemmats and Lemmats.EN and Lemmats.EN[word]
        if w then cm2 = cm2 .. w .. " " end
    end

    -- A follower riding in your car is removed from the world, so getTarget can't
    -- find them. Dismiss the seated passenger here, before targeting.
    if tryVehiclePassengerCommand(player, cm, cm2, chatMessage, quiet) then
        return true
    end

    -- No NPC in range -> nothing we can do; let vanilla print the player line.
    local bandit, brain = getTarget(player)
    if not bandit then return false end
    local ctx = buildCtx(player, bandit, brain)
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
            if not v.nosass then res = sassify(res, ctx) end
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
    -- proximity barks: same defensive style as the chat wrapper - never let a
    -- per-frame error spill into the log, just skip that tick.
    Events.OnPlayerUpdate.Add(function(player) pcall(proximityBark, player) end)

    -- enhance follower car-entry barks (override only the Babe car block)
    if ZombiePrograms and ZombiePrograms.Babe and type(ZombiePrograms.Babe.Main) == "function"
       and not ZombiePrograms.Babe.__extraChatCarBarks then
        origBabeMain = ZombiePrograms.Babe.Main
        ZombiePrograms.Babe.Main = babeMainEnhanced
        ZombiePrograms.Babe.__extraChatCarBarks = true
    end
    print("[BWOExtraChat] installed - " .. #data .. " custom phrases active (+ proximity barks, car barks).")
end

Events.OnGameStart.Add(install)
