# Switching projects on this board (same SD card)

This board runs a **single Ubuntu install on one SD card**, shared by whatever
Kria project is currently active (this IMX477 driver, `kv260-smartcam`, or
PYNQ/DPU). All of these projects compete for the same PL (programmable logic)
and the same overlay manager (`xmutil`/`dfx-mgr`), so switching between them is
a stateful hardware operation, not just a `git checkout`.

**If you have a spare microSD card, use it instead of this procedure.** Flash a
second card with stock Kria-PYNQ (or the DPU image) and swap cards + power
cycle to change projects. That gives zero interaction risk between projects.
This doc is for when everyone is sharing the one card.

## Why this needs care: what already went wrong here

On 2026-09-10, unloading the current app and loading PYNQ's `base` overlay in
one live SSH session (`xmutil unloadapp` immediately followed by loading PYNQ,
no reboot in between) **hung the board completely** — no ping, no serial,
`/dev/ttyUSB*` dropped off USB. It needed a physical power cycle (12V barrel
jack) to recover. Suspected cause: unloading an app while the VCU (`al5e`) was
still bound is fragile. See `STATUS.md` (search "Board hung") for the full
writeup.

**Rule: always reboot between unloading the current app and loading the next
one. Never hot-swap live.**

## Current board state

- OS: Ubuntu 22.04.5 LTS, kernel `5.15.0-1077-xilinx-zynqmp`
- PYNQ is installed on the image but disabled by default so it doesn't fight
  `xmutil` for the PL:
  - `jupyter.service` → masked
  - `clear_pl_statefile.service` → disabled
  - the `pynq` device-tree overlay does not load at boot
- Active app is managed by `xmutil` (`kv260_imx477` for this project, or
  `k26-starter-kits` for the bare/stock state)

Check the current state before doing anything:
```bash
xmutil listapps
systemctl is-active jupyter.service
```

## Switching to PYNQ / DPU

```bash
sudo xmutil unloadapp
sudo reboot
```
Wait for the board to come back up, **then** on a clean slate:
```bash
sudo systemctl unmask jupyter.service
sudo systemctl enable --now clear_pl_statefile.service jupyter.service
```
PYNQ's own overlay and Jupyter server come up from here. Do your PYNQ/DPU work
and keep any notebooks in PYNQ's own notebook directory — not in this repo,
since they belong to a different toolchain/environment.

## Switching back to the IMX477 project

```bash
sudo systemctl disable --now clear_pl_statefile.service jupyter.service
sudo systemctl mask jupyter.service
sudo reboot
```
Then, on the clean slate:
```bash
sudo xmutil unloadapp
sudo xmutil loadapp kv260_imx477
sudo modprobe imx477
dmesg | grep -i imx477
media-ctl -p
```
See the main `README.md` for the rest of the capture/config steps.

## Jupyter notebooks

- PYNQ's Jupyter service holds live `Overlay()` handles tied to whatever
  bitstream is currently loaded. **Never leave Jupyter running across an
  overlay switch** — restart the kernel, or the whole `jupyter.service`, any
  time the PL was reloaded. A stale `Overlay` handle to a bitstream that just
  got swapped out is the same class of bug that caused the VCU hang above.
- This repo has no notebooks of its own (the IMX477 workflow is shell +
  V4L2/`media-ctl`). Keep DPU/PYNQ notebooks in their own repo or the default
  PYNQ notebook directory so they don't get mixed into this driver project.

## General checklist for whoever is switching

1. `xmutil listapps` — know what's currently loaded before you touch anything.
2. Keep the serial console attached during any switch (`/dev/ttyUSB*` @115200).
   If something hangs, serial is how you'll see it.
3. Unload → **reboot** → load the next thing. Never combine unload + load of a
   different project in one live session.
4. If you're not sure the board came back clean, power-cycle (12V barrel jack)
   rather than fighting a half-hung state over SSH.
