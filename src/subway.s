; ============================================================================
;  U83R RUL3Z - MEGADEMO   (C64 / ACME)
; ----------------------------------------------------------------------------
;  Four effects welded into one sequenced production with a shared 3-voice SID
;  score and wipe + title-card transitions:
;     PART 0  TITLE          - title screen with colour-cycling text
;     PART 1  DIGITAL RAIN    - Matrix-style falling glyph columns
;     PART 2  HORIZON WARP    - concentric colour-cycling rainbow rings
;     PART 3  SINE STARFIELD  - parallax char starfield + glowing greets scroller
;
;  Sources integrated (re-implemented under one framework):
;     matrix_rain_fixed_v2.s, horizonwarp_rings_baremetal.s,
;     U83R demo.s (starfield + ticker), cracktro_strict_v7 (SID engine)
;
;  Unified layout: VIC bank 0, screen $0400, colour $d800, charset = ROM font
;  mirrored at $1000 (no copy needed), text mode.  A single raster IRQ at line
;  250 ticks the music at 50 Hz and raises a frame flag; the main loop renders
;  the active part and drives the part/transition state machine.
;
;  Build:  acme -f cbm -o build/megademo.prg src/megademo.s
;  Run:    LOAD"*",8,1 : SYS 2061     (or autostart)
; ============================================================================

!cpu 6502

; ------- BASIC stub: 10 SYS 2061 -------
* = $0801
        !word stub_end, 10
        !byte $9e
        !text "2061"
        !byte 0
stub_end:
        !word 0

; ============================================================================
;  Shared hardware constants
; ============================================================================
SCREEN      = $0400
COLOR       = $d800
SCR_COL_OFF = COLOR - SCREEN        ; $d400  (add to screen-hi for colour-hi)

BORDER      = $d020
BKG         = $d021
VIC_CTRL1   = $d011
VIC_CTRL2   = $d016
VIC_RASTER  = $d012
VIC_MEMPTR  = $d018
VIC_IRR     = $d019
VIC_IMR     = $d01a
VIC_BANK    = $dd00
VIC_BANKDDR = $dd02
CIA1_ICR    = $dc0d
CIA2_ICR    = $dc0d+$0100           ; $dd0d
CIA1_TALO   = $dc04
JiffyFPS    = $02a6
KERNAL_IRQ  = $ea31                 ; KERNAL IRQ continuation (keyboard/jiffy)

; --- SID (TunnelVoyager engine) ---
SID        = $d400
SID_V1FLO  = $d400
SID_V1FHI  = $d401
SID_V1PWLO = $d402
SID_V1PWHI = $d403
SID_V1CTL  = $d404
SID_V1AD   = $d405
SID_V1SR   = $d406
SID_V2FLO  = $d407
SID_V2FHI  = $d408
SID_V2PWLO = $d409
SID_V2PWHI = $d40a
SID_V2CTL  = $d40b
SID_V2AD   = $d40c
SID_V2SR   = $d40d
SID_V3FLO  = $d40e
SID_V3FHI  = $d40f
SID_V3CTL  = $d412
SID_V3AD   = $d413
SID_V3SR   = $d414
SID_FCLO   = $d415
SID_FCHI   = $d416
SID_RESFLT = $d417
SID_MODEVOL= $d418
MUS_SPEED  = 6                      ; frames per pattern row

IRQ_LINE    = 250

; --- Matrix colours ---
COL_GREEN   = 5
COL_LGREEN  = 13
COL_HEAD    = 1

; --- zero page (music in IRQ must stay disjoint from effects in main loop) ---
ZP_MLO  = $f7      ; music: melody pattern ptr
ZP_MHI  = $f8
ZP_BLO  = $f9      ; music: bass pattern ptr
ZP_BHI  = $fa
SPTR    = $fb      ; effects: screen dest ptr
SPTR_HI = $fc
CPTR    = $fd      ; effects: colour dest ptr
CPTR_HI = $fe
TXTP    = $05      ; effects: text source ptr
TXTP_HI = $06
ET0     = $02
ET1     = $03
ET2     = $04
ET3     = $ff

; ============================================================================
;  ENTRY  (immediately after the BASIC stub, at $080d = SYS 2061)
; ============================================================================
MegaMain:
        sei
        ; Bank out BASIC ROM ($a000-$bfff) -> that RAM is now usable, because the
        ; demo's code+data grew past $a000.  Keep KERNAL (IRQ chain + GETIN) + I/O.
        lda #$36
        sta $01
        ; CIA IRQs off (we own the IRQ; KERNAL keyboard still scanned via $ea31)
        lda #$7f
        sta CIA1_ICR
        sta CIA2_ICR
        lda CIA1_ICR
        lda CIA2_ICR
        lda #$00
        sta VIC_IMR

        jsr SetupVIC
        jsr ClearScreenColor
        jsr TV_MusInit
        jsr SeedRand
        jsr GlobalScrollerInit

        ; Start on part 0 (title), no preceding card.
        lda #0
        sta partId
        sta demoState           ; 0 = RUN
        jsr InitPart
        jsr SetPartTimer

        jsr InstallIRQ
        cli

MainLoop:
        lda frameReady          ; new frame from the IRQ?
        beq MainLoop
        lda #0
        sta frameReady          ; consume immediately -> heavy effects free-run and
                                ; sample the sound pulse every pass (tight beat tracking)

        jsr ReadKeys            ; SPACE=pause scroller, +/- = speed
                                ; (pulses now refreshed in the IRQ at 50 Hz)
        lda demoState
        bne ML_trans
        ; ---- RUN: render active part, count down its timer ----
        jsr UpdatePart
        lda partFramesLo
        bne @decLo
        lda partFramesHi
        beq @expire
        dec partFramesHi
@decLo:
        dec partFramesLo
        jmp ML_scroll
@expire:
        jsr BeginTransition
        jmp ML_scroll
ML_trans:
        jsr StepTransition
ML_scroll:
        jsr GlobalScroller      ; row-24 scroller runs in every scene + transition
        jmp MainLoop

; ============================================================================
;  VIC / screen setup
; ============================================================================
SetupVIC:
        ; VIC bank 0 ($0000-$3fff): CIA2 port A bits 0-1 = %11
        lda VIC_BANKDDR
        ora #%00000011
        sta VIC_BANKDDR
        lda VIC_BANK
        and #%11111100
        ora #%00000011
        sta VIC_BANK
        ; screen $0400, charset $1000 (ROM font mirrored into VIC view)
        lda #$14
        sta VIC_MEMPTR
        ; text mode, 25 rows, 40 cols
        lda #$1b
        sta VIC_CTRL1
        lda #$08
        sta VIC_CTRL2
        lda #$00
        sta BORDER
        sta BKG
        rts

ClearScreenColor:
        ldx #0
        lda #$20
@s:     sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$300,x
        inx
        bne @s
        ldx #0
        lda #$00
@c:     sta COLOR+$000,x
        sta COLOR+$100,x
        sta COLOR+$200,x
        sta COLOR+$300,x
        inx
        bne @c
        rts

; ============================================================================
;  GLOBAL SCROLLER (row 24, runs in every scene + transition)
;  Smooth: $d016 fine scroll via scrollReg + full row redraw each frame (so it
;  survives screen clears between parts).  Glow colour overlay scrolls under it.
; ============================================================================
SCR_HOLD    = 150               ; frames to freeze on a greet "stop"
SCR_SENTCOL = 16                ; column at which a $ff sentinel fires a stop
SCR_CORE    = ScrollMsgEnd - ScrollMsg - 40   ; 16-bit core length
gscWinLo !byte 0                ; visible window char offset (16-bit)
gscWinHi !byte 0
gscFine  !byte 7                ; $d016 fine X (7..0)
gscGlow  !byte 0                ; glow colour phase
scrSpeed !byte 2                ; pixels/frame (1..6, +/- keys)
scrPause !byte 0                ; 1 = paused by SPACE
scrHold  !byte 0                ; >0 = auto greet-stop countdown
scrLastLo !byte $ff             ; last window that fired a stop (debounce)
scrLastHi !byte $ff

GlobalScrollerInit:
        lda #0
        sta gscWinLo
        sta gscWinHi
        sta gscGlow
        sta scrPause
        sta scrHold
        lda #2
        sta scrSpeed
        lda #7
        sta gscFine
        lda #$ff
        sta scrLastLo
        sta scrLastHi
        rts

; ReadKeys: SPACE = pause toggle, '+' faster, '-' slower (GETIN $ffe4)
ReadKeys:
        jsr $ffe4
        beq @rkdone
        cmp #$20                ; SPACE -> toggle pause
        bne @chkplus
        lda scrPause
        eor #$01
        sta scrPause
        rts
@chkplus:
        cmp #$2b                ; '+' -> faster (cap 6)
        bne @chkminus
        lda scrSpeed
        cmp #6
        bcs @rkdone
        inc scrSpeed
        rts
@chkminus:
        cmp #$2d                ; '-' -> slower (min 1)
        bne @rkdone
        lda scrSpeed
        cmp #2
        bcc @rkdone
        dec scrSpeed
@rkdone:
        rts

GlobalScroller:
        inc gscGlow             ; glow keeps shimmering even when paused/held
        ; -- frozen during a greet stop --
        lda scrHold
        beq @noHold
        dec scrHold
        jmp @draw
@noHold:
        lda scrPause            ; user pause -> freeze (still redraw for glow)
        bne @draw
        ; -- greet sentinel ($ff) reaching the centre column fires a stop --
        clc
        lda #<ScrollMsg
        adc gscWinLo
        sta TXTP
        lda #>ScrollMsg
        adc gscWinHi
        sta TXTP_HI
        ldy #SCR_SENTCOL
        lda (TXTP),y
        cmp #$ff
        bne @advance
        lda gscWinLo            ; debounce: only fire once per window
        cmp scrLastLo
        bne @fire
        lda gscWinHi
        cmp scrLastHi
        beq @advance
@fire:
        lda gscWinLo
        sta scrLastLo
        lda gscWinHi
        sta scrLastHi
        lda #SCR_HOLD
        sta scrHold
        jmp @draw
@advance:
        lda gscFine
        sec
        sbc scrSpeed
        bcs @savefine
        clc
        adc #8                  ; wrapped -> advance one character
        sta gscFine
        inc gscWinLo            ; gscWin++ (16-bit)
        bne @wchk
        inc gscWinHi
@wchk:
        lda gscWinHi            ; if gscWin >= core length -> wrap to 0
        cmp #>SCR_CORE
        bcc @draw
        bne @wrap
        lda gscWinLo
        cmp #<SCR_CORE
        bcc @draw
@wrap:
        lda #0
        sta gscWinLo
        sta gscWinHi
        lda #$ff
        sta scrLastLo
        sta scrLastHi
        jmp @draw
@savefine:
        sta gscFine
@draw:
        lda gscFine
        ora #$08
        sta scrollReg           ; the IRQ split writes this to $d016 for row 24
        clc
        lda #<ScrollMsg
        adc gscWinLo
        sta TXTP
        lda #>ScrollMsg
        adc gscWinHi
        sta TXTP_HI
        ldy #39
@d:     lda (TXTP),y
        cmp #$ff                ; sentinel -> render as a blank
        bne @notsent
        lda #$20
@notsent:
        sta SCREEN+24*40,y
        tya
        clc
        adc gscGlow
        and #$1f
        tax
        lda GlowRamp,x
        sta COLOR+24*40,y
        dey
        bpl @d
        rts

; ============================================================================
;  IRQ : 50 Hz music tick + frame flag, chained to KERNAL
; ============================================================================
SPLIT_LINE = 241        ; just before char row 24 -> sets fine scroll
MAIN_LINE  = 251        ; below the display -> resets scroll, music, border

InstallIRQ:
        sei
        lda #<MegaMain_IRQ
        sta $0314
        lda #>MegaMain_IRQ
        sta $0315
        lda #MAIN_LINE
        sta VIC_RASTER
        lda VIC_CTRL1
        and #$7f
        sta VIC_CTRL1
        lda #$01
        sta VIC_IMR
        sta VIC_IRR
        cli
        rts

; ---- MAIN stop @ line 251: fine-scroll reset, music tick, frame flag, border ----
MegaMain_IRQ:
        lda #$01
        sta VIC_IRR
        lda #$08                ; 40 cols, X fine scroll = 0 for the upper screen
        sta VIC_CTRL2
        inc frameCounter
        jsr TV_PlayMusic        ; TunnelVoyager music + beat-flash border (50 Hz)
        jsr ComputeVisualPulses ; 50 Hz, frame-accurate -> effects always read the
                                ; current beat even if a heavy render spans frames
        lda #$01
        sta frameReady
        ; schedule the scroller split for next frame
        lda #SPLIT_LINE
        sta VIC_RASTER
        lda #<MegaSplit_IRQ
        sta $0314
        lda #>MegaSplit_IRQ
        sta $0315
        jmp KERNAL_IRQ          ; chain (keyboard/jiffy)

; ---- SPLIT stop @ line 241: apply the IRQ smooth-scroller fine offset ----
MegaSplit_IRQ:
        lda #$01
        sta VIC_IRR
        lda scrollReg           ; $08|fine  ($08 = no scroll outside part 3)
        sta VIC_CTRL2
        lda #MAIN_LINE
        sta VIC_RASTER
        lda #<MegaMain_IRQ
        sta $0314
        lda #>MegaMain_IRQ
        sta $0315
        jmp $ea81               ; tight return (restore regs + rti)

; ============================================================================
;  Part / transition state machine
; ============================================================================
; demoState: 0 = RUN, 1 = TRANSITION
; transPhase: 0 = wipe to black, 1 = show title card
partId          !byte 0
nextPart        !byte 0
demoState       !byte 0
transPhase      !byte 0
transStyle      !byte 0         ; 0 = row wipe, 1 = colour flash-fade
wipeRow         !byte 0
cardTimer       !byte 0
; flash-fade transition colour ramp (white -> hues -> black)
FlashFadeRamp:  !byte $01,$01,$0f,$07,$0a,$04,$0e,$06,$00,$00
FLASHFADE_LEN = 10
partFramesLo    !byte 0
partFramesHi    !byte 0
frameReady      !byte 0
frameCounter    !byte 0
scrollReg       !byte $08       ; $d016 value applied at the split (fine scroll)
partBorder      !byte 0         ; per-part border base colour

NUM_PARTS = 28
; Per-part border tint (21 parts; horizon-warp/rings removed)
;             title matrix plasma hyper vortex xor waves tunnel fire star wf hp lw dt CUBE nr STAR hr pg tz of
;             ti mat pl hy vx xr wv tn fi st | ts hv mc rb yw tb gh mb rg cg sp bo rc  (23)
PartBorderTbl:  !byte $06, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $0b, $00, $06
; Per-scene background tint (mostly black; deep/tunnel scenes get a dark-blue void)
;            ti mat pl hy vx xr wv tn fi st wf hp lw DT CB nr ST hr pg TZ of
; tunnel-ish ported engines (ts,rb,yw,tb,sp,bo) get a dark-blue void for depth
; all scenes on pure black for max contrast / clean 3D
PartBgTbl:  !byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

; Per-part run length in frames (low,high).  CUBE (idx 14) lingers; rest snappy.
;                title matrix plasma hyper vortex  xor   waves  tunnel fire  star  wf    hp    lw    dt   CUBE   nr   STAR   hr    pg    tz    of
;                ti  mat  pl   hy   vx   xr   wv   tn   fi   st | ts   hv   mc   rb   yw   tb   gh   mb   rg   cg   sp   bo   rc
PartFramesTbl_Lo  !byte <224, <266, <266, <251, <266, <336, <266, <322, <294, <350, <308, <322, <336, <308, <350, <322, <336, <406, <294, <294, <294, <336, <322, <588, <320, <300, <300, <460
PartFramesTbl_Hi  !byte >224, >266, >266, >251, >266, >336, >266, >322, >294, >350, >308, >322, >336, >308, >350, >322, >336, >406, >294, >294, >294, >336, >322, >588, >320, >300, >300, >460

SetPartTimer:
        ldx partId
        lda PartFramesTbl_Lo,x
        sta partFramesLo
        lda PartFramesTbl_Hi,x
        sta partFramesHi
        rts

BeginTransition:
        lda #1
        sta demoState
        lda #0
        sta transPhase
        sta wipeRow
        lda #$00
        sta BKG                 ; clear any title background pulse
        lda transStyle          ; alternate transition FX each time
        eor #1
        sta transStyle
        ; next part = (partId + 1) mod NUM_PARTS
        lda partId
        clc
        adc #1
        cmp #NUM_PARTS
        bcc @ok
        lda #0
@ok:    sta nextPart
        ; ---- DIGITAL RAIN MENU between effects ----
        jsr ClearScreenColor    ; cut to a fresh field
        jsr mr_init             ; seed the rain columns
        jsr ShowCard            ; print the next effect's name
        lda #110
        sta cardTimer
        lda #1
        sta transPhase          ; go straight to the rain + name menu
        rts

StepTransition:
        lda transPhase
        beq @notcard
        jmp TransCard
@notcard:
        lda transStyle
        bne StepFlashFade
; ---- wipe to black, 3 rows per frame ----
        ldx wipeRow
@wloop:
        cpx #25
        bcs @wipeDone
        ; clear screen row x = space, colour row x = black
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
@wcell:
        lda #$20
        sta (SPTR),y
        lda #$00
        sta (CPTR),y
        dey
        bpl @wcell
        inx
        cpx wipeRow
        ; advance 3 rows total this frame
        txa
        sec
        sbc wipeRow
        cmp #3
        bcc @wloop
@wipeDone2:
        stx wipeRow
        cpx #25
        bcc @wret
        ; wipe complete -> show the card
        jsr ShowCard
        lda #90
        sta cardTimer
        lda #1
        sta transPhase
@wret:
        rts
@wipeDone:
        stx wipeRow
        jsr ShowCard
        lda #90
        sta cardTimer
        lda #1
        sta transPhase
        rts

; ---- alternate FX: full-screen colour flash that fades to black ----
StepFlashFade:
        ldx wipeRow
        lda FlashFadeRamp,x
        sta ET0                 ; this step's flash colour
        lda #$a0
        ldx #0
@ffs:   sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$300,x
        inx
        bne @ffs
        lda ET0
        ldx #0
@ffc:   sta COLOR+$000,x
        sta COLOR+$100,x
        sta COLOR+$200,x
        sta COLOR+$300,x
        inx
        bne @ffc
        inc wipeRow
        lda wipeRow
        cmp #FLASHFADE_LEN
        bcc @ffret
        jsr ShowCard
        lda #90
        sta cardTimer
        lda #1
        sta transPhase
@ffret:
        rts

TransCard:
        jsr mr_update           ; digital rain falls behind the menu
        jsr ShowCard            ; re-stamp the effect name on top of the rain
        ; the two name rows pulse through bright colours so they pop over the rain
        lda frameCounter
        lsr
        lsr
        and #$03
        tax
        lda MenuNamePalette,x
        sta ET0
        ldx #39
.tc_namecol:
        lda ET0
        sta COLOR+11*40,x
        sta COLOR+13*40,x
        dex
        bpl .tc_namecol
        dec cardTimer
        bne @cret
        ; menu done -> switch to next part
        jsr ClearScreenColor
        lda nextPart
        sta partId
        jsr InitPart
        jsr SetPartTimer
        lda #0
        sta demoState
@cret:
        rts

; ============================================================================
;  Part dispatch
; ============================================================================
InitPart:
        ldx partId
        lda PartBorderTbl,x
        sta partBorder
        lda PartBgTbl,x          ; per-scene background tint (scenery)
        sta BKG
        lda #$08
        sta scrollReg           ; scroller split inert until the finale sets it
        ; (music: the 4 tracks cycle on their own full arcs, driven by the engine)
        lda partId
        asl
        tax
        lda InitTbl,x
        sta TXTP
        lda InitTbl+1,x
        sta TXTP_HI
        jmp (TXTP)
InitTbl:
        !word ti_init, pl_init, hs_init, xr_init, wv_init, tn_init, ss_init
        !word ts_init, hv_init, mc_init, yw_init, tb_init, gh_init, rg_init, cg_init, sp_init, bo_init, rc_init
        !word PortedInit, PortedInit, PortedInit, ic_init, gt_init, cv_init   ; solar, prism, twist, full3d cube
        !word vx_init, mb_init, rb_init, nw_init   ; +vortex, mux edge, raster boot, neon wire

UpdatePart:
        lda partId
        asl
        tax
        lda UpdateTbl,x
        sta TXTP
        lda UpdateTbl+1,x
        sta TXTP_HI
        jmp (TXTP)
UpdateTbl:
        !word ti_update, pl_update, hs_update, xr_update, wv_update, tn_update, ss_update
        !word ts_update, hv_update, mc_update, yw_update, tb_update, gh_update, rg_update, cg_update, sp_update, bo_update, rc_update
        !word SolarFlareRender, PrismGateRender, TwistLatticeRender, ic_update, gt_update, cv_update
        !word vx_update, mb_update, rb_update, nw_update

; ============================================================================
;  Title cards (shown during transitions) + title part text
; ============================================================================
; Card name/subtitle for the *next* part (table-driven, auto-centred).
ShowCard:
        ldx nextPart
        lda CardNameLo,x
        sta TXTP
        lda CardNameHi,x
        sta TXTP_HI
        ldx #11
        jsr PrintCenteredAuto
        ldx nextPart
        lda CardSubLo,x
        sta TXTP
        lda CardSubHi,x
        sta TXTP_HI
        ldx #13
        jsr PrintCenteredAuto
        rts

; PrintCenteredAuto: TXTP -> $ff-term text, X=row -> measures length, centres
PrintCenteredAuto:
        ldy #0
@m:     lda (TXTP),y
        cmp #$ff
        beq @d
        iny
        bne @m
@d:     jmp PrintCentered       ; X=row, Y=length

; Re-colour the two card rows (10 and 13) with a cycling hue.
CycleCardColor:
        lda frameCounter
        lsr
        lsr
        clc
        adc #$01
        and #$0f
        bne @ok
        lda #$01
@ok:    sta ET0
        ldx #39
@l:     lda ET0
        sta COLOR+10*40,x
        sta COLOR+13*40,x
        dex
        bpl @l
        rts

; PrintCentered: TXTP -> text ($ff term), X=row, Y=length -> centred on row X
PrintCentered:
        ; col = (40 - len) / 2
        tya
        sta ET1                 ; len
        lda #40
        sec
        sbc ET1
        lsr
        sta ET2                 ; col
        ; SPTR = ScrRow[X] + col ; CPTR = colour
        lda ScrRowLo,x
        clc
        adc ET2
        sta SPTR
        lda ScrRowHi,x
        adc #0
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #0
@p:     lda (TXTP),y
        cmp #$ff
        beq @d
        sta (SPTR),y
        lda #$01
        sta (CPTR),y
        iny
        jmp @p
@d:     rts

; ============================================================================
;  PART 0 : TITLE
; ============================================================================
!zone title
ti_init:
        jsr ClearScreenColor
        lda #<TitleA : sta TXTP : lda #>TitleA : sta TXTP_HI
        ldx #8  : jsr PrintCenteredAuto
        lda #<TitleB : sta TXTP : lda #>TitleB : sta TXTP_HI
        ldx #11 : jsr PrintCenteredAuto
        lda #<TitleC : sta TXTP : lda #>TitleC : sta TXTP_HI
        ldx #15 : jsr PrintCenteredAuto
        lda #<TitleD : sta TXTP : lda #>TitleD : sta TXTP_HI
        ldx #17 : jsr PrintCenteredAuto
        rts

ti_update:
        lda #$00
        sta BKG                 ; solid black bg so title text stays readable
        ; colour-cycle the two name rows (8 / 11) as one bright hue
        lda frameCounter
        lsr
        and #$0f
        tax
        lda ColorCycle,x
        and #$0f
        bne .okc
        lda #$01
.okc:   sta ET0
        ldx #39
.cl:    lda ET0
        sta COLOR+8*40,x
        sta COLOR+11*40,x
        dex
        bpl .cl
        ; per-column rainbow on the two info rows (15 / 17), never bg-black
        ldx #39
.cr:    txa
        clc
        adc frameCounter
        tay
        lda ColorCycle,y
        and #$0f
        bne .okr
        lda #$01
.okr:   sta COLOR+15*40,x
        sta COLOR+17*40,x
        dex
        bpl .cr
        rts
!zone

; ============================================================================
;  PART 1 : DIGITAL RAIN (Matrix)
; ============================================================================
!zone matrix
MR_COLS = 40
mr_y      !fill MR_COLS,0
mr_speed  !fill MR_COLS,1
mr_tick   !fill MR_COLS,0
mr_len    !fill MR_COLS,5
mrBeat    !byte 0

mr_init:
        ; whole field black/space (already cleared), seed columns
        ldx #0
.ic:    jsr Rand8
        and #$1f
        eor #$1f
        clc
        adc #$e0                ; y in 224..255 (off top)
        sta mr_y,x
        jsr Rand8
        and #3
        clc
        adc #1
        sta mr_speed,x
        sta mr_tick,x
        jsr Rand8
        and #7
        clc
        adc #3
        sta mr_len,x
        inx
        cpx #MR_COLS
        bne .ic
        rts

mr_update:
        lda TV_FlashI            ; rain falls faster on the beat
        lsr
        lsr
        lsr
        sta mrBeat
        ldx #0
.col:
        lda mr_tick,x
        beq .step
        dec mr_tick,x
        jmp .next
.step:
        lda mr_speed,x
        sec
        sbc mrBeat
        bcs .spd_ok
        lda #1
.spd_ok:
        sta mr_tick,x
        inc mr_y,x

        ; draw trail head..head-len+1
        lda mr_y,x
        sta ET0                 ; head_y
        lda #0
        sta ET1                 ; k
.trail:
        lda ET0
        sec
        sbc ET1
        bcc .skip               ; row < 0
        cmp #24
        bcs .skip               ; row >= 24 (row 24 reserved for scroller)
        tay                     ; row
        jsr mr_setptr           ; SPTR/CPTR for (row=Y, col=X)
        jsr RandGlyph
        ldy #0
        sta (SPTR),y
        ; colour by k: 0=head white, 1=mid lgreen, else green
        lda ET1
        bne .mid
        lda #COL_HEAD
        jmp .putc
.mid:   cmp #1
        bne .grn
        lda #COL_LGREEN
        jmp .putc
.grn:   lda #COL_GREEN
.putc:  ldy #0
        sta (CPTR),y
.skip:
        inc ET1
        lda ET1
        cmp mr_len,x
        bcc .trail

        ; erase the tail cell at row = head_y - len
        lda mr_y,x
        sec
        sbc mr_len,x
        bcc .resp_chk
        cmp #24
        bcs .resp_chk
        tay
        jsr mr_setptr
        ldy #0
        lda #$20
        sta (SPTR),y
        lda #$00
        sta (CPTR),y
.resp_chk:
        lda mr_y,x
        cmp #(25+8)
        bcc .next
        ; respawn above the top
        jsr Rand8
        and #$1f
        eor #$1f
        clc
        adc #$e0
        sta mr_y,x
        jsr Rand8
        and #3
        clc
        adc #1
        sta mr_speed,x
        sta mr_tick,x
        jsr Rand8
        and #7
        clc
        adc #3
        sta mr_len,x
.next:
        inx
        cpx #MR_COLS
        bcs .done
        jmp .col
.done:
        rts

; SPTR/CPTR for cell (row in Y, col in X); preserves X
mr_setptr:
        lda ScrRowLo,y
        sta SPTR
        lda ScrRowHi,y
        sta SPTR_HI
        txa
        clc
        adc SPTR
        sta SPTR
        bcc .nc
        inc SPTR_HI
.nc:    lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        rts
!zone

; ============================================================================
;  PART 2 : HORIZON WARP (rings)
; ============================================================================

; ============================================================================
;  PART 3 : SINE STARFIELD + glowing greets scroller
; ============================================================================
!zone stars
NUM_FAST = 40
NUM_SLOW = 24

ss_fx   !fill NUM_FAST,0
ss_fy   !fill NUM_FAST,0
ss_sx   !fill NUM_SLOW,0
ss_sy   !fill NUM_SLOW,0

ss_init:
        jsr ClearScreenColor
        ldx #0
.if:    jsr Rand8
        jsr Mod40
        sta ss_fx,x
        jsr Rand8
        jsr Mod25
        sta ss_fy,x
        inx
        cpx #NUM_FAST
        bne .if
        ldx #0
.is:    jsr Rand8
        jsr Mod40
        sta ss_sx,x
        jsr Rand8
        jsr Mod25
        sta ss_sy,x
        inx
        cpx #NUM_SLOW
        bne .is
        rts

ss_update:
        ; --- fast stars (X = star index throughout; helpers preserve X) ---
        ldx #0
.fl:
        ; erase old position
        ldy ss_fy,x
        lda ss_fx,x
        jsr ss_ptr
        ldy #0
        lda #$20
        sta (SPTR),y
        ; move down / respawn
        lda ss_fy,x
        clc
        adc #1
        cmp #24
        bcc .fstore
        jsr Rand8
        jsr Mod40
        sta ss_fx,x
        lda #0
.fstore:
        sta ss_fy,x
        ; draw new (alternate * and .)
        ldy ss_fy,x
        lda ss_fx,x
        jsr ss_ptr
        lda frameCounter
        eor ss_fx_cur
        and #$08
        beq .cstar
        lda #$2e
        jmp .cput
.cstar: lda #$2a
.cput:  ldy #0
        sta (SPTR),y
        lda ss_fx_cur
        clc
        adc frameCounter
        adc TV_FlashI            ; stars shimmer on the beat
        tay
        lda Sin256,y
        lsr
        lsr
        clc
        adc #$08
        and #$0f
        ldy #0
        sta (CPTR),y
        inx
        cpx #NUM_FAST
        bcs .fastdone
        jmp .fl
.fastdone:
        ; --- slow stars (move every other frame) ---
        ldx #0
.sl:
        ldy ss_sy,x
        lda ss_sx,x
        jsr ss_ptr
        ldy #0
        lda #$20
        sta (SPTR),y
        lda frameCounter
        and #1
        bne .snomove
        lda ss_sy,x
        clc
        adc #1
        cmp #24
        bcc .sstore
        jsr Rand8
        jsr Mod40
        sta ss_sx,x
        lda #0
.sstore:
        sta ss_sy,x
.snomove:
        ldy ss_sy,x
        lda ss_sx,x
        jsr ss_ptr
        ldy #0
        lda #$2e
        sta (SPTR),y
        lda #$0e
        sta (CPTR),y
        inx
        cpx #NUM_SLOW
        bcs .slowdone
        jmp .sl
.slowdone:
        rts                     ; row 24 scroller is handled by GlobalScroller

; ss_ptr: A=col, Y=row -> SPTR/CPTR ; stashes col in ss_fx_cur
ss_ptr:
        sta ss_fx_cur
        lda ScrRowLo,y
        sta SPTR
        lda ScrRowHi,y
        sta SPTR_HI
        lda ss_fx_cur
        clc
        adc SPTR
        sta SPTR
        bcc .nc
        inc SPTR_HI
.nc:    lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        rts

ss_idx     !byte 0
ss_fx_cur  !byte 0
!zone

; ============================================================================
;  PART 3 : PLASMA STORM  (interfering sines -> colour RAM)
; ============================================================================
!zone plasma
pl_p1     !byte 0
pl_p2     !byte 0
pl_p3     !byte 0
pl_colbuf !fill 40,0

pl_init:
        ldx #0
        lda #$a0                ; solid blocks so the colour plasma shows
.f:     sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        inx
        bne .f
        ldx #0
.f2:    sta SCREEN+$300,x       ; rows 0..23 only; row 24 left for the scroller
        inx
        cpx #192
        bne .f2
        lda #0
        sta pl_p1
        sta pl_p2
        sta pl_p3
        rts

pl_update:
        ; advance the three phases at different rates
        lda pl_p1 : clc : adc #2 : sta pl_p1
        lda pl_p2 : clc : adc #3 : sta pl_p2
        lda pl_p3 : clc : adc #1 : adc TV_FlashI : sta pl_p3   ; beat = colour surge
        ; per-frame column sine buffer: colbuf[c] = Sin256[(c*4 + p2) & 255]
        ldx #39
.cb:    txa
        asl
        asl
        clc
        adc pl_p2
        tay
        lda Sin256,y
        sta pl_colbuf,x
        dex
        bpl .cb
        ; rows
        lda #0
        sta ET2                 ; row
.row:
        ldx ET2
        lda ColRowLo,x
        sta CPTR
        lda ColRowHi,x
        sta CPTR_HI
        ; rowval = Sin256[(row*4 + p1) & 255] + p3 (colour drift)
        txa
        asl
        asl
        clc
        adc pl_p1
        tay
        lda Sin256,y
        clc
        adc pl_p3
        sta ET1                 ; rowval
        ldy #39
.col:
        lda pl_colbuf,y
        clc
        adc ET1
        lsr
        lsr
        and #$0f
        tax
        lda PAL16,x
        sta (CPTR),y
        dey
        bpl .col
        inc ET2
        lda ET2
        cmp #24
        bne .row
        rts
!zone

; ============================================================================
;  PART 4 : HYPERSPACE  (centre-out warp starfield, 8.8 fixed point)
; ============================================================================
!zone hyper
HS_NUM = 64
HS_CXLO = $00       ; centre 20.0
HS_CXHI = $14
HS_CYLO = $00       ; centre 12.0
HS_CYHI = $0c

hs_xl   !fill HS_NUM,0
hs_xh   !fill HS_NUM,0
hs_yl   !fill HS_NUM,0
hs_yh   !fill HS_NUM,0
hs_oc   !fill HS_NUM,$ff     ; last drawn col ($ff = none)
hs_or   !fill HS_NUM,0       ; last drawn row
hs_dlo  !byte 0
hs_dhi  !byte 0

hs_init:
        jsr ClearScreenColor
        ldx #0
.i:     jsr hs_spawn
        lda #$ff
        sta hs_oc,x             ; nothing drawn yet
        inx
        cpx #HS_NUM
        bne .i
        rts

; spawn star X near the centre with a random SIGNED offset (all directions,
; never exactly centred so the outward delta is never zero)
hs_spawn:
        jsr Rand8
        sta hs_xl,x
        jsr Rand8
        and #$03
        tay
        lda HsOff,y
        clc
        adc #HS_CXHI
        sta hs_xh,x
        jsr Rand8
        sta hs_yl,x
        jsr Rand8
        and #$03
        tay
        lda HsOff,y
        clc
        adc #HS_CYHI
        sta hs_yh,x
        rts
HsOff:  !byte $fe,$ff,$01,$02       ; -2,-1,+1,+2 cells (never 0)

hs_update:
        ldx #0
.loop:
        ; erase previous cell if any
        lda hs_oc,x
        cmp #$ff
        beq .moved
        tay                     ; Y = old col
        lda hs_or,x             ; A = old row
        jsr hs_ptr
        ldy #0
        lda #$20
        sta (SPTR),y
.moved:
        ; X axis: delta = X - centreX ; X += delta>>2  (accelerate outward)
        sec
        lda hs_xl,x
        sbc #HS_CXLO
        sta hs_dlo
        lda hs_xh,x
        sbc #HS_CXHI
        sta hs_dhi
        jsr hs_sar2             ; signed (dhi:dlo) >>= 2
        clc
        lda hs_xl,x
        adc hs_dlo
        sta hs_xl,x
        lda hs_xh,x
        adc hs_dhi
        sta hs_xh,x
        ; Y axis
        sec
        lda hs_yl,x
        sbc #HS_CYLO
        sta hs_dlo
        lda hs_yh,x
        sbc #HS_CYHI
        sta hs_dhi
        jsr hs_sar2
        clc
        lda hs_yl,x
        adc hs_dlo
        sta hs_yl,x
        lda hs_yh,x
        adc hs_dhi
        sta hs_yh,x
        ; off screen?  (xh>=40 covers negatives via unsigned wrap; yh>=25)
        lda hs_xh,x
        cmp #40
        bcs .resp
        lda hs_yh,x
        cmp #24
        bcs .resp
        ; draw at (row=yh, col=xh)
        lda hs_xh,x
        sta hs_oc,x             ; col
        lda hs_yh,x
        sta hs_or,x             ; row
        ldy hs_oc,x             ; Y = col
        lda hs_or,x             ; A = row
        jsr hs_ptr
        ; brightness by distance: |xh-20| -> char/colour
        lda hs_xh,x
        sec
        sbc #HS_CXHI
        bpl .pabs
        eor #$ff
        clc
        adc #1
.pabs:  cmp #6
        bcc .dim
        ldy #0
        lda #$2a                ; '*' near
        sta (SPTR),y
        lda TV_FlashI            ; near stars flash cyan on strong beats
        cmp #5
        bcc .nwhite
        lda #$03
        jmp .nput
.nwhite:
        lda #$01                ; white
.nput:  sta (CPTR),y
        jmp .next
.dim:   ldy #0
        lda #$2e                ; '.' far
        sta (SPTR),y
        lda #$0b                ; dark grey
        sta (CPTR),y
        jmp .next
.resp:
        lda #$ff
        sta hs_oc,x             ; mark erased
        jsr hs_spawn
.next:
        inx
        cpx #HS_NUM
        bcs .done
        jmp .loop
.done:
        rts

; signed arithmetic shift right by 2 of (hs_dhi:hs_dlo)
hs_sar2:
        ldy #2
.s:     lda hs_dhi
        cmp #$80                ; copy sign into carry
        ror hs_dhi
        ror hs_dlo
        dey
        bne .s
        rts

; hs_ptr: A=row, Y=col -> SPTR/CPTR (preserves X)
hs_ptr:
        sty ET1                 ; col
        tay                     ; Y = row
        lda ScrRowLo,y
        clc
        adc ET1
        sta SPTR
        lda ScrRowHi,y
        adc #0
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        rts
!zone

; ============================================================================
;  PART 5 : VORTEX  (rotating spiral; precomputed atan2+distance into colour RAM)
; ============================================================================
!zone vortex
vx_phase !byte 0

vx_init:
        ldx #0
        lda #$a0
.f:     sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        inx
        bne .f
        ldx #0
.f2:    sta SCREEN+$300,x       ; rows 0..23 only; row 24 left for the scroller
        inx
        cpx #192
        bne .f2
        lda #0
        sta vx_phase
        rts

vx_update:
        inc vx_phase            ; rotate the spiral
        lda vx_phase
        clc
        adc TV_FlashI           ; beat = spin jolt
        sta vx_phase
        lda #0
        sta ET2
.row:
        ldx ET2
        lda ColRowLo,x
        sta CPTR
        lda ColRowHi,x
        sta CPTR_HI
        lda VxRowLo,x
        sta TXTP
        lda VxRowHi,x
        sta TXTP_HI
        ldy #0
.cell:
        lda (TXTP),y
        clc
        adc vx_phase
        and #$0f
        tax
        lda PAL16,x
        sta (CPTR),y
        iny
        cpy #40
        bne .cell
        inc ET2
        lda ET2
        cmp #24
        bne .row
        rts

; spiral = (int(dist) + int(angle/2pi * 16*ARMS)) & 15, centre (19.5,12), 2 arms
VortexBase:
        !byte $9,$9,$9,$8,$7,$6,$6,$5,$5,$4,$4,$3,$4,$3,$3,$3,$3,$3,$4,$4,$5,$5,$6,$6,$6,$8,$8,$9,$a,$b,$b,$c,$e,$f,$f,$0,$1,$2,$4,$4
        !byte $9,$8,$7,$6,$7,$6,$5,$4,$3,$4,$3,$2,$2,$2,$2,$2,$2,$2,$3,$3,$4,$4,$5,$5,$5,$7,$7,$9,$9,$a,$b,$c,$d,$e,$f,$0,$1,$2,$3,$4
        !byte $8,$8,$7,$6,$5,$5,$4,$4,$3,$2,$2,$2,$1,$1,$1,$0,$1,$1,$2,$2,$3,$3,$4,$4,$5,$6,$6,$8,$9,$9,$b,$c,$d,$d,$e,$0,$1,$2,$3,$3
        !byte $8,$7,$6,$5,$4,$4,$3,$3,$2,$1,$1,$1,$0,$0,$0,$0,$0,$0,$1,$1,$2,$2,$3,$3,$5,$5,$7,$7,$8,$a,$a,$b,$c,$e,$f,$f,$0,$1,$2,$3
        !byte $7,$7,$6,$5,$4,$3,$2,$1,$2,$1,$0,$f,$f,$f,$e,$f,$e,$f,$0,$0,$1,$1,$2,$3,$4,$5,$6,$6,$8,$9,$a,$b,$c,$d,$e,$f,$0,$1,$2,$4
        !byte $6,$5,$4,$4,$4,$3,$2,$1,$0,$f,$f,$f,$e,$e,$d,$e,$d,$e,$e,$f,$0,$1,$1,$2,$3,$4,$5,$7,$8,$8,$a,$b,$c,$d,$e,$f,$f,$1,$2,$3
        !byte $6,$5,$4,$3,$2,$1,$1,$0,$f,$f,$e,$e,$d,$c,$d,$c,$c,$c,$d,$e,$f,$0,$1,$1,$3,$4,$5,$6,$7,$9,$a,$a,$b,$c,$e,$f,$0,$1,$2,$3
        !byte $6,$5,$4,$3,$2,$1,$0,$f,$f,$e,$d,$c,$c,$c,$b,$b,$b,$b,$c,$d,$e,$f,$0,$2,$2,$4,$5,$7,$7,$8,$9,$a,$c,$d,$e,$f,$0,$1,$2,$3
        !byte $5,$4,$3,$2,$2,$1,$0,$f,$e,$d,$d,$c,$b,$a,$a,$a,$a,$a,$b,$c,$d,$e,$f,$1,$3,$3,$5,$6,$7,$8,$a,$b,$c,$d,$e,$f,$f,$0,$1,$2
        !byte $4,$3,$2,$1,$0,$0,$f,$e,$d,$c,$b,$b,$a,$a,$9,$8,$8,$8,$9,$b,$c,$e,$f,$1,$3,$4,$5,$7,$8,$8,$9,$a,$b,$c,$d,$f,$0,$1,$2,$3
        !byte $4,$3,$2,$1,$0,$f,$e,$d,$c,$b,$b,$a,$9,$8,$7,$7,$7,$7,$7,$9,$c,$e,$0,$2,$2,$4,$5,$6,$7,$8,$a,$b,$c,$d,$e,$f,$0,$1,$2,$3
        !byte $4,$3,$2,$1,$0,$f,$e,$d,$c,$b,$a,$9,$8,$7,$6,$6,$5,$4,$4,$7,$c,$f,$1,$2,$3,$5,$6,$7,$8,$9,$a,$b,$c,$d,$e,$f,$0,$1,$2,$3
        !byte $3,$2,$1,$0,$f,$e,$d,$c,$b,$a,$9,$8,$7,$6,$5,$4,$3,$2,$1,$0,$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,$a,$b,$c,$d,$e,$f,$0,$1,$2,$3
        !byte $2,$1,$0,$f,$e,$d,$c,$b,$a,$9,$8,$7,$6,$5,$4,$2,$1,$0,$e,$b,$6,$3,$3,$4,$5,$5,$6,$7,$8,$9,$a,$b,$c,$d,$e,$f,$0,$1,$2,$3
        !byte $2,$1,$0,$f,$e,$d,$c,$b,$a,$9,$7,$6,$5,$4,$3,$1,$1,$f,$d,$b,$8,$6,$6,$6,$6,$6,$7,$8,$9,$a,$a,$b,$c,$d,$e,$f,$0,$1,$2,$3
        !byte $2,$1,$0,$f,$e,$c,$b,$a,$9,$8,$7,$7,$6,$4,$3,$2,$0,$e,$d,$b,$a,$8,$7,$7,$7,$8,$9,$9,$a,$a,$b,$c,$d,$e,$f,$f,$0,$1,$2,$3
        !byte $1,$0,$f,$e,$e,$d,$c,$b,$a,$9,$7,$6,$5,$4,$2,$2,$0,$e,$d,$c,$b,$a,$9,$9,$9,$9,$9,$a,$b,$c,$c,$d,$e,$f,$0,$1,$1,$2,$3,$4
        !byte $2,$1,$0,$f,$e,$d,$c,$b,$9,$8,$7,$6,$6,$4,$3,$1,$1,$f,$e,$d,$c,$b,$a,$a,$a,$a,$b,$b,$b,$c,$d,$e,$e,$f,$0,$1,$2,$3,$4,$5
        !byte $2,$1,$0,$f,$e,$d,$b,$a,$9,$9,$8,$6,$5,$4,$3,$2,$0,$0,$f,$e,$d,$c,$b,$b,$b,$c,$b,$c,$d,$d,$e,$e,$f,$0,$0,$1,$2,$3,$4,$5
        !byte $2,$1,$0,$e,$e,$d,$c,$b,$a,$9,$7,$7,$6,$4,$3,$2,$1,$0,$0,$f,$e,$d,$d,$c,$d,$c,$d,$d,$e,$e,$e,$f,$0,$1,$2,$3,$3,$3,$4,$5
        !byte $3,$1,$0,$f,$e,$d,$c,$b,$a,$9,$8,$7,$5,$5,$4,$3,$2,$1,$0,$0,$f,$f,$e,$d,$e,$d,$e,$e,$e,$f,$0,$1,$0,$1,$2,$3,$4,$5,$6,$6
        !byte $2,$1,$0,$f,$e,$e,$d,$b,$a,$9,$9,$7,$6,$6,$4,$4,$2,$2,$1,$1,$0,$0,$f,$f,$f,$f,$f,$f,$0,$0,$0,$1,$2,$2,$3,$3,$4,$5,$6,$7
        !byte $2,$2,$1,$0,$f,$d,$c,$c,$b,$a,$8,$8,$7,$5,$5,$4,$3,$3,$2,$2,$1,$1,$0,$0,$f,$0,$0,$0,$1,$1,$1,$2,$3,$3,$4,$4,$5,$6,$7,$7
        !byte $3,$2,$1,$0,$f,$e,$d,$c,$b,$a,$9,$8,$8,$6,$6,$4,$4,$4,$3,$3,$2,$2,$1,$1,$1,$1,$1,$1,$1,$2,$3,$2,$3,$4,$5,$6,$5,$6,$7,$8
        !byte $3,$3,$1,$0,$f,$e,$e,$d,$b,$a,$a,$9,$8,$7,$7,$5,$5,$5,$4,$4,$3,$3,$2,$2,$2,$2,$2,$3,$2,$3,$3,$4,$4,$5,$5,$6,$7,$8,$8,$8
VxRowLo: !for r,0,24 { !byte <(VortexBase + r*40) }
VxRowHi: !for r,0,24 { !byte >(VortexBase + r*40) }
!zone

; ============================================================================
;  PART 6 : XOR MOIRE  (sharp interference diamonds in colour RAM)
; ============================================================================
!zone xormoire
xr_pa !byte 0
xr_pb !byte 0

xr_init:
        ldx #0
        lda #$a0
.f:     sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        inx
        bne .f
        ldx #0
.f2:    sta SCREEN+$300,x       ; rows 0..23 only
        inx
        cpx #192
        bne .f2
        lda #0
        sta xr_pa
        sta xr_pb
        rts

xr_update:
        lda xr_pa : clc : adc #1 : adc TV_FlashI : sta xr_pa   ; beat surge
        lda xr_pb : clc : adc #2 : sta xr_pb
        lda #0
        sta ET2                 ; row
.row:
        ldx ET2
        lda ColRowLo,x
        sta CPTR
        lda ColRowHi,x
        sta CPTR_HI
        txa
        clc
        adc xr_pb
        sta ET1                 ; rowval = row + pb
        ldy #39
.col:
        tya
        clc
        adc xr_pa
        eor ET1                 ; (col+pa) XOR (row+pb)
        and #$0f
        tax
        lda PAL16,x
        sta (CPTR),y
        dey
        bpl .col
        inc ET2
        lda ET2
        cmp #24
        bne .row
        rts
!zone

; ============================================================================
;  PART 7 : WAVES  (sine-displaced horizontal colour bands)
; ============================================================================
!zone waves
wv_p1 !byte 0          ; wave scroll phase
wv_p2 !byte 0          ; colour drift
wv_colbuf !fill 40,0

wv_init:
        ldx #0
        lda #$a0
.f:     sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        inx
        bne .f
        ldx #0
.f2:    sta SCREEN+$300,x
        inx
        cpx #192
        bne .f2
        lda #0
        sta wv_p1
        sta wv_p2
        rts

wv_update:
        lda wv_p1 : clc : adc #3 : adc TV_FlashI : sta wv_p1   ; beat surge
        lda wv_p2 : clc : adc #1 : sta wv_p2
        ; per-column vertical displacement: colbuf[c] = Sin256[(c*4+p1)] >> 3
        ldx #39
.cb:    txa
        asl
        asl
        clc
        adc wv_p1
        tay
        lda Sin256,y
        lsr
        lsr
        lsr
        sta wv_colbuf,x
        dex
        bpl .cb
        lda #0
        sta ET2                 ; row
.row:
        ldx ET2
        lda ColRowLo,x
        sta CPTR
        lda ColRowHi,x
        sta CPTR_HI
        ldy #39
.col:
        lda wv_colbuf,y
        clc
        adc ET2                 ; + row -> horizontal bands waved per column
        clc
        adc wv_p2               ; colour drift
        and #$0f
        tax
        lda PAL16,x
        sta (CPTR),y
        dey
        bpl .col
        inc ET2
        lda ET2
        cmp #24
        bne .row
        rts
!zone

; ============================================================================
;  PART 8 : PERSPECTIVE TUNNEL  (XMUL perspective + barrel warp + forward Z)
;  Integrated from the TunnelVoyager sources (deepseek v1.6 / spiraldrive).
;  Colour-only on a solid block field, so no custom charset is needed.
; ============================================================================
!zone tunnel
tn_z      !byte 0          ; forward depth scroll
tn_yaw    !byte 0          ; horizontal sweep
tn_col    !byte 0          ; colour drift
tn_frame  !byte 0

tn_init:
        ldx #0
        lda #$a0
.f:     sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        inx
        bne .f
        ldx #0
.f2:    sta SCREEN+$300,x       ; rows 0..23 only; row 24 = scroller
        inx
        cpx #192
        bne .f2
        lda #0
        sta tn_z
        sta tn_yaw
        sta tn_col
        sta tn_frame
        rts

tn_update:
        ; forward motion (+ beat lurch) + gentle yaw sweep + colour drift
        lda tn_z   : clc : adc #3 : adc TV_FlashI : sta tn_z
        inc tn_frame
        lda tn_frame
        lsr
        and #$3f
        tax
        lda Sin256,x            ; 0..31 -> yaw sweep
        sta tn_yaw
        lda tn_frame
        and #$03
        bne .nocol
        inc tn_col
.nocol:
        lda #0
        sta ET2                 ; row
.row:
        ldx ET2
        lda ColRowLo,x : sta CPTR
        lda ColRowHi,x : sta CPTR_HI
        lda TnXMRowLo,x : sta TXTP
        lda TnXMRowHi,x : sta TXTP_HI
        lda TnRowBase,x
        clc
        adc tn_z
        sta ET1                 ; RowDynBase = RowBase[row] + Z
        ldy #39
.col:
        lda (TXTP),y            ; xmul[row][col]
        clc
        adc ET1                 ; + depth
        clc
        adc TnColWarp,y         ; + barrel warp
        clc
        adc tn_yaw              ; + yaw
        lsr
        lsr
        lsr
        clc
        adc tn_col              ; colour drift
        and #$0f
        tax
        lda PAL16,x
        sta (CPTR),y
        dey
        bpl .col
        inc ET2
        lda ET2
        cmp #24
        bne .row
        rts

TnRowBase:
        !byte 0,1,2,4,6,9,12,16,21,27,34,42,51,61,72,84,97,111,126,142,159,177,196,216,237
TnColWarp:
        !byte 0,2,4,6,8,9,10,10,9,8,6,4,2,0,254,252,250,248,247,246,246,247,248,250,252,254,0,2,4,6,8,9,10,10,9,8,6,4,2,0
TnXMul:
        !byte $d8,$da,$dc,$de,$e0,$e2,$e4,$e6,$e8,$ea,$ec,$ee,$f0,$f2,$f4,$f6,$f8,$fa,$fc,$fe,$00,$02,$04,$06,$08,$0a,$0c,$0e,$10,$12,$14,$16,$18,$1a,$1c,$1e,$20,$22,$24,$26
        !byte $d8,$da,$dc,$de,$e0,$e2,$e4,$e6,$e8,$ea,$ec,$ee,$f0,$f2,$f4,$f6,$f8,$fa,$fc,$fe,$00,$02,$04,$06,$08,$0a,$0c,$0e,$10,$12,$14,$16,$18,$1a,$1c,$1e,$20,$22,$24,$26
        !byte $c4,$c7,$ca,$cd,$d0,$d3,$d6,$d9,$dc,$df,$e2,$e5,$e8,$eb,$ee,$f1,$f4,$f7,$fa,$fd,$00,$03,$06,$09,$0c,$0f,$12,$15,$18,$1b,$1e,$21,$24,$27,$2a,$2d,$30,$33,$36,$39
        !byte $c4,$c7,$ca,$cd,$d0,$d3,$d6,$d9,$dc,$df,$e2,$e5,$e8,$eb,$ee,$f1,$f4,$f7,$fa,$fd,$00,$03,$06,$09,$0c,$0f,$12,$15,$18,$1b,$1e,$21,$24,$27,$2a,$2d,$30,$33,$36,$39
        !byte $b0,$b4,$b8,$bc,$c0,$c4,$c8,$cc,$d0,$d4,$d8,$dc,$e0,$e4,$e8,$ec,$f0,$f4,$f8,$fc,$00,$04,$08,$0c,$10,$14,$18,$1c,$20,$24,$28,$2c,$30,$34,$38,$3c,$40,$44,$48,$4c
        !byte $b0,$b4,$b8,$bc,$c0,$c4,$c8,$cc,$d0,$d4,$d8,$dc,$e0,$e4,$e8,$ec,$f0,$f4,$f8,$fc,$00,$04,$08,$0c,$10,$14,$18,$1c,$20,$24,$28,$2c,$30,$34,$38,$3c,$40,$44,$48,$4c
        !byte $9c,$a1,$a6,$ab,$b0,$b5,$ba,$bf,$c4,$c9,$ce,$d3,$d8,$dd,$e2,$e7,$ec,$f1,$f6,$fb,$00,$05,$0a,$0f,$14,$19,$1e,$23,$28,$2d,$32,$37,$3c,$41,$46,$4b,$50,$55,$5a,$5f
        !byte $9c,$a1,$a6,$ab,$b0,$b5,$ba,$bf,$c4,$c9,$ce,$d3,$d8,$dd,$e2,$e7,$ec,$f1,$f6,$fb,$00,$05,$0a,$0f,$14,$19,$1e,$23,$28,$2d,$32,$37,$3c,$41,$46,$4b,$50,$55,$5a,$5f
        !byte $88,$8e,$94,$9a,$a0,$a6,$ac,$b2,$b8,$be,$c4,$ca,$d0,$d6,$dc,$e2,$e8,$ee,$f4,$fa,$00,$06,$0c,$12,$18,$1e,$24,$2a,$30,$36,$3c,$42,$48,$4e,$54,$5a,$60,$66,$6c,$72
        !byte $88,$8e,$94,$9a,$a0,$a6,$ac,$b2,$b8,$be,$c4,$ca,$d0,$d6,$dc,$e2,$e8,$ee,$f4,$fa,$00,$06,$0c,$12,$18,$1e,$24,$2a,$30,$36,$3c,$42,$48,$4e,$54,$5a,$60,$66,$6c,$72
        !byte $74,$7b,$82,$89,$90,$97,$9e,$a5,$ac,$b3,$ba,$c1,$c8,$cf,$d6,$dd,$e4,$eb,$f2,$f9,$00,$07,$0e,$15,$1c,$23,$2a,$31,$38,$3f,$46,$4d,$54,$5b,$62,$69,$70,$77,$7e,$85
        !byte $74,$7b,$82,$89,$90,$97,$9e,$a5,$ac,$b3,$ba,$c1,$c8,$cf,$d6,$dd,$e4,$eb,$f2,$f9,$00,$07,$0e,$15,$1c,$23,$2a,$31,$38,$3f,$46,$4d,$54,$5b,$62,$69,$70,$77,$7e,$85
        !byte $60,$68,$70,$78,$80,$88,$90,$98,$a0,$a8,$b0,$b8,$c0,$c8,$d0,$d8,$e0,$e8,$f0,$f8,$00,$08,$10,$18,$20,$28,$30,$38,$40,$48,$50,$58,$60,$68,$70,$78,$80,$88,$90,$98
        !byte $60,$68,$70,$78,$80,$88,$90,$98,$a0,$a8,$b0,$b8,$c0,$c8,$d0,$d8,$e0,$e8,$f0,$f8,$00,$08,$10,$18,$20,$28,$30,$38,$40,$48,$50,$58,$60,$68,$70,$78,$80,$88,$90,$98
        !byte $74,$7b,$82,$89,$90,$97,$9e,$a5,$ac,$b3,$ba,$c1,$c8,$cf,$d6,$dd,$e4,$eb,$f2,$f9,$00,$07,$0e,$15,$1c,$23,$2a,$31,$38,$3f,$46,$4d,$54,$5b,$62,$69,$70,$77,$7e,$85
        !byte $74,$7b,$82,$89,$90,$97,$9e,$a5,$ac,$b3,$ba,$c1,$c8,$cf,$d6,$dd,$e4,$eb,$f2,$f9,$00,$07,$0e,$15,$1c,$23,$2a,$31,$38,$3f,$46,$4d,$54,$5b,$62,$69,$70,$77,$7e,$85
        !byte $88,$8e,$94,$9a,$a0,$a6,$ac,$b2,$b8,$be,$c4,$ca,$d0,$d6,$dc,$e2,$e8,$ee,$f4,$fa,$00,$06,$0c,$12,$18,$1e,$24,$2a,$30,$36,$3c,$42,$48,$4e,$54,$5a,$60,$66,$6c,$72
        !byte $88,$8e,$94,$9a,$a0,$a6,$ac,$b2,$b8,$be,$c4,$ca,$d0,$d6,$dc,$e2,$e8,$ee,$f4,$fa,$00,$06,$0c,$12,$18,$1e,$24,$2a,$30,$36,$3c,$42,$48,$4e,$54,$5a,$60,$66,$6c,$72
        !byte $9c,$a1,$a6,$ab,$b0,$b5,$ba,$bf,$c4,$c9,$ce,$d3,$d8,$dd,$e2,$e7,$ec,$f1,$f6,$fb,$00,$05,$0a,$0f,$14,$19,$1e,$23,$28,$2d,$32,$37,$3c,$41,$46,$4b,$50,$55,$5a,$5f
        !byte $9c,$a1,$a6,$ab,$b0,$b5,$ba,$bf,$c4,$c9,$ce,$d3,$d8,$dd,$e2,$e7,$ec,$f1,$f6,$fb,$00,$05,$0a,$0f,$14,$19,$1e,$23,$28,$2d,$32,$37,$3c,$41,$46,$4b,$50,$55,$5a,$5f
        !byte $b0,$b4,$b8,$bc,$c0,$c4,$c8,$cc,$d0,$d4,$d8,$dc,$e0,$e4,$e8,$ec,$f0,$f4,$f8,$fc,$00,$04,$08,$0c,$10,$14,$18,$1c,$20,$24,$28,$2c,$30,$34,$38,$3c,$40,$44,$48,$4c
        !byte $b0,$b4,$b8,$bc,$c0,$c4,$c8,$cc,$d0,$d4,$d8,$dc,$e0,$e4,$e8,$ec,$f0,$f4,$f8,$fc,$00,$04,$08,$0c,$10,$14,$18,$1c,$20,$24,$28,$2c,$30,$34,$38,$3c,$40,$44,$48,$4c
        !byte $c4,$c7,$ca,$cd,$d0,$d3,$d6,$d9,$dc,$df,$e2,$e5,$e8,$eb,$ee,$f1,$f4,$f7,$fa,$fd,$00,$03,$06,$09,$0c,$0f,$12,$15,$18,$1b,$1e,$21,$24,$27,$2a,$2d,$30,$33,$36,$39
        !byte $c4,$c7,$ca,$cd,$d0,$d3,$d6,$d9,$dc,$df,$e2,$e5,$e8,$eb,$ee,$f1,$f4,$f7,$fa,$fd,$00,$03,$06,$09,$0c,$0f,$12,$15,$18,$1b,$1e,$21,$24,$27,$2a,$2d,$30,$33,$36,$39
        !byte $d8,$da,$dc,$de,$e0,$e2,$e4,$e6,$e8,$ea,$ec,$ee,$f0,$f2,$f4,$f6,$f8,$fa,$fc,$fe,$00,$02,$04,$06,$08,$0a,$0c,$0e,$10,$12,$14,$16,$18,$1a,$1c,$1e,$20,$22,$24,$26
TnXMRowLo: !for r,0,24 { !byte <(TnXMul + r*40) }
TnXMRowHi: !for r,0,24 { !byte >(TnXMul + r*40) }
!zone

; ============================================================================
;  PART 9 : FIRE  (Doom-style rising fire on the colour RAM)
; ============================================================================

;  >>> imported textmode engines (beat-reactive) <<<

; ============================================================================
;  ACTIVE PART 0 : TEXT WIREFRAME / cube grid
;  Source idea: wireframe/cube engines, adapted to textmode row-safe grid.
; ============================================================================
!zone tunnelsafeinline
ts_phase !byte 0
ts_row   !byte 0
ts_init:
        jsr ClearScreenColor
        lda #0
        sta ts_phase
        rts
ts_update:
        ; Fixed tunnel renderer: row-24 safe, centered, beat/sine driven and
        ; deterministic. The previous variant sampled the generic DistBase in a
        ; way that could look like broken/noisy rings. This one makes depth bands
        ; from distance + phase + wobble + zoomPulse, so the tunnel reads as a
        ; proper forward-moving bass-synced corridor.
        inc ts_phase
        lda #0
        sta ts_row
.ts_row_loop:
        ldx ts_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda DistLo,x
        sta TXTP
        lda DistHi,x
        sta TXTP_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.ts_col_loop:
        ; base radial distance from shared 40x25 distance table
        lda (TXTP),y
        asl
        sta ET0

        ; column wobble: wraps 0..31 and adds signed wobble byte
        tya
        clc
        adc ts_phase
        adc beatSin
        and #$1f
        tax
        lda SafeWobble32,x
        clc
        adc ET0
        sta ET0

        ; forward motion + techno zoom pulse
        lda ts_phase
        lsr
        clc
        adc zoomPulse
        adc ET0
        and #$0f
        tax

        ; character ramp: sparse outside, dense in the virtual center
        lda SafeTunnelChars,x
        sta (SPTR),y

        ; colour is separate from char index, so it does not alias badly
        txa
        clc
        adc musicPulse
        adc ts_row
        and #$0f
        tax
        lda SafeTunnelColors,x
        sta (CPTR),y

        dey
        bmi .ts_row_done
        jmp .ts_col_loop
.ts_row_done:
        inc ts_row
        lda ts_row
        cmp #24
        beq .ts_done
        jmp .ts_row_loop
.ts_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 1 : HEART VOYAGER / golden trail heart
; ----------------------------------------------------------------------------
;  Own effect adapted from heartvoyager.asm.  It keeps the already requested
;  golden identity, but adds the Voyager-style trail/halo layer as a separate
;  part rather than replacing GOLDEN HEART.
; ============================================================================
!zone heartvoyagertrail
hv_phase !byte 0
hv_row   !byte 0
hv_init:
        jsr ClearScreenColor
        lda #0
        sta hv_phase
        lda #$08
        sta BORDER
        rts
hv_update:
        inc hv_phase
        lda musicPulse
        and #$01
        beq .hv_nx
        inc hv_phase
.hv_nx:
        lda #0
        sta hv_row
.hv_row_loop:
        ldx hv_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        lda HeartShapeLo,x
        sta TXTP
        lda HeartShapeHi,x
        sta TXTP_HI
        ldy #39
.hv_col_loop:
        lda (TXTP),y            ; heart mask: 1 = inside heart, 0 = outside
        bne .hv_inside
        lda hv_phase
        clc
        adc hv_row
        adc beatSin
        and #$07
        tax
        lda HeartTrailChars,x
        sta (SPTR),y
        lda #$00
        sta (CPTR),y
        jmp .hv_next
.hv_inside:
        lda hv_phase
        clc
        adc hv_row
        adc beatSin
        and #$03
        tax
        lda HeartChars,x
        sta (SPTR),y
        lda hv_phase
        clc
        adc hv_row
        adc musicPulse
        and #$0f
        tax
        lda HeartVoyagerGold,x
        sta (CPTR),y
.hv_next:
        dey
        bmi .hv_row_done
        jmp .hv_col_loop
.hv_row_done:
        inc hv_row
        lda hv_row
        cmp #24
        beq .hv_done
        jmp .hv_row_loop
.hv_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 2 : MULTIPLEX CUBE / sprite-mux idea in textmode
; ----------------------------------------------------------------------------
;  Own effect from cube_mc_sprite_multiplex_v2_nodupmac.zip concepts. The
;  uploaded code owns bitmap/sprite banks; this keeps only the multiplexed edge
;  timing idea and renders it as fast textmode bars/edges.
; ============================================================================
!zone multiplexcube
mc_phase !byte 0
mc_row   !byte 0
mc_init:
        jsr ClearScreenColor
        lda #0
        sta mc_phase
        rts
mc_update:
        inc mc_phase
        lda musicPulse
        and #$03
        bne .mc_no_extra_phase
        inc mc_phase
.mc_no_extra_phase:
        lda #0
        sta mc_row
.mc_row_loop:
        ldx mc_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.mc_col_loop:
        tya
        clc
        adc mc_phase
        adc beatSin
        eor mc_row
        and #$0f
        cmp #2
        bcc .mc_edge
        tya
        sec
        sbc mc_row
        clc
        adc mc_phase
        and #$1f
        cmp #3
        bcc .mc_edge
        lda #$20
        sta (SPTR),y
        lda #0
        sta (CPTR),y
        jmp .mc_next
.mc_edge:
        lda mc_phase
        clc
        adc mc_row
        adc zoomPulse
        and #$07
        tax
        lda MultiplexCubeChars,x
        sta (SPTR),y
        txa
        clc
        adc mc_phase
        adc musicPulse
        and #$0f
        tax
        lda MultiplexCubeColors,x
        sta (CPTR),y
.mc_next:
        dey
        bmi .mc_row_done
        jmp .mc_col_loop
.mc_row_done:
        inc mc_row
        lda mc_row
        cmp #24
        beq .mc_done
        jmp .mc_row_loop
.mc_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 3 : RASTER BOOT TUNNEL / safe h-scroll tunnel
; ----------------------------------------------------------------------------
;  Own effect adapted from tunnel_raster_safe_boot_v3.s: robust raster-safe
;  tunnel logic and smooth h-scroll/control ideas.  No IRQ takeover is imported;
;  UpdatePart calls SetupVIC first, then this part applies only safe $D016 scroll.
; ============================================================================
!zone rasterboottunnel
rb_phase !byte 0
rb_row   !byte 0
rb_init:
        jsr ClearScreenColor
        lda #0
        sta rb_phase
        rts
rb_update:
        inc rb_phase
        lda musicPulse
        and #$01
        beq .rb_no_extra_phase
        inc rb_phase
.rb_no_extra_phase:
        lda rb_phase
        and #$07
        ora #$08
        sta VIC_CTRL2
        lda #0
        sta rb_row
.rb_row_loop:
        ldx rb_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda DistLo,x
        sta TXTP
        lda DistHi,x
        sta TXTP_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.rb_col_loop:
        lda (TXTP),y
        clc
        adc rb_phase
        adc rb_row
        adc zoomPulse
        adc beatSin
        and #$0f
        tax
        lda RasterBootChars,x
        sta (SPTR),y
        txa
        clc
        adc rb_phase
        adc rb_row
        adc musicPulse
        and #$0f
        tax
        lda RasterBootColors,x
        sta (CPTR),y
        dey
        bmi .rb_row_done
        jmp .rb_col_loop
.rb_row_done:
        inc rb_row
        lda rb_row
        cmp #24
        beq .rb_done
        jmp .rb_row_loop
.rb_done:
        rts
!zone


; ============================================================================
;  ACTIVE PART 4 : YAW WOBBLE TUNNEL / no-SMC yaw+column wobble variant
; ----------------------------------------------------------------------------
;  Further source-kilde integration from tunnel_engine_no_smc_fixed.s: auto-yaw,
;  column wobble and per-cell tint, adapted to the shared MegaDemo text engine.
; ============================================================================
!zone yawwobbletunnel
yw_phase !byte 0
yw_row   !byte 0
yw_init:
        jsr ClearScreenColor
        lda #0
        sta yw_phase
        rts
yw_update:
        inc yw_phase
        lda musicPulse
        and #$01
        beq .yw_no_extra_phase
        inc yw_phase
.yw_no_extra_phase:
        lda yw_phase
        lsr
        lsr
        and #$0f
        sta BORDER
        lda #0
        sta yw_row
.yw_row_loop:
        ldx yw_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda DistLo,x
        sta TXTP
        lda DistHi,x
        sta TXTP_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.yw_col_loop:
        tya
        clc
        adc yw_phase
        adc beatSin
        and #$1f
        tax
        lda SafeWobble32,x
        sta ET1
        lda (TXTP),y
        clc
        adc ET1
        adc yw_row
        adc yw_phase
        adc zoomPulse
        and #$0f
        tax
        lda SafeTunnelChars,x
        sta (SPTR),y
        txa
        clc
        adc yw_phase
        adc ET1
        adc musicPulse
        and #$0f
        tax
        lda SafeTunnelColors,x
        sta (CPTR),y
        dey
        bmi .yw_row_done
        jmp .yw_col_loop
.yw_row_done:
        inc yw_row
        lda yw_row
        cmp #24
        beq .yw_done
        jmp .yw_row_loop
.yw_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 5 : TURBO BOOT TUNNEL / raster-safe turbo feel
; ----------------------------------------------------------------------------
;  Takes the useful smooth/turbo control idea from tunnel_raster_safe_boot_v3.s
;  and expresses it as a deterministic auto-turbo textmode zoom engine.
; ============================================================================
!zone turboboottunnel
tb_phase !byte 0
tb_row   !byte 0
tb_init:
        jsr ClearScreenColor
        lda #0
        sta tb_phase
        rts
tb_update:
        inc tb_phase
        inc tb_phase              ; turbo tunnel always moves faster
        lda musicPulse
        and #$01
        beq .tb_no_extra_phase
        inc tb_phase
.tb_no_extra_phase:
        lda tb_phase
        and #$07
        ora #$08
        sta VIC_CTRL2
        lda #0
        sta tb_row
.tb_row_loop:
        ldx tb_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda DistLo,x
        sta TXTP
        lda DistHi,x
        sta TXTP_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.tb_col_loop:
        lda (TXTP),y
        asl
        clc
        adc tb_phase
        adc tb_row
        adc zoomPulse
        adc beatSin
        and #$0f
        tax
        lda RasterBootChars,x
        sta (SPTR),y
        txa
        clc
        adc tb_phase
        adc musicPulse
        and #$0f
        tax
        lda TunnelZoomColors,x
        sta (CPTR),y
        dey
        bmi .tb_row_done
        jmp .tb_col_loop
.tb_row_done:
        inc tb_row
        lda tb_row
        cmp #24
        beq .tb_done
        jmp .tb_row_loop
.tb_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 6 : GOLDEN HALO HEART / own heart-voyager halo layer
; ----------------------------------------------------------------------------
;  Extra own effect from heartvoyager.asm ideas: the center is sparse, the halo
;  is golden and animated, so it reads differently from HEART VOYAGER TRAIL.
; ============================================================================
!zone goldenhaloheart
gh_phase !byte 0
gh_row   !byte 0
gh_init:
        jsr ClearScreenColor
        lda #$08
        sta BORDER
        lda #0
        sta gh_phase
        rts
gh_update:
        inc gh_phase
        lda musicPulse
        and #$01
        beq .gh_no_extra_phase
        inc gh_phase
.gh_no_extra_phase:
        lda #0
        sta gh_row
.gh_row_loop:
        ldx gh_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        lda HeartWidth,x
        clc
        adc zoomPulse
        lsr
        lsr
        adc #4
        sta ET1
        ldy #39
.gh_col_loop:
        tya
        cmp #20
        bcc .gh_left
        sec
        sbc #20
        jmp .gh_abs_ok
.gh_left:
        eor #$ff
        clc
        adc #21
.gh_abs_ok:
        cmp ET1
        bcc .gh_inside
        lda #$20
        sta (SPTR),y
        lda #0
        sta (CPTR),y
        jmp .gh_next
.gh_inside:
        eor gh_phase
        adc beatSin
        and #$07
        tax
        lda GoldenHaloChars,x
        sta (SPTR),y
        lda gh_phase
        clc
        adc gh_row
        adc ET1
        adc musicPulse
        and #$0f
        tax
        lda HeartVoyagerGold,x
        sta (CPTR),y
.gh_next:
        dey
        bmi .gh_row_done
        jmp .gh_col_loop
.gh_row_done:
        inc gh_row
        lda gh_row
        cmp #24
        beq .gh_done
        jmp .gh_row_loop
.gh_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 7 : MUX EDGE FIELD / multiplexed edge bars
; ----------------------------------------------------------------------------
;  Extra cube/sprite-multiplex-source idea: alternating horizontal/vertical edge
;  bands, converted from sprite timing into textmode geometry.
; ============================================================================
!zone muxedgefield
mb_phase !byte 0
mb_row   !byte 0
mb_init:
        jsr ClearScreenColor
        lda #0
        sta mb_phase
        rts
mb_update:
        inc mb_phase
        lda musicPulse
        and #$03
        bne .mb_no_extra_phase
        inc mb_phase
.mb_no_extra_phase:
        lda #0
        sta mb_row
.mb_row_loop:
        ldx mb_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.mb_col_loop:
        tya
        eor mb_row
        clc
        adc mb_phase
        adc beatSin
        and #$0f
        cmp #3
        bcc .mb_edge
        tya
        clc
        adc mb_phase
        and #$07
        cmp #1
        bcc .mb_edge
        lda #$20
        sta (SPTR),y
        lda #0
        sta (CPTR),y
        jmp .mb_next
.mb_edge:
        lda mb_phase
        clc
        adc mb_row
        adc zoomPulse
        and #$07
        tax
        lda MultiplexCubeChars,x
        sta (SPTR),y
        lda mb_phase
        clc
        adc mb_row
        adc #$04
        adc musicPulse
        and #$0f
        tax
        lda MultiplexCubeColors,x
        sta (CPTR),y
.mb_next:
        dey
        bmi .mb_row_done
        jmp .mb_col_loop
.mb_row_done:
        inc mb_row
        lda mb_row
        cmp #24
        beq .mb_done
        jmp .mb_row_loop
.mb_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 8 : RASTER GRID BOOT / safe perspective boot grid
; ----------------------------------------------------------------------------
;  Extra raster-safe boot tunnel source idea: no IRQ takeover, no standalone
;  loop; only the safe boot-grid visual language is kept.
; ============================================================================
!zone rastergridboot
rg_phase !byte 0
rg_row   !byte 0
rg_init:
        jsr ClearScreenColor
        lda #0
        sta rg_phase
        rts
rg_update:
        inc rg_phase
        lda musicPulse
        and #$01
        beq .rg_no_extra_phase
        inc rg_phase
.rg_no_extra_phase:
        lda #0
        sta rg_row
.rg_row_loop:
        ldx rg_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.rg_col_loop:
        tya
        clc
        adc rg_phase
        adc beatSin
        and #$07
        beq .rg_line
        lda rg_row
        clc
        adc rg_phase
        adc zoomPulse
        and #$07
        beq .rg_line
        tya
        sec
        sbc rg_row
        clc
        adc rg_phase
        and #$0f
        cmp #1
        beq .rg_line
        lda #$20
        sta (SPTR),y
        lda #0
        sta (CPTR),y
        jmp .rg_next
.rg_line:
        lda rg_phase
        clc
        adc rg_row
        adc zoomPulse
        and #$07
        tax
        lda GridChars,x
        sta (SPTR),y
        txa
        clc
        adc rg_phase
        adc musicPulse
        and #$0f
        tax
        lda GridColors,x
        sta (CPTR),y
.rg_next:
        dey
        bmi .rg_row_done
        jmp .rg_col_loop
.rg_row_done:
        inc rg_row
        lda rg_row
        cmp #24
        beq .rg_done
        jmp .rg_row_loop
.rg_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 9 : CYBER GRID / neon matrix floor from source material
; ============================================================================
!zone cybergrid
cg_phase !byte 0
cg_row   !byte 0
cg_init:
        jsr ClearScreenColor
        lda #0
        sta cg_phase
        rts
cg_update:
        inc cg_phase
        lda musicPulse
        and #$01
        beq .cg_no_extra_phase
        inc cg_phase
.cg_no_extra_phase:
        lda #0
        sta cg_row
.cg_row_loop:
        ldx cg_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.cg_col_loop:
        tya
        eor cg_row
        clc
        adc cg_phase
        adc beatSin
        and #$07
        beq .cg_line
        tya
        clc
        adc cg_phase
        adc zoomPulse
        and #$0f
        cmp #1
        beq .cg_line
        lda #$20
        sta (SPTR),y
        lda #0
        sta (CPTR),y
        jmp .cg_next
.cg_line:
        lda cg_phase
        clc
        adc cg_row
        adc musicPulse
        and #$0f
        tax
        lda CyberGridChars,x
        sta (SPTR),y
        txa
        clc
        adc cg_phase
        adc beatSin
        and #$0f
        tax
        lda CyberColors,x
        sta (CPTR),y
.cg_next:
        dey
        bmi .cg_row_done
        jmp .cg_col_loop
.cg_row_done:
        inc cg_row
        lda cg_row
        cmp #24
        beq .cg_done
        jmp .cg_row_loop
.cg_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 10 : SAFE TUNNEL PRIME / no-SMC wobble tunnel variant
; ============================================================================
!zone safetunnelprime
sp_phase !byte 0
sp_row   !byte 0
sp_init:
        jsr ClearScreenColor
        lda #0
        sta sp_phase
        rts
sp_update:
        inc sp_phase
        lda musicPulse
        and #$01
        beq .sp_no_extra_phase
        inc sp_phase
.sp_no_extra_phase:
        lda #0
        sta sp_row
.sp_row_loop:
        ldx sp_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.sp_col_loop:
        tya
        clc
        adc sp_phase
        adc beatSin
        and #$1f
        tax
        lda SafeWobble32,x
        clc
        adc sp_row
        adc sp_phase
        adc zoomPulse
        and #$0f
        tax
        lda SafeTunnelPrimeChars,x
        sta (SPTR),y
        txa
        clc
        adc sp_phase
        adc musicPulse
        and #$0f
        tax
        lda CyberColors,x
        sta (CPTR),y
        dey
        bmi .sp_row_done
        jmp .sp_col_loop
.sp_row_done:
        inc sp_row
        lda sp_row
        cmp #24
        beq .sp_done
        jmp .sp_row_loop
.sp_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 11 : BLACK ORBIT FIELD / black-hole orbital fold
; ============================================================================
!zone blackorbit
bo_phase !byte 0
bo_row   !byte 0
bo_init:
        jsr ClearScreenColor
        lda #0
        sta bo_phase
        rts
bo_update:
        inc bo_phase
        lda musicPulse
        and #$01
        beq .bo_no_extra_phase
        inc bo_phase
.bo_no_extra_phase:
        lda #0
        sta bo_row
.bo_row_loop:
        ldx bo_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        lda DistLo,x
        sta TXTP
        lda DistHi,x
        sta TXTP_HI
        ldy #39
.bo_col_loop:
        lda (TXTP),y
        clc
        adc bo_phase
        adc beatSin
        adc zoomPulse
        and #$0f
        tax
        lda BlackOrbitMask,x
        beq .bo_gap
        lda BlackOrbitChars,x
        sta (SPTR),y
        txa
        clc
        adc bo_phase
        adc musicPulse
        and #$0f
        tax
        lda BlackOrbitColors,x
        sta (CPTR),y
        jmp .bo_next
.bo_gap:
        lda #$20
        sta (SPTR),y
        lda #0
        sta (CPTR),y
.bo_next:
        dey
        bmi .bo_row_done
        jmp .bo_col_loop
.bo_row_done:
        inc bo_row
        lda bo_row
        cmp #24
        beq .bo_done
        jmp .bo_row_loop
.bo_done:
        rts
!zone

; ============================================================================
;  ACTIVE PART 12 : ROTOR CUBE FINAL / corrected last rotating effect
; ============================================================================
!zone rotorcube
rc_phase !byte 0
rc_row   !byte 0
rc_fx0   !byte 0
rc_fx1   !byte 0
rc_fy0   !byte 0
rc_fy1   !byte 0
rc_bx0   !byte 0
rc_bx1   !byte 0
rc_by0   !byte 0
rc_by1   !byte 0
rc_hit   !byte 0

rc_init:
        jsr ClearScreenColor
        lda #0
        sta rc_phase
        rts

; Corrected rotating cube: the old final effect was mostly XOR diagonals, so it
; looked like a random rotor.  This version uses a real 16-step rotation state:
; two projected rectangles (front/back) move against each other and the renderer
; draws their horizontal/vertical edges plus connector-style phase diagonals.
; It stays textmode-only and row-24-safe.
rc_update:
        ; Use a real 16-state projection.  musicPulse controls rotation speed
        ; while zoomPulse bends the projected front/back rectangles.
        inc rc_phase
        lda musicPulse
        and #$03
        beq .rc_single_step
        inc rc_phase
.rc_single_step:
        lda rc_phase
        clc
        adc zoomPulse            ; beat/sine zoom bends the 16-step projection
        and #$0f
        tax
        lda RcFrontX0,x
        sta rc_fx0
        lda RcFrontX1,x
        sta rc_fx1
        lda RcFrontY0,x
        sta rc_fy0
        lda RcFrontY1,x
        sta rc_fy1
        lda RcBackX0,x
        sta rc_bx0
        lda RcBackX1,x
        sta rc_bx1
        lda RcBackY0,x
        sta rc_by0
        lda RcBackY1,x
        sta rc_by1

        lda #0
        sta rc_row
.rc_row_loop:
        ldx rc_row
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.rc_col_loop:
        lda #0
        sta rc_hit

        ; front square horizontal edges: row == fy0/fy1 and fx0 <= col <= fx1
        lda rc_row
        cmp rc_fy0
        beq .rc_try_front_h
        cmp rc_fy1
        bne .rc_front_v
.rc_try_front_h:
        cpy rc_fx0
        bcc .rc_front_v
        cpy rc_fx1
        beq .rc_mark_front
        bcc .rc_mark_front
.rc_front_v:
        ; front square vertical edges: col == fx0/fx1 and fy0 <= row <= fy1
        cpy rc_fx0
        beq .rc_try_front_v
        cpy rc_fx1
        bne .rc_back_h
.rc_try_front_v:
        lda rc_row
        cmp rc_fy0
        bcc .rc_back_h
        cmp rc_fy1
        beq .rc_mark_front
        bcc .rc_mark_front
        jmp .rc_back_h
.rc_mark_front:
        lda #1
        sta rc_hit
        jmp .rc_draw_hit

.rc_back_h:
        ; back square horizontal edges
        lda rc_row
        cmp rc_by0
        beq .rc_try_back_h
        cmp rc_by1
        bne .rc_back_v
.rc_try_back_h:
        cpy rc_bx0
        bcc .rc_back_v
        cpy rc_bx1
        beq .rc_mark_back
        bcc .rc_mark_back
.rc_back_v:
        ; back square vertical edges
        cpy rc_bx0
        beq .rc_try_back_v
        cpy rc_bx1
        bne .rc_diag
.rc_try_back_v:
        lda rc_row
        cmp rc_by0
        bcc .rc_diag
        cmp rc_by1
        beq .rc_mark_back
        bcc .rc_mark_back
        jmp .rc_diag
.rc_mark_back:
        lda #2
        sta rc_hit
        jmp .rc_draw_hit

.rc_diag:
        ; connector/rotation energy lines.  This is deliberately sparse so the
        ; cube remains readable and not a full-screen XOR hiss effect.
        tya
        clc
        adc rc_row
        adc rc_phase
        adc beatSin
        and #$1f
        cmp #0
        beq .rc_mark_diag
        tya
        sec
        sbc rc_row
        clc
        adc rc_phase
        adc zoomPulse
        and #$1f
        cmp #0
        bne .rc_blank
.rc_mark_diag:
        lda #3
        sta rc_hit
        jmp .rc_draw_hit

.rc_blank:
        lda #$20
        sta (SPTR),y
        lda #0
        sta (CPTR),y
        jmp .rc_next

.rc_draw_hit:
        lda rc_hit
        clc
        adc rc_phase
        and #$07
        tax
        lda RotorCubeChars,x
        sta (SPTR),y
        txa
        clc
        adc rc_phase
        adc musicPulse
        and #$0f
        tax
        lda RotorCubeColors,x
        sta (CPTR),y

.rc_next:
        dey
        bmi .rc_row_done
        jmp .rc_col_loop
.rc_row_done:
        inc rc_row
        lda rc_row
        cmp #24
        beq .rc_done
        jmp .rc_row_loop
.rc_done:
        rts
!zone

; ============================================================================
;  Ported full-3D cube + distance-field engines (from skip3_full3d zip)
;  beat-reactive via musicPulse / zoomPulse; row-24 safe.
; ============================================================================
EFFECT_ROW_COUNT = 24
engineMode  !byte 0
enginePhase !byte 0
engineRow   !byte 0
engineCol   !byte 0

PortedInit:
        jsr ClearScreenColor
        lda #0
        sta enginePhase
        rts

; icy depth gradient (dark -> cyan -> white -> dark) so the wireframe reads as 3D
WireColors:      !byte $0b,$06,$0e,$03,$0d,$01,$0f,$0f,$01,$0d,$03,$0e,$06,$0b,$0c,$0c
SolarChars:      !byte $20,$2e,$2b,$2a,$e1,$e2,$e3,$e4,$e5,$e4,$e3,$e2,$e1,$2a,$2b,$2e
SolarColors:     !byte $00,$09,$08,$02,$0a,$07,$01,$07,$0a,$02,$08,$09,$0b,$0c,$0f,$0c
PrismGateChars:  !byte $20,$2e,$2b,$2a,$e0,$e1,$e2,$e3,$e4,$e5,$e3,$e2,$e1,$e0,$2a,$2b
PrismGateColors: !byte $06,$0e,$03,$0d,$01,$07,$0f,$07,$01,$0d,$03,$0e,$06,$0b,$0c,$0b
TwistChars:      !byte $2f,$5c,$2d,$2b,$e0,$e1,$e2,$e3
TwistColors:     !byte $00,$09,$08,$0a,$07,$01,$07,$0a,$08,$09,$08,$0a,$07,$01,$0a,$08
WireCubeChars:   !binary "wire_cube_chars.bin"
WireCubeMask:    !binary "wire_cube_mask.bin"
WireCubeCharLo: !for r,0,95 { !byte <(WireCubeChars + r*40) }
WireCubeCharHi: !for r,0,95 { !byte >(WireCubeChars + r*40) }
WireCubeMaskLo: !for r,0,95 { !byte <(WireCubeMask + r*40) }
WireCubeMaskHi: !for r,0,95 { !byte >(WireCubeMask + r*40) }
CubeFrameBase:   !byte 0,24,48,72


!zone full3dcube
WireframeGridRender:
        ; Fully 3D table-driven rotating wireframe cube.  The row atlas is indexed
        ; with true modulo-24, so every projected slice is used.
        sta engineMode
        lda zoomPulse           ; livelier beat-synced spin
        lsr
        clc
        adc #2
        adc enginePhase
        sta enginePhase
        lda #0
        sta engineRow
.wf_row:
        ldx engineRow
        cpx #EFFECT_ROW_COUNT
        bcc .wf_go
        jmp .wf_done
.wf_go:
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda ColRowLo,x
        sta CPTR
        lda ColRowHi,x
        sta CPTR_HI
        lda enginePhase
        lsr
        lsr
        lsr
        and #$03
        tax
        lda CubeFrameBase,x
        clc
        adc engineRow
        tax
        lda WireCubeCharLo,x
        sta ET0
        lda WireCubeCharHi,x
        sta ET1
        lda WireCubeMaskLo,x
        sta TXTP
        lda WireCubeMaskHi,x
        sta TXTP_HI
        lda beatSin             ; sine sway (smooth pendulum) instead of linear drift -> reads 3D
        lsr
        lsr
        lsr
        lsr
        lsr
        and #$07
        sta ET2
        ldy #39
.wf_cell:
        sty engineCol
        tya
        clc
        adc ET2
        cmp #40
        bcc .wf_samp
        sec
        sbc #40
.wf_samp:
        tay
        lda (TXTP),y
        sta ET3
        lda (ET0),y
        ldy engineCol
        ldx ET3
        beq .wf_blank
        sta (SPTR),y
        txa
        clc
        adc enginePhase
        adc musicPulse
        and #$0f
        tax
        lda WireColors,x
        sta (CPTR),y
        jmp .wf_next
.wf_blank:
        lda #$20
        sta (SPTR),y
        lda #$00
        sta (CPTR),y
.wf_next:
        ldy engineCol
        dey
        bpl .wf_cell
        inc engineRow
        jmp .wf_row
.wf_done:
        rts

!zone

!zone solarflare
SolarFlareRender:
        sta engineMode
        inc enginePhase
        lda #0
        sta engineRow
.sf_row:
        ldx engineRow
        cpx #EFFECT_ROW_COUNT
        bcc .sf_row_continue
        jmp .sf_done
.sf_row_continue:
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda ColRowLo,x
        sta CPTR
        lda ColRowHi,x
        sta CPTR_HI
        ldy #39
.sf_cell:
        tya
        sec
        sbc #20
        bcs .sf_x
        eor #$ff
        clc
        adc #1
.sf_x:
        sta ET2
        lda engineRow
        sec
        sbc #12
        bcs .sf_y
        eor #$ff
        clc
        adc #1
.sf_y:
        clc
        adc ET2
        eor enginePhase
        clc
        adc musicPulse
        and #$0f
        tax
        lda SolarChars,x
        sta (SPTR),y
        lda SolarColors,x
        sta (CPTR),y
        dey
        bpl .sf_cell
        inc engineRow
        jmp .sf_row
.sf_done:
        rts

!zone

!zone prismgate
PrismGateRender:
        sta engineMode
        inc enginePhase
        lda #0
        sta engineRow
.pg_row:
        ldx engineRow
        cpx #EFFECT_ROW_COUNT
        bcc .pg_row_continue
        jmp .pg_done
.pg_row_continue:
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda ColRowLo,x
        sta CPTR
        lda ColRowHi,x
        sta CPTR_HI
        ldy #39
.pg_cell:
        tya
        sec
        sbc #20
        bcs .pg_abs
        eor #$ff
        clc
        adc #1
.pg_abs:
        clc
        adc engineRow
        adc enginePhase
        clc
        adc musicPulse
        and #$0f
        tax
        lda PrismGateChars,x
        sta (SPTR),y
        lda PrismGateColors,x
        sta (CPTR),y
        dey
        bpl .pg_cell
        inc engineRow
        jmp .pg_row
.pg_done:
        rts

!zone

!zone twistlattice
TwistLatticeRender:
        sta engineMode
        inc enginePhase
        lda #0
        sta engineRow
.tl_row:
        ldx engineRow
        cpx #EFFECT_ROW_COUNT
        bcc .tl_row_continue
        jmp .tl_done
.tl_row_continue:
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda ColRowLo,x
        sta CPTR
        lda ColRowHi,x
        sta CPTR_HI
        ldy #39
.tl_cell:
        tya
        eor enginePhase
        eor engineRow
        and #$07
        tax
        lda TwistChars,x
        sta (SPTR),y
        txa
        clc
        adc enginePhase
        clc
        adc musicPulse
        and #$0f
        tax
        lda TwistColors,x
        sta (CPTR),y
        dey
        bpl .tl_cell
        inc engineRow
        jmp .tl_row
.tl_done:
        rts

!zone



; ============================================================================
;  Shared helpers
; ============================================================================
Rand8:
        lda rand8_s
        lsr
        bcc @nx
        eor #$b4
@nx:    sta rand8_s
        lda rand8_s
        rts

SeedRand:
        lda CIA1_TALO
        eor VIC_RASTER
        eor #$a7
        ora #$01
        sta rand8_s
        rts

RandGlyph:
        jsr Rand8
        and #$3f
        clc
        adc #$40
        cmp #$60
        bcs @ok
        adc #$20
@ok:    rts

; bounded mods used by the starfield
Mod40:
        cmp #40
        bcc @d
@l:     sec
        sbc #40
        cmp #40
        bcs @l
@d:     rts
Mod25:
        cmp #25
        bcc @d
@l:     sec
        sbc #25
        cmp #25
        bcs @l
@d:     rts

rand8_s !byte $a5

; ============================================================================
;  SID MUSIC ENGINE  (from TunnelVoyager)
;  Filtered saw bass / pulse arpeggiator / noise drums, one arranged 256-row
;  cyber tune.  Runs once per frame (50 Hz) from the IRQ.
; ============================================================================
TV_MusTick   !byte MUS_SPEED
TV_MusRow    !byte 0
TV_ArpStep   !byte 0
TV_FlashI    !byte 0
TV_Beat      !byte 0
sndPulse     !byte 0      ; combined sound energy (kick+snare+hat+bass+arp); all effects react to it
musicPulse   !byte 0      ; copy of sndPulse for the ported hyperopt engines
zoomPulse    !byte 0      ; smooth 0..15 sine zoom for the ported engines
beatSin      !byte 0      ; full 0..255 beat sine for the ported engines

; ComputeVisualPulses: refresh the pulse globals the ported engines read
ComputeVisualPulses:
        ; musical pulse with a visible floor (matches the original engines) so the
        ; visuals always have musical motion, not just brief spikes between beats
        lda sndPulse
        cmp #3
        bcs .mpok
        lda #3
.mpok:  sta musicPulse
        ; beatSin = full sine ; zoomPulse = fast 0..15 (cycles 4x per sine, as the
        ; original engines expect) -> zoom/rotation engines move at full speed again
        lda frameCounter
        asl
        asl
        clc
        adc musicPulse
        tax
        lda Sin256,x
        sta beatSin
        lsr
        lsr
        and #$0f
        sta zoomPulse
        rts
TV_FiltPhase !byte 0
TV_PwmPhase  !byte 0
TV_KickEnv   !byte 0
TV_FlashRamp: !byte $00,$06,$04,$0e,$03,$05,$0d,$07,$01
BeatBorderTbl: !byte $02,$08,$07,$05,$0e,$04,$0a,$0d   ; per-beat rainbow flash

TV_MusInit:
        lda #0
        ldx #$18
.clr:   sta SID,x
        dex
        bpl .clr
        lda #$a1 : sta SID_RESFLT      ; resonant low-pass on the bass
        lda #$1f : sta SID_MODEVOL     ; LP + max volume
        lda #$08 : sta SID_V1AD         ; bass: instant attack, snappy decay
        lda #$78 : sta SID_V1SR         ; sustain 7 -> body while held, short release
        lda #$00 : sta SID_V1PWLO
        lda #$08 : sta SID_V1PWHI
        lda #$00 : sta SID_V2PWLO
        lda #$08 : sta SID_V2PWHI
        lda #$00 : sta SID_V2AD
        lda #$f8 : sta SID_V2SR         ; stabs: full sustain + release tail (rings out)
        lda #0
        sta TV_MusRow
        sta TV_ArpStep
        sta TV_FlashI
        sta TV_Beat
        sta musTranspose
        lda #2                  ; open on the BERLIN TECHNO tune (first/opening track)
        sta curSong
        lda #MUS_SPEED
        sta musSpeed
        sta TV_MusTick
        lda #2
        jsr SelectStyle         ; load the opening track (song + instrument + tempo)
        ldx #0
        jsr TV_MusRowTrigger
        rts
curSong  !byte 0

; --- per-scene music variety: transpose (semitones) + tempo (frames/row) ---
musTranspose !byte 0
musSpeed     !byte MUS_SPEED
;                 title mat rng pls hyp vor xor wav tun star
MusXposeTbl: !byte 0,   3,  7,  5,  2, 10,  3,  8,  5,  7,  0
MusSpeedTbl: !byte 7,   4,  6,  5,  4,  6,  4,  5,  4,  4,  6

; SetMusicScene: pick transpose for the current partId (A=partId).
; (tempo + song style are chosen by SelectStyle.)
SetMusicScene:
        tax
        lda MusXposeTbl,x
        sta musTranspose
        rts

; SelectStyle: switch the whole song + instrument + tempo + filter (A=style 0..3)
; Patches the engine's read operands to the chosen song's pattern tables.
SelectStyle:
        tax
        lda SongBassLo,x : sta pBass+1
        lda SongBassHi,x : sta pBass+2
        lda SongArp0Lo,x : sta pArp0+1
        lda SongArp0Hi,x : sta pArp0+2
        lda SongArp1Lo,x : sta pArp1+1
        lda SongArp1Hi,x : sta pArp1+2
        lda SongArp2Lo,x : sta pArp2+1
        lda SongArp2Hi,x : sta pArp2+2
        lda SongDrumLo,x : sta pDrum+1
        lda SongDrumHi,x : sta pDrum+2
        lda SongFiltLo,x : sta pFilt+1
        lda SongFiltHi,x : sta pFilt+2
        lda StyleBassWaveTbl,x : sta styleBassWave
        lda StyleArpWaveTbl,x  : sta styleArpWave
        lda StyleSpeedTbl,x    : sta musSpeed
        lda StyleResTbl,x      : sta SID_RESFLT
        lda StyleVolTbl,x      : sta SID_MODEVOL
        lda StyleXposeTbl,x    : sta musTranspose   ; per-track key -> 6 distinct tunes
        lda StyleBassADTbl,x   : sta SID_V1AD
        lda StyleBassSRTbl,x   : sta SID_V1SR
        lda StyleArpADTbl,x    : sta SID_V2AD
        lda StyleArpSRTbl,x    : sta SID_V2SR
        lda StylePwmBaseTbl,x  : sta stylePwmBase
        lda StylePwmStepTbl,x  : sta stylePwmStep
        lda StyleFiltStepTbl,x : sta styleFiltStep
        rts

; MusXpose: A = note index -> + transpose, clamped into the 0..95 freq table
MusXpose:
        clc
        adc musTranspose
        cmp #96
        bcc .mx
        sec
        sbc #12
.mx:    rts

TV_PlayMusic:
        jsr TV_MusArp
        jsr TV_MusFilter
        jsr TV_MusPwm
        jsr TV_DrumPitch
        dec TV_MusTick
        bne .doFlash
        lda musSpeed
        sta TV_MusTick
        ldx TV_MusRow
        inx                            ; 256-row song wraps for free
        stx TV_MusRow
        bne .sameSong
        ; song looped -> advance through the 5 techno journey sections (2..6),
        ; departure -> through the city -> underground -> arrival, then loop.
        inc curSong
        lda curSong
        cmp #7
        bcc @songOk
        lda #2
@songOk:
        sta curSong
        jsr SelectStyle
.sameSong:
        ldx TV_MusRow
        jsr TV_MusRowTrigger
.doFlash:
        jsr TV_MusFlash
        rts

TV_MusFilter:
        lda TV_FiltPhase
        clc
        adc styleFiltStep       ; per-section filter LFO speed: slow dub -> fast peak
        sta TV_FiltPhase
        bpl MusFiltTri
        eor #$ff
MusFiltTri:
        lsr
        lsr
        ldx TV_MusRow
        clc
pFilt:  adc MUS_FILT,x          ; operand patched by SelectStyle
        bcc MusFiltNoSat
        lda #$f0                ; do not wrap high cutoff back to mud/silence
MusFiltNoSat:
        cmp #$f1
        bcc MusFiltStore
        lda #$f0
MusFiltStore:
        sta SID_FCHI
        lda TV_MusRow           ; animate low 3 cutoff bits for extra analogue fizz
        and #$07
        sta SID_FCLO
        rts

TV_MusPwm:
        lda TV_PwmPhase
        clc
        adc stylePwmStep        ; per-section PWM speed
        sta TV_PwmPhase
        bpl MusPwmTri
        eor #$ff
MusPwmTri:
        lsr
        lsr
        lsr
        lsr
        clc
        adc stylePwmBase        ; keep pulse away from 0/4095 mute edges
        cmp #$0d
        bcc MusPwmStore
        lda #$0c
MusPwmStore:
        sta SID_V2PWHI
        sta SID_V1PWHI          ; bass also breathes if pulse/combined wave is selected
        lda #$00
        sta SID_V2PWLO
        sta SID_V1PWLO
        rts

TV_DrumPitch:
        lda TV_KickEnv
        beq .dpDone
        clc
        adc #$04
        sta SID_V3FHI
        dec TV_KickEnv
.dpDone:
        rts

TV_MusArp:
        ldx TV_MusRow
        ldy TV_ArpStep
        cpy #0
        beq .a0
        cpy #1
        beq .a1
pArp2:  lda MUS_ARP2,x
        jmp .have
.a0:
pArp0:  lda MUS_ARP0,x
        jmp .have
.a1:
pArp1:  lda MUS_ARP1,x
.have:  cmp #$ff
        beq .silent
        jsr MusXpose
        tay
        lda SID_FREQLO,y : sta SID_V2FLO
        lda SID_FREQHI,y : sta SID_V2FHI
        lda styleArpWave : sta SID_V2CTL    ; per-style arp waveform (gate on)
        lda #3 : jsr SndAdd                 ; arp notes feed the pulse
        jmp .step
.silent:
        lda styleArpWave
        and #$fe                            ; gate off (clear bit0)
        sta SID_V2CTL
.step:  inc TV_ArpStep
        lda TV_ArpStep
        cmp #3
        bcc .ok
        lda #0
        sta TV_ArpStep
.ok:    rts

TV_MusRowTrigger:
pBass:  lda MUS_BASS,x
        cmp #$ff
        beq MusRowNoBass
        jsr MusXpose
        tay
        lda SID_FREQLO,y : sta SID_V1FLO
        lda SID_FREQHI,y : sta SID_V1FHI
        lda #$20         : sta SID_V1CTL      ; hard reset waveform for crisp techno gate
        lda styleBassWave : sta SID_V1CTL     ; per-style bass waveform
        lda #4 : jsr SndAdd                   ; bass note feeds the sound pulse
        jmp MusRowAfterBass
MusRowNoBass:
        lda styleBassWave
        and #$fe                              ; true staccato: rests release bass gate
        sta SID_V1CTL
MusRowAfterBass:
pDrum:  lda MUS_DRUM,x
        beq .mdone
        cmp #1
        beq .kick
        cmp #2
        beq .hat
        lda #$00 : sta TV_KickEnv      ; snare
        lda #$00 : sta SID_V3FLO
        lda #$28 : sta SID_V3FHI
        lda #$09 : sta SID_V3AD
        lda #$00 : sta SID_V3SR
        lda #$80 : sta SID_V3CTL
        lda #$81 : sta SID_V3CTL
        jmp .flash
.kick:
        lda #$00 : sta SID_V3FLO
        lda #$10 : sta SID_V3FHI
        lda #$08 : sta SID_V3AD
        lda #$00 : sta SID_V3SR
        lda #$10 : sta SID_V3CTL
        lda #$11 : sta SID_V3CTL
        lda #12  : sta TV_KickEnv
        jmp .flash
.hat:
        lda #$00 : sta TV_KickEnv
        lda #$00 : sta SID_V3FLO
        lda #$f0 : sta SID_V3FHI
        lda #$03 : sta SID_V3AD
        lda #$00 : sta SID_V3SR
        lda #$80 : sta SID_V3CTL
        lda #$81 : sta SID_V3CTL
        lda #6 : jsr SndAdd                  ; hats shimmer into the pulse
.mdone: rts
.flash:
        lda #$08 : sta TV_FlashI
        lda #16  : sta sndPulse              ; kick/snare slam the pulse to max
        inc TV_Beat
        rts

; SndAdd: A = amount, add to sndPulse clamped at 16 (A clobbered)
SndAdd:
        clc
        adc sndPulse
        cmp #17
        bcc @s
        lda #16
@s:     sta sndPulse
        rts

TV_MusFlash:
        lda sndPulse            ; decay the combined sound pulse each frame
        beq .nopd
        sec
        sbc #2
        bcs .pds
        lda #0
.pds:   sta sndPulse
.nopd:
        ldx TV_FlashI
        beq .dark
        cpx #4                  ; strong part of the flash -> rainbow per-beat colour
        bcc .ramp
        lda TV_Beat
        and #$07
        tay
        lda BeatBorderTbl,y
        sta BORDER
        dec TV_FlashI
        rts
.ramp:
        lda TV_FlashRamp,x
        sta BORDER
        dec TV_FlashI
        rts
.dark:  lda partBorder
        sta BORDER
        rts

; ---- inline music data (generated by TunnelVoyager gen_tables.py) ----
SID_FREQLO:
        !byte $16,$27,$39,$4b,$5f,$74,$8a,$a1,$ba,$d4,$f0,$0e,$2d,$4e,$71,$96
        !byte $be,$e7,$14,$42,$74,$a9,$e0,$1b,$5a,$9c,$e2,$2d,$7b,$cf,$27,$85
        !byte $e8,$51,$c1,$37,$b4,$38,$c4,$59,$f7,$9d,$4e,$0a,$d0,$a2,$81,$6d
        !byte $67,$70,$89,$b2,$ed,$3b,$9c,$13,$a0,$45,$02,$da,$ce,$e0,$11,$64
        !byte $da,$76,$39,$26,$40,$89,$04,$b4,$9c,$c0,$23,$c8,$b4,$eb,$72,$4c
        !byte $80,$12,$08,$68,$39,$80,$45,$90,$68,$d6,$e3,$99,$00,$24,$10,$ff
SID_FREQHI:
        !byte $01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$01,$02,$02,$02,$02,$02
        !byte $02,$02,$03,$03,$03,$03,$03,$04,$04,$04,$04,$05,$05,$05,$06,$06
        !byte $06,$07,$07,$08,$08,$09,$09,$0a,$0a,$0b,$0c,$0d,$0d,$0e,$0f,$10
        !byte $11,$12,$13,$14,$15,$17,$18,$1a,$1b,$1d,$1f,$20,$22,$24,$27,$29
        !byte $2b,$2e,$31,$34,$37,$3a,$3e,$41,$45,$49,$4e,$52,$57,$5c,$62,$68
        !byte $6e,$75,$7c,$83,$8b,$93,$9c,$a5,$af,$b9,$c4,$d0,$dd,$ea,$f8,$ff
MUS_BASS:
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$18,$ff,$ff,$ff,$18,$ff,$ff,$ff,$18,$ff,$ff,$ff
        !byte $20,$ff,$ff,$ff,$20,$ff,$ff,$ff,$20,$ff,$ff,$ff,$20,$ff,$ff,$ff
        !byte $18,$ff,$18,$ff,$1f,$ff,$18,$ff,$18,$ff,$ff,$ff,$1f,$ff,$18,$ff
        !byte $20,$ff,$20,$ff,$27,$ff,$20,$ff,$20,$ff,$ff,$ff,$27,$ff,$20,$ff
        !byte $22,$ff,$22,$ff,$29,$ff,$22,$ff,$22,$ff,$ff,$ff,$29,$ff,$22,$ff
        !byte $1f,$ff,$1f,$ff,$26,$ff,$1f,$ff,$1f,$ff,$ff,$ff,$26,$ff,$1f,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$24,$18,$ff,$18,$24,$18,$ff,$18,$24,$18,$ff,$18,$24,$18,$ff
        !byte $20,$2c,$20,$ff,$20,$2c,$20,$ff,$20,$2c,$20,$ff,$20,$2c,$20,$ff
        !byte $22,$2e,$22,$ff,$22,$2e,$22,$ff,$22,$2e,$22,$ff,$22,$2e,$22,$ff
        !byte $1f,$2b,$1f,$ff,$1f,$2b,$1f,$ff,$1f,$2b,$1f,$ff,$1f,$2b,$1f,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
MUS_ARP0:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $30,$ff,$30,$ff,$30,$ff,$30,$ff,$30,$ff,$30,$ff,$30,$ff,$30,$ff
        !byte $38,$ff,$38,$ff,$38,$ff,$38,$ff,$38,$ff,$38,$ff,$38,$ff,$38,$ff
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38
        !byte $3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff
        !byte $37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38
        !byte $3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff
        !byte $30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff
MUS_ARP1:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $33,$ff,$33,$ff,$33,$ff,$33,$ff,$33,$ff,$33,$ff,$33,$ff,$33,$ff
        !byte $3c,$ff,$3c,$ff,$3c,$ff,$3c,$ff,$3c,$ff,$3c,$ff,$3c,$ff,$3c,$ff
        !byte $33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33
        !byte $3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c
        !byte $3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e
        !byte $3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a
        !byte $38,$ff,$ff,$ff,$38,$ff,$ff,$ff,$38,$ff,$ff,$ff,$38,$ff,$ff,$ff
        !byte $3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff
        !byte $33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33
        !byte $3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c
        !byte $3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e
        !byte $3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a
        !byte $33,$ff,$ff,$ff,$33,$ff,$ff,$ff,$33,$ff,$ff,$ff,$33,$ff,$ff,$ff
        !byte $33,$ff,$ff,$ff,$33,$ff,$ff,$ff,$33,$ff,$ff,$ff,$33,$ff,$ff,$ff
MUS_ARP2:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $37,$ff,$37,$ff,$37,$ff,$37,$ff,$37,$ff,$37,$ff,$37,$ff,$37,$ff
        !byte $3f,$ff,$3f,$ff,$3f,$ff,$3f,$ff,$3f,$ff,$3f,$ff,$3f,$ff,$3f,$ff
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f
        !byte $41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41
        !byte $3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e
        !byte $3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff
        !byte $3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f
        !byte $41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41
        !byte $3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e
        !byte $37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff
        !byte $37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff
MUS_DRUM:
        !byte $01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        !byte $01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$00,$00,$00,$00,$00,$02,$02,$00,$00,$00,$00,$00,$00,$02,$02
        !byte $01,$00,$00,$00,$00,$00,$02,$02,$00,$00,$00,$00,$00,$00,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        !byte $01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
MUS_FILT:
        !byte $28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28
        !byte $28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28
        !byte $30,$34,$38,$3c,$40,$44,$48,$4c,$51,$55,$59,$5d,$61,$65,$69,$6d
        !byte $72,$76,$7a,$7e,$82,$86,$8a,$8e,$93,$97,$9b,$9f,$a3,$a7,$ab,$b0
        !byte $70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70
        !byte $70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70
        !byte $70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70
        !byte $70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70
        !byte $38,$3c,$40,$45,$49,$4d,$52,$56,$5b,$5f,$63,$68,$6c,$71,$75,$79
        !byte $7e,$82,$86,$8b,$8f,$94,$98,$9c,$a1,$a5,$aa,$ae,$b2,$b7,$bb,$c0
        !byte $88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88
        !byte $88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88
        !byte $88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88
        !byte $88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88
        !byte $80,$7d,$7a,$77,$74,$71,$6e,$6b,$68,$65,$62,$5e,$5b,$58,$55,$52
        !byte $4f,$4c,$49,$46,$43,$3f,$3c,$39,$36,$33,$30,$2d,$2a,$27,$24,$20
Song1Bass:
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$18,$ff,$ff,$ff,$18,$ff,$ff,$ff,$18,$ff,$ff,$ff
        !byte $22,$ff,$ff,$ff,$22,$ff,$ff,$ff,$22,$ff,$ff,$ff,$22,$ff,$ff,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $20,$ff,$2c,$ff,$20,$ff,$2c,$ff,$20,$ff,$2c,$ff,$20,$ff,$2c,$ff
        !byte $22,$ff,$2e,$ff,$22,$ff,$2e,$ff,$22,$ff,$2e,$ff,$22,$ff,$2e,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$24,$18,$ff,$18,$24,$18,$ff,$18,$24,$18,$ff,$18,$24,$18,$ff
        !byte $22,$2e,$22,$ff,$22,$2e,$22,$ff,$22,$2e,$22,$ff,$22,$2e,$22,$ff
        !byte $20,$2c,$20,$ff,$20,$2c,$20,$ff,$20,$2c,$20,$ff,$20,$2c,$20,$ff
        !byte $1f,$2b,$1f,$ff,$1f,$2b,$1f,$ff,$1f,$2b,$1f,$ff,$1f,$2b,$1f,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
Song1Arp0:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $30,$ff,$30,$ff,$30,$ff,$30,$ff,$30,$ff,$30,$ff,$30,$ff,$30,$ff
        !byte $3a,$ff,$3a,$ff,$3a,$ff,$3a,$ff,$3a,$ff,$3a,$ff,$3a,$ff,$3a,$ff
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38
        !byte $3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff
        !byte $37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a,$3a
        !byte $38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38,$38
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff
        !byte $30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff
Song1Arp1:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $33,$ff,$33,$ff,$33,$ff,$33,$ff,$33,$ff,$33,$ff,$33,$ff,$33,$ff
        !byte $3e,$ff,$3e,$ff,$3e,$ff,$3e,$ff,$3e,$ff,$3e,$ff,$3e,$ff,$3e,$ff
        !byte $33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33
        !byte $3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c
        !byte $3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e
        !byte $33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33
        !byte $38,$ff,$ff,$ff,$38,$ff,$ff,$ff,$38,$ff,$ff,$ff,$38,$ff,$ff,$ff
        !byte $3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff
        !byte $33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33,$33
        !byte $3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e
        !byte $3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c,$3c
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $33,$ff,$ff,$ff,$33,$ff,$ff,$ff,$33,$ff,$ff,$ff,$33,$ff,$ff,$ff
        !byte $33,$ff,$ff,$ff,$33,$ff,$ff,$ff,$33,$ff,$ff,$ff,$33,$ff,$ff,$ff
Song1Arp2:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $37,$ff,$37,$ff,$37,$ff,$37,$ff,$37,$ff,$37,$ff,$37,$ff,$37,$ff
        !byte $41,$ff,$41,$ff,$41,$ff,$41,$ff,$41,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f
        !byte $41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff
        !byte $3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41,$41
        !byte $3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f,$3f
        !byte $3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e,$3e
        !byte $37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff
        !byte $37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff
Song1Drum:
        !byte $01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        !byte $01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$02,$00,$02,$03,$02,$00,$02,$01,$02,$00,$02,$03,$02,$00,$02
        !byte $01,$00,$00,$00,$00,$00,$02,$02,$00,$00,$00,$00,$00,$00,$02,$02
        !byte $01,$00,$00,$00,$00,$00,$02,$02,$00,$00,$00,$00,$00,$00,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        !byte $01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
Song1Filt:
        !byte $28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28
        !byte $28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28,$28
        !byte $30,$34,$38,$3c,$40,$44,$48,$4c,$51,$55,$59,$5d,$61,$65,$69,$6d
        !byte $72,$76,$7a,$7e,$82,$86,$8a,$8e,$93,$97,$9b,$9f,$a3,$a7,$ab,$b0
        !byte $70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70
        !byte $70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70
        !byte $70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70
        !byte $70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70,$70
        !byte $38,$3c,$40,$45,$49,$4d,$52,$56,$5b,$5f,$63,$68,$6c,$71,$75,$79
        !byte $7e,$82,$86,$8b,$8f,$94,$98,$9c,$a1,$a5,$aa,$ae,$b2,$b7,$bb,$c0
        !byte $88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88
        !byte $88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88
        !byte $88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88
        !byte $88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88,$88
        !byte $80,$7d,$7a,$77,$74,$71,$6e,$6b,$68,$65,$62,$5e,$5b,$58,$55,$52
        !byte $4f,$4c,$49,$46,$43,$3f,$3c,$39,$36,$33,$30,$2d,$2a,$27,$24,$20
DreamyABass:
        !byte $15,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$15,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$29,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2b,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $15,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$15,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$29,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2b,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $15,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$15,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$29,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2b,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $15,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$15,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$29,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$18,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2b,$ff,$ff,$ff,$ff,$ff,$ff,$ff
DreamyAArp0:
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
DreamyAArp1:
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
DreamyAArp2:
        !byte $32,$34,$34,$34,$2f,$34,$34,$34,$2f,$34,$34,$34,$32,$34,$34,$34
        !byte $3b,$3c,$3c,$3c,$37,$3c,$3c,$3c,$37,$3c,$3c,$3c,$3b,$3c,$3c,$3c
        !byte $35,$37,$37,$37,$32,$37,$37,$37,$32,$37,$37,$37,$35,$37,$37,$37
        !byte $3c,$3e,$3e,$3e,$39,$3e,$3e,$3e,$39,$3e,$3e,$3e,$3c,$3e,$3e,$3e
        !byte $32,$34,$34,$34,$2f,$34,$34,$34,$2f,$34,$34,$34,$32,$34,$34,$34
        !byte $3b,$3c,$3c,$3c,$37,$3c,$3c,$3c,$37,$3c,$3c,$3c,$3b,$3c,$3c,$3c
        !byte $35,$37,$37,$37,$32,$37,$37,$37,$32,$37,$37,$37,$35,$37,$37,$37
        !byte $3c,$3e,$3e,$3e,$39,$3e,$3e,$3e,$39,$3e,$3e,$3e,$3c,$3e,$3e,$3e
        !byte $32,$34,$34,$34,$2f,$34,$34,$34,$2f,$34,$34,$34,$32,$34,$34,$34
        !byte $3b,$3c,$3c,$3c,$37,$3c,$3c,$3c,$37,$3c,$3c,$3c,$3b,$3c,$3c,$3c
        !byte $35,$37,$37,$37,$32,$37,$37,$37,$32,$37,$37,$37,$35,$37,$37,$37
        !byte $3c,$3e,$3e,$3e,$39,$3e,$3e,$3e,$39,$3e,$3e,$3e,$3c,$3e,$3e,$3e
        !byte $32,$34,$34,$34,$2f,$34,$34,$34,$2f,$34,$34,$34,$32,$34,$34,$34
        !byte $3b,$3c,$3c,$3c,$37,$3c,$3c,$3c,$37,$3c,$3c,$3c,$3b,$3c,$3c,$3c
        !byte $35,$37,$37,$37,$32,$37,$37,$37,$32,$37,$37,$37,$35,$37,$37,$37
        !byte $3c,$3e,$3e,$3e,$39,$3e,$3e,$3e,$39,$3e,$3e,$3e,$3c,$3e,$3e,$3e
DreamyADrum:
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
        !byte $01,$00,$00,$00,$02,$00,$00,$00,$00,$00,$00,$00,$02,$00,$00,$00
DreamyAFilt:
        !byte $6b,$6d,$6f,$71,$73,$75,$77,$79,$7b,$7d,$7f,$81,$82,$84,$86,$87
        !byte $89,$8a,$8c,$8d,$8e,$8f,$90,$91,$92,$93,$94,$94,$95,$95,$95,$95
        !byte $96,$95,$95,$95,$95,$94,$94,$93,$92,$91,$90,$8f,$8e,$8d,$8c,$8a
        !byte $89,$87,$86,$84,$82,$81,$7f,$7d,$7b,$79,$77,$75,$73,$71,$6f,$6d
        !byte $6b,$68,$66,$64,$62,$60,$5e,$5c,$5a,$58,$56,$54,$53,$51,$4f,$4e
        !byte $4c,$4b,$49,$48,$47,$46,$45,$44,$43,$42,$41,$41,$40,$40,$40,$40
        !byte $40,$40,$40,$40,$40,$41,$41,$42,$43,$44,$45,$46,$47,$48,$49,$4b
        !byte $4c,$4e,$4f,$51,$53,$54,$56,$58,$5a,$5c,$5e,$60,$62,$64,$66,$68
        !byte $6b,$6d,$6f,$71,$73,$75,$77,$79,$7b,$7d,$7f,$81,$82,$84,$86,$87
        !byte $89,$8a,$8c,$8d,$8e,$8f,$90,$91,$92,$93,$94,$94,$95,$95,$95,$95
        !byte $96,$95,$95,$95,$95,$94,$94,$93,$92,$91,$90,$8f,$8e,$8d,$8c,$8a
        !byte $89,$87,$86,$84,$82,$81,$7f,$7d,$7b,$79,$77,$75,$73,$71,$6f,$6d
        !byte $6b,$68,$66,$64,$62,$60,$5e,$5c,$5a,$58,$56,$54,$53,$51,$4f,$4e
        !byte $4c,$4b,$49,$48,$47,$46,$45,$44,$43,$42,$41,$41,$40,$40,$40,$40
        !byte $40,$40,$40,$40,$40,$41,$41,$42,$43,$44,$45,$46,$47,$48,$49,$4b
        !byte $4c,$4e,$4f,$51,$53,$54,$56,$58,$5a,$5c,$5e,$60,$62,$64,$66,$68
DreamyBBass:
        !byte $15,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$15,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$29,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1a,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1a,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2b,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $15,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$15,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$29,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1c,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1c,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2b,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $15,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$15,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$29,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1a,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1a,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $18,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$24,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1d,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1c,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$28,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$1f,$ff,$ff,$ff,$ff,$ff,$ff,$ff
        !byte $15,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$21,$ff,$ff,$ff,$ff,$ff,$ff,$ff
DreamyBArp0:
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
DreamyBArp1:
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
DreamyBArp2:
        !byte $32,$34,$34,$34,$2f,$34,$34,$34,$2f,$34,$34,$34,$32,$34,$34,$34
        !byte $3b,$3c,$3c,$3c,$37,$3c,$3c,$3c,$37,$3c,$3c,$3c,$3b,$3c,$3c,$3c
        !byte $37,$39,$39,$39,$34,$39,$39,$39,$34,$39,$39,$39,$37,$39,$39,$39
        !byte $3c,$3e,$3e,$3e,$39,$3e,$3e,$3e,$39,$3e,$3e,$3e,$3c,$3e,$3e,$3e
        !byte $32,$34,$34,$34,$2f,$34,$34,$34,$2f,$34,$34,$34,$32,$34,$34,$34
        !byte $3b,$3c,$3c,$3c,$37,$3c,$3c,$3c,$37,$3c,$3c,$3c,$3b,$3c,$3c,$3c
        !byte $39,$3b,$3b,$3b,$35,$3b,$3b,$3b,$35,$3b,$3b,$3b,$39,$3b,$3b,$3b
        !byte $3c,$3e,$3e,$3e,$39,$3e,$3e,$3e,$39,$3e,$3e,$3e,$3c,$3e,$3e,$3e
        !byte $32,$34,$34,$34,$2f,$34,$34,$34,$2f,$34,$34,$34,$32,$34,$34,$34
        !byte $3b,$3c,$3c,$3c,$37,$3c,$3c,$3c,$37,$3c,$3c,$3c,$3b,$3c,$3c,$3c
        !byte $37,$39,$39,$39,$34,$39,$39,$39,$34,$39,$39,$39,$37,$39,$39,$39
        !byte $35,$37,$37,$37,$32,$37,$37,$37,$32,$37,$37,$37,$35,$37,$37,$37
        !byte $3b,$3c,$3c,$3c,$37,$3c,$3c,$3c,$37,$3c,$3c,$3c,$3b,$3c,$3c,$3c
        !byte $39,$3b,$3b,$3b,$35,$3b,$3b,$3b,$35,$3b,$3b,$3b,$39,$3b,$3b,$3b
        !byte $3c,$3e,$3e,$3e,$39,$3e,$3e,$3e,$39,$3e,$3e,$3e,$3c,$3e,$3e,$3e
        !byte $32,$34,$34,$34,$2f,$34,$34,$34,$2f,$34,$34,$34,$32,$34,$34,$34
DreamyBDrum:
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
        !byte $01,$00,$02,$00,$00,$00,$02,$00,$03,$00,$02,$00,$00,$00,$02,$00
DreamyBFilt:
        !byte $b0,$af,$af,$af,$af,$ae,$ad,$ad,$ac,$ab,$aa,$a9,$a7,$a6,$a5,$a3
        !byte $a1,$a0,$9e,$9c,$9a,$98,$96,$94,$92,$90,$8d,$8b,$89,$87,$84,$82
        !byte $80,$7d,$7b,$78,$76,$74,$72,$6f,$6d,$6b,$69,$67,$65,$63,$61,$5f
        !byte $5e,$5c,$5a,$59,$58,$56,$55,$54,$53,$52,$52,$51,$50,$50,$50,$50
        !byte $50,$50,$50,$50,$50,$51,$52,$52,$53,$54,$55,$56,$58,$59,$5a,$5c
        !byte $5e,$5f,$61,$63,$65,$67,$69,$6b,$6d,$6f,$72,$74,$76,$78,$7b,$7d
        !byte $7f,$82,$84,$87,$89,$8b,$8d,$90,$92,$94,$96,$98,$9a,$9c,$9e,$a0
        !byte $a1,$a3,$a5,$a6,$a7,$a9,$aa,$ab,$ac,$ad,$ad,$ae,$af,$af,$af,$af
        !byte $b0,$af,$af,$af,$af,$ae,$ad,$ad,$ac,$ab,$aa,$a9,$a7,$a6,$a5,$a3
        !byte $a1,$a0,$9e,$9c,$9a,$98,$96,$94,$92,$90,$8d,$8b,$89,$87,$84,$82
        !byte $80,$7d,$7b,$78,$76,$74,$72,$6f,$6d,$6b,$69,$67,$65,$63,$61,$5f
        !byte $5e,$5c,$5a,$59,$58,$56,$55,$54,$53,$52,$52,$51,$50,$50,$50,$50
        !byte $50,$50,$50,$50,$50,$51,$52,$52,$53,$54,$55,$56,$58,$59,$5a,$5c
        !byte $5e,$5f,$61,$63,$65,$67,$69,$6b,$6d,$6f,$72,$74,$76,$78,$7b,$7d
        !byte $7f,$82,$84,$87,$89,$8b,$8d,$90,$92,$94,$96,$98,$9a,$9c,$9e,$a0
        !byte $a1,$a3,$a5,$a6,$a7,$a9,$aa,$ab,$ac,$ad,$ad,$ae,$af,$af,$af,$af
TechnoABass:
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $0e,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$21
        !byte $10,$1c,$1c,$28,$1c,$1c,$1c,$28,$1c,$1c,$1c,$28,$1c,$1c,$1c,$23
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $0e,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$21
        !byte $10,$1c,$1c,$28,$1c,$1c,$1c,$28,$1c,$1c,$1c,$28,$1c,$1c,$1c,$23
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $0e,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$21
        !byte $10,$1c,$1c,$28,$1c,$1c,$1c,$28,$1c,$1c,$1c,$28,$1c,$1c,$1c,$23
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $0e,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$21
        !byte $10,$1c,$1c,$28,$1c,$1c,$1c,$28,$1c,$1c,$1c,$28,$1c,$1c,$1c,$23
TechnoAArp0:
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$32,$ff,$ff,$ff,$32,$ff,$ff,$ff,$32,$ff,$ff,$ff,$32,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$32,$ff,$ff,$ff,$32,$ff,$ff,$ff,$32,$ff,$ff,$ff,$32,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$32,$ff,$ff,$ff,$32,$ff,$ff,$ff,$32,$ff,$ff,$ff,$32,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$32,$ff,$ff,$ff,$32,$ff,$ff,$ff,$32,$ff,$ff,$ff,$32,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
TechnoAArp1:
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff
TechnoAArp2:
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff
TechnoADrum:
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
TechnoAFilt:
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
TechnoBBass:
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $11,$ff,$ff,$1d,$ff,$ff,$1d,$ff,$11,$ff,$ff,$1d,$ff,$ff,$1d,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $11,$ff,$ff,$1d,$ff,$ff,$1d,$ff,$11,$ff,$ff,$1d,$ff,$ff,$1d,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $11,$ff,$ff,$1d,$ff,$ff,$1d,$ff,$11,$ff,$ff,$1d,$ff,$ff,$1d,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $09,$ff,$ff,$15,$ff,$ff,$15,$ff,$09,$ff,$ff,$15,$ff,$ff,$15,$ff
        !byte $11,$ff,$ff,$1d,$ff,$ff,$1d,$ff,$11,$ff,$ff,$1d,$ff,$ff,$1d,$ff
TechnoBArp0:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$35,$ff
TechnoBArp1:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$39,$ff
TechnoBArp2:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff
TechnoBDrum:
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
        !byte $01,$00,$00,$00,$03,$00,$00,$00,$01,$00,$00,$00,$03,$00,$00,$00
TechnoBFilt:
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
        !byte $5e,$5c,$5a,$58,$56,$54,$52,$50,$4e,$4c,$4a,$48,$46,$44,$42,$40
AcidABass:
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $1d,$29,$1d,$24,$1d,$29,$20,$1d,$1d,$29,$1d,$24,$27,$1d,$29,$1d
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $1c,$28,$1c,$23,$1c,$28,$1f,$1c,$1c,$28,$1c,$23,$26,$1c,$28,$1c
        !byte $1f,$2b,$1f,$26,$1f,$2b,$22,$1f,$1f,$2b,$1f,$26,$29,$1f,$2b,$1f
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $1d,$29,$1d,$24,$1d,$29,$20,$1d,$1d,$29,$1d,$24,$27,$1d,$29,$1d
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $15,$21,$15,$1c,$15,$21,$18,$15,$15,$21,$15,$1c,$1f,$15,$21,$15
        !byte $1c,$28,$1c,$23,$1c,$28,$1f,$1c,$1c,$28,$1c,$23,$26,$1c,$28,$1c
        !byte $1f,$2b,$1f,$26,$1f,$2b,$22,$1f,$1f,$2b,$1f,$26,$29,$1f,$2b,$1f
AcidAArp0:
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
AcidAArp1:
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
AcidAArp2:
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $35,$3c,$41,$3c,$35,$3c,$41,$3c,$35,$3c,$41,$3c,$35,$3c,$41,$3c
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b
        !byte $37,$3e,$43,$3e,$37,$3e,$43,$3e,$37,$3e,$43,$3e,$37,$3e,$43,$3e
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $35,$3c,$41,$3c,$35,$3c,$41,$3c,$35,$3c,$41,$3c,$35,$3c,$41,$3c
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b
        !byte $37,$3e,$43,$3e,$37,$3e,$43,$3e,$37,$3e,$43,$3e,$37,$3e,$43,$3e
AcidADrum:
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
AcidAFilt:
        !byte $20,$26,$2c,$32,$38,$3e,$44,$4a,$50,$56,$5c,$62,$68,$6e,$74,$7a
        !byte $80,$86,$8c,$92,$98,$9e,$a4,$aa,$b0,$b6,$bc,$c2,$c8,$ce,$d4,$da
        !byte $20,$26,$2c,$32,$38,$3e,$44,$4a,$50,$56,$5c,$62,$68,$6e,$74,$7a
        !byte $80,$86,$8c,$92,$98,$9e,$a4,$aa,$b0,$b6,$bc,$c2,$c8,$ce,$d4,$da
        !byte $20,$26,$2c,$32,$38,$3e,$44,$4a,$50,$56,$5c,$62,$68,$6e,$74,$7a
        !byte $80,$86,$8c,$92,$98,$9e,$a4,$aa,$b0,$b6,$bc,$c2,$c8,$ce,$d4,$da
        !byte $20,$26,$2c,$32,$38,$3e,$44,$4a,$50,$56,$5c,$62,$68,$6e,$74,$7a
        !byte $80,$86,$8c,$92,$98,$9e,$a4,$aa,$b0,$b6,$bc,$c2,$c8,$ce,$d4,$da
        !byte $20,$26,$2c,$32,$38,$3e,$44,$4a,$50,$56,$5c,$62,$68,$6e,$74,$7a
        !byte $80,$86,$8c,$92,$98,$9e,$a4,$aa,$b0,$b6,$bc,$c2,$c8,$ce,$d4,$da
        !byte $20,$26,$2c,$32,$38,$3e,$44,$4a,$50,$56,$5c,$62,$68,$6e,$74,$7a
        !byte $80,$86,$8c,$92,$98,$9e,$a4,$aa,$b0,$b6,$bc,$c2,$c8,$ce,$d4,$da
        !byte $20,$26,$2c,$32,$38,$3e,$44,$4a,$50,$56,$5c,$62,$68,$6e,$74,$7a
        !byte $80,$86,$8c,$92,$98,$9e,$a4,$aa,$b0,$b6,$bc,$c2,$c8,$ce,$d4,$da
        !byte $20,$26,$2c,$32,$38,$3e,$44,$4a,$50,$56,$5c,$62,$68,$6e,$74,$7a
        !byte $80,$86,$8c,$92,$98,$9e,$a4,$aa,$b0,$b6,$bc,$c2,$c8,$ce,$d4,$da
AcidBBass:
        !byte $15,$21,$1c,$15,$18,$21,$15,$1f,$15,$21,$1c,$15,$1a,$15,$21,$18
        !byte $15,$21,$1c,$15,$18,$21,$15,$1f,$15,$21,$1c,$15,$1a,$15,$21,$18
        !byte $1d,$29,$24,$1d,$20,$29,$1d,$27,$1d,$29,$24,$1d,$22,$1d,$29,$20
        !byte $1c,$28,$23,$1c,$1f,$28,$1c,$26,$1c,$28,$23,$1c,$21,$1c,$28,$1f
        !byte $15,$21,$1c,$15,$18,$21,$15,$1f,$15,$21,$1c,$15,$1a,$15,$21,$18
        !byte $15,$21,$1c,$15,$18,$21,$15,$1f,$15,$21,$1c,$15,$1a,$15,$21,$18
        !byte $1f,$2b,$26,$1f,$22,$2b,$1f,$29,$1f,$2b,$26,$1f,$24,$1f,$2b,$22
        !byte $1c,$28,$23,$1c,$1f,$28,$1c,$26,$1c,$28,$23,$1c,$21,$1c,$28,$1f
        !byte $15,$21,$1c,$15,$18,$21,$15,$1f,$15,$21,$1c,$15,$1a,$15,$21,$18
        !byte $15,$21,$1c,$15,$18,$21,$15,$1f,$15,$21,$1c,$15,$1a,$15,$21,$18
        !byte $1d,$29,$24,$1d,$20,$29,$1d,$27,$1d,$29,$24,$1d,$22,$1d,$29,$20
        !byte $1c,$28,$23,$1c,$1f,$28,$1c,$26,$1c,$28,$23,$1c,$21,$1c,$28,$1f
        !byte $1a,$26,$21,$1a,$1d,$26,$1a,$24,$1a,$26,$21,$1a,$1f,$1a,$26,$1d
        !byte $1f,$2b,$26,$1f,$22,$2b,$1f,$29,$1f,$2b,$26,$1f,$24,$1f,$2b,$22
        !byte $1c,$28,$23,$1c,$1f,$28,$1c,$26,$1c,$28,$23,$1c,$21,$1c,$28,$1f
        !byte $15,$21,$1c,$15,$18,$21,$15,$1f,$15,$21,$1c,$15,$1a,$15,$21,$18
AcidBArp0:
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
AcidBArp1:
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
AcidBArp2:
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $35,$3c,$41,$3c,$35,$3c,$41,$3c,$35,$3c,$41,$3c,$35,$3c,$41,$3c
        !byte $34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $37,$3e,$43,$3e,$37,$3e,$43,$3e,$37,$3e,$43,$3e,$37,$3e,$43,$3e
        !byte $34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
        !byte $35,$3c,$41,$3c,$35,$3c,$41,$3c,$35,$3c,$41,$3c,$35,$3c,$41,$3c
        !byte $34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b
        !byte $32,$39,$3e,$39,$32,$39,$3e,$39,$32,$39,$3e,$39,$32,$39,$3e,$39
        !byte $37,$3e,$43,$3e,$37,$3e,$43,$3e,$37,$3e,$43,$3e,$37,$3e,$43,$3e
        !byte $34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b,$34,$3b,$40,$3b
        !byte $2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34,$2d,$34,$39,$34
AcidBDrum:
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
AcidBFilt:
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4
        !byte $30,$3c,$48,$54,$60,$6c,$78,$84,$90,$9c,$a8,$b4,$c0,$cc,$d8,$e4

; 8 subtunes: 0 dark  1 driving  2-3 DREAMY(512)  4-5 TECHNO(512)  6-7 ACID(512)
;  the A/B pairs share instruments+key so each plays as one seamless 512-row arc.
;  >>> 4th original 512-row tune: TRANCE <<<
TranceABass:
        !byte $15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff
        !byte $1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff
        !byte $15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff
        !byte $1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff
        !byte $15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff
        !byte $1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff
        !byte $15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff
        !byte $1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff
TranceAArp0:
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
TranceAArp1:
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
TranceAArp2:
        !byte $2d,$34,$30,$34,$2d,$34,$30,$34,$2d,$34,$30,$34,$2d,$34,$30,$34
        !byte $30,$37,$34,$37,$30,$37,$34,$37,$30,$37,$34,$37,$30,$37,$34,$37
        !byte $37,$3e,$3b,$3e,$37,$3e,$3b,$3e,$37,$3e,$3b,$3e,$37,$3e,$3b,$3e
        !byte $35,$3c,$39,$3c,$35,$3c,$39,$3c,$35,$3c,$39,$3c,$35,$3c,$39,$3c
        !byte $2d,$34,$30,$34,$2d,$34,$30,$34,$2d,$34,$30,$34,$2d,$34,$30,$34
        !byte $30,$37,$34,$37,$30,$37,$34,$37,$30,$37,$34,$37,$30,$37,$34,$37
        !byte $37,$3e,$3b,$3e,$37,$3e,$3b,$3e,$37,$3e,$3b,$3e,$37,$3e,$3b,$3e
        !byte $35,$3c,$39,$3c,$35,$3c,$39,$3c,$35,$3c,$39,$3c,$35,$3c,$39,$3c
        !byte $2d,$34,$30,$34,$2d,$34,$30,$34,$2d,$34,$30,$34,$2d,$34,$30,$34
        !byte $30,$37,$34,$37,$30,$37,$34,$37,$30,$37,$34,$37,$30,$37,$34,$37
        !byte $37,$3e,$3b,$3e,$37,$3e,$3b,$3e,$37,$3e,$3b,$3e,$37,$3e,$3b,$3e
        !byte $35,$3c,$39,$3c,$35,$3c,$39,$3c,$35,$3c,$39,$3c,$35,$3c,$39,$3c
        !byte $2d,$34,$30,$34,$2d,$34,$30,$34,$2d,$34,$30,$34,$2d,$34,$30,$34
        !byte $30,$37,$34,$37,$30,$37,$34,$37,$30,$37,$34,$37,$30,$37,$34,$37
        !byte $37,$3e,$3b,$3e,$37,$3e,$3b,$3e,$37,$3e,$3b,$3e,$37,$3e,$3b,$3e
        !byte $35,$3c,$39,$3c,$35,$3c,$39,$3c,$35,$3c,$39,$3c,$35,$3c,$39,$3c
TranceADrum:
        !byte $00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02
        !byte $00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02
        !byte $00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02
        !byte $00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
TranceAFilt:
        !byte $88,$8a,$8c,$8e,$90,$92,$94,$97,$99,$9b,$9d,$9f,$a1,$a3,$a5,$a7
        !byte $a9,$ab,$ad,$af,$b1,$b3,$b5,$b7,$b8,$ba,$bc,$be,$bf,$c1,$c3,$c4
        !byte $c6,$c7,$c9,$ca,$cc,$cd,$ce,$cf,$d1,$d2,$d3,$d4,$d5,$d6,$d7,$d8
        !byte $d9,$da,$da,$db,$dc,$dc,$dd,$dd,$de,$de,$df,$df,$df,$df,$df,$df
        !byte $e0,$df,$df,$df,$df,$df,$df,$de,$de,$dd,$dd,$dc,$dc,$db,$da,$da
        !byte $d9,$d8,$d7,$d6,$d5,$d4,$d3,$d2,$d1,$cf,$ce,$cd,$cc,$ca,$c9,$c7
        !byte $c6,$c4,$c3,$c1,$bf,$be,$bc,$ba,$b8,$b7,$b5,$b3,$b1,$af,$ad,$ab
        !byte $a9,$a7,$a5,$a3,$a1,$9f,$9d,$9b,$99,$97,$94,$92,$90,$8e,$8c,$8a
        !byte $88,$85,$83,$81,$7f,$7d,$7b,$78,$76,$74,$72,$70,$6e,$6c,$6a,$68
        !byte $66,$64,$62,$60,$5e,$5c,$5a,$58,$57,$55,$53,$51,$50,$4e,$4c,$4b
        !byte $49,$48,$46,$45,$43,$42,$41,$40,$3e,$3d,$3c,$3b,$3a,$39,$38,$37
        !byte $36,$35,$35,$34,$33,$33,$32,$32,$31,$31,$30,$30,$30,$30,$30,$30
        !byte $30,$30,$30,$30,$30,$30,$30,$31,$31,$32,$32,$33,$33,$34,$35,$35
        !byte $36,$37,$38,$39,$3a,$3b,$3c,$3d,$3e,$40,$41,$42,$43,$45,$46,$48
        !byte $49,$4b,$4c,$4e,$50,$51,$53,$55,$57,$58,$5a,$5c,$5e,$60,$62,$64
        !byte $66,$68,$6a,$6c,$6e,$70,$72,$74,$76,$78,$7b,$7d,$7f,$81,$83,$85
TranceBBass:
        !byte $15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff
        !byte $1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff
        !byte $15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1c,$ff,$28,$ff,$1c,$ff,$28,$ff,$1c,$ff,$28,$ff,$1c,$ff,$28,$ff
        !byte $1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff
        !byte $1a,$ff,$26,$ff,$1a,$ff,$26,$ff,$1a,$ff,$26,$ff,$1a,$ff,$26,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff
        !byte $1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff,$1d,$ff,$29,$ff
        !byte $1c,$ff,$28,$ff,$1c,$ff,$28,$ff,$1c,$ff,$28,$ff,$1c,$ff,$28,$ff
        !byte $18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff,$18,$ff,$24,$ff
        !byte $1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff,$1f,$ff,$2b,$ff
        !byte $15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff,$15,$ff,$21,$ff
TranceBArp0:
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32,$32
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d,$2d
TranceBArp1:
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35,$35
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39,$39
        !byte $37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37,$37
        !byte $34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34,$34
        !byte $3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b,$3b
        !byte $30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30,$30
TranceBArp2:
        !byte $30,$2d,$2f,$32,$30,$2d,$2f,$2d,$30,$2d,$2f,$32,$30,$2d,$2f,$2d
        !byte $34,$30,$32,$35,$34,$30,$32,$30,$34,$30,$32,$35,$34,$30,$32,$30
        !byte $3b,$37,$39,$3c,$3b,$37,$39,$37,$3b,$37,$39,$3c,$3b,$37,$39,$37
        !byte $39,$35,$37,$3b,$39,$35,$37,$35,$39,$35,$37,$3b,$39,$35,$37,$35
        !byte $30,$2d,$2f,$32,$30,$2d,$2f,$2d,$30,$2d,$2f,$32,$30,$2d,$2f,$2d
        !byte $34,$30,$32,$35,$34,$30,$32,$30,$34,$30,$32,$35,$34,$30,$32,$30
        !byte $37,$34,$35,$39,$37,$34,$35,$34,$37,$34,$35,$39,$37,$34,$35,$34
        !byte $39,$35,$37,$3b,$39,$35,$37,$35,$39,$35,$37,$3b,$39,$35,$37,$35
        !byte $35,$32,$34,$37,$35,$32,$34,$32,$35,$32,$34,$37,$35,$32,$34,$32
        !byte $34,$30,$32,$35,$34,$30,$32,$30,$34,$30,$32,$35,$34,$30,$32,$30
        !byte $3b,$37,$39,$3c,$3b,$37,$39,$37,$3b,$37,$39,$3c,$3b,$37,$39,$37
        !byte $39,$35,$37,$3b,$39,$35,$37,$35,$39,$35,$37,$3b,$39,$35,$37,$35
        !byte $37,$34,$35,$39,$37,$34,$35,$34,$37,$34,$35,$39,$37,$34,$35,$34
        !byte $34,$30,$32,$35,$34,$30,$32,$30,$34,$30,$32,$35,$34,$30,$32,$30
        !byte $3b,$37,$39,$3c,$3b,$37,$39,$37,$3b,$37,$39,$3c,$3b,$37,$39,$37
        !byte $30,$2d,$2f,$32,$30,$2d,$2f,$2d,$30,$2d,$2f,$32,$30,$2d,$2f,$2d
TranceBDrum:
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
        !byte $01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02,$01,$02,$00,$02
TranceBFilt:
        !byte $b0,$b6,$bc,$c2,$c8,$ce,$d3,$d8,$dd,$e1,$e5,$e8,$eb,$ed,$ee,$ef
        !byte $f0,$ef,$ee,$ed,$eb,$e8,$e5,$e1,$dd,$d8,$d3,$ce,$c8,$c2,$bc,$b6
        !byte $b0,$a9,$a3,$9d,$97,$91,$8c,$87,$82,$7e,$7a,$77,$74,$72,$71,$70
        !byte $70,$70,$71,$72,$74,$77,$7a,$7e,$82,$87,$8c,$91,$97,$9d,$a3,$a9
        !byte $b0,$b6,$bc,$c2,$c8,$ce,$d3,$d8,$dd,$e1,$e5,$e8,$eb,$ed,$ee,$ef
        !byte $f0,$ef,$ee,$ed,$eb,$e8,$e5,$e1,$dd,$d8,$d3,$ce,$c8,$c2,$bc,$b6
        !byte $b0,$a9,$a3,$9d,$97,$91,$8c,$87,$82,$7e,$7a,$77,$74,$72,$71,$70
        !byte $70,$70,$71,$72,$74,$77,$7a,$7e,$82,$87,$8c,$91,$97,$9d,$a3,$a9
        !byte $af,$b6,$bc,$c2,$c8,$ce,$d3,$d8,$dd,$e1,$e5,$e8,$eb,$ed,$ee,$ef
        !byte $f0,$ef,$ee,$ed,$eb,$e8,$e5,$e1,$dd,$d8,$d3,$ce,$c8,$c2,$bc,$b6
        !byte $b0,$a9,$a3,$9d,$97,$91,$8c,$87,$82,$7e,$7a,$77,$74,$72,$71,$70
        !byte $70,$70,$71,$72,$74,$77,$7a,$7e,$82,$87,$8c,$91,$97,$9d,$a3,$a9
        !byte $af,$b6,$bc,$c2,$c8,$ce,$d3,$d8,$dd,$e1,$e5,$e8,$eb,$ed,$ee,$ef
        !byte $f0,$ef,$ee,$ed,$eb,$e8,$e5,$e1,$dd,$d8,$d3,$ce,$c8,$c2,$bc,$b6
        !byte $b0,$a9,$a3,$9d,$97,$91,$8c,$87,$82,$7e,$7a,$77,$74,$72,$71,$70
        !byte $70,$70,$71,$72,$74,$77,$7a,$7e,$82,$87,$8c,$91,$97,$9d,$a3,$a9

;  >>> techno 3rd bank (768-row techno) <<<
TechnoCBass:
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $0e,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$21
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $13,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$26
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $0e,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$21
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $13,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$26
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $0e,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$21
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $13,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$26
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $0e,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$26,$1a,$1a,$1a,$21
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $13,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$26
TechnoCArp0:
        !byte $ff,$ff,$39,$ff,$39,$ff,$39,$ff,$ff,$ff,$39,$ff,$39,$ff,$39,$ff
        !byte $ff,$ff,$3e,$ff,$3e,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$3e,$ff,$3e,$ff
        !byte $ff,$ff,$41,$ff,$41,$ff,$41,$ff,$ff,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $ff,$ff,$43,$ff,$43,$ff,$43,$ff,$ff,$ff,$43,$ff,$43,$ff,$43,$ff
        !byte $ff,$ff,$39,$ff,$39,$ff,$39,$ff,$ff,$ff,$39,$ff,$39,$ff,$39,$ff
        !byte $ff,$ff,$3e,$ff,$3e,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$3e,$ff,$3e,$ff
        !byte $ff,$ff,$41,$ff,$41,$ff,$41,$ff,$ff,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $ff,$ff,$43,$ff,$43,$ff,$43,$ff,$ff,$ff,$43,$ff,$43,$ff,$43,$ff
        !byte $ff,$ff,$39,$ff,$39,$ff,$39,$ff,$ff,$ff,$39,$ff,$39,$ff,$39,$ff
        !byte $ff,$ff,$3e,$ff,$3e,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$3e,$ff,$3e,$ff
        !byte $ff,$ff,$41,$ff,$41,$ff,$41,$ff,$ff,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $ff,$ff,$43,$ff,$43,$ff,$43,$ff,$ff,$ff,$43,$ff,$43,$ff,$43,$ff
        !byte $ff,$ff,$39,$ff,$39,$ff,$39,$ff,$ff,$ff,$39,$ff,$39,$ff,$39,$ff
        !byte $ff,$ff,$3e,$ff,$3e,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$3e,$ff,$3e,$ff
        !byte $ff,$ff,$41,$ff,$41,$ff,$41,$ff,$ff,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $ff,$ff,$43,$ff,$43,$ff,$43,$ff,$ff,$ff,$43,$ff,$43,$ff,$43,$ff
TechnoCArp1:
        !byte $ff,$ff,$3c,$ff,$3c,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$3c,$ff,$3c,$ff
        !byte $ff,$ff,$41,$ff,$41,$ff,$41,$ff,$ff,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $ff,$ff,$45,$ff,$45,$ff,$45,$ff,$ff,$ff,$45,$ff,$45,$ff,$45,$ff
        !byte $ff,$ff,$47,$ff,$47,$ff,$47,$ff,$ff,$ff,$47,$ff,$47,$ff,$47,$ff
        !byte $ff,$ff,$3c,$ff,$3c,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$3c,$ff,$3c,$ff
        !byte $ff,$ff,$41,$ff,$41,$ff,$41,$ff,$ff,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $ff,$ff,$45,$ff,$45,$ff,$45,$ff,$ff,$ff,$45,$ff,$45,$ff,$45,$ff
        !byte $ff,$ff,$47,$ff,$47,$ff,$47,$ff,$ff,$ff,$47,$ff,$47,$ff,$47,$ff
        !byte $ff,$ff,$3c,$ff,$3c,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$3c,$ff,$3c,$ff
        !byte $ff,$ff,$41,$ff,$41,$ff,$41,$ff,$ff,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $ff,$ff,$45,$ff,$45,$ff,$45,$ff,$ff,$ff,$45,$ff,$45,$ff,$45,$ff
        !byte $ff,$ff,$47,$ff,$47,$ff,$47,$ff,$ff,$ff,$47,$ff,$47,$ff,$47,$ff
        !byte $ff,$ff,$3c,$ff,$3c,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$3c,$ff,$3c,$ff
        !byte $ff,$ff,$41,$ff,$41,$ff,$41,$ff,$ff,$ff,$41,$ff,$41,$ff,$41,$ff
        !byte $ff,$ff,$45,$ff,$45,$ff,$45,$ff,$ff,$ff,$45,$ff,$45,$ff,$45,$ff
        !byte $ff,$ff,$47,$ff,$47,$ff,$47,$ff,$ff,$ff,$47,$ff,$47,$ff,$47,$ff
TechnoCArp2:
        !byte $ff,$ff,$40,$ff,$40,$ff,$40,$ff,$ff,$ff,$40,$ff,$40,$ff,$40,$ff
        !byte $ff,$ff,$45,$ff,$45,$ff,$45,$ff,$ff,$ff,$45,$ff,$45,$ff,$45,$ff
        !byte $ff,$ff,$48,$ff,$48,$ff,$48,$ff,$ff,$ff,$48,$ff,$48,$ff,$48,$ff
        !byte $ff,$ff,$4a,$ff,$4a,$ff,$4a,$ff,$ff,$ff,$4a,$ff,$4a,$ff,$4a,$ff
        !byte $ff,$ff,$40,$ff,$40,$ff,$40,$ff,$ff,$ff,$40,$ff,$40,$ff,$40,$ff
        !byte $ff,$ff,$45,$ff,$45,$ff,$45,$ff,$ff,$ff,$45,$ff,$45,$ff,$45,$ff
        !byte $ff,$ff,$48,$ff,$48,$ff,$48,$ff,$ff,$ff,$48,$ff,$48,$ff,$48,$ff
        !byte $ff,$ff,$4a,$ff,$4a,$ff,$4a,$ff,$ff,$ff,$4a,$ff,$4a,$ff,$4a,$ff
        !byte $ff,$ff,$40,$ff,$40,$ff,$40,$ff,$ff,$ff,$40,$ff,$40,$ff,$40,$ff
        !byte $ff,$ff,$45,$ff,$45,$ff,$45,$ff,$ff,$ff,$45,$ff,$45,$ff,$45,$ff
        !byte $ff,$ff,$48,$ff,$48,$ff,$48,$ff,$ff,$ff,$48,$ff,$48,$ff,$48,$ff
        !byte $ff,$ff,$4a,$ff,$4a,$ff,$4a,$ff,$ff,$ff,$4a,$ff,$4a,$ff,$4a,$ff
        !byte $ff,$ff,$40,$ff,$40,$ff,$40,$ff,$ff,$ff,$40,$ff,$40,$ff,$40,$ff
        !byte $ff,$ff,$45,$ff,$45,$ff,$45,$ff,$ff,$ff,$45,$ff,$45,$ff,$45,$ff
        !byte $ff,$ff,$48,$ff,$48,$ff,$48,$ff,$ff,$ff,$48,$ff,$48,$ff,$48,$ff
        !byte $ff,$ff,$4a,$ff,$4a,$ff,$4a,$ff,$ff,$ff,$4a,$ff,$4a,$ff,$4a,$ff
TechnoCDrum:
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
TechnoCFilt:
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f

SongBassLo: !byte <MUS_BASS,<Song1Bass,<BerlinABass,<BerlinBBass,<TechnoABass,<TechnoBBass,<TechnoCBass,<AcidABass,<AcidBBass, <TranceABass,<TranceBBass
SongBassHi: !byte >MUS_BASS,>Song1Bass,>BerlinABass,>BerlinBBass,>TechnoABass,>TechnoBBass,>TechnoCBass,>AcidABass,>AcidBBass, >TranceABass,>TranceBBass
SongArp0Lo: !byte <MUS_ARP0,<Song1Arp0,<BerlinAArp0,<BerlinBArp0,<TechnoAArp0,<TechnoBArp0,<TechnoCArp0,<AcidAArp0,<AcidBArp0, <TranceAArp0,<TranceBArp0
SongArp0Hi: !byte >MUS_ARP0,>Song1Arp0,>BerlinAArp0,>BerlinBArp0,>TechnoAArp0,>TechnoBArp0,>TechnoCArp0,>AcidAArp0,>AcidBArp0, >TranceAArp0,>TranceBArp0
SongArp1Lo: !byte <MUS_ARP1,<Song1Arp1,<BerlinAArp1,<BerlinBArp1,<TechnoAArp1,<TechnoBArp1,<TechnoCArp1,<AcidAArp1,<AcidBArp1, <TranceAArp1,<TranceBArp1
SongArp1Hi: !byte >MUS_ARP1,>Song1Arp1,>BerlinAArp1,>BerlinBArp1,>TechnoAArp1,>TechnoBArp1,>TechnoCArp1,>AcidAArp1,>AcidBArp1, >TranceAArp1,>TranceBArp1
SongArp2Lo: !byte <MUS_ARP2,<Song1Arp2,<BerlinAArp2,<BerlinBArp2,<TechnoAArp2,<TechnoBArp2,<TechnoCArp2,<AcidAArp2,<AcidBArp2, <TranceAArp2,<TranceBArp2
SongArp2Hi: !byte >MUS_ARP2,>Song1Arp2,>BerlinAArp2,>BerlinBArp2,>TechnoAArp2,>TechnoBArp2,>TechnoCArp2,>AcidAArp2,>AcidBArp2, >TranceAArp2,>TranceBArp2
SongDrumLo: !byte <MUS_DRUM,<Song1Drum,<BerlinADrum,<BerlinBDrum,<TechnoADrum,<TechnoBDrum,<TechnoCDrum,<AcidADrum,<AcidBDrum, <TranceADrum,<TranceBDrum
SongDrumHi: !byte >MUS_DRUM,>Song1Drum,>BerlinADrum,>BerlinBDrum,>TechnoADrum,>TechnoBDrum,>TechnoCDrum,>AcidADrum,>AcidBDrum, >TranceADrum,>TranceBDrum
SongFiltLo: !byte <MUS_FILT,<Song1Filt,<BerlinAFilt,<BerlinBFilt,<TechnoAFilt,<TechnoBFilt,<TechnoCFilt,<AcidAFilt,<AcidBFilt, <TranceAFilt,<TranceBFilt
SongFiltHi: !byte >MUS_FILT,>Song1Filt,>BerlinAFilt,>BerlinBFilt,>TechnoAFilt,>TechnoBFilt,>TechnoCFilt,>AcidAFilt,>AcidBFilt, >TranceAFilt,>TranceBFilt

; per-style instrument / mix (A/B pairs identical so 512-row tunes are seamless)
StyleBassWaveTbl: !byte $21, $41, $21,$21, $21,$21,$61, $21,$21, $21,$21
StyleArpWaveTbl:  !byte $41, $41, $41,$41, $15,$13,$61, $41,$41, $41,$41
StyleSpeedTbl:    !byte 6,   4,   5,5,   5,5,5,   3,3, 3,3
StyleResTbl:      !byte $c1, $31, $f1,$f1, $f3,$f3,$f7, $f1,$f1, $f1,$f1
StyleXposeTbl:    !byte 0,   0,   0,0,     0,0,0,   0,0, 0,0
StyleVolTbl:      !byte $1f, $1f, $1f,$1f, $1f,$3f,$5f, $1f,$1f, $1f,$1f
; per-style SID programming: ADSR + PWM/filter LFO.  Active trip styles 2..6 use
; progressively more real SID techno: saw/pulse bass, ringmod acid, hard-sync lead,
; combined saw+pulse peak and higher resonance/filter movement.
StyleBassADTbl:   !byte $08, $08, $08,$08, $06,$05,$04, $08,$08, $08,$08
StyleBassSRTbl:   !byte $78, $78, $78,$68, $58,$78,$88, $78,$78, $78,$78
StyleArpADTbl:    !byte $00, $00, $00,$00, $02,$04,$02, $00,$00, $00,$00
StyleArpSRTbl:    !byte $f8, $f8, $48,$68, $78,$a8,$98, $f8,$f8, $f8,$f8
StylePwmBaseTbl:  !byte $04, $04, $04,$04, $05,$04,$03, $04,$04, $04,$04
StylePwmStepTbl:  !byte $02, $02, $02,$03, $04,$06,$07, $02,$02, $02,$02
StyleFiltStepTbl: !byte $03, $03, $02,$03, $04,$06,$08, $03,$03, $03,$03

; which style each of the 10 parts uses
;             title mat rng pls hyp vor xor wav tun star
PartStyleTbl: !byte 0,   3,  2,  1,  3,  1,  3,  2,  1,  3,  0

styleBassWave: !byte $21
styleArpWave:  !byte $41
stylePwmBase:  !byte $04
stylePwmStep:  !byte $02
styleFiltStep: !byte $03


; ============================================================================
;  Shared data tables
; ============================================================================
; Screen / colour row pointers
ScrRowLo: !for r,0,24 { !byte <(SCREEN + r*40) }
ScrRowHi: !for r,0,24 { !byte >(SCREEN + r*40) }
ColRowLo: !for r,0,24 { !byte <(COLOR + r*40) }
ColRowHi: !for r,0,24 { !byte >(COLOR + r*40) }

; Rings distance table: index = (((dx^2+dy^2)/8) & 15), centre (20,12)
DistBase:
!for r,0,24 {
  !for c,0,39 {
    !byte ( ( ((c-20)*(c-20) + (r-12)*(r-12)) / 8 ) & $0f )
  }
}
DistLo: !for r,0,24 { !byte <(DistBase + r*40) }
DistHi: !for r,0,24 { !byte >(DistBase + r*40) }

; Rings 16-colour chromatic palette (no greys/black/white)
PAL16:
        !byte $02,$08,$07,$0d,$05,$03,$0e,$06,$04,$0a,$08,$07,$0d,$05,$03,$06

; Sine (values 0..32) for starfield colour shimmer
; Full 256-byte sine (amplitude 0..31) so any 8-bit index is in-bounds.
Sin256:
        !byte $10,$10,$10,$11,$11,$11,$12,$12,$13,$13,$13,$14,$14,$14,$15,$15
        !byte $15,$16,$16,$16,$17,$17,$17,$18,$18,$18,$19,$19,$19,$1a,$1a,$1a
        !byte $1a,$1b,$1b,$1b,$1b,$1c,$1c,$1c,$1c,$1d,$1d,$1d,$1d,$1d,$1e,$1e
        !byte $1e,$1e,$1e,$1e,$1e,$1e,$1f,$1f,$1f,$1f,$1f,$1f,$1f,$1f,$1f,$1f
        !byte $1f,$1f,$1f,$1f,$1f,$1f,$1f,$1f,$1f,$1f,$1f,$1e,$1e,$1e,$1e,$1e
        !byte $1e,$1e,$1e,$1d,$1d,$1d,$1d,$1d,$1c,$1c,$1c,$1c,$1b,$1b,$1b,$1b
        !byte $1a,$1a,$1a,$1a,$19,$19,$19,$18,$18,$18,$17,$17,$17,$16,$16,$16
        !byte $15,$15,$15,$14,$14,$14,$13,$13,$13,$12,$12,$11,$11,$11,$10,$10
        !byte $10,$0f,$0f,$0e,$0e,$0e,$0d,$0d,$0c,$0c,$0c,$0b,$0b,$0b,$0a,$0a
        !byte $0a,$09,$09,$09,$08,$08,$08,$07,$07,$07,$06,$06,$06,$05,$05,$05
        !byte $05,$04,$04,$04,$04,$03,$03,$03,$03,$02,$02,$02,$02,$02,$01,$01
        !byte $01,$01,$01,$01,$01,$01,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        !byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$01,$01,$01,$01,$01
        !byte $01,$01,$01,$02,$02,$02,$02,$02,$03,$03,$03,$03,$04,$04,$04,$04
        !byte $05,$05,$05,$05,$06,$06,$06,$07,$07,$07,$08,$08,$08,$09,$09,$09
        !byte $0a,$0a,$0a,$0b,$0b,$0b,$0c,$0c,$0c,$0d,$0d,$0e,$0e,$0e,$0f,$0f

; Sparkle/cycle palette (1..15)
ColorCycle:
        !byte $08,$08,$08,$09,$09,$09,$0a,$0a,$0a,$0b,$0b,$0b,$0c,$0c,$0c,$0d
        !byte $0d,$0d,$0e,$0e,$0e,$0f,$0f,$0f,$0e,$0e,$0e,$0d,$0d,$0d,$0c,$0c
        !byte $0c,$0b,$0b,$0b,$0a,$0a,$0a,$09,$09,$09,$08,$08,$08,$07,$07,$07
        !byte $06,$06,$06,$05,$05,$05,$04,$04,$04,$03,$03,$03,$02,$02,$02,$01
        !byte $01,$01,$02,$02,$02,$03,$03,$03,$04,$04,$04,$05,$05,$05,$06,$06
        !byte $06,$07,$07,$07,$08,$08,$08,$09,$09,$09,$0a,$0a,$0a,$0b,$0b,$0b
        !byte $0c,$0c,$0c,$0d,$0d,$0d,$0e,$0e,$0e,$0f,$0f,$0f,$0e,$0e,$0e,$0d
        !byte $0d,$0d,$0c,$0c,$0c,$0b,$0b,$0b,$0a,$0a,$0a,$09,$09,$09,$08,$08

; Scroller glow ramp (32, loops) - light blue -> white -> light blue
GlowRamp:
        !byte $0e,$0e,$0e,$03,$03,$0d,$0d,$01
        !byte $01,$01,$0f,$0f,$0f,$0f,$0f,$0f
        !byte $0f,$0f,$0f,$0f,$01,$01,$01,$0d
        !byte $0d,$03,$03,$0e,$0e,$0e,$0e,$0e

;  >>> imported-effect data tables <<<
; Extra effect tables
HeartWidth:  !byte 0,1,3,6,10,14,17,19,20,20,19,18,17,15,13,10,8,6,4,3,2,1,0,0,0
HeartChars:  !byte $20,$e2,$e3,$e4
HeartColors: !byte $09,$08,$07,$0f,$01,$0f,$07,$08,$09,$08,$07,$0f,$01,$0f,$07,$08
WaveHeight:  !byte 4,8,13,18,22,19,14,10,6,11,17,23,20,15,9,5
GridChars:   !byte $2d,$2b,$5c,$2f,$e2,$e3,$e4,$e5
GridColors:  !byte $06,$0e,$03,$0d,$01,$07,$0f,$07,$01,$0d,$03,$0e,$06,$0b,$0c,$0b
TunnelZoomColors: !byte $00,$06,$06,$0e,$0e,$03,$03,$0d,$0d,$01,$07,$0f,$07,$01,$0d,$03
SafeWobble32:
        !byte $00,$01,$02,$03,$04,$03,$02,$01,$00,$ff,$fe,$fd,$fc,$fd,$fe,$ff
        !byte $00,$01,$02,$03,$04,$03,$02,$01,$00,$ff,$fe,$fd,$fc,$fd,$fe,$ff
SafeTunnelChars:
        !byte $20,$20,$2e,$2e,$21,$21,$22,$22,$23,$23,$2a,$2a,$e2,$e3,$e4,$e5
SafeTunnelColors:
        !byte $06,$0e,$03,$0d,$07,$08,$02,$0a,$04,$0c,$0f,$0b,$09,$08,$07,$06
HeartTrailChars:
        !byte $20,$2e,$20,$2b,$20,$2a,$20,$2e
GoldenHaloChars:
        !byte $20,$2e,$2b,$2a,$e2,$e3,$e4,$e5
HeartVoyagerGold:
        !byte $09,$08,$07,$0f,$01,$0f,$07,$08,$09,$08,$07,$0f,$01,$0f,$07,$08
MultiplexCubeChars:
        !byte $2d,$5c,$2f,$2b,$e2,$e3,$e4,$e5
MultiplexCubeColors:
        !byte $06,$0e,$03,$0d,$01,$07,$0f,$07,$01,$0d,$03,$0e,$06,$0b,$0c,$0b
RasterBootChars:
        !byte $23,$23,$22,$22,$21,$21,$20,$20,$20,$20,$21,$21,$22,$22,$23,$23
RasterBootColors:
        !byte $06,$06,$0e,$0e,$03,$03,$0d,$0d,$01,$07,$0f,$07,$01,$0d,$03,$06

CyberGridChars:
        !byte $20,$2e,$2b,$2a,$e2,$e3,$e4,$e5,$2d,$5c,$2f,$2b,$e2,$e3,$e4,$e5
CyberColors:
        !byte $00,$06,$0b,$0c,$0f,$01,$07,$0d,$03,$0e,$06,$0b,$0c,$0f,$01,$07
SafeTunnelPrimeChars:
        !byte $20,$20,$2e,$2e,$21,$21,$22,$22,$23,$23,$2a,$2a,$e2,$e3,$e4,$e5
BlackOrbitMask:
        !byte 1,0,0,1,0,1,0,0,1,0,0,1,0,1,0,0
BlackOrbitChars:
        !byte $2e,$20,$20,$2b,$20,$2a,$20,$20,$e2,$20,$20,$e3,$20,$e4,$20,$20
BlackOrbitColors:
        !byte $06,$00,$00,$0b,$00,$0c,$00,$00,$0f,$00,$00,$01,$00,$07,$00,$00
RcFrontX0:
        !byte 8,9,10,11,12,13,12,11,10,9,8,7,6,7,8,8
RcFrontX1:
        !byte 30,31,32,33,34,33,32,31,30,29,28,27,26,27,28,29
RcFrontY0:
        !byte 5,5,6,6,7,7,8,8,7,7,6,6,5,5,4,4
RcFrontY1:
        !byte 18,18,17,17,16,16,15,15,16,16,17,17,18,18,19,19
RcBackX0:
        !byte 12,11,10,9,8,7,8,9,10,11,12,13,14,13,12,12
RcBackX1:
        !byte 26,25,24,23,22,23,24,25,26,27,28,29,30,29,28,27
RcBackY0:
        !byte 8,8,7,7,6,6,5,5,6,6,7,7,8,8,9,9
RcBackY1:
        !byte 15,15,16,16,17,17,18,18,17,17,16,16,15,15,14,14
BridgeChars:
        !byte $20,$2e,$2b,$2a,$e2,$e3,$e4,$e5
BridgeColors:
        !byte $00,$06,$0b,$0c,$0f,$01,$07,$0d,$03,$0e,$06,$0b,$0c,$0f,$01,$07
EndtroGreetingRow:
        !byte $13,$14,$0f,$10,$20,$14,$0f,$20,$07,$12,$05,$05,$14,$20,$13,$14,$09,$01,$0e,$20,$12,$15,$0e,$01,$12,$20,$13,$16,$05,$09,$0e,$20,$0d,$01,$07,$0e,$15,$13,$20,$08

RotorCubeChars:
        !byte $2d,$5c,$2f,$2b,$e2,$e3,$e4,$e5
RotorCubeColors:
        !byte $06,$0e,$03,$0d,$01,$07,$0f,$07,$01,$0d,$03,$0e,$06,$0b,$0c,$0b

; Title background pulse (8 dark steps; keeps title text readable)
TitleBgPulse:
        !byte $00,$00,$06,$06,$0b,$06,$06,$00

; ============================================================================
;  Text  (screen codes via !scr, $ff-terminated)
; ============================================================================
; NOTE: ACME !scr maps lowercase a-z -> screen codes $01-$1a (the letter
; glyphs in the uppercase ROM font).  Uppercase a-z would map to $41-$5a =
; graphics, so all on-screen text is written here in lowercase.
TitleA: !scr "berlin" : !byte $ff
TitleB: !scr "a trip" : !byte $ff
TitleC: !scr "from the airport" : !byte $ff
TitleD: !scr "to the golden heart hotel" : !byte $ff

; Per-part title cards (indexed by nextPart)
CardName0: !scr "golden heart hotel" : !byte $ff
CardSub0:  !scr "you have arrived" : !byte $ff
CardName1: !scr "flughafen ber" : !byte $ff
CardSub1:  !scr "airport express" : !byte $ff
CardName2: !scr "terminal one two" : !byte $ff
CardSub2:  !scr "follow the signs" : !byte $ff
CardName3: !scr "wassmannsdorf" : !byte $ff
CardSub3:  !scr "regional fex" : !byte $ff
CardName4: !scr "schoenefeld" : !byte $ff
CardSub4:  !scr "s9 to the city" : !byte $ff
CardName5: !scr "gruenbergallee" : !byte $ff
CardSub5:  !scr "mind the gap" : !byte $ff
CardName6: !scr "adlershof" : !byte $ff
CardSub6:  !scr "s-bahn south" : !byte $ff
CardName7: !scr "schoeneweide" : !byte $ff
CardSub7:  !scr "change here" : !byte $ff
CardName8: !scr "baumschulenweg" : !byte $ff
CardSub8:  !scr "next stop" : !byte $ff
CardName9: !scr "plaenterwald" : !byte $ff
CardSub9:  !scr "along the spree" : !byte $ff
CardName10: !scr "treptower park" : !byte $ff
CardSub10:  !scr "doors open left" : !byte $ff
CardName11: !scr "ostkreuz" : !byte $ff
CardSub11:  !scr "change for s3 s5 s7" : !byte $ff
CardName12: !scr "warschauer strasse" : !byte $ff
CardSub12:  !scr "u1 u3" : !byte $ff
CardName13: !scr "ostbahnhof" : !byte $ff
CardSub13:  !scr "mainline north" : !byte $ff
CardName14: !scr "jannowitzbruecke" : !byte $ff
CardSub14:  !scr "over the river" : !byte $ff
CardName15: !scr "alexanderplatz" : !byte $ff
CardSub15:  !scr "change u2 u5 u8" : !byte $ff
CardName16: !scr "hackescher markt" : !byte $ff
CardSub16:  !scr "old town" : !byte $ff
CardName17: !scr "friedrichstrasse" : !byte $ff
CardSub17:  !scr "interchange" : !byte $ff
CardName18: !scr "brandenburger tor" : !byte $ff
CardSub18:  !scr "under the gate" : !byte $ff
CardName19: !scr "potsdamer platz" : !byte $ff
CardSub19:  !scr "downtown" : !byte $ff
CardName20: !scr "gleisdreieck" : !byte $ff
CardSub20:  !scr "u1 u2 u3" : !byte $ff
CardName21: !scr "moeckernbruecke" : !byte $ff
CardSub21:  !scr "next stop" : !byte $ff
CardName22: !scr "hallesches tor" : !byte $ff
CardSub22:  !scr "u1 u6" : !byte $ff
CardName23: !scr "kottbusser tor" : !byte $ff
CardSub23:  !scr "kotti by night" : !byte $ff
CardName24: !scr "goerlitzer bahnhof" : !byte $ff
CardSub24:  !scr "almost there" : !byte $ff
CardName25: !scr "schlesisches tor" : !byte $ff
CardSub25:  !scr "last change" : !byte $ff
CardName26: !scr "warschauer bruecke" : !byte $ff
CardSub26:  !scr "up the stairs" : !byte $ff
CardName27: !scr "boxhagener platz" : !byte $ff
CardSub27:  !scr "one block to go" : !byte $ff
CardNameLo: !byte <CardName0, <CardName1, <CardName2, <CardName3, <CardName4, <CardName5, <CardName6, <CardName7, <CardName8, <CardName9, <CardName10, <CardName11, <CardName12, <CardName13, <CardName14, <CardName15, <CardName16, <CardName17, <CardName18, <CardName19, <CardName20, <CardName21, <CardName22, <CardName23, <CardName24, <CardName25, <CardName26, <CardName27
CardNameHi: !byte >CardName0, >CardName1, >CardName2, >CardName3, >CardName4, >CardName5, >CardName6, >CardName7, >CardName8, >CardName9, >CardName10, >CardName11, >CardName12, >CardName13, >CardName14, >CardName15, >CardName16, >CardName17, >CardName18, >CardName19, >CardName20, >CardName21, >CardName22, >CardName23, >CardName24, >CardName25, >CardName26, >CardName27
CardSubLo: !byte <CardSub0, <CardSub1, <CardSub2, <CardSub3, <CardSub4, <CardSub5, <CardSub6, <CardSub7, <CardSub8, <CardSub9, <CardSub10, <CardSub11, <CardSub12, <CardSub13, <CardSub14, <CardSub15, <CardSub16, <CardSub17, <CardSub18, <CardSub19, <CardSub20, <CardSub21, <CardSub22, <CardSub23, <CardSub24, <CardSub25, <CardSub26, <CardSub27
CardSubHi: !byte >CardSub0, >CardSub1, >CardSub2, >CardSub3, >CardSub4, >CardSub5, >CardSub6, >CardSub7, >CardSub8, >CardSub9, >CardSub10, >CardSub11, >CardSub12, >CardSub13, >CardSub14, >CardSub15, >CardSub16, >CardSub17, >CardSub18, >CardSub19, >CardSub20, >CardSub21, >CardSub22, >CardSub23, >CardSub24, >CardSub25, >CardSub26, >CardSub27

ScrollMsg:
!scr "   berlin - a trip from the airport to the golden heart hotel   ....   "
!scr "touchdown at flughafen ber - grab your bag and follow the signs down to the platform   ....   "
!scr "the airport express slides into the tunnel - neon strip lights flicker past the window   ....   "
!scr "through schoeneweide - ostkreuz - alexanderplatz - the whole city rolls by underground   ....   "
!scr "one last change - up the stairs into the warm berlin night   ....   "
!scr "now arriving at  -  "
!scr "                " : !byte $ff : !scr "   schoeneweide   "
!scr "                " : !byte $ff : !scr "   ostkreuz   "
!scr "                " : !byte $ff : !scr "   alexanderplatz   "
!scr "                " : !byte $ff : !scr "   kottbusser tor   "
!scr "                " : !byte $ff : !scr "   warschauer bruecke   "
!scr "                " : !byte $ff : !scr "   golden heart hotel   "
!scr "   checked in - the techno still humming in your chest   -   "
!scr "                                        "
ScrollMsgEnd:
ScrollCore = ScrollMsgEnd - ScrollMsg - 40   ; (16-bit now; no 255 cap)

; ============================================================================
;  size guard
; ============================================================================

; ============================================================================
;  NEW EFFECTS (gold cube zip) - placed at end so the page-sensitive effect
;  code region is never shifted by a large amount.
; ============================================================================
NfxCoolPalette:      !byte $06,$0e,$03,$0d,$01,$07,$0f,$07,$01,$0d,$03,$0e,$06,$0b,$0c,$0b
NfxWireRows:         !byte 5,6,7,8,10,12,14,16,18,19,20,21
NfxWireChars:        !byte $2d,$2d,$5c,$2f,$2b,$2a,$2a,$2b,$2f,$5c,$2d,$2d,$2b,$2a,$2d,$5c,$2f,$2b,$2a,$2d,$5c,$2f,$2b,$2a
NfxWireColors:       !byte $06,$0e,$03,$0d,$01,$07,$0f,$07,$01,$0d,$03,$0e
NfxCorridorChars:    !byte $20,$20,$2e,$2e,$3a,$3a,$2b,$2b,$2a,$2a,$e2,$e3,$e4,$e5,$a0,$a0
NfxCorridorColors:   !byte $00,$06,$06,$0e,$0e,$03,$03,$0d,$0d,$01,$07,$0f,$07,$01,$0d,$03
NfxCorridorBg:       !byte $00,$00,$06,$06,$0b,$06,$00,$00,$00,$00,$06,$0b,$06,$00,$00,$00
NfxCorridorBorder:   !byte $06,$0e,$03,$0d,$01,$07,$0f,$07,$01,$0d,$03,$0e,$06,$0b,$0c,$0b
NfxColWarp:          !byte 0,1,1,2,2,3,4,5,6,7,8,9,10,11,12,11,10,9,8,7,6,5,4,3,2,2,1,1,0,1,2,3,4,3,2,1,0,1,2,3
NfxGoldBorder:       !byte $08,$09,$07,$0f,$01,$0f,$07,$08
NfxGoldDimPalette: !byte $09,$08,$0a,$0f
NfxGoldPalette:      !byte $09,$08,$07,$0f,$01,$0f,$07,$08,$09,$08,$07,$0f,$01,$0f,$07,$08
NfxGoldWallChars:    !byte $2f,$5c,$2d,$3d,$2b,$2a,$2f,$5c
NfxTrenchLeft:       !byte 1,2,3,4,5,6,7,8,9,10,11,12,12,11,10,9,8,7,6,5,4,3,2,1
NfxTrenchRight:      !byte 38,37,36,35,34,33,32,31,30,29,28,27,27,28,29,30,31,32,33,34,35,36,37,38
NfxCubePalette:      !byte $06,$0e,$03,$0d,$01,$07,$0f,$07,$01,$0d,$03,$0e,$06,$0b,$0c,$0b
NfxCubeRow:          !byte 6,7,8,9,10,11,13,14,15,16,17,18,8,10,14,16
NfxCubePhase:        !byte 0,3,6,9,12,15,18,21,24,27,30,1,4,10,16,22

NfxWireTitle:     !scr "wire cube clean" : !byte $ff
NfxInfinityTitle: !scr "infinity corridor" : !byte $ff
NfxGoldTitle:     !scr "gold trench" : !byte $ff
NfxCubeTitle:     !scr "cube v3 rotor" : !byte $ff

!zone new_wire_cube
nw_phase !byte 0
nw_init:
        jsr ClearScreenColor
        lda #<NfxWireTitle
        sta TXTP
        lda #>NfxWireTitle
        sta TXTP_HI
        ldx #2
        jsr PrintCenteredAuto
        rts

nw_update:
        inc nw_phase
        lda nw_phase
        lsr
        clc
        adc sndPulse
        and #$0f
        tax
        lda NfxCoolPalette,x
        lda #$00
        ; clear active rows only, keep row 24 for scroller
        ldx #3
.nw_clear_row:
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.nw_clear_cell:
        lda #$20
        sta (SPTR),y
        lda #$00
        sta (CPTR),y
        dey
        bpl .nw_clear_cell
        inx
        cpx #23
        bne .nw_clear_row
        ; draw 12 edge-ish rows from uploaded wire cube theme
        ldx #0
.nw_edge_loop:
        lda NfxWireRows,x
        tay
        lda ScrRowLo,y
        sta SPTR
        lda ScrRowHi,y
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        txa
        clc
        adc nw_phase
        adc sndPulse
        and #$1f
        tay
        lda NfxWireChars,x
        sta (SPTR),y
        lda NfxWireColors,x
        sta (CPTR),y
        tya
        eor #$1f
        tay
        lda NfxWireChars+12,x
        sta (SPTR),y
        txa
        clc
        adc nw_phase
        adc sndPulse
        and #$0f
        tay
        lda NfxCoolPalette,y
        sta ET0
        ; restore Y target by recomputing mirrored col through X/phase
        txa
        clc
        adc nw_phase
        eor #$1f
        and #$1f
        tay
        lda ET0
        sta (CPTR),y
        inx
        cpx #12
        bne .nw_edge_loop
        rts
!zone

!zone infinity_corridor
ic_phase !byte 0
ic_init:
        jsr ClearScreenColor
        lda #<NfxInfinityTitle
        sta TXTP
        lda #>NfxInfinityTitle
        sta TXTP_HI
        ldx #2
        jsr PrintCenteredAuto
        rts
ic_update:
        inc ic_phase
        lda #0
        sta ic_row_temp
        lda ic_phase
        clc
        adc sndPulse
        and #$07
        ora #$08
        lda ic_phase
        lsr
        clc
        adc sndPulse
        and #$0f
        tax
        lda NfxCorridorBg,x
        lda NfxCorridorBorder,x
.ic_row_loop:
        ldx ic_row_temp
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        lda DistLo,x
        sta TXTP
        lda DistHi,x
        sta TXTP_HI
        ldy #39
.ic_col_loop:
        lda (TXTP),y
        clc
        adc ic_phase
        adc sndPulse
        adc NfxColWarp,y
        and #$0f
        tax
        lda NfxCorridorChars,x
        sta (SPTR),y
        txa
        clc
        adc ic_phase
        adc sndPulse
        and #$0f
        tax
        lda NfxCorridorColors,x
        sta (CPTR),y
        dey
        bpl .ic_col_loop
        inc ic_row_temp
        lda ic_row_temp
        cmp #24
        bne .ic_row_loop
        rts
ic_row_temp !byte 0
!zone

!zone gold_trench

gt_phase !byte 0

gt_init:
        jsr ClearScreenColor
        lda #<NfxGoldTitle
        sta TXTP
        lda #>NfxGoldTitle
        sta TXTP_HI
        ldx #2
        jsr PrintCenteredAuto
        rts

gt_update:
        inc gt_phase
        lda #0
        sta gt_row_temp
        lda gt_phase
        lsr
        clc
        adc sndPulse
        and #$07
        tax
        lda NfxGoldBorder,x
        lda #$00
.gt_row_loop:
        ldx gt_row_temp
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        lda NfxTrenchLeft,x
        sta ET0
        lda NfxTrenchRight,x
        sta ET1
        lda gt_row_temp
        clc
        adc gt_phase
        adc sndPulse
        and #$07
        sta gt_cross_gate
        ldy #39
.gt_col_loop:
        sty gt_col_y
        ; Gold trench lines v2: double rails, soft edge glow, beat crossbars,
        ; and centre vanishing markers.  Blank cells also clear colour RAM.
        cpy ET0
        beq .gt_wall_left
        cpy ET1
        beq .gt_wall_right
        tya
        sec
        sbc ET0
        cmp #1
        beq .gt_wall_left_inner
        lda ET1
        sec
        sbc #1
        cmp gt_col_y
        beq .gt_wall_right_inner
        lda gt_cross_gate
        bne .gt_no_crossbar
        cpy ET0
        bcc .gt_no_crossbar
        cpy ET1
        bcs .gt_no_crossbar
        lda #$3d                ; solid horizontal gold crossbar - stronger v2
        jmp .gt_store_gold
.gt_no_crossbar:
        cpy #19
        beq .gt_center
        cpy #20
        beq .gt_center
        tya
        sec
        sbc ET0
        cmp #2
        beq .gt_soft_left
        lda ET1
        sec
        sbc #2
        cmp gt_col_y
        beq .gt_soft_right
        lda #$20
        jmp .gt_store
.gt_wall_left:
        lda #$2f                ; / left main rail
        jmp .gt_store_gold
.gt_wall_left_inner:
        lda #$2f                ; / left inner glow rail
        jmp .gt_store_gold
.gt_wall_right:
        lda #$5c                ; \ right main rail
        jmp .gt_store_gold
.gt_wall_right_inner:
        lda #$5c                ; \ right inner glow rail
        jmp .gt_store_gold
.gt_soft_left:
        lda #$2e                ; edge glow near rail
        jmp .gt_store_dim_gold
.gt_soft_right:
        lda #$2e
        jmp .gt_store_dim_gold
.gt_center:
        lda #$2b                ; centre vanishing line
        jmp .gt_store_gold
.gt_store:
        sta (SPTR),y
        lda #$00                ; blank interior = black, prevents stale gold trails
        sta (CPTR),y
        dey
        bmi .gt_row_next
        jmp .gt_col_loop
.gt_store_dim_gold:
        sta (SPTR),y
        lda gt_row_temp
        clc
        adc sndPulse
        and #$03
        tax
        lda NfxGoldDimPalette,x
        sta (CPTR),y
        dey
        bmi .gt_row_next
        jmp .gt_col_loop
.gt_store_gold:
        sta (SPTR),y
        tya
        clc
        adc gt_phase
        adc sndPulse
        adc ET0
        and #$0f
        tax
        lda NfxGoldPalette,x
        sta (CPTR),y
        dey
        bmi .gt_row_next
        jmp .gt_col_loop
.gt_row_next:
        inc gt_row_temp
        lda gt_row_temp
        cmp #24
        beq .gt_rows_done
        jmp .gt_row_loop
.gt_rows_done:
        rts

gt_row_temp !byte 0
gt_cross_gate !byte 0
gt_col_y !byte 0
!zone

!zone cube_v3_rotor
; -----------------------------------------------------------------------------
; CUBE V3 ROTOR FINAL - stable text-mode 3D wire cube
; -----------------------------------------------------------------------------
; The previous placeholder only plotted 16 moving points and cleared four rows,
; so the cube could look broken/trail-heavy or invisible.  This version draws a
; real two-plane wire cube every frame: front square, rear square, and four depth
; connectors.  It stays in rows 4..22, leaving row 24 for the global scroller.
cv_phase !byte 0
cv_init:
        jsr ClearScreenColor
        lda #<NfxCubeTitle
        sta TXTP
        lda #>NfxCubeTitle
        sta TXTP_HI
        ldx #2
        jsr PrintCenteredAuto
        rts

cv_update:
        lda cv_phase            ; faster, beat-nudged spin (was a slow +1 wobble)
        clc
        adc #3
        ldx zoomPulse           ; smooth sine adds a little extra spin on the swell
        cpx #8
        bcc .cv_nospin
        adc #2
.cv_nospin:
        sta cv_phase
        jsr CvClearField
        jsr CvBuildGeometry
        jsr CvDrawWireCube
        rts

CvClearField:
        lda #4
        sta cv_row_draw
.cv_cf_row:
        ldx cv_row_draw
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy #39
.cv_cf_col:
        lda #$20
        sta (SPTR),y
        lda #$00
        sta (CPTR),y
        dey
        bpl .cv_cf_col
        inc cv_row_draw
        lda cv_row_draw
        cmp #23                 ; clear rows 4..22 only; row 24 is scroller
        bne .cv_cf_row
        rts

CvBuildGeometry:
        ; Real stable rotation illusion: geometry is frame-table driven, so
        ; the cube never collapses, never reverses line order, and clears cleanly.
        ; Frame table columns: FL, FR, FT, FB, depthX, depthY, diagMode.
        lda cv_phase
        lsr
        lsr
        and #$0f
        sta cv_rot_idx
        asl
        asl
        asl
        sec
        sbc cv_rot_idx          ; idx*7
        tax
        lda CvFrameGeom,x
        sta cv_fl
        inx
        lda CvFrameGeom,x
        sta cv_fr
        inx
        lda CvFrameGeom,x
        sta cv_ft
        inx
        lda CvFrameGeom,x
        sta cv_fb
        inx
        lda CvFrameGeom,x
        sta cv_depth_x
        inx
        lda CvFrameGeom,x
        sta cv_depth_y
        inx
        lda CvFrameGeom,x
        sta cv_depth_idx

        lda cv_fl
        clc
        adc cv_depth_x
        sta cv_bl
        lda cv_fr
        clc
        adc cv_depth_x
        sta cv_br
        lda cv_ft
        clc
        adc cv_depth_y
        sta cv_bt
        lda cv_fb
        clc
        adc cv_depth_y
        sta cv_bb
        rts

CvDrawWireCube:
        ; Back square first, darker.
        lda #$2d
        sta cv_char
        lda #$0b
        sta cv_color
        lda cv_bt
        sta cv_row_draw
        lda cv_bl
        sta cv_col_start
        lda cv_br
        sta cv_col_end
        jsr CvHLine
        lda cv_bb
        sta cv_row_draw
        jsr CvHLine
        lda #$7c
        sta cv_char
        lda cv_bl
        sta cv_col_start
        lda cv_bt
        sta cv_row_start
        lda cv_bb
        sta cv_row_end
        jsr CvVLine
        lda cv_br
        sta cv_col_start
        jsr CvVLine

        ; Front square, bright and pulse-coloured.
        lda #$2d
        sta cv_char
        lda sndPulse
        clc
        adc cv_phase
        and #$0f
        tax
        lda NfxCubePalette,x
        sta cv_color
        lda cv_ft
        sta cv_row_draw
        lda cv_fl
        sta cv_col_start
        lda cv_fr
        sta cv_col_end
        jsr CvHLine
        lda cv_fb
        sta cv_row_draw
        jsr CvHLine
        lda #$7c
        sta cv_char
        lda cv_fl
        sta cv_col_start
        lda cv_ft
        sta cv_row_start
        lda cv_fb
        sta cv_row_end
        jsr CvVLine
        lda cv_fr
        sta cv_col_start
        jsr CvVLine

        ; Depth connectors.  Four corner lines make it visibly 3D.
        lda #$2f
        sta cv_char
        lda #$0e
        sta cv_color
        lda cv_fl
        sta cv_d_x0
        lda cv_ft
        sta cv_d_y0
        lda cv_bl
        sta cv_d_x1
        lda cv_bt
        sta cv_d_y1
        jsr CvDiagLine
        lda cv_fr
        sta cv_d_x0
        lda cv_ft
        sta cv_d_y0
        lda cv_br
        sta cv_d_x1
        lda cv_bt
        sta cv_d_y1
        jsr CvDiagLine
        lda cv_fl
        sta cv_d_x0
        lda cv_fb
        sta cv_d_y0
        lda cv_bl
        sta cv_d_x1
        lda cv_bb
        sta cv_d_y1
        jsr CvDiagLine
        lda cv_fr
        sta cv_d_x0
        lda cv_fb
        sta cv_d_y0
        lda cv_br
        sta cv_d_x1
        lda cv_bb
        sta cv_d_y1
        jsr CvDiagLine
        jsr CvDrawCorners
        jsr CvDrawSpinCore
        rts

CvDrawCorners:
        lda #$2b                ; + corners make cube read as connected 3D object
        sta cv_char
        lda #$01
        sta cv_color
        lda cv_ft
        sta cv_d_y0
        lda cv_fl
        sta cv_d_x0
        jsr CvPlotPoint
        lda cv_ft
        sta cv_d_y0
        lda cv_fr
        sta cv_d_x0
        jsr CvPlotPoint
        lda cv_fb
        sta cv_d_y0
        lda cv_fl
        sta cv_d_x0
        jsr CvPlotPoint
        lda cv_fb
        sta cv_d_y0
        lda cv_fr
        sta cv_d_x0
        jsr CvPlotPoint
        lda cv_bt
        sta cv_d_y0
        lda cv_bl
        sta cv_d_x0
        jsr CvPlotPoint
        lda cv_bt
        sta cv_d_y0
        lda cv_br
        sta cv_d_x0
        jsr CvPlotPoint
        lda cv_bb
        sta cv_d_y0
        lda cv_bl
        sta cv_d_x0
        jsr CvPlotPoint
        lda cv_bb
        sta cv_d_y0
        lda cv_br
        sta cv_d_x0
        jsr CvPlotPoint
        rts

CvDrawSpinCore:
        ; Finished last effect: rotating inner core points make the cube read as
        ; a real moving 3D object even in text mode.  Rows stay inside 7..18.
        lda cv_phase
        and #$1f
        sta cv_core_base
        ldx #7
.cv_core_loop:
        stx cv_idx
        txa
        clc
        adc cv_core_base
        and #$1f
        tax
        lda CvCoreYTbl,x
        sta cv_d_y0
        lda CvCoreXTbl,x
        sta cv_d_x0
        lda #$2a
        sta cv_char
        lda sndPulse
        clc
        adc cv_phase
        adc cv_idx
        and #$0f
        tax
        lda NfxCubePalette,x
        sta cv_color
        jsr CvPlotPoint
        ldx cv_idx
        dex
        bpl .cv_core_loop
        rts

CvPlotPoint:
        ldx cv_d_y0
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy cv_d_x0
        lda cv_char
        sta (SPTR),y
        lda cv_color
        sta (CPTR),y
        rts

CvHLine:
        ldx cv_row_draw
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy cv_col_start
.cv_h_loop:
        lda cv_char
        sta (SPTR),y
        lda cv_color
        sta (CPTR),y
        cpy cv_col_end
        beq .cv_h_done
        iny
        bne .cv_h_loop
.cv_h_done:
        rts

CvVLine:
        lda cv_row_start
        sta cv_row_draw
.cv_v_loop:
        ldx cv_row_draw
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        ldy cv_col_start
        lda cv_char
        sta (SPTR),y
        lda cv_color
        sta (CPTR),y
        lda cv_row_draw
        cmp cv_row_end
        beq .cv_v_done
        inc cv_row_draw
        jmp .cv_v_loop
.cv_v_done:
        rts

CvDiagLine:
        ; Draws 6 sampled points between two corners using the active depth
        ; vector.  The old placeholder used step for both X and Y, so shallow
        ; depth vectors overshot the rear face vertically.  This table-driven
        ; connector lands exactly on the rear square for every depth mode.
        lda cv_depth_idx
        asl
        clc
        adc cv_depth_idx          ; idx*3
        asl                       ; idx*6
        sta cv_diag_base
        lda #0
        sta cv_diag_step
.cv_d_loop:
        lda cv_diag_base
        clc
        adc cv_diag_step
        tax
        lda cv_d_y0
        clc
        adc CvDiagYOffset,x
        tax
        lda ScrRowLo,x
        sta SPTR
        lda ScrRowHi,x
        sta SPTR_HI
        lda SPTR
        sta CPTR
        lda SPTR_HI
        clc
        adc #>SCR_COL_OFF
        sta CPTR_HI
        lda cv_diag_base
        clc
        adc cv_diag_step
        tax
        lda cv_d_x0
        clc
        adc CvDiagXOffset,x
        tay
        lda cv_char
        sta (SPTR),y
        lda cv_color
        sta (CPTR),y
        inc cv_diag_step
        lda cv_diag_step
        cmp #6
        bne .cv_d_loop
        rts

cv_idx       !byte 0
cv_row_draw  !byte 0
cv_row_start !byte 0
cv_row_end   !byte 0
cv_col_start !byte 0
cv_col_end   !byte 0
cv_char      !byte 0
cv_color     !byte 0
cv_inset     !byte 0
cv_depth_idx !byte 0
cv_rot_idx   !byte 0
cv_depth_x   !byte 0
cv_depth_y   !byte 0
cv_fl        !byte 0
cv_fr        !byte 0
cv_ft        !byte 0
cv_fb        !byte 0
cv_bl        !byte 0
cv_br        !byte 0
cv_bt        !byte 0
cv_bb        !byte 0
cv_d_x0      !byte 0
cv_d_y0      !byte 0
cv_d_x1      !byte 0
cv_d_y1      !byte 0
cv_diag_step !byte 0
cv_diag_base !byte 0
cv_core_base !byte 0
; Six-point connector offsets for the 8 active depth vectors.
CvDiagXOffset:
        !byte 0,1,2,3,4,5
        !byte 0,1,2,2,3,4
        !byte 0,1,1,2,2,3
        !byte 0,0,1,1,2,2
        !byte 0,1,2,3,4,5
        !byte 0,1,2,4,5,6
        !byte 0,1,3,4,6,7
        !byte 0,1,2,4,5,6
CvDiagYOffset:
        !byte 0,1,1,2,2,3
        !byte 0,1,1,2,2,3
        !byte 0,0,1,1,2,2
        !byte 0,0,0,1,1,1
        !byte 0,1,1,2,2,3
        !byte 0,1,1,2,2,3
        !byte 0,0,1,1,2,2
        !byte 0,0,0,1,1,1
; 16 stable cube rotation frames: FL,FR,FT,FB,depthX,depthY,diagMode.
; All coordinates stay inside cols 0..39 and rows 4..22.
CvFrameGeom:
        !byte 9,30,7,18,5,3,0
        !byte 10,29,7,18,6,2,1
        !byte 11,28,8,18,7,2,2
        !byte 12,27,8,17,6,1,3
        !byte 13,26,9,17,5,1,4
        !byte 12,27,8,17,4,1,5
        !byte 11,28,8,18,3,2,6
        !byte 10,29,7,18,4,2,7
        !byte 9,30,7,18,5,3,0
        !byte 8,31,7,18,6,3,1
        !byte 7,32,8,18,7,2,2
        !byte 8,31,8,17,6,1,3
        !byte 9,30,9,17,5,1,4
        !byte 8,31,8,17,4,1,5
        !byte 7,32,8,18,3,2,6
        !byte 8,31,7,18,4,3,7
; 32-frame inner spin core. These are inside the cube clear field.
CvCoreXTbl:
        !byte 18,20,22,24,25,24,22,20,18,16,14,13,14,16,18,20
        !byte 21,23,25,26,25,23,21,19,17,15,13,12,13,15,17,19
CvCoreYTbl:
        !byte 12,11,10,10,11,12,13,14,15,16,16,15,14,13,12,11
        !byte 10,9,10,12,14,16,17,18,17,16,14,12,10,9,10,11

; Legacy compatibility markers kept for audit readability; geometry now uses CvFrameGeom.
CvInsetTbl:  !byte 0,1,2,3,3,2,1,0
CvDepthX:    !byte 5,4,3,2,5,6,7,6
CvDepthY:    !byte 3,3,2,1,3,3,2,1
!zone

;  >>> Berlin techno (replaces dreamy, styles 2 & 3) <<<
BerlinABass:
        !byte $09,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$1c
        !byte $09,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$1c
        !byte $13,$1f,$ff,$2b,$1f,$1f,$ff,$2b,$1f,$1f,$ff,$2b,$1f,$1f,$ff,$26
        !byte $11,$1d,$ff,$29,$1d,$1d,$ff,$29,$1d,$1d,$ff,$29,$1d,$1d,$ff,$24
        !byte $09,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$1c
        !byte $09,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$1c
        !byte $13,$1f,$ff,$2b,$1f,$1f,$ff,$2b,$1f,$1f,$ff,$2b,$1f,$1f,$ff,$26
        !byte $11,$1d,$ff,$29,$1d,$1d,$ff,$29,$1d,$1d,$ff,$29,$1d,$1d,$ff,$24
        !byte $09,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$1c
        !byte $09,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$1c
        !byte $13,$1f,$ff,$2b,$1f,$1f,$ff,$2b,$1f,$1f,$ff,$2b,$1f,$1f,$ff,$26
        !byte $11,$1d,$ff,$29,$1d,$1d,$ff,$29,$1d,$1d,$ff,$29,$1d,$1d,$ff,$24
        !byte $09,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$1c
        !byte $09,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$21,$15,$15,$ff,$1c
        !byte $13,$1f,$ff,$2b,$1f,$1f,$ff,$2b,$1f,$1f,$ff,$2b,$1f,$1f,$ff,$26
        !byte $11,$1d,$ff,$29,$1d,$1d,$ff,$29,$1d,$1d,$ff,$29,$1d,$1d,$ff,$24
BerlinAArp0:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$37,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$35,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$37,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$35,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$37,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$35,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$37,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$35,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$35,$ff
BerlinAArp1:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$30,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$30,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$39,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$30,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$30,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$39,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$30,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$30,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$39,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$30,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$30,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$39,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$39,$ff
BerlinAArp2:
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$34,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$34,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3e,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$34,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$34,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3e,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$34,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$34,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3e,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$34,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$34,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3e,$ff
        !byte $ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$ff,$ff,$ff,$ff,$3c,$ff
BerlinADrum:
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
        !byte $01,$00,$02,$00,$03,$00,$02,$00,$01,$00,$02,$00,$03,$00,$02,$00
BerlinAFilt:
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5d,$5a,$58
BerlinBBass:
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $13,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$26
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $13,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$26
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $13,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$26
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $09,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$21,$15,$15,$15,$1c
        !byte $13,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$2b,$1f,$1f,$1f,$26
        !byte $11,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$29,$1d,$1d,$1d,$24
BerlinBArp0:
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff,$ff,$ff,$2d,$ff
        !byte $ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff,$ff,$ff,$37,$ff
        !byte $ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff,$ff,$ff,$35,$ff
BerlinBArp1:
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff,$ff,$ff,$30,$ff
        !byte $ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff,$ff,$ff,$3b,$ff
        !byte $ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff,$ff,$ff,$39,$ff
BerlinBArp2:
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff
        !byte $ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff
        !byte $ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff
        !byte $ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff,$ff,$ff,$34,$ff
        !byte $ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff,$ff,$ff,$3e,$ff
        !byte $ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff,$ff,$ff,$3c,$ff
BerlinBDrum:
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
        !byte $01,$02,$02,$02,$03,$02,$02,$02,$01,$02,$02,$02,$03,$02,$02,$02
BerlinBFilt:
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f
        !byte $5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f,$5f



HeartShapeMask:
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        !byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
HeartShapeLo: !for r,0,23 { !byte <(HeartShapeMask + r*40) }
HeartShapeHi: !for r,0,23 { !byte >(HeartShapeMask + r*40) }

MenuNamePalette: !byte $01,$07,$03,$0d   ; white, yellow, cyan, lt-green (menu name pulse)

!if * > $c000 {
        !error "megademo overruns $c000! end = ", *
}
; The hard $c000 boundary above remains the build-time size guard.
