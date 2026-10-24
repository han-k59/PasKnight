unit pasknight_unit_nnue;
{ =============================================================================
  PasKnight -- classic 768-input NNUE, eval-matching validation experiment.

  Architecture:  768 -> 256 (clipped ReLU) -> 32 (clipped ReLU) -> 1
                 single accumulator, no king buckets, no PSQT skip connection,
                 no MG/EG heads.

  This unit is deliberately independent of the engine: it knows nothing about
  TGameState, TPiece or TMove. The engine drives it through (PieceIdx, Square)
  pairs. That keeps it testable on its own and keeps the engine diff tiny.

  FEATURE INDEXING
    PieceIdx  0..11  = Ord(TPiece) - 1, i.e. 0=wP 1=wN 2=wB 3=wR 4=wQ 5=wK
                                             6=bP 7=bN 8=bB 9=bR 10=bQ 11=bK
    Sq        0..63  = LERF bit index, a1=0 .. h8=63 (engine's SquareIndex)
    feature   = PieceIdx * 64 + Sq

  WHAT THE NET PREDICTS
    A WHITE-POV score in centipawns. The net is format 2 (v2.0): besides the
    768 piece-square features it has a side-to-move column of 256 L1 weights,
    added when Black is to move, after the accumulator and before the first
    CReLU. It therefore learns the value of having the move itself; the engine
    only flips the sign for Black to move. The accumulator stays a pure
    function of piece placement, which is what makes the accumulator
    self-consistency check meaningful. Format-1 nets (no side-to-move input,
    an external tempo bonus) are no longer supported as of v2.0.

  INTEGER FORMAT (mirrors nnue_quant_reference.py exactly)
    L1 weights / biases   Int16,  scale QA
    accumulator           Int16,  scale QA
    L2 / L3 weights       Int16,  scale QB      (int16, not int8 -- see REPORT)
    L2 / L3 biases        Int32,  scale QA*QB
    layer sums            Int32
    final scaling         Int64   (o * OUTPUT_SCALE overflows Int32)

  Copyright (C) 2026. Same licence as PasKnight (MPL 2.0).
  ========================================================================== }

{$mode objfpc}{$H+}

{ PERFORMANCE-CRITICAL DIRECTIVES -- do not remove.

  This unit spends essentially all of its time in two tight loops: the 256-wide
  accumulator update (run several times per move) and the 256x32 layer-2 matrix
  multiply (run once per evaluation). That is ~8200 multiply-accumulates per
  eval, in scalar Pascal.

  Range and overflow checking put a test on every one of those array accesses
  and every arithmetic op. Inherited from a project that has them enabled, they
  cost 5-10x here. They are disabled locally so this unit's speed does not
  depend on project settings -- correctness of the integer path is guaranteed
  by nnue_quant_reference.py and `nnue testvec`, not by runtime checks.

  Note the deliberate exception: the accumulator is Int16 and CAN in principle
  overflow. That is guarded at EXPORT time by check_ranges() in export_nnue.py,
  which tests the worst case over any legal 32-piece position -- a far stronger
  guarantee than catching it at runtime after the fact. }
{$R-}          { no range checking   }
{$Q-}          { no overflow checking }
{$OPTIMIZATION ON}
{$INLINE ON}

{ Define NNUE_FLOAT_REF to maintain a parallel Double accumulator and expose
  NNUE_EvalWhitePOV_Float. Build one binary with it and one without; any
  disagreement beyond a couple of centipawns is a quantization bug, and it is
  isolated from every other moving part. }
{ .$DEFINE NNUE_FLOAT_REF }

{ Define NNUE_DEBUG_ACC to enable the periodic incremental-vs-full accumulator
  assertion (validation criterion 1). Costs a full refresh every N nodes. }
{ .$DEFINE NNUE_DEBUG_ACC }

{$IFDEF CPUX86_64}
  {$DEFINE NNUE_SSE2}
  {$DEFINE NNUE_AVX2}    { AVX2 kernels, chosen at runtime by CPUID }
  {$ASMMODE INTEL}
{$ENDIF}

interface

const
  NNUE_N_IN  = 768;
  NNUE_N_L1  = 256;
  NNUE_N_L2  = 32;

  NNUE_QA           = 1024;  { activation scale: CReLU output in [0, QA] }
  NNUE_QB           = 1024;  { weight scale for layers 2 and 3           }
  NNUE_OUTPUT_SCALE = 400;   { float net output * this = centipawns      }

  { Accumulator stack depth. One slot per DoMakeMove currently on the stack.
    Three things share it: the game moves replayed at the root by ApplyUCIMove,
    the search ply, and the quiescence ply. GetBestMove does a full refresh at
    the start of every search, which resets the pointer to 0, so the search
    itself only ever needs (ply + qply) slots. The root replay is what can grow
    unboundedly in a very long game, hence the generous ceiling: 2048 slots is
    1 MB, noise next to the transposition table. }
  NNUE_MAX_ACC = 2048;

  NNUE_MAGIC   = $504B4E55;  { 'PKNU' }
  { Format 1 (768 inputs, no side-to-move column) is no longer accepted. }
  NNUE_VERSION_STM = 2;      { 768 inputs + a side-to-move column (v2.0):
                               256 extra L1 weights, added when BLACK is to
                               move, after the accumulator and before the
                               first CReLU. Not part of the incremental
                               accumulator, so DoMakeMove is unaffected.    }

type
  TNNUEAcc  = array[0..NNUE_N_L1 - 1] of Int16;
  TNNUEL2   = array[0..NNUE_N_L2 - 1] of Int32;

var
  { True once a weight file has loaded and passed its header + checksum check.
    v2.0: the NNUE is the engine's only evaluation, so while this is False the
    engine refuses to search. }
  NNUE_Available: boolean = False;

  { True when the CPU and OS both support AVX2 and the wide kernels are in
    use. Reported by `nnue check` so a speed measurement always states which
    kernels produced it. }
  NNUE_HasAVX2: boolean = False;

  { Current accumulator slot. The ENGINE owns this value -- it lives in
    TGameState so that the existing "State := OldState" copy-restore unwinds
    it for free, with no separate unmake path. The engine writes it back here
    via NNUE_SetPtr after every restore. }
  NNUE_Ptr: integer = 0;

  { Diagnostics, printed by the `nnue check` command. }
  NNUE_PeakAcc: integer = 0;      { largest |accumulator| seen this run }
  NNUE_Overflows: int64 = 0;      { times an accumulator left Int16 range }
  NNUE_StackOverflows: int64 = 0; { times NNUE_Push hit NNUE_MAX_ACC }

  { Cost-attribution counters. One increment each, negligible against the
    256-wide loops they sit in front of, and they answer the only question
    that matters once the accumulator is known to be the bottleneck: how
    OFTEN is this work happening? Compare NNUE_PushCount with the node count
    bench reports. ~1 push per node means the suspend during legality probing
    is working and the cost is intrinsic; tens per node means it is not, and
    the fix is a gating bug rather than an optimisation problem. }
  NNUE_PushCount: int64 = 0;      { NNUE_Push calls (one per hooked DoMakeMove) }
  NNUE_UpdCount: int64 = 0;       { NNUE_Add + NNUE_Sub calls                   }
  NNUE_EvalCount: int64 = 0;      { NNUE_EvalWhitePOV calls                     }

  { The push:eval ratio decides the strategy. Every push exists only to keep
    the accumulator correct for some later evaluation. If evals are far rarer
    than pushes, most of that work is for positions that are never evaluated
    -- searched and pruned, or cut off -- and the fix is to defer the update
    until an eval asks for it (the standard "dirty piece" scheme), not to make
    the loops faster. If the ratio is near 1, every push is paid for and the
    only lever left is the cost per push: narrower L1, or SIMD. }

  NNUE_CPUHasAVX2: boolean=false;


{ --- loading (v2.0.0alpha3) ---------------------------------------------
  ALL validation lives in NNUE_CheckBuffer: magic, version, geometry, scales,
  exact size, checksum. It has no side effects, so 'nnue embed' can use it on
  a file without replacing the active net. NNUE_LoadFromBuffer = check, then
  copy into the live weights. NNUE_Load (an external file) and
  NNUE_LoadEmbedded (the array built into the executable) only supply the
  bytes. Every load first unloads: a failed load leaves NO net. }
function  NNUE_CheckBuffer(const Buf; Size: Int64; const Name: string): boolean;
function  NNUE_LoadFromBuffer(const Buf; Size: Int64; const Name: string): boolean;
function  NNUE_Load(const FileName: string): boolean;
function  NNUE_LoadEmbedded: boolean;
function  NNUE_EmbeddedDesc: string;        { 'embedded net (nnue9, 410856 bytes)' }
function  NNUE_EmbeddedName: string;        { 'nnue9'                              }
function  NNUE_EmbeddedChecksum: Cardinal;  { the trailing byte-sum word           }
{ Validate NetFile with NNUE_CheckBuffer and write it as a Pascal include that
  defines the embedded net. Does not touch the active net. }
function  NNUE_Embed(const NetFile, IncFile, NetName: string): boolean;
procedure NNUE_Unload;

{ --- accumulator maintenance (called from the engine's BB_ hooks) --------- }
procedure NNUE_Add(PieceIdx, Sq: integer);
procedure NNUE_Sub(PieceIdx, Sq: integer);
procedure NNUE_Push;
procedure NNUE_SetPtr(P: integer); inline;
procedure NNUE_ResetCounters;

{ --- full refresh -------------------------------------------------------- }
procedure NNUE_RefreshBegin;                          { clear slot 0, Ptr := 0 }
procedure NNUE_RefreshAdd(PieceIdx, Sq: integer);     { add one piece         }

{ --- forward pass -------------------------------------------------------- }
{ Stm = State.SideToMove (0 = White, 1 = Black): selects whether the
  side-to-move column is added. It is a PARAMETER rather than a global on
  purpose: every call site must state the side to move, so none can silently
  evaluate a black-to-move position as white-to-move. }
function  NNUE_EvalWhitePOV(Stm: integer): integer;   { centipawns, white POV }
{$IFDEF NNUE_FLOAT_REF}
function  NNUE_EvalWhitePOV_Float(Stm: integer): Double;
{$ENDIF}

{ --- validation ---------------------------------------------------------- }
{ Recompute an accumulator from scratch into a scratch slot and compare it
  with the live one. Usage:
      NNUE_VerifyBegin;
      for each piece on the board: NNUE_VerifyAdd(pieceIdx, sq);
      if not NNUE_VerifyMatches then <report drift>;  }
procedure NNUE_VerifyBegin;
procedure NNUE_VerifyAdd(PieceIdx, Sq: integer);
function  NNUE_VerifyMatches(out BadIndex, GotVal, WantVal: integer): boolean;

{ Dump every intermediate layer for one position. Used by `nnue testvec` to
  check the Pascal against the test vectors emitted by export_nnue.py. }
procedure NNUE_Trace(Stm: integer; out Acc0, A0: TNNUEAcc; out S, A1: TNNUEL2;
                     out O: Int32; out Cp: integer);

implementation

uses SysUtils;

type
  { Feature-major so that one feature's column is 256 contiguous Int16 --
    the accumulator update is then a single linear sweep, which is the whole
    reason an accumulator is cheaper than a full recompute. }
  TL1W = array[0..NNUE_N_IN - 1, 0..NNUE_N_L1 - 1] of Int16;
  TL1B = array[0..NNUE_N_L1 - 1] of Int16;
  TL2W = array[0..NNUE_N_L2 - 1, 0..NNUE_N_L1 - 1] of Int16;
  TL2B = array[0..NNUE_N_L2 - 1] of Int32;
  TL3W = array[0..NNUE_N_L2 - 1] of Int16;

var
  L1W: TL1W;
  L1B: TL1B;
  L1S: TL1B;     { side-to-move column, added when Black is to move }
  L2W: TL2W;
  L2B: TL2B;
  L3W: TL3W;
  L3B: Int32;

  Acc: array[0..NNUE_MAX_ACC - 1] of TNNUEAcc;
  Scratch: TNNUEAcc;

{$IFDEF NNUE_FLOAT_REF}
type
  TNNUEAccF = array[0..NNUE_N_L1 - 1] of Double;
var
  AccF: array[0..NNUE_MAX_ACC - 1] of TNNUEAccF;
  L1Wf: array[0..NNUE_N_IN - 1, 0..NNUE_N_L1 - 1] of Double;
  L1Bf: array[0..NNUE_N_L1 - 1] of Double;
  L1Sf: array[0..NNUE_N_L1 - 1] of Double;
  L2Wf: array[0..NNUE_N_L2 - 1, 0..NNUE_N_L1 - 1] of Double;
  L2Bf: array[0..NNUE_N_L2 - 1] of Double;
  L3Wf: array[0..NNUE_N_L2 - 1] of Double;
  L3Bf: Double;
{$ENDIF}

{ ------------------------------------------------------------------------- }

{ ---------------------------------------------------------------------------
  SSE2 primitives.

  These must be declared BEFORE NNUE_Add / NNUE_Sub / NNUE_EvalWhitePOV, which
  call them -- Pascal resolves identifiers strictly top-down within the
  implementation section, and a helper defined below its call site is simply
  "identifier not found".
  --------------------------------------------------------------------------- }

  {$IFDEF NNUE_SSE2}

  { Sixteen int16 of NNUE_QA, used as the upper clamp by the vector CReLU.
    Filled at unit initialisation rather than written as a literal array so it
    cannot drift if NNUE_QA ever changes. Passed to the kernels as a pointer:
    referring to a global symbol from inside an FPC asm block has syntax that
    varies between versions, and a parameter does not. }
  var
    QAVec16: array[0..15] of Int16;

  { ---------------------------------------------------------------------------
    SSE2 kernels -- unchanged, and the fallback whenever AVX2 is unavailable.
    --------------------------------------------------------------------------- }

  function Dot256_SSE2(pa, pw: PInt16): Int32;
  { Sum of 256 int16 products. Bit-identical to the scalar loop: integer
    addition is associative, so PMADDWD's pairwise grouping and the horizontal
    reduction give the same total as any other order. }
  var
    res: Int32;
  begin
    res := 0;
    asm
      mov   rax, pa
      mov   rdx, pw
      pxor  xmm0, xmm0
      mov   ecx, 32              // 32 iterations x 8 int16 = 256
    @@dotloop:
      movdqu xmm1, [rax]
      movdqu xmm2, [rdx]
      pmaddwd xmm1, xmm2
      paddd  xmm0, xmm1
      add    rax, 16
      add    rdx, 16
      dec    ecx
      jnz    @@dotloop
      // horizontal sum of the four int32 lanes
      movdqa xmm1, xmm0
      psrldq xmm1, 8
      paddd  xmm0, xmm1
      movdqa xmm1, xmm0
      psrldq xmm1, 4
      paddd  xmm0, xmm1
      movd   eax, xmm0
      mov    res, eax
    end;
    Result := res;
  end;

  procedure AddCol256_SSE2(pa, pw: PInt16);
  begin
    asm
      mov   rax, pa
      mov   rdx, pw
      mov   ecx, 32
    @@addloop:
      movdqu xmm0, [rax]
      movdqu xmm1, [rdx]
      paddw  xmm0, xmm1
      movdqu [rax], xmm0
      add    rax, 16
      add    rdx, 16
      dec    ecx
      jnz    @@addloop
    end;
  end;

  procedure SubCol256_SSE2(pa, pw: PInt16);
  begin
    asm
      mov   rax, pa
      mov   rdx, pw
      mov   ecx, 32
    @@subloop:
      movdqu xmm0, [rax]
      movdqu xmm1, [rdx]
      psubw  xmm0, xmm1
      movdqu [rax], xmm0
      add    rax, 16
      add    rdx, 16
      dec    ecx
      jnz    @@subloop
    end;
  end;

  { ---------------------------------------------------------------------------
    AVX2 kernels.

    Unaligned moves (vmovdqu) throughout: the accumulator and weight rows are
    ordinary Pascal arrays with no alignment guarantee, and on any CPU that has
    AVX2 an unaligned move costs nothing extra when the data does not straddle
    a cache line -- and correctness does not depend on it when it does.

    vzeroupper before each return. Leaving the upper halves of the ymm
    registers live makes every subsequent legacy-SSE instruction pay a
    transition penalty on Intel parts. The rest of the engine is full of
    compiler-generated SSE, so the one-cycle vzeroupper is cheap insurance.
    --------------------------------------------------------------------------- }
{$IFDEF NNUE_AVX2}

function Dot256_AVX2(pa, pw: PInt16): Int32;
var
  res: Int32;
begin
  res := 0;
  asm
    mov    rax, pa
    mov    rdx, pw
    vpxor  ymm0, ymm0, ymm0
    mov    ecx, 16                 // 16 iterations x 16 int16 = 256
  @@dotloop:
    vmovdqu  ymm1, [rax]
    vmovdqu  ymm2, [rdx]
    vpmaddwd ymm1, ymm1, ymm2
    vpaddd   ymm0, ymm0, ymm1
    add      rax, 32
    add      rdx, 32
    dec      ecx
    jnz      @@dotloop
    // fold the two 128-bit halves together, then the four int32 lanes
    vextracti128 xmm1, ymm0, 1
    vpaddd   xmm0, xmm0, xmm1
    vpshufd  xmm1, xmm0, $0E       // lanes 2,3 -> 0,1
    vpaddd   xmm0, xmm0, xmm1
    vpshufd  xmm1, xmm0, $01       // lane 1 -> 0
    vpaddd   xmm0, xmm0, xmm1
    vmovd    eax, xmm0
    vzeroupper
    mov      res, eax
  end;
  Result := res;
end;

procedure AddCol256_AVX2(pa, pw: PInt16);
begin
  asm
    mov   rax, pa
    mov   rdx, pw
    mov   ecx, 16
  @@addloop:
    vmovdqu ymm0, [rax]
    vmovdqu ymm1, [rdx]
    vpaddw  ymm0, ymm0, ymm1
    vmovdqu [rax], ymm0
    add     rax, 32
    add     rdx, 32
    dec     ecx
    jnz     @@addloop
    vzeroupper
  end;
end;

procedure SubCol256_AVX2(pa, pw: PInt16);
begin
  asm
    mov   rax, pa
    mov   rdx, pw
    mov   ecx, 16
  @@subloop:
    vmovdqu ymm0, [rax]
    vmovdqu ymm1, [rdx]
    vpsubw  ymm0, ymm0, ymm1
    vmovdqu [rax], ymm0
    add     rax, 32
    add     rdx, 32
    dec     ecx
    jnz     @@subloop
    vzeroupper
  end;
end;

procedure CReLU256_AVX2(psrc, pdst, pqa: PInt16);
{ pdst[j] := clamp(psrc[j], 0, NNUE_QA) for 256 int16.

  Worth vectorising, not just the dot products. 256 scalar clamps with two
  branches each is a few hundred cycles, which is small against an SSE2
  forward pass and NOT small against an AVX2 one -- optimise the multiplies
  and this becomes the next thing in the way.

  vpmaxsw against zero and vpminsw against QA give exactly what CReLU16
  computes, elementwise, with no branches. }
begin
  asm
    mov    rax, psrc
    mov    rdx, pdst
    mov    r8,  pqa
    vmovdqu ymm3, [r8]             // 16 copies of NNUE_QA
    vpxor  ymm2, ymm2, ymm2
    mov    ecx, 16
  @@clamploop:
    vmovdqu ymm0, [rax]
    vpmaxsw ymm0, ymm0, ymm2       // lower clamp at 0
    vpminsw ymm0, ymm0, ymm3       // upper clamp at QA
    vmovdqu [rdx], ymm0
    add    rax, 32
    add    rdx, 32
    dec    ecx
    jnz    @@clamploop
    vzeroupper
  end;
end;

function DetectAVX2: boolean;
{ CPUID feature detection. Three things must all hold: the CPU has AVX2, the
  CPU has OSXSAVE/AVX, and the OPERATING SYSTEM has enabled saving of the
  ymm register state. The last one is not optional -- without it the ymm
  registers are not preserved across a context switch and results are
  silently corrupted rather than faulting.

  RBX is callee-saved under the Win64 ABI and CPUID clobbers it, so it is
  pushed and popped around every CPUID, and the leaf-7 result is moved out
  through the volatile R8 before RBX is restored. }
var
  maxleaf, c1, b7, xcr: Cardinal;
begin
  Result  := False;
  maxleaf := 0; c1 := 0; b7 := 0; xcr := 0;

  asm
    push rbx
    xor  eax, eax
    cpuid
    pop  rbx
    mov  maxleaf, eax
  end;
  if maxleaf < 7 then Exit;

  asm
    push rbx
    mov  eax, 1
    xor  ecx, ecx
    cpuid
    pop  rbx
    mov  c1, ecx
  end;
  { bit 27 = OSXSAVE, bit 28 = AVX. XGETBV is not legal without OSXSAVE. }
  if (c1 and $18000000) <> $18000000 then Exit;

  asm
    xor  ecx, ecx
    db   $0F, $01, $D0     // xgetbv -- byte-encoded, because the mnemonic is
                           // not accepted by every FPC assembler version
    mov  xcr, eax
  end;
  { bit 1 = XMM state saved, bit 2 = YMM state saved; both are required }
  if (xcr and 6) <> 6 then Exit;

  asm
    push rbx
    mov  eax, 7
    xor  ecx, ecx
    cpuid
    mov  r8d, ebx
    pop  rbx
    mov  b7, r8d
  end;
  Result := (b7 and (1 shl 5)) <> 0;   { CPUID.7.EBX bit 5 = AVX2 }
end;

{$ENDIF}

{ ---------------------------------------------------------------------------
  Dispatchers. Call sites stay exactly as they were.

  One predictable branch per call, 32 of them per evaluation, against a loop
  of 16 vector multiply-adds each -- unmeasurable, and it buys a single
  binary that runs everywhere.
  --------------------------------------------------------------------------- }

function Dot256(pa, pw: PInt16): Int32;
begin
  {$IFDEF NNUE_AVX2}
  if NNUE_HasAVX2 then Exit(Dot256_AVX2(pa, pw));
  {$ENDIF}
  Result := Dot256_SSE2(pa, pw);
end;

procedure AddCol256(pa, pw: PInt16);
begin
  {$IFDEF NNUE_AVX2}
  if NNUE_HasAVX2 then begin AddCol256_AVX2(pa, pw); Exit; end;
  {$ENDIF}
  AddCol256_SSE2(pa, pw);
end;

procedure SubCol256(pa, pw: PInt16);
begin
  {$IFDEF NNUE_AVX2}
  if NNUE_HasAVX2 then begin SubCol256_AVX2(pa, pw); Exit; end;
  {$ENDIF}
  SubCol256_SSE2(pa, pw);
end;

{$ENDIF}

{$IFDEF NNUE_AVX2}
procedure AddCReLU256_AVX2(psrc, pstm, pdst, pqa: PInt16);
{ pdst[j] := clamp(psrc[j] + pstm[j], 0, NNUE_QA) for 256 int16 -- the
  format-2 side-to-move column, applied once per evaluation.

  vpaddsw SATURATES at +/-32767 instead of wrapping. That is exact here, not
  an approximation: a sum beyond +32767 clamps to QA either way, and one below
  -32768 clamps to 0 either way, so saturating first and clamping after gives
  the same result as clamping the exact Int32 sum -- which is what
  nnue_quant_reference.py computes and `nnue testvec` checks. }
begin
  asm
    mov    rax, psrc
    mov    r10, pstm
    mov    rdx, pdst
    mov    r8,  pqa
    vmovdqu ymm3, [r8]             // 16 copies of NNUE_QA
    vpxor  ymm2, ymm2, ymm2
    mov    ecx, 16
  @@addclamploop:
    vmovdqu ymm0, [rax]
    vmovdqu ymm1, [r10]
    vpaddsw ymm0, ymm0, ymm1       // + side-to-move column, saturating
    vpmaxsw ymm0, ymm0, ymm2       // lower clamp at 0
    vpminsw ymm0, ymm0, ymm3       // upper clamp at QA
    vmovdqu [rdx], ymm0
    add    rax, 32
    add    r10, 32
    add    rdx, 32
    dec    ecx
    jnz    @@addclamploop
    vzeroupper
  end;
end;
{$ENDIF}

procedure NNUE_Unload;
begin
  NNUE_Available := False;
  NNUE_Ptr := 0;
  NNUE_PeakAcc := 0;
  NNUE_Overflows := 0;
end;

function ReadU32(var F: file): Cardinal;
begin
  BlockRead(F, Result, 4);
end;

{ ---------------------------------------------------------------------------
  The embedded net (v2.0.0alpha3). pasknight_net.inc is GENERATED by the
  engine command 'nnue embed <file.nnue> <out.inc> [name]' and defines
    EMBEDDED_NET_NAME, EMBEDDED_NET_SIZE, EMBEDDED_NET_CHECKSUM and
    EMBEDDED_NET: array[0..EMBEDDED_NET_SIZE - 1] of byte -- the .nnue file
  byte for byte. A truncated array is a compile error (the range is fixed by
  EMBEDDED_NET_SIZE); its contents are checked by NNUE_CheckBuffer at every
  startup, exactly like an external file.
  --------------------------------------------------------------------------- }
{$I pasknight_net.inc}

function NNUE_CheckBuffer(const Buf; Size: Int64; const Name: string): boolean;
{ Weight file layout (little-endian, packed, no padding):
    Cardinal magic      = NNUE_MAGIC
    Cardinal version    = NNUE_VERSION_STM (2); format 1 is refused (v2.0)
    Cardinal n_in, n_l1, n_l2
    Int32    qa, qb, output_scale
    Int16    L1W[n_in][n_l1]          feature-major
    Int16    L1B[n_l1]
    Int16    L1S[n_l1]                side-to-move column
    Int16    L2W[n_l2][n_l1]
    Int32    L2B[n_l2]
    Int16    L3W[n_l2]
    Int32    L3B
    Cardinal checksum   = sum of every preceding byte, mod 2^32
  Refusing to load on any mismatch is deliberate: a net silently loaded with
  the wrong geometry or scale produces plausible-looking garbage, which is
  exactly the failure mode this experiment exists to rule out.

  THE ONLY PLACE nets are validated -- external files, the embedded array and
  'nnue embed' all come through here. No side effects: it reads Buf and
  prints the reason for a refusal, nothing else.

  v2.0.0alpha3: the exact-size check now comes BEFORE the checksum (it used
  to come after the weights were copied), so a wrong-size file reports
  'size mismatch' instead of usually 'checksum mismatch'. }
var
  p: PByte;
  hdr: array[0..7] of Cardinal;
  sum, want: Cardinal;
  expected: Int64;
  i: integer;
begin
  Result := False;
  p := PByte(@Buf);
  if Size < 32 then
  begin
    WriteLn('info string NNUE: ', Name, ': file too small (', Size, ' bytes)');
    Exit;
  end;

  Move(p^, hdr[0], 32);
  if hdr[0] <> NNUE_MAGIC then
    begin WriteLn('info string NNUE: ', Name, ': bad magic'); Exit; end;
  if hdr[1] = 1 then
    begin WriteLn('info string NNUE: ', Name, ' is a format-1 net (no ',
                  'side-to-move input); format 1 is no longer supported (v2.0)'); Exit; end;
  if hdr[1] <> NNUE_VERSION_STM then
    begin WriteLn('info string NNUE: ', Name, ': version ', hdr[1], ', expected ',
                  NNUE_VERSION_STM); Exit; end;
  if (hdr[2] <> NNUE_N_IN) or (hdr[3] <> NNUE_N_L1) or (hdr[4] <> NNUE_N_L2) then
    begin WriteLn('info string NNUE: ', Name, ': geometry mismatch'); Exit; end;
  if (Int32(hdr[5]) <> NNUE_QA) or (Int32(hdr[6]) <> NNUE_QB) or
     (Int32(hdr[7]) <> NNUE_OUTPUT_SCALE) then
    begin WriteLn('info string NNUE: ', Name, ': quantization scale mismatch'); Exit; end;

  expected := 32 + SizeOf(L1W) + SizeOf(L1B) + SizeOf(L1S) + SizeOf(L2W) +
              SizeOf(L2B) + SizeOf(L3W) + SizeOf(L3B) + 4;
  if Size <> expected then
    begin WriteLn('info string NNUE: ', Name, ': size mismatch, got ', Size,
                  ' expected ', expected); Exit; end;

  { checksum over everything except the trailing 4 bytes }
  sum := 0;
  for i := 0 to Integer(Size) - 5 do sum := sum + p[i];
  Move(p[Size - 4], want, 4);
  if sum <> want then
    begin WriteLn('info string NNUE: ', Name, ': checksum mismatch'); Exit; end;

  Result := True;
end;

function NNUE_LoadFromBuffer(const Buf; Size: Int64; const Name: string): boolean;
{ Check, then copy into the live weights. Unloads first, so a refused buffer
  leaves NO net loaded and the engine refuses to search -- deliberately, a
  wrong net must not pass silently for the intended one. }
var
  p: PByte;
  i: Int64;
{$IFDEF NNUE_FLOAT_REF}
  j, k: integer;
{$ENDIF}
begin
  Result := False;
  NNUE_Unload;
  if not NNUE_CheckBuffer(Buf, Size, Name) then Exit;

  p := PByte(@Buf);
  i := 32;
  Move(p[i], L1W, SizeOf(L1W)); Inc(i, SizeOf(L1W));
  Move(p[i], L1B, SizeOf(L1B)); Inc(i, SizeOf(L1B));
  Move(p[i], L1S, SizeOf(L1S)); Inc(i, SizeOf(L1S));
  Move(p[i], L2W, SizeOf(L2W)); Inc(i, SizeOf(L2W));
  Move(p[i], L2B, SizeOf(L2B)); Inc(i, SizeOf(L2B));
  Move(p[i], L3W, SizeOf(L3W)); Inc(i, SizeOf(L3W));
  Move(p[i], L3B, SizeOf(L3B));

  {$IFDEF NNUE_FLOAT_REF}
  for k := 0 to NNUE_N_IN - 1 do
    for j := 0 to NNUE_N_L1 - 1 do L1Wf[k, j] := L1W[k, j] / NNUE_QA;
  for j := 0 to NNUE_N_L1 - 1 do L1Bf[j] := L1B[j] / NNUE_QA;
  for j := 0 to NNUE_N_L1 - 1 do L1Sf[j] := L1S[j] / NNUE_QA;
  for k := 0 to NNUE_N_L2 - 1 do
  begin
    for j := 0 to NNUE_N_L1 - 1 do L2Wf[k, j] := L2W[k, j] / NNUE_QB;
    L2Bf[k] := L2B[k] / (NNUE_QA * NNUE_QB);
    L3Wf[k] := L3W[k] / NNUE_QB;
  end;
  L3Bf := L3B / (NNUE_QA * NNUE_QB);
  {$ENDIF}

  NNUE_Available := True;
  Result := True;
  WriteLn('info string NNUE: loaded ', Name, ' (', Size, ' bytes, ',
          NNUE_N_IN, '+stm->', NNUE_N_L1, '->', NNUE_N_L2,
          '->1, format 2: side-to-move input)');
end;

function ReadNetFile(const FileName: string; out Buf: TBytes): boolean;
{ File I/O only -- no validation here. A missing file is not reported: the
  callers report it themselves, with the working directory. }
var
  F: file;
  sz: Int64;
  oldMode: byte;
  ioErr: word;
begin
  Result := False;
  Buf := nil;
  if not FileExists(FileName) then Exit;

  AssignFile(F, FileName);
  oldMode := FileMode;
  FileMode := 0;          { read-only: a match may open this file from several engines at once }
  {$I-} Reset(F, 1); {$I+}
  FileMode := oldMode;
  ioErr := IOResult;
  if ioErr <> 0 then
  begin
    WriteLn('info string NNUE: cannot open ', FileName, ' (I/O error ', ioErr, ')');
    Exit;
  end;
  try
    sz := FileSize(F);
    if sz = 0 then
    begin
      WriteLn('info string NNUE: ', FileName, ' is empty');
      Exit;
    end;
    SetLength(Buf, sz);
    BlockRead(F, Buf[0], sz);
    Result := True;
  finally
    CloseFile(F);
  end;
end;

function NNUE_Load(const FileName: string): boolean;
{ An external net. Unloads first (also when the file is missing), so a failed
  load always leaves NO net. }
var
  buf: TBytes;
begin
  Result := False;
  NNUE_Unload;
  if not ReadNetFile(FileName, buf) then Exit;
  Result := NNUE_LoadFromBuffer(buf[0], Length(buf), FileName);
end;

function NNUE_LoadEmbedded: boolean;
begin
  Result := NNUE_LoadFromBuffer(EMBEDDED_NET[0], SizeOf(EMBEDDED_NET),
                                'embedded net ' + EMBEDDED_NET_NAME);
end;

function NNUE_EmbeddedName: string;
begin
  Result := EMBEDDED_NET_NAME;
end;

function NNUE_EmbeddedChecksum: Cardinal;
begin
  Result := EMBEDDED_NET_CHECKSUM;
end;

function NNUE_EmbeddedDesc: string;
begin
  Result := 'embedded net (' + EMBEDDED_NET_NAME + ', ' +
            IntToStr(SizeOf(EMBEDDED_NET)) + ' bytes)';
end;

function NNUE_Embed(const NetFile, IncFile, NetName: string): boolean;
{ 'nnue embed'. Validates NetFile with NNUE_CheckBuffer (no second validator
  anywhere) and writes IncFile in the layout NNUE_LoadEmbedded expects.
  Writes to IncFile + '.tmp' first and renames at the end, so a failure never
  leaves a half-written include behind. LF line endings, as for every .inc of
  this project. The active net is not touched. }
const
  PER_LINE = 20;
var
  buf: TBytes;
  nm, tmp, line, incAbs: string;
  F: TextFile;
  i, n: integer;
  sum: Cardinal;
  opened: boolean;
begin
  Result := False;
  if not FileExists(NetFile) then
  begin
    WriteLn('nnue embed: cannot find "', NetFile, '"');
    WriteLn('  looked relative to the working directory: ', GetCurrentDir);
    Exit;
  end;
  if LowerCase(ExtractFileExt(IncFile)) <> '.inc' then
  begin
    WriteLn('nnue embed: the output file must end in .inc (got "', IncFile, '")');
    Exit;
  end;

  nm := NetName;
  if nm = '' then nm := ChangeFileExt(ExtractFileName(NetFile), '');
  if LowerCase(nm) = 'pasknight' then
  begin
    WriteLn('nnue embed: the name "', nm, '" says nothing about which net this is.');
    WriteLn('  give the name explicitly:  nnue embed <file.nnue> <out.inc> nnue10');
    Exit;
  end;
  if (nm = '') or (Length(nm) > 40) then
  begin
    WriteLn('nnue embed: bad net name "', nm, '" (1-40 characters)');
    Exit;
  end;
  for i := 1 to Length(nm) do
    if not (nm[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.']) then
    begin
      WriteLn('nnue embed: bad character in net name "', nm,
              '" (allowed: letters, digits, _ - .)');
      WriteLn('  give the name explicitly:  nnue embed <file.nnue> <out.inc> <name>');
      Exit;
    end;

  if not ReadNetFile(NetFile, buf) then
  begin
    WriteLn('nnue embed: could not read "', NetFile, '" -- nothing written');
    Exit;
  end;
  if not NNUE_CheckBuffer(buf[0], Length(buf), NetFile) then
  begin
    WriteLn('nnue embed: "', NetFile, '" refused (reason above) -- nothing written');
    Exit;
  end;
  n := Length(buf);
  Move(buf[n - 4], sum, 4);   { NNUE_CheckBuffer verified it equals the byte sum }

  incAbs := ExpandFileName(IncFile);
  tmp := incAbs + '.tmp';
  opened := False;
  try
    AssignFile(F, tmp);
    {$I-} Rewrite(F); {$I+}
    if IOResult <> 0 then
    begin
      WriteLn('nnue embed: cannot create "', tmp, '" -- nothing written');
      Exit;
    end;
    opened := True;
    Write(F, '// pasknight_net.inc -- the net embedded in the executable.', #10);
    Write(F, '// GENERATED by the engine command ''nnue embed''. Do not edit by hand.', #10);
    Write(F, '//', #10);
    Write(F, '//   source    ', ExpandFileName(NetFile), #10);
    Write(F, '//   name      ', nm, #10);
    Write(F, '//   size      ', n, ' bytes', #10);
    Write(F, '//   checksum  $', HexStr(Int64(sum), 8),
             '  (byte sum mod 2^32, the file''s trailing word)', #10);
    Write(F, '//   written   ', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), #10);
    Write(F, '//', #10);
    Write(F, '// The engine checks this array at every startup with NNUE_CheckBuffer,', #10);
    Write(F, '// the same checks as for an external file, and refuses to search if', #10);
    Write(F, '// they fail. To embed another net:', #10);
    Write(F, '//   nnue embed <file.nnue> <path of this file> [name]', #10);
    Write(F, '// then rebuild BOTH build modes (Release and GenData).', #10);
    Write(F, #10);
    Write(F, 'const', #10);
    Write(F, '  EMBEDDED_NET_NAME     = ''', nm, ''';', #10);
    Write(F, '  EMBEDDED_NET_SIZE     = ', n, ';', #10);
    Write(F, '  EMBEDDED_NET_CHECKSUM = $', HexStr(Int64(sum), 8), ';', #10);
    Write(F, #10);
    Write(F, '  EMBEDDED_NET: array[0..EMBEDDED_NET_SIZE - 1] of byte = (', #10);
    line := '';
    for i := 0 to n - 1 do
    begin
      line := line + '$' + HexStr(buf[i], 2);
      if i < n - 1 then line := line + ',';
      if ((i + 1) mod PER_LINE = 0) or (i = n - 1) then
      begin
        Write(F, '    ', line, #10);
        line := '';
      end;
    end;
    Write(F, '  );', #10);
    CloseFile(F);
    opened := False;

    if FileExists(incAbs) and not DeleteFile(incAbs) then
    begin
      WriteLn('nnue embed: cannot replace "', incAbs, '" (in use or read-only?)');
      WriteLn('  the new include is in "', tmp, '"');
      Exit;
    end;
    if not RenameFile(tmp, incAbs) then
    begin
      WriteLn('nnue embed: cannot rename "', tmp, '" to "', incAbs, '"');
      Exit;
    end;
  except
    on E: Exception do
    begin
      if opened then
      begin
        {$I-} CloseFile(F); {$I+}
        if IOResult <> 0 then ;
      end;
      DeleteFile(tmp);
      WriteLn('nnue embed: write failed (', E.Message, ') -- nothing written');
      Exit;
    end;
  end;

  WriteLn('nnue embed: ', NetFile, ' passed all checks (', n,
          ' bytes, checksum $', HexStr(Int64(sum), 8), ')');
  WriteLn('nnue embed: wrote ', incAbs, '  (net name ''', nm, ''')');
  if sum = EMBEDDED_NET_CHECKSUM then
    WriteLn('  same checksum as the net built into this executable (',
            EMBEDDED_NET_NAME, ')')
  else
    WriteLn('  replaces, after a rebuild, the net built into this executable: ',
            EMBEDDED_NET_NAME, ' (checksum $', HexStr(Int64(EMBEDDED_NET_CHECKSUM), 8), ')');
  WriteLn('  the active net is unchanged. Rebuild BOTH build modes (Release and');
  WriteLn('  GenData), then check the startup line names ', nm, '.');
  Result := True;
end;

{ --- accumulator --------------------------------------------------------- }

{$IFDEF NNUE_DEBUG_ACC}
procedure NNUE_TrackPeak;
{ 256 comparisons per evaluation is far too expensive for a release build, so
  this only exists in the debug build. Its job is to answer one question --
  how close does the int16 accumulator actually get to overflowing on real
  positions -- and to answer it empirically rather than from the static bound
  that export_nnue.py checks. }
var j, v: integer;
begin
  for j := 0 to NNUE_N_L1 - 1 do
  begin
    v := Abs(Acc[NNUE_Ptr][j]);
    if v > NNUE_PeakAcc then NNUE_PeakAcc := v;
    if v > 32767 then Inc(NNUE_Overflows);
  end;
end;
{$ENDIF}

procedure NNUE_Add(PieceIdx, Sq: integer);
{ One feature's weight column is 256 contiguous Int16 -- that is the whole
  reason the file stores L1 weights feature-major. On the SSE2 path this is a
  single PADDW loop; the scalar fallback walks it with pointers, because FPC
  recomputes the base address of a 2-D static array on every [f, j] access. }
var
  {$IF (NOT DEFINED(NNUE_SSE2)) OR DEFINED(NNUE_FLOAT_REF)}
  j: integer;
  {$ENDIF}
  pw, pa: PInt16;
begin
  Inc(NNUE_UpdCount);
  pw := @L1W[PieceIdx * 64 + Sq, 0];
  pa := @Acc[NNUE_Ptr][0];
  {$IFDEF NNUE_SSE2}
  AddCol256(pa, pw);
  {$ELSE}
  for j := 0 to NNUE_N_L1 - 1 do
    pa[j] := pa[j] + pw[j];
  {$ENDIF}
  {$IFDEF NNUE_FLOAT_REF}
  { The parallel Double accumulator exists only to isolate quantization error.
    It costs 256 extra double ops here and 2 KB per push, so a FLOAT_REF build
    is several times slower than the real one on the accumulator path. NEVER
    benchmark or play matches with this define -- compare a FLOAT_REF build
    only against another FLOAT_REF build. }
  for j := 0 to NNUE_N_L1 - 1 do
    AccF[NNUE_Ptr][j] := AccF[NNUE_Ptr][j] + L1Wf[PieceIdx * 64 + Sq, j];
  {$ENDIF}
end;

procedure NNUE_Sub(PieceIdx, Sq: integer);
var
  {$IF (NOT DEFINED(NNUE_SSE2)) OR DEFINED(NNUE_FLOAT_REF)}
  j: integer;
  {$ENDIF}
  pw, pa: PInt16;
begin
  Inc(NNUE_UpdCount);
  pw := @L1W[PieceIdx * 64 + Sq, 0];
  pa := @Acc[NNUE_Ptr][0];
  {$IFDEF NNUE_SSE2}
  SubCol256(pa, pw);
  {$ELSE}
  for j := 0 to NNUE_N_L1 - 1 do
    pa[j] := pa[j] - pw[j];
  {$ENDIF}
  {$IFDEF NNUE_FLOAT_REF}
  for j := 0 to NNUE_N_L1 - 1 do
    AccF[NNUE_Ptr][j] := AccF[NNUE_Ptr][j] - L1Wf[PieceIdx * 64 + Sq, j];
  {$ENDIF}
end;

procedure NNUE_Push;
{ Copy the current accumulator to the next slot and descend into it. Called
  once at the top of DoMakeMove, BEFORE any BB_PlacePiece / BB_RemovePiece, so
  every delta of that move lands on the child slot and the parent's
  accumulator survives untouched for the copy-restore unwind. }
begin
  if NNUE_Ptr + 1 >= NNUE_MAX_ACC then
  begin
    { Must never happen in practice -- see NNUE_MAX_ACC. If it ever does, the
      caller writes this move's deltas into the PARENT slot, silently
      corrupting the position we will unwind to. Refusing quietly would turn
      that into mystery lost games, so make it loud once and count it; the
      next NNUE_FullRefresh (one per search) repairs the damage. }
    Inc(NNUE_StackOverflows);
    if NNUE_StackOverflows = 1 then
      WriteLn('info string NNUE: accumulator stack exhausted at depth ',
              NNUE_MAX_ACC, ' -- accumulator may be stale until the next refresh');
    Exit;
  end;
  Inc(NNUE_PushCount);
  Acc[NNUE_Ptr + 1] := Acc[NNUE_Ptr];
  {$IFDEF NNUE_FLOAT_REF}
  AccF[NNUE_Ptr + 1] := AccF[NNUE_Ptr];
  {$ENDIF}
  Inc(NNUE_Ptr);
end;

procedure NNUE_SetPtr(P: integer); inline;
begin
  NNUE_Ptr := P;
end;

procedure NNUE_ResetCounters;
begin
  NNUE_PushCount := 0;
  NNUE_UpdCount := 0;
  NNUE_EvalCount := 0;
end;

procedure NNUE_RefreshBegin;
var j: integer;
begin
  NNUE_Ptr := 0;
  for j := 0 to NNUE_N_L1 - 1 do Acc[0][j] := L1B[j];
  {$IFDEF NNUE_FLOAT_REF}
  for j := 0 to NNUE_N_L1 - 1 do AccF[0][j] := L1Bf[j];
  {$ENDIF}
end;

procedure NNUE_RefreshAdd(PieceIdx, Sq: integer);
begin
  NNUE_Add(PieceIdx, Sq);
end;

{ --- forward pass -------------------------------------------------------- }

function CReLU16(v: Int32): Int32; inline;
begin
  if v < 0 then Result := 0
  else if v > NNUE_QA then Result := NNUE_QA
  else Result := v;
end;

function NNUE_EvalWhitePOV(Stm: integer): integer;
{ ~8200 multiply-accumulates, scalar. This is the single hottest routine in an
  NNUE build, so it is written for the code generator rather than for looks:
  a0 is kept as Int16 to halve cache traffic through the layer-2 loop, both
  operand walks are pointer-based, and the inner loop is unrolled by 4 to cut
  loop overhead and give the scheduler independent chains.

  The ARITHMETIC is unchanged and must stay bit-identical to
  nnue_quant_reference.py -- `nnue testvec` is what proves it. }
var
  a0: array[0..NNUE_N_L1 - 1] of Int16;   { values in [0, QA], fits Int16 }
  a1: array[0..NNUE_N_L2 - 1] of Int16;
  s, o: Int32;
  s0, s1, s2, s3: Int32;      { independent chains -- see the loop below }
  j, k: integer;
  pw, pa, pacc: PInt16;
begin
  Inc(NNUE_EvalCount);
  {$IFDEF NNUE_DEBUG_ACC}
  NNUE_TrackPeak;
  {$ENDIF}

  pacc := @Acc[NNUE_Ptr][0];
  if Stm = 1 then
  begin
    { Black to move: add the side-to-move column before the CReLU.
      Exact in both paths: the scalar one sums in Int32, the AVX2 one
      saturates, and the clamp to [0, QA] makes the two identical. }
    {$IFDEF NNUE_AVX2}
    if NNUE_HasAVX2 then
      AddCReLU256_AVX2(pacc, @L1S[0], @a0[0], @QAVec16[0])
    else
    {$ENDIF}
      for j := 0 to NNUE_N_L1 - 1 do
        a0[j] := Int16(CReLU16(Int32(pacc[j]) + L1S[j]));
  end
  else
  begin
    {$IFDEF NNUE_AVX2}
    if NNUE_HasAVX2 then
      CReLU256_AVX2(pacc, @a0[0], @QAVec16[0])
    else
    {$ENDIF}
      for j := 0 to NNUE_N_L1 - 1 do
        a0[j] := Int16(CReLU16(pacc[j]));
  end;


  { Four INDEPENDENT accumulators. The previous version unrolled by 4 but
    summed into a single variable, which serialises the whole loop: every add
    waits on the one before it, so the multiplier's latency is exposed instead
    of its throughput. Four chains let the out-of-order engine keep several
    multiplies in flight at once.

    Integer addition is associative, so regrouping the sum is EXACT -- the
    result is bit-identical to the plain loop, which `nnue testvec` checks.

    Overflow: |a0| <= QA = 1024 and |w| <= 1.98*QB ~ 2027, so each product is
    under 2.1e6 and each of the four chains accumulates 64 of them, under
    1.4e8. Int32 holds it with an order of magnitude to spare. }
  pa := @a0[0];
  for k := 0 to NNUE_N_L2 - 1 do
  begin
    pw := @L2W[k, 0];
    {$IFDEF NNUE_SSE2}
    s := L2B[k] + Dot256(pa, pw);
    {$ELSE}
    { Four independent accumulator chains so the adds do not serialise.
      Integer addition is associative, so this is bit-identical. }
    s0 := 0; s1 := 0; s2 := 0; s3 := 0;
    j := 0;
    while j < NNUE_N_L1 do
    begin
      s0 := s0 + Int32(pa[j    ]) * pw[j    ] + Int32(pa[j + 4]) * pw[j + 4];
      s1 := s1 + Int32(pa[j + 1]) * pw[j + 1] + Int32(pa[j + 5]) * pw[j + 5];
      s2 := s2 + Int32(pa[j + 2]) * pw[j + 2] + Int32(pa[j + 6]) * pw[j + 6];
      s3 := s3 + Int32(pa[j + 3]) * pw[j + 3] + Int32(pa[j + 7]) * pw[j + 7];
      Inc(j, 8);
    end;
    s := L2B[k] + s0 + s1 + s2 + s3;
    {$ENDIF}
    { Round to nearest rather than truncate. Truncation biases every hidden
      unit half an LSB low, and 32 of those do not cancel -- they show up as a
      systematic centipawn offset in the final output. }
    a1[k] := Int16(CReLU16((s + NNUE_QB div 2) div NNUE_QB));
  end;

  o := L3B;
  for k := 0 to NNUE_N_L2 - 1 do
    o := o + Int32(a1[k]) * L3W[k];

  { Int64: o can reach ~6.6e7 and OUTPUT_SCALE is 400, so the product
    overflows Int32. Pascal `div` truncates toward zero, matching the
    trunc_div() in nnue_quant_reference.py. }
  Result := Integer((Int64(o) * NNUE_OUTPUT_SCALE) div (Int64(NNUE_QA) * NNUE_QB));
end;

{$IFDEF NNUE_FLOAT_REF}
function ClampF(v: Double): Double; inline;
begin
  if v < 0.0 then Result := 0.0 else if v > 1.0 then Result := 1.0 else Result := v;
end;

function NNUE_EvalWhitePOV_Float(Stm: integer): Double;
var
  h0: array[0..NNUE_N_L1 - 1] of Double;
  h1: array[0..NNUE_N_L2 - 1] of Double;
  s, o: Double;
  j, k: integer;
begin
  if Stm = 1 then
    for j := 0 to NNUE_N_L1 - 1 do h0[j] := ClampF(AccF[NNUE_Ptr][j] + L1Sf[j])
  else
    for j := 0 to NNUE_N_L1 - 1 do h0[j] := ClampF(AccF[NNUE_Ptr][j]);
  for k := 0 to NNUE_N_L2 - 1 do
  begin
    s := L2Bf[k];
    for j := 0 to NNUE_N_L1 - 1 do s := s + h0[j] * L2Wf[k, j];
    h1[k] := ClampF(s);
  end;
  o := L3Bf;
  for k := 0 to NNUE_N_L2 - 1 do o := o + h1[k] * L3Wf[k];
  Result := o * NNUE_OUTPUT_SCALE;
end;
{$ENDIF}

{ --- validation ---------------------------------------------------------- }

procedure NNUE_VerifyBegin;
var j: integer;
begin
  for j := 0 to NNUE_N_L1 - 1 do Scratch[j] := L1B[j];
end;

procedure NNUE_VerifyAdd(PieceIdx, Sq: integer);
var j, f: integer;
begin
  f := PieceIdx * 64 + Sq;
  for j := 0 to NNUE_N_L1 - 1 do Scratch[j] := Scratch[j] + L1W[f, j];
end;

function NNUE_VerifyMatches(out BadIndex, GotVal, WantVal: integer): boolean;
var j: integer;
begin
  BadIndex := -1; GotVal := 0; WantVal := 0;
  for j := 0 to NNUE_N_L1 - 1 do
    if Acc[NNUE_Ptr][j] <> Scratch[j] then
    begin
      BadIndex := j;
      GotVal   := Acc[NNUE_Ptr][j];
      WantVal  := Scratch[j];
      Exit(False);
    end;
  Result := True;
end;

procedure NNUE_Trace(Stm: integer; out Acc0, A0: TNNUEAcc; out S, A1: TNNUEL2;
                     out O: Int32; out Cp: integer);
{ Acc0 is the accumulator itself, WITHOUT the side-to-move column -- the same
  quantity the test vectors' accSum records. The column enters at A0. }
var
  j, k: integer;
  ss, oo: Int32;
  aa: array[0..NNUE_N_L1 - 1] of Int32;
begin
  for j := 0 to NNUE_N_L1 - 1 do
  begin
    Acc0[j] := Acc[NNUE_Ptr][j];
    if Stm = 1 then
      aa[j] := CReLU16(Int32(Acc[NNUE_Ptr][j]) + L1S[j])
    else
      aa[j] := CReLU16(Acc[NNUE_Ptr][j]);
    A0[j]   := Int16(aa[j]);          { A0 fits Int16: range [0, QA] }
  end;
  for k := 0 to NNUE_N_L2 - 1 do
  begin
    ss := L2B[k];
    for j := 0 to NNUE_N_L1 - 1 do ss := ss + aa[j] * L2W[k, j];
    S[k]  := ss;
    A1[k] := CReLU16((ss + NNUE_QB div 2) div NNUE_QB);
  end;
  oo := L3B;
  for k := 0 to NNUE_N_L2 - 1 do oo := oo + A1[k] * L3W[k];
  O  := oo;
  Cp := Integer((Int64(oo) * NNUE_OUTPUT_SCALE) div (Int64(NNUE_QA) * NNUE_QB));
end;

procedure InitNNUECPU;
var
  i: integer;
begin
  {$IFDEF NNUE_SSE2}
  for i := 0 to 15 do QAVec16[i] := NNUE_QA;
  {$ENDIF}
  {$IFDEF NNUE_AVX2}
  NNUE_CPUHasAVX2 := DetectAVX2;
  NNUE_HasAVX2    := NNUE_CPUHasAVX2;
  {$ENDIF}
end;

initialization
  InitNNUECPU;

end.
