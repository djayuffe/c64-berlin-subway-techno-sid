# Function guide

The shared engine follows the same entry points as the eyecandy build. In addition:

- `SelectStyle` selects per-section waveform, ADSR, PWM, filter, and resonance settings.
- `TV_MusPwm` advances bounded pulse-width modulation for the active style.
- `TV_MusFilter` advances the style filter LFO and writes the saturated cutoff value.
- The SID tick in `MegaMain_IRQ` applies note gates/rests and advances the five-section techno sequence.
- `InitPart` / `UpdatePart` dispatch the visual station effects and transitions.
- `WireframeGridRender` uses `wire_cube_chars.bin` and `wire_cube_mask.bin` as its character atlas.
