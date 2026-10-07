// Ported from Aoe2MacSteamNoRosetta tests/platform/x18.S at f37dfc2 (plan R2, N2).
// Called only while the custom x18 ABI is enabled; no macOS calls here.
.text
.globl _probe_custom_x18
.p2align 2
_probe_custom_x18:
    mov x18, #0x1234
    mov x0, x18
    ret
