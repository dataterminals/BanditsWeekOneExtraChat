# Bandits Week One — Extra Chat

A standalone add-on for the [**Bandits Week One**](https://steamcommunity.com/sharedfiles/filedetails/?id=3403180543) mod for **Project Zomboid (Build 42)**. It extends Week One's "press **T** and talk to a nearby NPC" system with **more things you can say**, **richer responses**, and **new actions** — without editing the Week One mod itself.

> Requires **Bandits Week One** (and its dependency, **Bandits**). This add-on does nothing on its own.

## What it adds

- **New actions you can speak to NPCs:**
  - **Give** — *"give me a bandage"*, *"give me water"* — the NPC forages and drops the item for you.
  - **Grab** — *"grab that gun"*, *"arm yourself"* — if you've dropped a weapon next to an NPC, they pick it up and **wield** it.
  - **Go** — *"go over there"* — sends a **recruited follower** to wherever your mouse is pointing.
- **Smarter responses:**
  - **Random variety** — the same question can return a different line each time.
  - **Per-speaker answers** — replies can branch on who's talking (name, gender, role, mood, personality).
  - **Consistent character voices** — each NPC has stable per-character traits, so a given survivor always answers the same way.
  - **Sassy female NPCs** — women automatically layer in emphasis like *"oh my god"* and *"literally,"* applied centrally so every line gets it for free.
- **Extra roleplay / flavour lines**, easy to expand.

Anything this add-on doesn't recognise falls straight through to vanilla Week One chat, so all of the original lines and behaviours keep working untouched.

## How it works

Week One's chat entry point, `BWOChat.Say(message)`, is a global function. On game start this mod saves the original and swaps in a wrapper that:

1. Matches your message against **its own** phrase table first (same lowercase + lemmatise + whole-word matching the base mod uses).
2. On a hit, runs the custom response/action against the **nearest NPC within 8 tiles**.
3. On a miss, **delegates to the original** `Say` so vanilla behaviour is preserved.

Because the hook installs on `OnGameStart`, **load order does not matter** and **no Week One files are modified** — making the add-on resilient to Week One updates and safe to remove at any time.

## Installing (manual / local)

Copy the `BanditsWeekOneExtraChat` folder into your Zomboid mods directory:

```
<user>/Zomboid/mods/BanditsWeekOneExtraChat/
```

Then enable **Bandits Week One — Extra Chat** in the in-game mod list (alongside Bandits Week One). On a successful load you'll see this in the console:

```
[BWOExtraChat] installed - N custom phrases active.
```

## Adding your own lines

All content lives at the top of [`42/media/lua/client/BWOExtraChat.lua`](42/media/lua/client/BWOExtraChat.lua). Each entry is one `add{ ... }` call:

```lua
-- Simple line
add{ query={"are","you","scared"}, res="Everyone's scared. The smart ones just hide it." }

-- Random variety (a list -> one picked each time)
add{ query={"you","doing","okay"}, res={ "Hanging in there. Barely.", "Define 'okay'." } }

-- Computed: branch on who's answering
add{ query={"what","s","your","name"}, res=function(ctx)
    if ctx.female then return "I'm " .. ctx.name .. "." end
    return "Name's " .. ctx.name .. "."
end }

-- An action (give an item)
add{ query={"give","me","bandage"}, res="Here, patch yourself up.", action="GIVE", give="Base.Bandage" }
```

An entry supports:

| Field    | Meaning |
|----------|---------|
| `query`  | List of words; **all** must appear in your message for the entry to match. |
| `res`    | A string, a list (random pick), or a `function(ctx)` returning a string. Supports `%NAME %HOUR %MINUTE %MOOD %CITY`. |
| `cond`   | Optional `function(ctx) -> bool`; the entry only applies to NPCs for which it's true. |
| `anim`   | Optional animation name (defaults to a random talk gesture). |
| `action` | Optional: `"GIVE"`, `"GOTO"`, or `"GRAB"`. |
| `give`   | Item id, required when `action="GIVE"` (e.g. `"Base.Bandage"`). |

`ctx` exposes the speaking NPC: `name`, `female`, `role`, `hostile`, `smoker`, `alcoholic`, `polish`, `rnd` (stable per-NPC randoms), plus `pick(list)` and the raw `brain` / `bandit` / `player`.

## Status

Early/experimental (**v0.2**). The give/grab/go actions are functional but lightly tested; weapon `GRAB` works best with a weapon dropped right next to the NPC, and `GIVE` is most reliable on calm NPCs (homeowners / recruited followers). Bug reports and PRs welcome.

## Credits

- Built on top of **Bandits** and **Bandits Week One** by their respective authors. This is an independent fan add-on and is not affiliated with them.
- Add-on by **dataterminals**.

## License

[MIT](LICENSE) © 2026 dataterminals
