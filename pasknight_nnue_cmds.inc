{ =============================================================================
  pasknight_nnue_cmds.inc  --  validation commands.

  Include from pasknight.lpr after NNUE_Evaluate / GenerateLegalMoves are
  declared and before the UCI dispatch loop:

      {$I pasknight_nnue_cmds.inc}

  Commands:
    nnue check [plies]     criterion 1: incremental vs full-recompute
                           accumulator over a long random game.
    nnue testvec <file>    checks the Pascal integer path against the vectors
                           emitted by export_nnue.py. Catches a mis-ported
                           forward pass in seconds, without a single game.
    nnue stats             peak accumulator magnitude and overflow count.
    nnue embed <file.nnue> <out.inc> [name]
                           v2.0.0alpha3: checks a net with NNUE_CheckBuffer
                           and writes it as pasknight_net.inc, the net built
                           into the executable. Rebuild both modes after.

  v2.0: the hand-crafted eval was removed, and with it 'nnue match' (NNUE vs
  Evaluate agreement) and 'nnue tempo' (the fixed tempo bonus of format-1
  nets, which are no longer supported).
  ========================================================================== }

procedure NNUE_ReportNet(const Cmd: string);
{ v2.0: every validation command first says WHICH net it is testing. The
  engine always starts with the embedded net (v2.0.0alpha3; before that
  pasknight.nnue); a test run without an explicit 'setoption name EvalFile'
  silently tests that net instead of the new one, and a whole testvec run
  then reports 64/64 MISMATCH for a perfectly good net. Printing the name up
  front makes that visible before the results. }
begin
  WriteLn('nnue ', Cmd, ': net ', ActiveNetDesc, '  (format 2, side-to-move input)');
  WriteLn('  to test another net first: setoption name EvalFile value <absolute path>');
end;

procedure NNUE_VerifyFromBoard(const Where: string; var Fails: integer);
var
  r, c, bad, got, want: integer;
  P: TPiece;
begin
  NNUE_SetPtr(State.AccPtr);
  NNUE_VerifyBegin;
  for r := 0 to 7 do
    for c := 0 to 7 do
    begin
      P := State.Board[r, c];
      if P <> EMPTY then NNUE_VerifyAdd(Ord(P) - 1, SquareIndex(r, c));
    end;
  if not NNUE_VerifyMatches(bad, got, want) then
  begin
    Inc(Fails);
    WriteLn('NNUE ACC DRIFT at ', Where, ': neuron ', bad,
            ' incremental=', got, ' recomputed=', want);
    if Fails > 5 then WriteLn('  (further drift reports suppressed)');
  end;
end;

procedure NNUE_CheckGame(Plies: integer);
{ Criterion 1. Plays random legal moves, verifying the accumulator after every
  single one. Counts the special cases actually exercised, because "no drift"
  is worthless if the run never castled or promoted. }
var
  Moves: TMoveList;
  Cnt, i, j, ply, Fails: integer;
  nCastle, nPromo, nEP, nCap: integer;
  Saved: TGameState;
  M: TMove;
begin
  if not NNUE_Available then begin WriteLn('nnue check: no net loaded'); Exit; end;
  NNUE_ReportNet('check');
  Saved := State;
  Fails := 0; nCastle := 0; nPromo := 0; nEP := 0; nCap := 0;
  Randomize;
  InitState;
  NNUE_FullRefresh;
  NNUE_VerifyFromBoard('initial position', Fails);

  for ply := 1 to Plies do
  begin
    GenerateLegalMoves(Moves, Cnt);
    if Cnt = 0 then
    begin
      InitState; NNUE_FullRefresh;
      NNUE_VerifyFromBoard('after restart', Fails);
      Continue;
    end;
    { Prefer promotions and castles when available so the special cases are
      actually hit rather than hoped for. }
    i := Random(Cnt);
    { Bias hard toward the special cases. A clean run that never castled or
      promoted proves nothing about the branches most likely to be wrong. }
    if Random(100) < 40 then
      for j := 0 to Cnt - 1 do
        if (Moves[j].Promotion <> EMPTY) or
           (Moves[j].MoveType in [MT_CASTLE_WK, MT_CASTLE_WQ,
                                  MT_CASTLE_BK, MT_CASTLE_BQ]) or
           (Moves[j].MoveType = MT_EN_PASSANT) then
        begin i := j; Break; end;
    M := Moves[i];

    if M.Promotion <> EMPTY then Inc(nPromo);
    if M.MoveType = MT_EN_PASSANT then Inc(nEP);
    if M.MoveType in [MT_CASTLE_WK, MT_CASTLE_WQ, MT_CASTLE_BK, MT_CASTLE_BQ] then Inc(nCastle);
    if State.Board[M.ToR, M.ToC] <> EMPTY then Inc(nCap);

    DoMakeMove(M);
    NNUE_VerifyFromBoard('ply ' + IntToStr(ply), Fails);

    if (State.HalfMoveClock >= 100) or (PopCnt(State.AllOccupied) <= 3) then
    begin
      InitState; NNUE_FullRefresh;
      NNUE_VerifyFromBoard('after restart', Fails);
    end;
  end;

  State := Saved;
  NNUE_FullRefresh;

  WriteLn('nnue check: ', Plies, ' plies');
  WriteLn('  captures ', nCap, '  castles ', nCastle,
          '  promotions ', nPromo, '  en passant ', nEP);
  if (nCastle = 0) or (nPromo = 0) or (nEP = 0) then
    WriteLn('  WARNING: a special case was never exercised -- rerun with more plies');
  if Fails = 0 then WriteLn('  accumulator: EXACT MATCH at every ply  [criterion 1 PASS]')
               else WriteLn('  accumulator: ', Fails, ' MISMATCHES  [criterion 1 FAIL]');
  {$IFDEF NNUE_DEBUG_ACC}
  WriteLn('  peak |accumulator| ', NNUE_PeakAcc, ' / 32767',
          '   int16 overflows ', NNUE_Overflows);
  {$ELSE}
  // Tracking the peak costs 256 comparisons per evaluation, so it is compiled
  // out of normal builds. Printing a bare 0 here would read as a measurement
  // rather than the absence of one.
  WriteLn('  peak |accumulator| not tracked in this build',
          ' (rebuild with -dNNUE_DEBUG_ACC to measure it)');
  {$ENDIF}
  if NNUE_StackOverflows > 0 then
    WriteLn('  WARNING: ', NNUE_StackOverflows, ' accumulator stack overflows');
end;

procedure NNUE_TestVec(const FileName: string);
{ Checks the Pascal forward pass against vectors produced by export_nnue.py,
  which are generated from nnue_quant_reference.py. A mismatch localises the
  bug to a layer immediately: acc -> loader or feature indexing, s -> layer 2,
  o -> layer 3, cp -> the final Int64 scaling. }
var
  F: TextFile;
  Line: string;
  SL: TStringList;
  n, i, j, cp, expCp: integer;
  expAccSum, expSSum, expO: int64;
  accSum, sSum: int64;
  Acc0, A0: TNNUEAcc;
  S, A1: TNNUEL2;
  O: Int32;
  nCase, nBad, nAccBad: integer;
  vecStm, o0: integer;
begin
  // Both of these used to fail with a bare one-line message, which left it
  // ambiguous whether the net, the filename or the path was the problem.
  if not NNUE_Available then
  begin
    WriteLn('nnue testvec: no net loaded (', EvalFileName, '). Load one first:');
    WriteLn('  setoption name EvalFile value <absolute path of the .nnue>');
    WriteLn('  setoption name EvalFile value ', EVALFILE_EMBEDDED, '   (the embedded net)');
    Exit;
  end;
  if Trim(FileName) = '' then
  begin
    WriteLn('nnue testvec: no file given.');
    WriteLn('  usage: nnue testvec <file>      e.g. nnue testvec testvec.txt');
    WriteLn('  the file is written by export_nnue.py alongside the .nnue');
    Exit;
  end;
  if not FileExists(FileName) then
  begin
    // Print what was actually looked for and where. The engine's working
    // directory is not necessarily the directory the executable sits in --
    // an IDE typically runs it from the project directory instead.
    WriteLn('nnue testvec: cannot find "', FileName, '"');
    WriteLn('  looked relative to the working directory: ', GetCurrentDir);
    WriteLn('  either copy the file there or give an absolute path');
    Exit;
  end;
  NNUE_ReportNet('testvec');
  WriteLn('  test vectors: ', FileName);
  AssignFile(F, FileName); Reset(F);
  SL := TStringList.Create;
  nCase := 0; nBad := 0; nAccBad := 0;
  try
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      Line := Trim(Line);
      if (Line = '') or (Line[1] = '#') then Continue;
      SL.Delimiter := ' '; SL.StrictDelimiter := False;
      SL.DelimitedText := Line;
      { format 2:  stm(w|b) n f1..fn accSum sSum o cp
        v2.0: format-1 vectors (no leading w|b) belong to format-1 nets, which
        are no longer supported; say so once instead of failing on every line. }
      if (SL[0] <> 'w') and (SL[0] <> 'b') then
      begin
        WriteLn('nnue testvec: these are FORMAT-1 vectors (no side to move). Format-1');
        WriteLn('  nets are no longer supported (v2.0); use the vectors of a format-2 net.');
        Exit;
      end;
      if SL[0] = 'b' then vecStm := 1 else vecStm := 0;
      o0 := 1;
      n := StrToInt(SL[o0]);
      NNUE_RefreshBegin;
      for i := 1 to n do
        NNUE_Add(StrToInt(SL[o0 + i]) div 64, StrToInt(SL[o0 + i]) mod 64);
      expAccSum := StrToInt64(SL[o0 + n + 1]);
      expSSum   := StrToInt64(SL[o0 + n + 2]);
      expO      := StrToInt64(SL[o0 + n + 3]);
      expCp     := StrToInt(SL[o0 + n + 4]);

      NNUE_Trace(vecStm, Acc0, A0, S, A1, O, cp);
      accSum := 0; for j := 0 to NNUE_N_L1 - 1 do Inc(accSum, Acc0[j]);
      sSum := 0;   for j := 0 to NNUE_N_L2 - 1 do Inc(sSum, S[j]);

      Inc(nCase);
      if accSum <> expAccSum then Inc(nAccBad);
      if (accSum <> expAccSum) or (sSum <> expSSum) or
         (O <> expO) or (cp <> expCp) then
      begin
        Inc(nBad);
        if nBad <= 5 then
        begin
          WriteLn('testvec case ', nCase, ' MISMATCH:');
          if accSum <> expAccSum then
            WriteLn('    accumulator sum  got ', accSum, ' want ', expAccSum,
                    '   -> loader layout or feature indexing');
          if sSum <> expSSum then
            WriteLn('    layer-2 sum      got ', sSum, ' want ', expSSum,
                    '   -> L2 weights or CReLU');
          if O <> expO then
            WriteLn('    layer-3 output   got ', O, ' want ', expO,
                    '   -> L3 weights or the rounding in a1');
          if cp <> expCp then
            WriteLn('    centipawns       got ', cp, ' want ', expCp,
                    '   -> final Int64 scaling / div truncation');
        end;
      end;
    end;
  finally
    CloseFile(F); SL.Free;
  end;
  if nBad = 0 then WriteLn('nnue testvec: all ', nCase, ' cases match exactly')
              else WriteLn('nnue testvec: ', nBad, ' of ', nCase, ' cases MISMATCH');
  // Every case wrong already at the first stage is the signature of a test
  // file that belongs to a DIFFERENT net, not of a porting bug -- a porting
  // bug almost never breaks the accumulator of every single position.
  if (nCase > 0) and (nAccBad = nCase) then
  begin
    WriteLn('  every case differs already at the accumulator: these test vectors');
    WriteLn('  almost certainly belong to another net than ', ActiveNetDesc, '.');
    WriteLn('  Load the matching net and run again:');
    WriteLn('    setoption name EvalFile value <absolute path of the .nnue>');
  end;
  NNUE_FullRefresh;
end;

procedure NNUE_SplitArgs(const S: string; Args: TStringList);
{ Splits on spaces; a "double-quoted" part may contain spaces. }
var
  i: integer;
  cur: string;
  inQ: boolean;
begin
  Args.Clear;
  cur := '';
  inQ := False;
  for i := 1 to Length(S) do
    if S[i] = '"' then
      inQ := not inQ
    else if (S[i] = ' ') and (not inQ) then
    begin
      if cur <> '' then Args.Add(cur);
      cur := '';
    end
    else
      cur := cur + S[i];
  if cur <> '' then Args.Add(cur);
end;

procedure NNUE_EmbedCommand(const Rest: string);
{ v2.0.0alpha3: nnue embed <file.nnue> <out.inc> [name]. All checking and
  writing is in unit_nnue (NNUE_Embed); this only splits the arguments. }
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    NNUE_SplitArgs(Rest, SL);
    if (SL.Count < 2) or (SL.Count > 3) then
    begin
      WriteLn('usage: nnue embed <file.nnue> <out.inc> [name]');
      WriteLn('  checks the net exactly as the loader does, then writes <out.inc>.');
      WriteLn('  To embed it: write the project''s pasknight_net.inc and rebuild');
      WriteLn('  both build modes. Quote paths that contain spaces.');
      WriteLn('  built into this executable now: ', NNUE_EmbeddedDesc);
      Exit;
    end;
    if SL.Count = 3 then
      NNUE_Embed(SL[0], SL[1], SL[2])
    else
      NNUE_Embed(SL[0], SL[1], '');
  finally
    SL.Free;
  end;
end;

procedure NNUE_Command(const Args: string);
var
  Verb, Rest: string;
  p: integer;
begin
  p := Pos(' ', Args);
  if p = 0 then begin Verb := LowerCase(Args); Rest := ''; end
  else begin Verb := LowerCase(Copy(Args, 1, p - 1)); Rest := Trim(Copy(Args, p + 1, MaxInt)); end;

  if Verb = 'check' then NNUE_CheckGame(StrToIntDef(Rest, 20000))
  else if Verb = 'testvec' then NNUE_TestVec(Rest)
  else if Verb = 'stats' then
  begin
    if NNUE_Available then
      WriteLn('nnue: available=TRUE net=', ActiveNetDesc)
    else
      WriteLn('nnue: available=FALSE requested=', EvalFileName);
    WriteLn('  built into this executable: ', NNUE_EmbeddedDesc,
            ', checksum $', HexStr(Int64(NNUE_EmbeddedChecksum), 8));
    WriteLn('  accumulator slot ', State.AccPtr, ' / ', NNUE_MAX_ACC,
            ', peak |acc| ', NNUE_PeakAcc, ' / 32767',
            ' (peak is tracked only in -dNNUE_DEBUG_ACC builds)');
    WriteLn('  int16 overflows ', NNUE_Overflows,
            ', stack overflows ', NNUE_StackOverflows);
    // Cost attribution. Run `nnue stats` (which zeroes these), then bench,
    // then `nnue stats` again, and divide by the node count bench reported.
    //   ~1 push per node    -> the legality-probe suspend is working
    //   ~40 pushes per node -> it is not, and that is the whole slowdown
    WriteLn('  since last stats: ', NNUE_PushCount, ' accumulator pushes, ',
            NNUE_UpdCount, ' feature updates, ',
            NNUE_EvalCount, ' evaluations');
    if NNUE_EvalCount > 0 then
      WriteLn('  pushes per evaluation: ',
              NNUE_PushCount / NNUE_EvalCount : 0 : 2,
              '  (>>1 means most accumulator work is for positions that are',
              ' never evaluated -> defer it)');
    if NNUE_PushCount > 0 then
      WriteLn('  feature updates per push: ',
              NNUE_UpdCount / NNUE_PushCount : 0 : 2,
              '  (expect ~2.2: a remove plus a place, more for captures,',
              ' castling and promotions)');
    NNUE_ResetCounters;
  end
  else if Verb = 'embed' then NNUE_EmbedCommand(Rest)
  else
    WriteLn('usage: nnue check [plies] | testvec <file> | stats | embed <file.nnue> <out.inc> [name]');
end;
