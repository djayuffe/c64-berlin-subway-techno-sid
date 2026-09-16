# TRUE TECHNO SID IMPLEMENTATION PASS

This pass continues the Berlin subway techno build and moves the SID player from
pattern-only sequencing toward actual SID sound-design programming.

## Implemented in `mega/src/subway.s`

### Voice 1 bass
- Added explicit V1 pulse-width registers:
  - `SID_V1PWLO = $d402`
  - `SID_V1PWHI = $d403`
- Bass pulse width is now modulated together with the acid/arp voice.
- Bass rests now clear the GATE bit instead of holding the previous note forever.
  This makes the bassline real staccato techno rather than smeared sustain.

### Voice 2 acid/lead
- Style-dependent waveform control is preserved and expanded:
  - normal saw/pulse sections
  - ring-mod triangle acid section
  - hard-sync lead section
  - combined saw+pulse peak section
- Style-dependent ADSR is now applied in `SelectStyle`:
  - short pluck for acid ticks
  - longer release for dub/breakdown stabs
  - harder sustain/release for peak sections

### PWM
- Added per-style PWM base and PWM speed tables:
  - `StylePwmBaseTbl`
  - `StylePwmStepTbl`
- `TV_MusPwm` now uses those tables instead of a fixed speed/base.
- PWM is clamped away from the 0/4095 mute edges.

### Filter
- Added per-style filter LFO speed:
  - `StyleFiltStepTbl`
- `TV_MusFilter` now:
  - uses style-dependent LFO speed
  - saturates cutoff at `$f0` instead of wrapping around to low cutoff/silence
  - animates the low 3 cutoff bits in `$d415` for extra analogue movement
- Style mode/volume and resonance now make the active techno sections evolve:
  - LP bass/acid
  - BP/HP breakdown colour
  - stronger filtered peak pressure

### Safety
- No new binary assets.
- No stale PRG should be trusted; rebuild with ACME.
- Static checks run locally:
  - no duplicate global labels found
  - no empty `!byte`, `!word`, `!text`, `!scr`
  - required new symbols found

Build:

```bash
cd mega/src
acme -f cbm -o ../build/subway.prg subway.s
x64sc -autostartprgmode 1 -autostart ../build/subway.prg
```
