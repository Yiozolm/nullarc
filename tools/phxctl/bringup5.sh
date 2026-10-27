#!/bin/bash
# Phoenix GFX power-up in the Linux driver's order: PSP ring, TOC and TMR, the firmware of every engine through
# LOAD_IP_FW, RLC autoload, then the SMU messages that switch GFX on (EnableGfxImu with 1). Firmware from ~/gpu/fw at
# the offsets and sizes of linux-firmware's gc_11_0_1/psp_13_0_4 files. Run as root (phxboot) or as a user with sudo.
# A reboot is armed for 3 minutes in case the PSP hangs and cancelled at the end.
set -u
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
P(){ $SUDO ~/gpu/phxctl/phxctl "$@"; }
# VRAM layout from PhxBringup (ioreg prints the numbers in decimal): the carve-out's MC base and system physical
# address, and how much of VRAM the firmware console covers from offset 0. Nothing here is the Firebat's any more: the
# Redmi Book Pro 15 2023 has 512 MiB of UMA (the Firebat 6 GiB) at another physical address and a 3200x2000 console
# that ends at 24.4 MiB, past the 17 MiB where the PSP ring used to be.
prop(){ ioreg -rc PhxBringup -d1 | sed -n "s/.*\"$1\" = \([0-9][0-9]*\).*/\1/p" | head -1; }
MC=$(prop phx-fb-mc-base); PA=$(prop phx-fb-phys); CON=$(prop phx-bootfb-bytes)
[ -n "$MC" ] && [ "$MC" != 0 ] && [ -n "$PA" ] || { echo "PhxBringup gives no VRAM layout (phx-fb-mc-base)"; exit 1; }
CON=${CON:-0}
# PSP ring + cmd + fence (36 KiB): a MiB above the console's last MiB, never below the 17 MiB the Firebat always used,
# and below the SDMA/GART/MES structures from 32 MiB on
RING=$(( ((CON + 0xFFFFF) & ~0xFFFFF) + 0x100000 )); [ $RING -lt $((0x1100000)) ] && RING=$((0x1100000))
[ $((RING + 0x9000)) -le $((0x2000000)) ] || { echo "the console ($CON bytes) leaves no room for the PSP ring below 32 MiB: boot a smaller GOP mode"; exit 1; }
hx(){ printf '0x%X' "$1"; }
FWBUF=$((MC + 0x4000000)); TMR=$((MC + 0x8000000)); TMR_PA=$((PA + 0x8000000))
# SETUP_TMR's system address is the TMR's physical address (Linux amdgpu_gmc_vram_pa). The Firebat has always booted
# with the words below instead; they stay for it until the computed ones have been tried there.
TMR_SYS="$(hx $((TMR_PA & 0xFFFFFFFF))) $(hx $((TMR_PA >> 32)))"
[ "$MC" = $((0x8000000000)) ] && [ "$PA" = $((0x6A0000000)) ] && TMR_SYS="0x0C000000 0x6A"
echo "== VRAM: MC $(hx $MC) phys $(hx $PA), console $CON bytes, PSP ring at +$(hx $RING), TMR sys $TMR_SYS =="
echo "== watchdog: reboot in 3 min unless cancelled =="
$SUDO bash -c 'nohup shutdown -r +3 >/dev/null 2>&1 &'
P psp destroy >/dev/null 2>&1
P psp create $(hx $RING) >/dev/null
P stage ~/gpu/fw/psp_13_0_4_toc.bin 256 2304 0x0 >/dev/null
P raw 0x20 $(hx $((FWBUF & 0xFFFFFFFF))) $(hx $((FWBUF >> 32))) 0x900 0 0 0 >/dev/null
P raw 0x5 $(hx $((TMR & 0xFFFFFFFF))) $(hx $((TMR >> 32))) 0x4000000 0x2 $TMR_SYS >/dev/null
echo "== load firmware =="
L(){ P loadfw "$@" 2>&1 | grep loadfw >> ~/gpu/fwaddr.log; }
: > ~/gpu/fwaddr.log
L ~/gpu/fw/gc_11_0_1_pfp.bin 256 263168 2 0x000000
L ~/gpu/fw/gc_11_0_1_me.bin  256 263168 1 0x100000
L ~/gpu/fw/gc_11_0_1_mec.bin 256 267008 4 0x200000
L ~/gpu/fw/sdma_6_0_1.bin    256 17408 71 0x380000
L ~/gpu/fw/sdma_6_0_1.bin    17664 16896 72 0x3C0000
L ~/gpu/fw/gc_11_0_1_mes_2.bin 256 135648 33 0x400000
L ~/gpu/fw/gc_11_0_1_mes_2.bin 135904 131072 34 0x440000
L ~/gpu/fw/gc_11_0_1_mes1.bin 256 104272 81 0x480000
L ~/gpu/fw/gc_11_0_1_mes1.bin 104528 131072 82 0x4C0000
L ~/gpu/fw/gc_11_0_1_imu.bin 256 66048 68 0x500000
L ~/gpu/fw/gc_11_0_1_imu.bin 66304 66048 69 0x600000
L ~/gpu/fw/gc_11_0_1_rlc.bin 25344 2560 20 0x700000
L ~/gpu/fw/gc_11_0_1_rlc.bin 27904 21104 21 0x720000
L ~/gpu/fw/gc_11_0_1_rlc.bin 49008 66048 26 0x800000
L ~/gpu/fw/gc_11_0_1_rlc.bin 115056 33280 48 0x840000
L ~/gpu/fw/gc_11_0_1_rlc.bin 148336 8704 25 0x880000
L ~/gpu/fw/gc_11_0_1_rlc.bin 256 25088  8 0x300000
echo "== AUTOLOAD_RLC =="
P autoload
echo "== SMU 0x3, 0x2, EnableGfxImu(param=1) (linux order) =="
P smu 0x3 0 | tail -1
P smu 0x2 0 | tail -1
P smu 0x16 1 | tail -1
sleep 2
P regs 0xee7e 0x21a0 0x2004 0x263e
$SUDO killall shutdown 2>/dev/null; echo "watchdog cancelled rc=$?"
