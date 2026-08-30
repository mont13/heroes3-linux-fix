# heroes3-linux-fix

**Make your legally owned GOG copy of Heroes of Might and Magic III Complete run
properly on Ubuntu 24.04 and newer — full-screen, with sound, video and a mouse
that works.**

If the game used to run fine on Ubuntu 22.04 and stopped working after you
upgraded, this repository explains exactly why and fixes it.

> This project contains **no game files**. You need to own Heroes III — buy it on
> [GOG.com](https://www.gog.com/game/heroes_of_might_and_magic_3_complete_edition).
> These scripts only configure software that is already on your machine.

---

## The symptoms this fixes

Any of these on Ubuntu 24.04 / Debian 13 and later:

| What you see | Actual cause |
|---|---|
| The game starts, no window ever appears, the process just sits there | Broken Wine 8.x build — every Windows program hangs at startup |
| Picture only refreshes when you Alt+Tab; a click repaints a fraction of the screen | No 32-bit OpenGL, and the window never really goes full-screen |
| No sound at all | `winepulse` cannot load because `libudev1:i386` is missing |
| The whole game freezes, desktop says *"not responding"* | Wine fell back to ALSA and opened a disconnected HDMI audio output |
| Crash right after the splash screen | GOG's bundled DirectDraw wrapper crashes under Wine |
| Wine crashes with an assertion in `xvidmode.c` | Wine bug in the old XVidMode resolution-change path |

None of these are your fault, and none of them are a broken game. They are six
separate problems that happen to look identical from the outside. The full
technical write-up with log evidence is in **[docs/ROOT-CAUSES.md](docs/ROOT-CAUSES.md)**.

---

## Quick start

```bash
git clone https://github.com/mont13/heroes3-linux-fix.git
cd heroes3-linux-fix

# 1. install the 32-bit libraries and tools (asks before touching anything)
./scripts/install-deps.sh

# 2. unpack the GOG offline installer you downloaded from your library
./scripts/install-game.sh ~/Downloads/setup_heroes_of_might_and_magic_3_complete_*.exe

# 3. apply the fixes and verify them automatically
./scripts/fix-heroes3.sh

# 4. play
./scripts/play-heroes3.sh              # windowed, you can work alongside it
./scripts/play-heroes3.sh --fullscreen # fills the screen, restores your resolution on exit
```

Already have the game installed through Heroic, Lutris or Steam? Skip step 2 —
`fix-heroes3.sh` finds the usual locations by itself, or point it at yours:

```bash
./scripts/fix-heroes3.sh --game-dir "/path/to/HoMM 3 Complete"
```

---

## Requirements

* A 64-bit Ubuntu/Debian-based system (other distributions work, but
  `install-deps.sh` only knows `apt` — install the equivalents by hand).
* **A Wine runtime, version 9 or newer** — either works, pick whichever you
  already have (details below). Wine 8.x builds hang on current kernels; see
  [docs/ROOT-CAUSES.md](docs/ROOT-CAUSES.md#1-broken-wine-runner).
* Your own copy of Heroes III Complete (GOG offline installer, or an existing
  install).
* About 2 GB of disk space for the game plus roughly 200 MB for the 32-bit
  libraries.

---

## Choosing a Wine runtime

Two options, both verified with this repository. You do **not** need both —
install whichever suits you and the scripts pick it up automatically.

### Option A — your distribution's Wine (simplest)

```bash
sudo apt install -y wine wine32 wine64
```

Ubuntu 24.04 ships Wine 9.0, which is new enough. About 300 MB of packages.
Nothing else to configure: the scripts find `/usr/bin/wine` on their own.

### Option B — GE-Proton (if you already use Heroic, Lutris or Steam)

Install a GE-Proton 9 or 10 build through your launcher, or drop it in
`~/.steam/steam/compatibilitytools.d/`. The scripts search Heroic's and Steam's
tool directories and prefer a Proton build when they find one, because those
builds track Wine more closely.

One extra step is handled for you: Proton keeps `libvkd3d` outside the normal
Wine directory and only installs it into a prefix through its own wrapper
script. `fix-heroes3.sh` copies the missing DLLs in, otherwise the game cannot
load `ddraw` at all — see the
[appendix](docs/ROOT-CAUSES.md#appendix-proton-builds-need-one-extra-step).

### Forcing a specific one

```bash
HEROES3_WINE=/usr/bin/wine ./scripts/fix-heroes3.sh
```

Auto-detection order: `HEROES3_WINE`, then Proton builds under Heroic and Steam,
then system Wine. `./scripts/fix-heroes3.sh --status` prints which one it picked.

If you switch between runtimes later, just run `fix-heroes3.sh` again: `ddraw`
and `wined3d` are a matched pair, and the script refreshes the game's copy so
both come from the same Wine build.

---

## What each script does

| Script | Purpose |
|---|---|
| `scripts/install-deps.sh` | Installs the 32-bit graphics and audio libraries plus `Xephyr`, `xdotool`, `wmctrl` and `innoextract`. Shows a dry run and asks before changing anything. Can install from an offline bundle. |
| `scripts/install-game.sh` | Unpacks a GOG offline installer with `innoextract`. No Wine or Windows involved. |
| `scripts/fix-heroes3.sh` | The actual fix. Creates the Wine prefix, replaces the crashing DirectDraw wrapper, sets the two Wine options, then starts the game on a hidden display and verifies that it draws, refreshes and finds an audio driver. Idempotent. `--status` reports without changing anything, `--revert` restores the last backup. |
| `scripts/play-heroes3.sh` | Launches the game inside a nested X server so DirectDraw takes its full-screen path and the picture actually refreshes. Windowed or full-screen. |
| `scripts/bundle-libs.sh` | Maintainer tool: collects the whole 32-bit dependency closure with checksums for the offline bundle. |

Everything the fix touches is backed up first, under
`~/.local/share/heroes3-linux-fix/backup/<timestamp>/`. Logs and test
screenshots land in `~/.local/share/heroes3-linux-fix/logs/`.

---

## When the packages disappear from the archive

Ubuntu releases reach end of life and their i386 packages leave the archive —
this already happened to 22.04. The complete set of 32-bit libraries this fix
needs (65 packages, about 65 MB) is therefore attached to the
[releases](../../releases) of this repository as
`heroes3-linux-fix-offline-libs.tar.gz`, together with a manifest listing every
package, its version and its SHA256.

```bash
tar xzf heroes3-linux-fix-offline-libs.tar.gz
./scripts/install-deps.sh --offline ./offline-libs
```

Checksums are verified before anything is installed. All of it is free software
from the Ubuntu archive (MIT / LGPL); the manifest records the source package
of every file, so the corresponding sources can be fetched with
`apt-get source <package>`.

---

## Something went wrong

```bash
./scripts/fix-heroes3.sh --status   # what is set, what is missing
./scripts/fix-heroes3.sh --revert   # undo the last run
```

Logs are in `~/.local/share/heroes3-linux-fix/logs/`. The most useful line is
usually the first `err:` in the newest `test_*.log` or `play_*.log`.
[docs/ROOT-CAUSES.md](docs/ROOT-CAUSES.md) lists the exact error messages and
what each of them means.

---

## If the scripts stop working — do it by hand

These scripts will age. Wine, package names and desktop environments change.
The findings behind them will not, so here is the whole fix as six manual
steps. Everything below is explained in detail, with the exact error messages,
in [docs/ROOT-CAUSES.md](docs/ROOT-CAUSES.md).

**1. Get a Wine 9+ runtime.** If a Windows program starts but never opens a
window, and `/proc/<pid>/status` shows a single thread while
`/proc/<pid>/wchan` says `futex_do_wait`, the Wine build is broken. Use another
one — the game is fine.

```bash
sudo apt install -y wine wine32 wine64
```

**2. Install the 32-bit host libraries.** The game is a 32-bit process, so it
needs i386 builds. Miss `libudev1:i386` and you get a picture but no sound.

```bash
sudo dpkg --add-architecture i386 && sudo apt update
sudo apt install -y libgl1:i386 libglx-mesa0:i386 libgl1-mesa-dri:i386 \
                    libpulse0:i386 libasound2t64:i386 libudev1:i386
```

If those packages no longer exist, take them from this repository's
[release](../../releases) and `sudo dpkg -i offline-libs/*.deb`.

**3. Replace GOG's DirectDraw wrapper.** `xdd.dll` in the game folder is
DDrawCompat and it crashes under Wine. Overwrite it with the `ddraw.dll` from
your own Wine installation — same file name, no download.

```bash
cd "/path/to/HoMM 3 Complete"
cp -a xdd.dll xdd.dll.backup
cp /usr/lib/i386-linux-gnu/wine/i386-windows/ddraw.dll xdd.dll
```

For a Proton build the source path is
`<proton>/files/lib/wine/i386-windows/ddraw.dll` instead.

**4. Set two Wine options.** The first stops Wine asserting in `xvidmode.c`
when the game changes resolution; the second stops ALSA grabbing a
disconnected HDMI audio output and freezing the game.

```bash
export WINEPREFIX=~/.local/share/heroes3-linux-fix/prefix
wine reg add 'HKEY_CURRENT_USER\Software\Wine\X11 Driver' /v UseXVidMode /t REG_SZ /d N /f
wine reg add 'HKEY_CURRENT_USER\Software\Wine\Drivers'    /v Audio       /t REG_SZ /d pulse /f
```

**5. With a Proton build only, add the vkd3d DLLs.** Proton keeps them outside
the Wine directory and its wrapper script normally installs them:

```bash
cp <proton>/files/lib/vkd3d/i386-windows/*.dll   "$WINEPREFIX/drive_c/windows/syswow64/"
cp <proton>/files/lib/vkd3d/x86_64-windows/*.dll "$WINEPREFIX/drive_c/windows/system32/"
```

**6. Run the game on a nested X server.** This is what makes the picture
refresh properly. Without it the window manager keeps the window off 0,0, Wine
uses the windowed DirectDraw path, and the screen only updates when you
Alt+Tab.

```bash
Xephyr :89 -screen 800x600 -title "Heroes III" &
cd "/path/to/HoMM 3 Complete"
DISPLAY=:89 wine Heroes3.exe
```

For full screen, switch your display to 800×600 first
(`xrandr --output <output> --mode 800x600`), add `-fullscreen` to the Xephyr
command, and switch back afterwards.

### Diagnosing something new

```bash
WINEDEBUG=fixme-all wine Heroes3.exe 2>&1 | tee log     # read the FIRST err: line
grep -E '^(State|Threads)' /proc/$(pgrep -x Heroes3.exe)/status
ls -l /proc/$(pgrep -x Heroes3.exe)/fd | grep -E 'snd|dri'
ldd /usr/lib/i386-linux-gnu/wine/i386-unix/*.so | grep 'not found'
```

One thread means it hung before it started. `/proc/<pid>/fd` shows which audio
and graphics devices it actually opened. The `ldd` line lists every host
library a Wine driver is missing, in one shot.

---

## Known limitations

* **Heroes III is a 800×600 game.** Nothing here changes that. `--fullscreen`
  switches the display to 800×600 so the panel scales it up; the picture is
  therefore soft on a 1080p screen. For a genuinely high-resolution interface
  you need the community **HD mod**, or **[VCMI](https://vcmi.eu/)**, an
  open-source re-implementation of the engine that runs natively on Linux and
  reads your existing GOG data.
* Only tested with the GOG *Complete* edition.
* `install-deps.sh` supports `apt` based distributions.

---

## License

MIT, see [LICENSE](LICENSE). Heroes of Might and Magic III is the property of
its rights holders and is not distributed here.
