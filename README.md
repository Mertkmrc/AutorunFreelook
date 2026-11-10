# Autorun Freelook

Look around freely during autorun and steer only when you want to, in WoW Forever's built-in gamepad mode. Holding R2 works like holding the right mouse button on keyboard and mouse.

## What it does

- **Free look during autorun.** The right stick moves the camera without turning your character.
- **Hold R2 to steer.** While R2 is held, the character turns with the camera, so the right stick changes your direction. Release R2 and you are back to free look, without stopping the run.
- **Left stick lock.** During autorun the left stick's movement is switched off, so a stray touch no longer cancels autorun. Stop with your autorun button (L3) as usual.
- **Nothing changes outside autorun.** Your own "Turn Player With Camera" setting is never saved over.

## How to use

1. Turn on the gamepad mode in Options > Gameplay > Gamepad.
2. Set "Turn Player With Camera" to the option you like for normal play. A setting where the camera does not turn your character gives free look during autorun.
3. Start autorun with L3.
4. Look around with the right stick. Hold R2 and push the right stick to change direction.
5. Stop autorun with L3.

## Settings

Open Options > AddOns > Autorun Freelook, or type `/afl config`.

- Turn the addon or the left stick lock on and off.
- Choose R2 or L2 as the steer button, or teach it another button.

R2 or L2 work best. L3 stops autorun when pressed, L1 and R1 turn the right stick into targeting, and D-pad or face buttons use abilities.

## Commands

| Command | What it does |
|---|---|
| `/afl` | Show the current state |
| `/afl on`, `/afl off` | Turn the addon on or off |
| `/afl lock on`, `/afl lock off` | Turn the left stick lock on or off |
| `/afl button r2`, `/afl button l2` | Choose the steer button |
| `/afl learn` | Hold any button for 3 seconds to make it the steer button |
| `/afl config` | Open the options panel |
| `/afl debug` | Print what the addon is doing in chat |

## How it works

- **Autorun detection:** You are moving, out of combat, and not touching the left stick.
- **Steering:** While you hold the steer button during autorun, the addon sets `GamePadTurnWithCamera` to "always" as a temporary setting that is never saved. Releasing the button removes it.
- **Left stick lock:** The addon raises the Movement stick deadzone through the gamepad config API (`C_GamePad.SetConfig`). The original config comes back when you stop, enter combat, log out or `/reload`.

## Limitations

- Addons cannot start or stop autorun. L3's autorun lives inside the gamepad UI, so L3 cannot double as the steer button.
- The addon never steers or locks the left stick in combat.
- Tested on WoW Forever 1.60.1 with a DualSense on macOS. Reports from other controllers are welcome on [GitHub issues](https://github.com/Mertkmrc/AutorunFreelook/issues).

## License

MIT, see [LICENSE](LICENSE).
