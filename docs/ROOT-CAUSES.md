# Root causes, one by one

Six independent problems make Heroes III fail on a current Linux desktop. Each
one on its own is enough to make the game look broken, and from the outside they
are hard to tell apart — which is why the usual advice ("reinstall", "try another
Wine", "disable esync") rarely helps.

Everything below was diagnosed on Ubuntu 24.04.3 (kernel 7.0), Intel UHD 770 +
NVIDIA RTX 4090 laptop, GOG Heroes of Might and Magic III Complete.

---

## 1. Broken Wine runner

**Symptom.** The game starts and nothing happens. No window, no error. The
process is alive but idle.

**Evidence.**

```
$ grep -E '^(State|Threads)' /proc/$(pgrep -x Heroes3.exe)/status
State:   S (sleeping)
Threads: 1
$ cat /proc/$(pgrep -x Heroes3.exe)/wchan
futex_do_wait
```

A single thread parked on a futex before the game ever opened a file from
`Data/`. The decisive test is that it is not about the game at all:

* the bundled map editor `h3maped.exe` hangs identically,
* Wine's own `notepad` hangs identically, 32-bit and 64-bit,
* `wineboot -u` in a brand new empty prefix hangs for 180 s and has to be killed.

So neither the game nor the prefix is at fault — the Wine build is. The build in
question reported `wine-8.0 (Staging)`. A GE-Proton 10 build (`wine-10.0
Staging`) created a prefix in seconds and ran the game.

**Fix.** Use Wine 9 or newer, or GE-Proton 9/10. `fix-heroes3.sh` refuses to
configure anything older and says so.

---

## 2. Missing 32-bit host libraries

**Symptom.** Black or frozen picture that only updates when you Alt+Tab; clicks
appear to repaint a fraction of the screen; no sound.

**Evidence.**

```
err:wgl:init_opengl Failed to load libGL: libGL.so.1: cannot open shared object file
err:wgl:init_opengl OpenGL support is disabled.
err:d3d:wined3d_caps_gl_ctx_create Failed to find a suitable pixel format.
err:mmdevapi:init_driver No driver from L"pulse,alsa,oss,coreaudio" could be initialized.
```

`libGL.so.1` exists — as the 64-bit build. Heroes III is a 32-bit program:

```
$ file -L /proc/$(pgrep -x Heroes3.exe)/exe
ELF 32-bit LSB executable, Intel 80386
$ ls /usr/lib/i386-linux-gnu/libGL.so.1
ls: cannot access ...: No such file or directory
```

Ubuntu 22.04 still pulled these in as dependencies of other things; 24.04 does
not, and a fresh install has none of them. This is the single biggest reason the
same GOG copy "worked before the upgrade".

Wine's own drivers reveal exactly what is missing:

```
$ ldd <proton>/files/lib/wine/i386-unix/winepulse.so | grep 'not found'
    libudev.so.1 => not found
```

`libudev1:i386` is the easiest one to miss. Without it `winepulse.so` never
loads, and Wine silently falls back to ALSA — which leads straight to problem 4.

**Fix.**

```bash
sudo apt install -y libgl1:i386 libglx-mesa0:i386 libgl1-mesa-dri:i386 \
                    libpulse0:i386 libasound2t64:i386 libudev1:i386
```

`install-deps.sh` does this, resolves package-name differences between releases,
and can install from an offline bundle when the archive is gone.

---

## 3. Wine asserts on the resolution change

**Symptom.** The game dies seconds after starting, sometimes with a Wine
debugger dump.

**Evidence.**

```
../src-wine/dlls/winex11.drv/xvidmode.c:164: xf86vm_free_modes:
  Assertion `modes[0].dmDriverExtra == sizeof(XF86VidModeModeInfo *)' failed.
wine: Assertion failed at address F43C71EC (thread 0024), starting debugger...
```

Heroes III asks for 800×600 at startup. Wine's legacy XVidMode path handles that
request and asserts.

**Fix.** Make Wine use XRandR instead:

```
HKEY_CURRENT_USER\Software\Wine\X11 Driver    UseXVidMode = "N"
```

---

## 4. ALSA grabs a disconnected HDMI audio output

**Symptom.** The game freezes solid partway through the intro. The desktop
offers to force-quit it. All threads are blocked.

**Evidence.**

```
$ ls -l /proc/$(pgrep -x Heroes3.exe)/fd | grep snd
... -> /dev/snd/pcmC0D3p
$ aplay -l | head -3
card 0: NVidia [HDA NVidia], device 3: HDMI 0 [HDMI 0]
```

With `winepulse` unavailable (problem 2), Wine tried ALSA and opened the first
PCM device it found — the GPU's HDMI output. With no monitor plugged into it,
the write never completes and the game hangs forever.

**Fix.** Route audio through PulseAudio/PipeWire explicitly:

```
HKEY_CURRENT_USER\Software\Wine\Drivers    Audio = "pulse"
```

Fixing problem 2 is still required; this setting makes sure a fallback to ALSA
cannot happen at all.

---

## 5. The window never really goes full-screen, so nothing repaints

**Symptom.** The classic one: *"I click and only a quarter of the screen
updates; I have to Alt+Tab to see what changed."*

**Evidence.** With the desktop at 800×600 and the game asking for full screen:

```
$ xwininfo -id <game window> | grep -E 'Absolute|Width|Height'
  Absolute upper-left X:  66
  Absolute upper-left Y:  32
  Width: 800
  Height: 600
$ xprop -id <game window> _NET_WM_STATE
_NET_WM_STATE(ATOM) = _NET_WM_STATE_ABOVE, _NET_WM_STATE_FOCUSED
```

The window sits at 66,32 — GNOME placed it inside the work area, past the dock
and below the top bar — so it does not cover the screen. `wmctrl -b
add,fullscreen` and `xdotool windowstate --add FULLSCREEN` are both ignored,
because Wine manages the state itself and keeps `_NET_WM_STATE_ABOVE`.

Wine therefore uses the *windowed* DirectDraw path, which only repaints on
demand. Alt+Tab forces a repaint — hence the symptom.

The proof is a comparison run on a bare `Xvfb` with no window manager: the
window lands at 0,0 at exactly the screen size, and screenshots taken five
seconds apart differ every time, the whole menu draws, and hovering a menu item
highlights it correctly. Identical checksums were then reproduced under Xephyr.

**Fix.** Run the game in a nested X server with no window manager
(`play-heroes3.sh`). Windowed mode gives you a normal 800×600 window on your
desktop that draws correctly; `--fullscreen` additionally switches the display
mode and restores it on exit.

---

## 6. GOG's DirectDraw wrapper crashes under Wine

**Symptom.** The game exits immediately after its configuration is read.

**Evidence.**

```
err:seh:NtRaiseException Unhandled exception code c0000409 flags 1 addr 0x7b241f30
```

`c0000409` is `STATUS_STACK_BUFFER_OVERRUN`. The GOG build ships
[DDrawCompat](https://github.com/narzoul/DDrawCompat) renamed to `xdd.dll`, and
`Heroes3.exe` imports from it. DDrawCompat hooks Windows internals — DWM, GDI,
the desktop window — that Wine does not implement. Its own log stops right after
`Final configuration:`, i.e. it dies during initialisation.

**Fix.** Replace `xdd.dll` with Wine's own `ddraw.dll` (the PE build shipped
inside every Wine installation, `lib/wine/i386-windows/ddraw.dll`). It exports
the same DirectDraw entry points, so the unmodified `Heroes3.exe` loads it
happily and renders through `wined3d`.

Nothing is downloaded for this: the file is copied from the Wine build already
on the machine, and the original is backed up first.

---

## How to diagnose this class of problem

The window's behaviour tells you almost nothing — all six failures look like
"the game is broken". What actually works:

* `WINEDEBUG=fixme-all wine Game.exe 2>&1 | tee log` and then read the **first**
  `err:` line, not the last.
* `/proc/<pid>/status` — one thread means it hung before it ever started;
  `Threads: 8` means it is really running.
* `/proc/<pid>/fd` — shows which audio and DRI devices were opened. This is how
  the dead HDMI output was found.
* `file -L /proc/<pid>/exe` — confirms whether you need i386 or amd64 host
  libraries.
* `ldd <wine>/lib/wine/i386-unix/*.so | grep 'not found'` — lists every host
  library a Wine driver is missing, in one shot.
* Reproduce on a bare `Xvfb`. If it works there and not on your desktop, the
  problem is the window manager or the compositor, not the game.

One practical trap: `pkill -f "pattern"` can match the shell that is running the
script and kill it. Kill by PID, or use `pkill -x`.

---

## Appendix: Proton builds need one extra step

Not a cause of the original breakage, but it bites anyone who reuses a Proton
build outside its launcher, so `fix-heroes3.sh` handles it.

Proton keeps some PE libraries outside the usual Wine directory, in
`files/lib/vkd3d/`, and only places them into a prefix through its own `proton`
wrapper script. Creating a prefix by calling `files/bin/wine wineboot` directly
skips that, and the game then fails before it starts:

```
err:module:import_dll Library libvkd3d-1.dll (which is needed by L"wined3d.dll") not found
err:module:import_dll Library wined3d.dll (which is needed by L"ddraw.dll") not found
err:module:import_dll Library ddraw.dll (which is needed by L"Heroes3.exe") not found
err:module:loader_init Importing dlls failed, status c0000135
```

`fix-heroes3.sh` copies the missing DLLs into the prefix's `system32` and
`syswow64` after creating it. Plain Wine builds are unaffected.
