{ =============================================================================
  pasknight_nnue_gendata.inc  --  training-data generator.

  Include from pasknight.lpr under {$IFDEF NNUE_GENDATA}, after SEE /
  GenerateLegalMoves / Search are declared and before the UCI dispatch loop:

      {$IFDEF NNUE_GENDATA}
      {$I pasknight_nnue_gendata.inc}
      {$ENDIF}

  ONE MODE (v2.0).

    gendata selfplay <count> <file> [nodes] [seed] [book.epd | pgnbook]
        Plays complete games with the engine's own search -- the loaded net --
        at a low fixed node count and records, for every retained position,
        BOTH the search score and the eventual game result. Refuses to run
        without a net.

        nodes defaults to SP_NODES_DEFAULT, seed to 0 = seed from the clock.

    The v1.10 distillation mode ('gendata <count> <file>': random-walk and
    synthetic positions labelled with the hand-crafted Evaluate()) was removed
    with the HCE in v2.0. The data it produced stays readable (Res = 0).

  ---------------------------------------------------------------------------
  SEED THE PARALLEL INSTANCES EXPLICITLY.

  The intended use is six concurrent processes writing six files. Randomize
  seeds RandSeed from the system clock, and six processes launched by the same
  script within the same clock tick get the SAME seed and play the SAME games.
  Nothing downstream would notice: the files would differ in name only, the
  trainer would report a healthy-looking loss, and the effective dataset would
  be one sixth of its apparent size. Pass a distinct seed per instance:

      gendata selfplay 1400000 sp0.bin 1000 1
      gendata selfplay 1400000 sp1.bin 1000 2   ... and so on.

  ---------------------------------------------------------------------------
  RECORD FORMAT, 32 bytes, little-endian, no header. Unchanged in size and in
  the first 28 bytes; two of the four pad bytes now carry game-result data, so
  every existing reader (train_nnue.py's vectorised decode, export_nnue.py)
  keeps working on both old and new files.

      QWord    Occ          occupancy bitboard, LERF (a1 = bit 0)
      byte[16] Nib          one nibble per occupied square in ascending bit
                            order; low nibble first. Value = Ord(TPiece)-1,
                            so 0=wP .. 5=wK, 6=bP .. 11=bK.
      SmallInt Score        WHITE-POV centipawns: the search score. (Files
                            from the removed v1.10 distillation mode carry a
                            tempo-free Evaluate() here instead.)
      byte     Stm          0 = white to move, 1 = black
      byte     Phase        0..24, the tapered-eval phase
      byte     Res          GAME RESULT, WHITE POV:
                              0 = unknown / not recorded
                              1 = black won
                              2 = draw
                              3 = white won
      byte     Ply          plies from the start of the game, capped at 255.
                            Diagnostics only: lets the trainer check that the
                            data is not dominated by openings or by endgames.
      byte[2]  Pad          zero

  Res = 0 for "absent" rather than 0 = "black won" is deliberate. Every record
  written before this change has all four pad bytes zero. Had 0 meant a black
  win, every one of the 16M distillation positions would silently decode as a
  black win and a WDL-blended loss would train against pure noise while
  reporting a perfectly plausible learning curve. With 0 = unknown, the
  trainer can tell the two files apart and refuse the blend on old data.

  ---------------------------------------------------------------------------
  THE SIDE TO MOVE. A search score is the value of the position to the side
  to move, including the benefit of moving first, so the label is not a pure
  function of piece placement. Format-2 nets (the only format since v2.0) see
  the side to move through their side-to-move input column and can learn
  that; the record's Stm byte carries it.
  ========================================================================== }

const
  { --- random-move filter (GenPickMove: the random opening plies) ---------- }

  { A uniformly random legal move hangs material
    constantly, and 80 plies of that drifts far from anything a search tree
    contains. Reject a move losing more than SEE_REJECT_CP by static exchange,
    SEE_REJECT_PCT of the time. Not 100%, because the net still has to be
    right about lopsided positions -- just not trained mostly on them. }
  SEE_REJECT_CP  = -150;
  SEE_REJECT_PCT = 85;

  { --- self-play constants ------------------------------------------------ }

  SP_NODES_DEFAULT = 5000;   { per search iteration; see GenSPSearch          }

  { Random opening plies, played with the SEE-filtered random picker rather
    than uniformly at random: a uniform random opening hangs a piece within a
    few moves and the rest of the game is a conversion exercise. Six to twelve
    plies of filtered randomness gives more distinct openings than 8M
    positions can exhaust while keeping the start of the game sane. }
  SP_OPEN_MIN      = 6;
  SP_OPEN_MAX      = 12;

  { Random plies played on top of a BOOK position (gendata selfplay ... book).
    The search runs at a fixed node count and is deterministic, so without
    them every game started from the same book line would be the SAME game.
    Same SEE-filtered picker as the plain random opening. }
  SP_BOOK_EXTRA_MIN = 2;
  SP_BOOK_EXTRA_MAX = 6;

  { Hard ceiling on game length. A game still running here has no result we
    can trust, so it is DISCARDED whole -- see the adjudication note below.

    Kept BELOW 256 deliberately. The Ply byte saturates at 255, and a game
    running past that emits a run of records all reading 255, which destroys
    the one property downstream tooling relies on: that ply increases within a
    game and therefore marks where one game ends and the next begins. That is
    how merge_shuffle.py recovers game boundaries for the train/val split
    without a game id in the record. Below 256, ply is unambiguous and the
    boundary test is exact.

    The cost is games between 250 and 400 plies now being discarded instead of
    finished. With win and draw adjudication both active the discard rate
    measured 0.7% at 400 plies, so this is a small number of the least useful
    games -- ones neither side could win and neither side would concede. }
  SP_MAX_PLIES     = 250;

  { Win adjudication. A 1000-node search is not reliable at converting a won
    endgame, and a game that reaches +25 pawns and then draws by the fifty-move
    rule teaches the net that a winning position is a draw. That is worse
    label noise than adjudicating. So a position at or beyond SP_ADJ_WIN_CP
    for SP_ADJ_WIN_PLIES consecutive plies is scored as a win for the leader.
    Set SP_ADJ_WIN_CP to 0 to disable and play everything out.

    Note this is the one adjudication that is kept rather than discarded. A
    ply-limit or repetition-limbo game ends with the result genuinely unknown;
    a +25-pawn game does not. }
  SP_ADJ_WIN_CP    = 2500;
  SP_ADJ_WIN_PLIES = 4;

  { Draw adjudication. Without it, roughly one game in seven at 1000 nodes
    grinds to SP_MAX_PLIES in a position neither side can win: the score never
    approaches SP_ADJ_WIN_CP, nothing terminal ever happens, and the whole game
    is discarded. That is a seventh of the generation budget spent on nothing,
    and it is also what stretches the mean game length -- and with it the
    number of correlated positions drawn from each game.

    The shape is the standard one (cutechess: score within 10 cp for 8
    consecutive moves after move 40). A position dead level for sixteen
    consecutive plies this late, under a search that both sides are running,
    is a draw far more reliably than a 400-ply timeout is anything.

    Set SP_ADJ_DRAW_CP to 0 to disable. }
  SP_ADJ_DRAW_CP    = 15;
  SP_ADJ_DRAW_PLIES = 16;
  SP_ADJ_DRAW_AFTER = 80;   { ply; before this, level scores mean nothing }

  { |score| above this is a mate score (the engine encodes mate as
    29000 - plies). Those positions are dropped: as regression targets they
    are meaningless, and the game result already carries everything true
    about them. Matches ASP_MATE_BOUND. }
  SP_MATE_BOUND    = 28000;

  { Per-game sample buffer. The result is not known until the game ends, so a
    game's positions are held here and stamped on the way out. 400 plies can
    at most produce 400 samples; 512 is slack. }
  SP_MAX_SAMPLES   = 512;

  { Result byte encoding, white POV. }
  RES_UNKNOWN = 0;
  RES_BLACK   = 1;
  RES_DRAW    = 2;
  RES_WHITE   = 3;

type
  TNNUESample = packed record
    Occ:   QWord;
    Nib:   array[0..15] of byte;
    Score: SmallInt;
    Stm:   byte;
    Phase: byte;
    Res:   byte;
    Ply:   byte;
    Pad:   array[0..1] of byte;
  end;

var
  GenBuf: array[0..8191] of TNNUESample;
  GenBufCount: integer = 0;
  GenFile: file;

  { Per-game staging area (self-play mode). }
  SPBuf: array[0..SP_MAX_SAMPLES - 1] of TNNUESample;
  SPBufCount: integer = 0;

  { Root sentinels for the self-play search, built once. }
  SPRootPrev, SPRootExcl: TMove;

  { Run statistics. int64 because a 48-hour run overflows nothing else. }
  SPGames, SPKept, SPDiscarded, SPAdjudicated, SPAdjDraw, SPIters: int64;
  SPResW, SPResD, SPResB: int64;
  SPSkipCheck, SPSkipCapture, SPSkipMate: int64;
  SPPlySum, SPNodeSum, SPMoves: int64;

procedure GenFlush;
begin
  if GenBufCount > 0 then
  begin
    BlockWrite(GenFile, GenBuf[0], GenBufCount * SizeOf(TNNUESample));
    GenBufCount := 0;
  end;
end;

function GenPhase: integer;
{ Game phase for the record's Phase byte (diagnostics only): 24 = all minor
  and major pieces on the board, 0 = pawns and kings only. PeSTO/Rofchade
  weights, as the removed tapered HCE used (v0960). Local since v2.0, because
  nothing else in the engine needs them any more. }
const
  PhaseN = 1; PhaseB = 1; PhaseR = 2; PhaseQ = 4;
  MaxPhase = 24;
begin
  Result := Integer(PopCnt(State.Pieces[wN] or State.Pieces[bN])) * PhaseN +
            Integer(PopCnt(State.Pieces[wB] or State.Pieces[bB])) * PhaseB +
            Integer(PopCnt(State.Pieces[wR] or State.Pieces[bR])) * PhaseR +
            Integer(PopCnt(State.Pieces[wQ] or State.Pieces[bQ])) * PhaseQ;
  if Result > MaxPhase then Result := MaxPhase;
end;

function GenPack(out S: TNNUESample): boolean;
{ Snapshot the current position into a record. Fills everything except Score,
  Res and Ply, which the caller supplies. The packing is what export_nnue.py
  and the trainer's decode agree with. }
var
  { Not named `bb`: that would shadow the bB (black bishop) enum constant for
    the whole function. Harmless while nothing here names bB, but it is a
    landmine for the next edit. }
  occBits: QWord;
  sq, k, r, c: integer;
  P: TPiece;
begin
  Result := False;
  FillChar(S, SizeOf(S), 0);
  S.Occ := State.AllOccupied;
  if PopCnt(S.Occ) > 32 then Exit;      { cannot happen, but the nibble array assumes it }

  occBits := S.Occ; k := 0;
  while occBits <> 0 do
  begin
    sq := Integer(BsfQWord(occBits)); occBits := occBits and (occBits - 1);
    SquareCoords(sq, r, c);
    P := State.Board[r, c];
    if P = EMPTY then Exit;             { bitboard/mailbox drift -- drop the sample }
    if (k and 1) = 0 then S.Nib[k shr 1] := S.Nib[k shr 1] or byte(Ord(P) - 1)
                     else S.Nib[k shr 1] := S.Nib[k shr 1] or (byte(Ord(P) - 1) shl 4);
    Inc(k);
  end;

  S.Stm   := State.SideToMove;
  S.Phase := GenPhase;
  Result  := True;
end;

function GenPickMove(out M: TMove): boolean;
{ A uniformly random legal move produces positions with pieces hanging
  everywhere -- not the distribution the search actually visits. Bias the
  random opening plies by rejecting obviously losing moves most of the time,
  using the engine's own SEE. }
var
  Moves: TMoveList;
  Cnt, i, tries: integer;
begin
  GenerateLegalMoves(Moves, Cnt);
  if Cnt = 0 then Exit(False);
  for tries := 1 to 8 do
  begin
    i := Random(Cnt);
    if (Random(100) < SEE_REJECT_PCT) and (SEE(Moves[i]) < SEE_REJECT_CP) then Continue;
    M := Moves[i];
    Exit(True);
  end;
  M := Moves[Random(Cnt)];
  Result := True;
end;

{ ===========================================================================
  SELF-PLAY MODE
  =========================================================================== }

function GenSPSearch(Nodes: integer; out Best: TMove; out Score: integer): boolean;
{ One search from the current position. Returns the best move and its score
  from the SIDE TO MOVE's point of view, exactly as Search() does.

  This is a deliberately small root driver rather than a call to GetBestMove.
  GetBestMove consults the opening book, prints info lines to stdout, runs
  aspiration windows and a partial-depth recovery heuristic, and manages a
  clock. Every one of those is either noise or a source of label variance
  here, and the book in particular would make the first dozen plies of every
  game come from the same small set of positions.

  NODE ACCOUNTING matches the engine's own `go nodes N` exactly: SearchNodes
  is reset at the start of each deepening iteration, so N bounds the nodes per
  ITERATION, and the total for a move is roughly 1.5-2x N. That convention is
  the one the fixed-nodes SPRT used, so "1000 nodes" here means the same thing
  it means there. Changing it would silently change the strength of the
  labelling engine relative to every measurement taken so far.

  On a mid-iteration abort the partial result is DISCARDED and the previous
  completed iteration stands. GetBestMove has a three-case partial-recovery
  rule tuned for playing strength under a clock; here the cheaper and stricter
  rule is better, because an inconsistent label is worse than a slightly
  shallower one and iteration depth 1 always completes at 1000 nodes. }
var
  Moves: TMoveList;
  OldState: TGameState;
  Temp: TMove;
  Cnt, i, d, sc, curBest, curIdx: integer;
begin
  Result := False;
  Score  := 0;
  Best   := Default(TMove);     { an out parameter must be defined on every path }
  GenerateLegalMoves(Moves, Cnt);
  if Cnt = 0 then Exit;
  Best := Moves[0];

  { Rebuild once per search, as GetBestMove does: it bounds State.AccPtr,
    which game moves applied at the root would otherwise push without ever
    popping, and it resynchronises against any incremental drift. Cheap
    against ~2000 nodes. }
  NNUE_FullRefresh;

  NodeLimit            := Nodes;
  ExceedCeilingAbortMs := 0;          { no wall-clock abort: nodes are the bound }
  SearchStartTime      := ClockMs;

  for d := 1 to MAX_SEARCH_DEPTH do
  begin
    SearchNodes    := 0;
    NodeCheckCount := 0;
    AbortSearch    := False;
    SelDepth       := d;

    curBest := -30001;
    curIdx  := 0;

    for i := 0 to Cnt - 1 do
    begin
      OldState := State;
      DoMakeMove(Moves[i]);

      { Plain PVS at the root: full window for the first move, null window
        plus re-search for the rest. RootDepth is passed as d-1, matching
        GetBestMove's root calls. -30001 is the IMPROVING_UNKNOWN sentinel:
        the root has no grandparent static eval. }
      if i = 0 then
        sc := -Search(d - 1, -30000, 30000, d - 1, SPRootPrev, SPRootExcl, -30001)
      else
      begin
        sc := -Search(d - 1, -curBest - 1, -curBest, d - 1, SPRootPrev, SPRootExcl, -30001);
        if (sc > curBest) and not AbortSearch then
          sc := -Search(d - 1, -30000, -curBest, d - 1, SPRootPrev, SPRootExcl, -30001);
      end;

      State := OldState;
      if AbortSearch then Break;

      if sc > curBest then
      begin
        curBest := sc;
        curIdx  := i;
      end;
    end;

    { Count the iteration's nodes BEFORE the abort test. The aborted iteration
      is the one that consumed the whole node limit, so excluding it -- as the
      first version did -- reports a mean node count below the limit itself,
      which looks like a broken node limiter and is not. }
    Inc(SPNodeSum, SearchNodes);
    Inc(SPIters);

    if AbortSearch then Break;        { iteration incomplete -> discard it }

    Best   := Moves[curIdx];
    Score  := curBest;
    Result := True;

    { Move the best move to the front for the next iteration. Worth doing:
      without it the deepening loop re-derives the ordering from scratch every
      iteration and reaches roughly a ply less within the same node budget. }
    if curIdx <> 0 then
    begin
      Temp          := Moves[0];
      Moves[0]      := Moves[curIdx];
      Moves[curIdx] := Temp;
    end;

    { A mate score will not change with more depth and the game result already
      records what matters about the position. }
    if Abs(Score) > SP_MATE_BOUND then Break;
  end;

  { Leave no abort latched: Search() exits immediately on a set AbortSearch,
    so a stale True here would make every later search in the run return
    Alpha without looking at anything. }
  NodeLimit   := 0;
  AbortSearch := False;
end;

function GenSPIsCapture(const M: TMove): boolean;
{ Must be called BEFORE the move is made. }
begin
  Result := (State.Board[M.ToR, M.ToC] <> EMPTY) or (M.MoveType = MT_EN_PASSANT);
end;

procedure GenSPStage(SearchScore, Ply: integer);
{ Stage the current position with its search score. The result byte is stamped
  later, when the game has one. }
var
  S: TNNUESample;
  sc: integer;
begin
  if SPBufCount >= SP_MAX_SAMPLES then Exit;
  if not GenPack(S) then Exit;

  sc := SearchScore;
  if State.SideToMove = 1 then sc := -sc;    { side-to-move POV -> white POV }
  if sc >  30000 then sc :=  30000;
  if sc < -30000 then sc := -30000;

  S.Score := sc;
  S.Res   := RES_UNKNOWN;
  if Ply > 255 then S.Ply := 255 else S.Ply := byte(Ply);

  SPBuf[SPBufCount] := S;
  Inc(SPBufCount);
end;

procedure GenSPFlushGame(Res: byte; var Remaining: integer);
{ Stamp the finished game's result onto every staged position and move them
  into the write buffer. }
var
  i: integer;
begin
  for i := 0 to SPBufCount - 1 do
  begin
    if Remaining <= 0 then Break;
    SPBuf[i].Res := Res;
    GenBuf[GenBufCount] := SPBuf[i];
    Inc(GenBufCount);
    Dec(Remaining);
    if GenBufCount = Length(GenBuf) then GenFlush;
  end;
  SPBufCount := 0;
end;

var
  { Opening book for self-play: normalised FEN strings, one per position.
    nil or empty = no book, the random opening is used as before. }
  GenBook: TStringList = nil;
  { True = walk the engine's own PGN opening book (the one BookFile loaded)
    from the start position instead. Selected with the argument 'pgnbook'. }
  GenUseEngineBook: boolean = False;

function GenBookFEN(const Line: string): string;
{ Normalise one book line to a full FEN, or return '' if it is not a position.
  Accepts a plain FEN (six fields) and an EPD line (four fields followed by
  opcodes such as  bm Nf3; c0 "...";). EPD has no move counters, so ' 0 1'
  is appended. PGN tag lines, comments and blank lines are skipped. }
var
  s: string;
  f: array[0..5] of string;
  n, p, dummy: integer;
begin
  Result := '';
  s := Trim(Line);
  if (s = '') or (s[1] in ['#', '[', ';', '%', '{']) then Exit;
  n := 0;
  while (n < 6) and (s <> '') do
  begin
    p := Pos(' ', s);
    if p = 0 then p := Length(s) + 1;
    f[n] := Copy(s, 1, p - 1);
    Delete(s, 1, p);
    s := TrimLeft(s);
    Inc(n);
  end;
  if n < 4 then Exit;
  if Pos('/', f[0]) = 0 then Exit;
  if (f[1] <> 'w') and (f[1] <> 'b') then Exit;
  Result := f[0] + ' ' + f[1] + ' ' + f[2] + ' ' + f[3];
  if (n = 6) and TryStrToInt(f[4], dummy) and TryStrToInt(f[5], dummy) then
    Result := Result + ' ' + f[4] + ' ' + f[5]
  else
    Result := Result + ' 0 1';
end;

function GenLoadBook(const FN: string): integer;
{ Load an EPD/FEN book into GenBook. Returns the number of positions kept,
  or -1 if the file does not exist. }
var
  Raw: TStringList;
  i: integer;
  fen: string;
begin
  if GenBook = nil then GenBook := TStringList.Create else GenBook.Clear;
  if not FileExists(FN) then begin Result := -1; Exit; end;
  Raw := TStringList.Create;
  try
    Raw.LoadFromFile(FN);
    for i := 0 to Raw.Count - 1 do
    begin
      fen := GenBookFEN(Raw[i]);
      if fen <> '' then GenBook.Add(fen);
    end;
  finally
    Raw.Free;
  end;
  Result := GenBook.Count;
end;

procedure GenSelfPlay(Nodes: integer; var Remaining: integer);
{ Play one complete game and emit its retained positions.

  Position filters, all standard and all for the same reason -- the static
  evaluation of the position must be a sensible regression target:

    in check          the eval of a position whose king is attacked is
                      dominated by a tactic the net cannot see
    best move is a
    capture           the position is in the middle of an exchange; its true
                      value is the value after the exchange resolves, which is
                      what the search reports and what a static eval cannot
    mate score        no meaningful centipawn target exists
    opening plies     played at random, so not search-evaluated

  Note the filters drop the POSITION from the training set but the game plays
  on: the moves are still the search's moves and the result still reflects
  them. }
var
  Best, M: TMove;
  Moves: TMoveList;
  Score, ply, ply0, openPlies, i, Cnt, winner: integer;
  bookMv: string;
  adjCount, adjSide, drawCount: integer;
  Res: byte;
  finished: boolean;
begin
  SPBufCount := 0;
  Inc(SPGames);

  InitState;              { also clears Killers, History and GameHistory[0] }
  ClearTT;

  { --- opening ------------------------------------------------------------- }
  { With a book: start from a random book position, then a few filtered random
    plies so that no two games from the same line are identical. ply0 is the
    book position's own ply count, taken from its FEN, so the record's ply
    field keeps meaning "plies from the start of the game" and keeps rising
    within a game -- merge_shuffle finds game boundaries by that. Game length
    limits below are measured from the start of THIS game (ply - ply0), so a
    book start does not shorten games or move the draw adjudication. }
  if GenUseEngineBook then
  begin
    { Walk the engine's PGN book from the start position, one random book
      move at a time (GetBookMove weights by how often a move occurs, which
      amounts to picking a random book line), until the position is out of
      book. For 8moves_v3 that is after 16 plies. ply0 counts the book plies.
      The 40-ply cap only guards against a book that never ends. }
    ply0 := 0;
    while ply0 < 40 do
    begin
      bookMv := GetBookMove;
      if bookMv = '' then Break;
      ApplyUCIMove(bookMv);
      Inc(ply0);
    end;
    openPlies := SP_BOOK_EXTRA_MIN + Random(SP_BOOK_EXTRA_MAX - SP_BOOK_EXTRA_MIN + 1);
  end
  else if (GenBook <> nil) and (GenBook.Count > 0) then
  begin
    ParseFEN(GenBook[Random(GenBook.Count)]);
    ply0 := (State.FullMoveNumber - 1) * 2 + State.SideToMove;
    if ply0 < 0 then ply0 := 0;
    openPlies := SP_BOOK_EXTRA_MIN + Random(SP_BOOK_EXTRA_MAX - SP_BOOK_EXTRA_MIN + 1);
  end
  else
  begin
    ply0 := 0;
    openPlies := SP_OPEN_MIN + Random(SP_OPEN_MAX - SP_OPEN_MIN + 1);
  end;
  for i := 1 to openPlies do
  begin
    if not GenPickMove(M) then
    begin
      { the random opening walked into mate or stalemate: no game to play }
      Inc(SPDiscarded);
      Exit;
    end;
    DoMakeMove(M);
  end;
  if State.HalfMoveClock >= 100 then begin Inc(SPDiscarded); Exit; end;

  { --- play -------------------------------------------------------------- }
  Res      := RES_UNKNOWN;
  adjCount  := 0;
  adjSide   := 0;
  drawCount := 0;
  finished  := False;
  ply      := ply0 + openPlies;

  while ply - ply0 < SP_MAX_PLIES do
  begin
    GenerateLegalMoves(Moves, Cnt);
    if Cnt = 0 then
    begin
      { Checkmate or stalemate. The side to move is the one with no moves. }
      if IsInCheck(State.SideToMove) then
      begin
        if State.SideToMove = 0 then Res := RES_BLACK else Res := RES_WHITE;
      end
      else
        Res := RES_DRAW;
      finished := True;
      Break;
    end;

    if State.HalfMoveClock >= 100 then begin Res := RES_DRAW; finished := True; Break; end;
    if IsThreefoldRepetition   then begin Res := RES_DRAW; finished := True; Break; end;
    if IsInsufficientMaterial  then begin Res := RES_DRAW; finished := True; Break; end;

    if not GenSPSearch(Nodes, Best, Score) then
    begin
      { Cnt > 0 was just established, so this is unreachable; treat it as a
        lost game rather than emitting positions with no result. }
      Inc(SPDiscarded);
      SPBufCount := 0;
      Exit;
    end;
    Inc(SPMoves);

    { --- position filters ---------------------------------------------- }
    if IsInCheck(State.SideToMove) then
      Inc(SPSkipCheck)
    else if Abs(Score) > SP_MATE_BOUND then
      Inc(SPSkipMate)
    else if GenSPIsCapture(Best) then
      Inc(SPSkipCapture)
    else
      GenSPStage(Score, ply);

    { --- win adjudication ----------------------------------------------- }
    if SP_ADJ_WIN_CP > 0 then
    begin
      if Abs(Score) >= SP_ADJ_WIN_CP then
      begin
        { Score is side-to-move POV; convert to "which colour is winning". }
        if ((Score > 0) and (State.SideToMove = 0)) or
           ((Score < 0) and (State.SideToMove = 1)) then winner := 0 else winner := 1;
        if (adjCount > 0) and (winner = adjSide) then Inc(adjCount)
        else begin adjSide := winner; adjCount := 1; end;
      end
      else
        adjCount := 0;

      if adjCount >= SP_ADJ_WIN_PLIES then
      begin
        if adjSide = 0 then Res := RES_WHITE else Res := RES_BLACK;
        finished := True;
        Inc(SPAdjudicated);
        Break;
      end;
    end;

    { --- draw adjudication ---------------------------------------------- }
    if (SP_ADJ_DRAW_CP > 0) and (ply - ply0 >= SP_ADJ_DRAW_AFTER) then
    begin
      if Abs(Score) <= SP_ADJ_DRAW_CP then Inc(drawCount) else drawCount := 0;
      if drawCount >= SP_ADJ_DRAW_PLIES then
      begin
        Res := RES_DRAW;
        finished := True;
        Inc(SPAdjDraw);
        Break;
      end;
    end;

    DoMakeMove(Best);
    Inc(ply);
  end;

  { --- outcome ----------------------------------------------------------- }
  if not finished then
  begin
    { Ply limit reached with no result. Nothing here is known, so the whole
      game is discarded rather than labelled a draw. }
    Inc(SPDiscarded);
    SPBufCount := 0;
    Exit;
  end;

  Inc(SPKept);
  Inc(SPPlySum, ply - ply0);
  case Res of
    RES_WHITE: Inc(SPResW);
    RES_BLACK: Inc(SPResB);
  else         Inc(SPResD);
  end;
  GenSPFlushGame(Res, Remaining);
end;

{ ===========================================================================
  COMMAND
  =========================================================================== }

procedure GenSPReport(Target: integer; T0: QWord);
{ Everything here is cheap to read and expensive to discover after 48 hours.
  What to look for:

    result split       far from symmetric between white and black means the
                       opening sampler is biased
    draw rate          near 100% means the node count is too low for either
                       side to break anything open; near 0% means the
                       adjudication threshold is firing on noise
    kept per game      expected around 40. Much lower and the filters are
                       eating the data; much higher and one of them is not
                       firing at all
    nodes per move     expected around 1.5-2x the node limit, because the
                       limit is per deepening iteration
    discarded          a few percent is normal; a large share means games are
                       running to the ply limit, which is what the draw
                       adjudication exists to prevent -- check
                       SP_ADJ_DRAW_* before raising SP_MAX_PLIES }
var
  secs: int64;
begin
  secs := int64((GetTickCount64 - T0) div 1000);
  if secs = 0 then secs := 1;
  WriteLn('gendata selfplay: ', Target, ' positions in ', secs, ' s (',
          int64(Target) div secs, ' pos/s)');
  WriteLn('  games ', SPGames, ': kept ', SPKept, ', discarded ', SPDiscarded,
          ' (', (SPDiscarded * 100) div SPGames, '%)');
  WriteLn('  adjudicated: ', SPAdjudicated, ' win, ', SPAdjDraw, ' draw');
  if SPKept > 0 then
  begin
    WriteLn('  results (white POV): ', SPResW, ' W / ', SPResD, ' D / ',
            SPResB, ' B   (', (SPResW * 100) div SPKept, '/',
            (SPResD * 100) div SPKept, '/', (SPResB * 100) div SPKept, '%)');
    WriteLn('  mean game length ', SPPlySum div SPKept, ' plies, ',
            int64(Target) div SPKept, ' positions kept per game');
  end;
  if SPMoves > 0 then
    WriteLn('  mean nodes per move ', SPNodeSum div SPMoves, ' over ',
            SPIters div SPMoves, ' completed+aborted iterations',
            '  (expect ~1.5-2x the node limit: it bounds each iteration)');
  WriteLn('  positions skipped: ', SPSkipCheck, ' in check, ',
          SPSkipCapture, ' capture best move, ', SPSkipMate, ' mate score');
  WriteLn('  eval used: NNUE ', ActiveNetDesc);
end;

procedure GenData_Command(const Args: string);
var
  SL: TStringList;
  Target, Remaining, Done, LastPct, Pct, Nodes, Seed: integer;
  FileName: string;
  Saved: TGameState;
  SavedNodeLimit: int64;
  T0: QWord;
  argBase, Stalled, StallCount: integer;
  BookName: string;
  GenBookN: integer;
begin
  BookName := '';
  Nodes    := SP_NODES_DEFAULT;
  Seed     := 0;

  SL := TStringList.Create;
  try
    SL.Delimiter := ' ';
    SL.DelimitedText := Args;
    argBase := 1;
    if (SL.Count < argBase + 2) or (LowerCase(SL[0]) <> 'selfplay') then
    begin
      WriteLn('usage: gendata selfplay <count> <file> [nodes] [seed] [book.epd | pgnbook]');
      WriteLn('  (the v1.10 distillation mode, gendata <count> <file>, was removed');
      WriteLn('   with the hand-crafted eval in v2.0)');
      Exit;
    end;
    Target   := StrToIntDef(SL[argBase], 0);
    FileName := SL[argBase + 1];
    if SL.Count > argBase + 2 then Nodes := StrToIntDef(SL[argBase + 2], SP_NODES_DEFAULT);
    if SL.Count > argBase + 3 then Seed  := StrToIntDef(SL[argBase + 3], 0);
    if SL.Count > argBase + 4 then BookName := SL[argBase + 4];
    if Target <= 0 then begin WriteLn('gendata: bad count'); Exit; end;
    if Nodes  <= 0 then begin WriteLn('gendata: bad node count'); Exit; end;
  finally
    SL.Free;
  end;

  { v2.0: the labels come from the net; there is no HCE to fall back on. }
  if not NNUE_Available then
  begin
    WriteLn('gendata: no net loaded (', EvalFileName, ') -- load one first:');
    WriteLn('  setoption name EvalFile value <absolute path of the .nnue>');
    Exit;
  end;

  { Book: load it BEFORE the output file is created, so a bad path fails
    without truncating anything. No book = clear any book a previous gendata
    command in this process loaded. }
  GenBookN := 0;
  GenUseEngineBook := False;
  if LowerCase(BookName) = 'pgnbook' then
  begin
    { The engine's own PGN book. The engine loads it lazily (at isready or
      go), and a setoption BookFile only marks it for reloading, so load it
      here if that has not happened yet. }
    if not BookInitialized then
    begin
      LoadAllOpeningBooks;
      BookInitialized := True;
    end;
    if not BookLoaded then
    begin
      WriteLn('gendata: pgnbook requested but no PGN book is loaded -- put ',
              'the .pgn next to the executable and send ',
              'setoption name BookFile value <name>.pgn first');
      Exit;
    end;
    GenUseEngineBook := True;
    GenBookN := BookCount;
    if GenBook <> nil then GenBook.Clear;
  end
  else if BookName <> '' then
  begin
    GenBookN := GenLoadBook(BookName);
    if GenBookN < 0 then
    begin
      WriteLn('gendata: book file not found: ', BookName);
      Exit;
    end;
    if GenBookN = 0 then
    begin
      WriteLn('gendata: no FEN/EPD positions found in ', BookName,
              ' -- the book must be EPD or FEN, one position per line');
      Exit;
    end;
  end
  else if GenBook <> nil then
    GenBook.Clear;

  Saved          := State;
  SavedNodeLimit := NodeLimit;

  { Explicit seed beats Randomize for parallel runs -- see the header. }
  if Seed <> 0 then RandSeed := Cardinal(Seed) else Randomize;

  AssignFile(GenFile, FileName);
  Rewrite(GenFile, 1);
  GenBufCount := 0;
  Remaining   := Target;
  LastPct     := -1;
  T0          := GetTickCount64;

  SPGames := 0; SPKept := 0; SPDiscarded := 0; SPAdjudicated := 0;
  SPAdjDraw := 0; SPIters := 0;
  SPResW := 0; SPResD := 0; SPResB := 0;
  SPSkipCheck := 0; SPSkipCapture := 0; SPSkipMate := 0;
  SPPlySum := 0; SPNodeSum := 0; SPMoves := 0;
  StallCount := 0; Stalled := Remaining;

  SPRootPrev := Default(TMove); SPRootPrev.FromR := -1;
  SPRootExcl := Default(TMove); SPRootExcl.FromR := -1;

  begin
    WriteLn('info string gendata selfplay: ', Target, ' positions, ', Nodes,
            ' nodes/iteration, seed ', Seed, ' -> ', FileName);
    { Report which net does the labelling: read it, do not assume it. }
    WriteLn('info string gendata: labelling with the NNUE eval (',
            ActiveNetDesc, ')');
    if GenUseEngineBook then
      WriteLn('info string gendata: openings from the engine''s PGN book ',
              bookfilename, ' (', GenBookN, ' book entries) + ',
              SP_BOOK_EXTRA_MIN, '..', SP_BOOK_EXTRA_MAX, ' random plies')
    else if GenBookN > 0 then
      WriteLn('info string gendata: openings from book ', BookName, ' (',
              GenBookN, ' positions) + ', SP_BOOK_EXTRA_MIN, '..',
              SP_BOOK_EXTRA_MAX, ' random plies')
    else
      WriteLn('info string gendata: openings: ', SP_OPEN_MIN, '..', SP_OPEN_MAX,
              ' random plies (no book)');
    Flush(Output);
  end;

  try
    while Remaining > 0 do
    begin
      Stalled := Remaining;
      GenSelfPlay(Nodes, Remaining);


      { A run in which every game is discarded -- games all reaching the ply
        limit, say -- never decrements Remaining and would spin here for 48
        hours while printing nothing, because the percentage never changes.
        Fail loudly instead. }
      if Remaining = Stalled then Inc(StallCount) else StallCount := 0;
      if StallCount >= 500 then
      begin
        WriteLn('gendata: 500 consecutive attempts produced no positions -- ',
                'aborting. Every game is being discarded; check SP_MAX_PLIES ',
                'and the position filters.');
        Break;
      end;

      Done := Target - Remaining;
      Pct := (Done * 100) div Target;
      if Pct <> LastPct then
      begin
        LastPct := Pct;
        WriteLn('info string gendata ', Pct, '% (', Done, '/', Target,
                ', ', SPGames, ' games, ', (GetTickCount64 - T0) div 1000, ' s)');
        Flush(Output);
      end;
    end;
    GenFlush;
  finally
    CloseFile(GenFile);
    State     := Saved;
    NodeLimit := SavedNodeLimit;
    AbortSearch := False;
  end;

  GenSPReport(Target - Remaining, T0);  { actual, not requested: the stall
                                          guard can end the run early }
end;
