program pasknight;//Chess engine which communicates in uci with a graphic user interface like Arena or CuteChess

{Copyright (C) 2026 by Han Kleijn, www.hnsky.org
 email: han.k.. at...hnsky.org

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.   }

{$APPTYPE CONSOLE}
{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  //{$DEFINE TUNER} //activate texel tuning

  SysUtils,
  Classes,
  DateUtils,
  Math;

const
  Version: string = 'v1.0.1';


{Some notes about terminology:

In chess, "pruning" is a computing term used in engine programming to describe ignoring bad or irrelevant variations so the program can calculate deeper.
Pruning "ALL moves" means that after analyzing a specific position, the engine determines no candidate move is worth playing and immediately discards the
entire branch.This concept happens primarily within computer analysis—such as when an engine runs its search algorithm. How it works:

1. Alpha-Beta Pruning
The foundation of engine calculation. If the engine determines a current move sequence results in a position that is objectively worse
than another line already found, it cuts off the remaining variations for that move entirely.2. Futility PruningA more aggressive heuristic used to save time.
If the current position's baseline evaluation is significantly below what the engine expects to achieve elsewhere, it will "prune all moves" that don't
immediately show a high probability of rescuing the position, completely stopping searches on that branch.3. Null Move PruningA technique where the engine
simulates "passing" a turn. If passing the turn still leaves the player with an overwhelming advantage, the engine aggressively prunes almost all other
move options in the tree

2. Futility Pruning
A more aggressive heuristic used to save time. If the current position's baseline evaluation is significantly below what the engine expects
to achieve elsewhere, it will "prune all moves" that don't immediately show a high probability of rescuing the position, completely stopping searches
on that branch.

3. Null Move Pruning
A technique where the engine simulates "passing" a turn. If passing the turn still leaves the player with an overwhelming advantage, the engine aggressively
prunes almost all other move options in the tree. }

{Implementation status
  v1.00 line = lazy-SEE (pr1) + stability-based time management (rc3f)
  + SEE capture pruning (rc4) + packed TT entry (rc5) + magic bitboards
  (rc7) + pawn hash (rc8) + StaticEval-everywhere/Improving (rc9) + the
  rc10-rc21 evaluation programme (per-rank passed pawns, mobility tables,
  king safety, threats, and the rc15-rc21 batched eval features with a
  full joint Texel retune) on the v09998d1 search baseline.
  RELEASE INTENT: no further features planned; rc21 is to be released as
  v1.00 after additional testing. NNUE / Lazy SMP / Syzygy remain out of
  scope for v1.00.

  Search/eval baseline chain (SPRT-validated, most recent last):
    v09992  Singular extensions over v0998 (+10.1 +/- 6.9, LOS 99.8%).
    v09996  Internal Iterative Reductions (IIR); first search-shape lever
            after the history class closed (+11.1 +/- 10.7, LOS 97.8%).
    v09997  Verified razoring, Depth 1-2, non-PV (+13.1 +/- 11.0, LOS 99.0%).
    v09998d1 Futility restricted to Depth 1 (dropped the now-negative Depth-2
            case; +10.5 +/- 11.1, LOS 96.8%). With v09997 this triangulated
            the razoring/futility interaction (lesson 8).
    v1.00-pr1 Lazy-SEE precompute: pure NPS gain, move order bit-identical to
            v09998d1. SEE() deferred from the up-front scoring pass to the
            point of selection; called at most once per capture, only for
            captures reaching the front of the list. Bench node counts
            unchanged; measured +4.3% NPS. Small confirmed positive; adopted.
    v1.00-rc3f Stability-based time management (+34.2 +/- 18.3, LOS 100.0%).
    v1.00-rc4 SEE capture pruning in main search: Depth <= 6, non-PV, skip
            captures with SEE < -100 cp per remaining ply; TT move exempt,
            checkmate/stalemate detection preserved (>= 1 legal move first).
            Reuses the SEE value the lazy-SEE machinery already resolves at
            point-of-selection (retained in SeeValue[]), so ZERO additional
            SEE() calls; pruned captures also skip make/unmake and the
            legality test. SPRT passed, ~+35 Elo.
    v1.00-rc5 Packed TT entry, 48 -> 16 bytes (move in 19 bits, Score
            SmallInt, Depth ShortInt, Flag 1-byte enum). ~3x entry density
            (128 MB: ~2.8M -> 8.4M entries), 4 entries per 64-byte cache
            line, never straddles. Search decisions bit-identical at equal
            entry count (verified: rc5 Hash=32 reproduces rc4 Hash=128
            bench node-for-node). SPRT vs rc4: no Elo reduction at test TC;
            adopted -- the density/cache benefit is structural and grows
            with time control.
    v1.00-rc6 Depth-scaled null-move reduction: R := 2 + (Depth div 4).
            Reproduces rc5 exactly at Depth 3..7, reduces more from Depth 8
            up. ~+8 Elo; the Stockfish eval-margin NMP term was unblocked by
            rc9 (StaticEval-everywhere) and is now available as a future
            search candidate rather than a hard block.
    v1.00-rc7 Plain magic bitboards (portable, no PEXT) as the single slider
            baseline. Fixed-size tables (rook 2 MB + bishop 256 KB),
            constructively re-verified at startup (Carry-Rippler fill halts
            on any colliding index with a differing attack set). Replaces the
            classical ray-walk on all four hot paths (movegen, IsAttacked,
            SliderAttacks, SEE FindLVA); move emission order and SEE
            tie-breaking preserved, so search is bit-identical to rc5 -- pure
            NPS. ~+19 Elo.
    v1.00-rc8 Pawn hash table. PASS 3 (doubled/isolated/passed/backward, and
            now the rc10/rc15 pawn terms) depends only on the two pawn
            bitboards; an incremental pawn-only Zobrist key (State.PawnHash,
            reusing the existing ZobristPiece pawn constants) caches the
            summed pass-3 accumulator deltas. Exact: a hit reproduces the
            miss path bit-for-bit, so search is identical to rc7 (pure NPS).
            ~+11 Elo. The pawn key is also the index correction-history
            Phase 2 would need (lesson 6 enabler).
    v1.00-rc9 StaticEval at all non-check nodes + Improving flag. (a) static
            eval computed at every non-check node (not only Depth<=3);
            (b) Search gains a ParentStaticEval parameter, deriving
            Improving := StaticEval > ParentStaticEval (both-valid guard);
            (c) first consumer: improving-conditioned RFP margin (120*Depth
            improving / 100*Depth not). Infrastructure enabler for the
            eval-margin NMP term, improving-conditioned LMR/futility, and
            correction-history Phase 2.
    v1.00-rc10 Passed-pawn bonus by rank. Flat bonus replaced by
            PassedPawnMG/EG[relRank] (8 entries each, shared across colours
            via the mirrored relative-rank index; entries 0/7 unreachable).
            PASS 3, most-advanced pawn per file, single-AND passed test,
            pawn-hash safe. First tuner-registered eval table.
    v1.00-rc11 Mobility tables per piece type, indexed by move count.
            KnightMob[0..8], BishopMob[0..13], RookMob[0..14],
            QueenMob[0..27], each MG/EG, seeded linearly from the v0981
            weights (bit-identical refactor). Gradient-projected and
            re-centered per sub-table (same material/PST gauge as the PSTs);
            zero-coverage cells frozen at seed (TuneFreezeUnseen...).
    v1.00-rc12 King safety as an attack-units table. Per side, enemy pieces
            attacking the king zone are summed into weighted attack units;
            SafetyTable[units] (convex, MG-weighted) is looked up. The table
            is NONLINEAR in the position, so it stays OUTSIDE the tunable
            block and lands in the tuner's fixed residual.
    v1.00-rc13 Threat terms. Six MG/EG scalar pairs (pawn attacks minor/rook/
            queen; minor attacks rook/queen; hanging piece) from the existing
            attack bitboards. Registered in the tuner (TUNE_THREAT_BASE).
    v1.00-rc15..rc21 Batched evaluation improvements + full joint retune.
            DELIBERATE departure from one-change-per-SPRT: individual eval
            terms here are worth only a few Elo and drown in SPRT noise, so a
            batch was implemented together, EVERY linear eval term (new and
            pre-existing) registered in the Texel tuner, the whole vector
            retuned jointly ONCE, and the aggregate validated vs rc13.
            Per-feature gate: compile (both TUNER modes) + colour-flip
            symmetry + exact-residual pass (0 mismatches on both dataset
            formats). Batch contents (full per-step rationale in the source
            header):
              Step 1 (rc15) Connected/phalanx pawns by rank, ConnectedMG/EG
                [0..7], PASS 3, coefficient = net sum of the SF multiplier
                (2 + phalanx - opposed).
              Step 2 (rc16) Per-rank knight outpost OutpostMG/EG[relRank]
                (replacing the rc14 flat scalars; only ranks 3-5 live) plus a
                half-weight bishop-outpost scalar pair.
              Step 3 (rc17) Bad bishop, blocked-central form: penalty per own
                pawn on the bishop's colour complex that is BLOCKED and on a
                central file (c-f); BadBishopPawnMG/EG registered.
              Step 4 (rc18) Rook terms: on relative rank 7, behind own passer,
                behind enemy passer (3 MG/EG pairs). Passed set exposed to
                PASS 4 by rebuilding wPassed/bPassed locally -- NOT via the
                pawn-hash entry. LESSON: SquareCoords returns the mailbox row,
                not the LERF rank; rank tests use (sq shr 3).
              Step 5 (rc19) King/passed-pawn distance, EG-only: Chebyshev
                distance of each king to the passer's front square, two
                scalars (enemy/own), distance-weighted coefficient, computed
                outside the pawn hash.
              Step 6 (rc20) Pawn shield as a rank-indexed table ShieldMG[0..3]
                by shield-pawn advancement (new "two ranks up" bucket),
                MG-only, king-dependent (outside the pawn hash).
              Step 7 (rc21) Safe mobility: the mobility destination mask now
                also excludes enemy-pawn-attacked squares. Changes the
                mobility table INDEX; old tuned mobility values became stale
                seeds re-fit by the joint retune. More high-index cells
                become zero-coverage and are frozen -- expected.
              Registration sweep (rc21) doubled/isolated/backward pawn
                penalties promoted from hard-coded PASS 3 literals to
                registered typed constants (eval-invariant refactor, 0 diffs);
                they were previously in the tuner's fixed residual.
            After the batch the ENTIRE linear eval is Texel-tunable
            (TUNE_NPARAMS = 992): PSTs, piece values, mobility, passed pawns,
            threats, connected, outposts, bad bishop, rook terms,
            king-passer distance, pawn shield, doubled/isolated/backward.
            SafetyTable remains the only nonlinear term (fixed residual).
            Joint retune complete; aggregate result vs rc13 positive,
            measured strength ~2510-2540.

  Abandoned on the path here (results retained in the Abandoned section):
    v0999/v0999b (history-malus asymmetry), v09991 (history decay),
    v09993 (history gravity), v09994 (correction history Phase 1),
    v09995 (multi-ply continuation history), v09998d3 (futility to Depth 3),
    v09999 (ProbCut, drifted to +2.1 and dropped before adoption),
    v1.00-pr2 (capture history, -4.1 +/- 10.1 over 2301, LOS 21.5%; fifth
    consecutive history-class non-positive result, lesson 7).

Time management (rc3 series - the main post-pr1 search-side work)
  The linear per-move allocation was replaced with a stability-based scheme,
  developed and simplified across rc3..rc3f. Final design (rc3f):
    Allocation: base = (MyTime div Movestogo) + (MyInc * 3 div 4), then
    LIMIT 1 (safety clamp, phase-independent, NOT a tuning knob): clamp the
    allocation between a control-relative minimum (~10% of the per-move slice,
    5 ms absolute floor) and a maximum (remaining clock minus a reserve of
    max(100 ms, 10% of clock); <=500 ms clock falls back to half).
    Stop rule (between iterations, TWO tuning knobs): count how many completed
    depths in a row returned the SAME best move (StableIters). Effective budget
    = the full allocation, or - once stable for STABLE_ITERS_FOR_EASE depths -
    the allocation shrunk to STABLE_EASE_PCT percent. Stop when elapsed reaches
    the effective budget. No predictor, no soft/hard split, no phase, no panic.
    LIMIT 2 (ExceedCeilingAbortMs, mid-search abort, derived NOT tuned): the
    emergency brake polled inside Search()/Quiescence(), set to allocation *
    EXCEED_CEILING_FACTOR_PCT/100 (150%). Fires only if a single deepening
    iteration runs far past the allocation; the normal stop is the stability
    check. Partial-depth recovery keeps the last completed depth on abort.
    Current tuning: STABLE_ITERS_FOR_EASE = 3, STABLE_EASE_PCT = 70,
    EXCEED_CEILING_FACTOR_PCT = 150.
  Open time-management items (post-v1.00 candidates):
    - Safety: clamp ExceedCeilingAbortMs to the remaining clock minus the
      reserve, so the 150% ceiling can never exceed the actual clock on the
      move before a time control (matters for repeating movestogo controls).
    - Optional: an explicit per-move MoveOverhead (20-50 ms) for GUI/comm
      latency at fast controls.
    - Continue fine-tuning STABLE_ITERS_FOR_EASE and STABLE_EASE_PCT.

Search
  Feature                                       Status
  Negamax alpha-beta                            Implemented
  Iterative deepening                           Implemented
  Quiescence search                             Implemented (delta + SEE pruning,
                                                  check evasions, mate detection)
  Transposition table (Zobrist hashing)         Implemented; runtime-resizable
                                                  via UCI Hash option (v0997);
                                                  packed 16-byte entry (v1.00-rc5).
  Null move pruning (with verification)         Implemented; depth-scaled R
                                                  (v1.00-rc6, R = 2 + Depth div 4).
                                                  Eval-margin NMP term now
                                                  unblocked by rc9 -- open search
                                                  candidate.
  NMP zugzwang guard (HasNonPawnMaterial)       Implemented (v0957)
  Check extensions                              Implemented
  Principal variation search (PVS, root + node) Implemented
  Aspiration windows                            Implemented (v0996, +8.8 Elo)
  Futility pruning                              Implemented (Depth 1 only, v09998d1)
  Reverse futility pruning                      Implemented; improving-conditioned
                                                  margin (v1.00-rc9).
  Late move reductions (bucket-based)           Implemented
  History-based LMR adjustments                 Implemented (v0997 -> v0997a ->
                                                  v0997b two-sided, +52 vs v0996).
  Late move pruning (LMP)                       Implemented (v0988)
  Mate-distance pruning                         Regression observed (v0992)
  Internal Iterative Reductions (IIR)           Implemented (v09996, +11.1).
  Razoring                                      Implemented (v09997, +13.1).
                                                  Depth 1-2, non-PV, RazorMargin
                                                  = (300, 500).
  Singular extensions                           Implemented (v09992, +10.1).
  StaticEval at all non-check nodes             Implemented (v1.00-rc9); Improving
                                                  flag via ParentStaticEval.
  SEE (Static Exchange Evaluation)              Implemented: qsearch (v0964) +
                                                  main-search ordering (v0986);
                                                  ordering SEE deferred to
                                                  point-of-selection (v1.00-pr1).
  SEE capture pruning (main search)             Implemented (v1.00-rc4, ~+35 Elo).
                                                  Depth <= 6, non-PV, margin
                                                  100 cp/ply, TT move exempt,
                                                  lazy-SEE value reused (zero extra
                                                  SEE calls). Knobs
                                                  SEE_PRUNE_MAX_DEPTH (6) /
                                                  SEE_PRUNE_MARGIN (100) are
                                                  post-v1.00 aggressiveness knobs.
  IsInCheck per-node cache                       Implemented (v0987)
  EP MVV-LVA scoring fix                          Implemented (v0987)
  Closed candidates (search):
    Counter-move heuristic     Two override-style attempts regressed
                               (v0989 -38.8, v0998 -5.0). Same failure class.
    Continuation history       Four attempts, all non-positive (v0998a/b/c,
                               v09995). Ordering-signal saturation (lessons 3,7).
    ProbCut                    Inconclusive at +2.1 (v09999); dropped.
    Qsearch checks (qchecks)   Regressed -32 at pre-PeSTO (v0991); untested since.
    LMR log-log formula tune   Neutral at pre-PeSTO (v0958); untested since.

Move ordering
  Feature                                       Status
  TT move first (locked at index 0)             Implemented (v0956a)
  MVV-LVA (captures)                            Implemented
  Killer move heuristic                         Implemented; slot restored v0997c.
  History heuristic (with ordering cap)         Implemented; signed since v0997b.
  History malus on beta cutoff                  Implemented (v0997b, symmetric).
  SEE bad-capture demotion                      Implemented (v0986); deferred to
                                                  point-of-selection (v1.00-pr1).
  Closed candidate (ordering):
    Capture history            v1.00-pr2 regressed -4.1 over 2301 (lesson 7).

Evaluation  (entire linear eval is Texel-tuned; jointly retuned at rc21)
  Feature                                       Status
  Material balance                              Implemented; tunable
  Tapered evaluation (phase interpolation)      Implemented (v0960)
  Tapered piece values (MG/EG)                  Implemented (v0995, +23 Elo); tunable
  Piece-square tables (PeSTO, full set)         Implemented (v0993-v0994); tunable
  Passed pawns (per-rank MG/EG tables)          Implemented (v1.00-rc10); tunable
  Connected/phalanx pawns by rank               Implemented (v1.00-rc15); tunable
  Doubled / isolated / backward pawns           Implemented (v0960-v0963); registered
                                                  and tunable (v1.00-rc21 sweep)
  Rook on open/semi-open file                   Implemented
  Rook on 7th / behind passed pawns             Implemented (v1.00-rc18); tunable
  Bishop pair bonus                             Implemented; tunable
  Bad bishop (blocked central complex pawns)    Implemented (v1.00-rc17); tunable
  Knight/bishop outposts (per-rank)             Implemented (v1.00-rc15/rc16); tunable
  King safety (attack-units table, MG-only)     Implemented (v1.00-rc12); NONLINEAR,
                                                  fixed residual (not tuned as a
                                                  linear block)
  King centralisation (EG-only)                 Implemented (v0960)
  King / passed-pawn distance (EG-only)         Implemented (v1.00-rc19); tunable
  Pawn shield (rank-indexed table, MG-only)     Implemented (v1.00-rc20); tunable
  Threat terms                                  Implemented (v1.00-rc13); tunable
  Mobility (per-piece tables, safe-mobility)    Implemented (v1.00-rc11 tables,
                                                  v1.00-rc21 safe-mobility index);
                                                  tunable
  Not implemented (eval), post-v1.00 only:
    King-attack tropism, trapped-piece detection, king-pawn
    square-of-the-pawn rule. King-safety zone (attacker-weighted) was
    tested at v0982 (~-8 Elo) and superseded by the rc12 attack-units
    table.

Infrastructure
  UCI protocol (incl. seldepth / hashfull / score-mate reporting, rc3b-c),
  UCI Hash option (runtime TT resize, v0997), packed 16-byte TT entry with
  PackMove/UnpackMove 19-bit move encoding (v1.00-rc5), magic bitboards
  (v1.00-rc7), incremental pawn-hash key (v1.00-rc8), FEN parsing (incl.
  full-move number, rc3), opening book, threefold-repetition detection,
  fifty-move rule, insufficient-material detection, PV extraction,
  stability-based time management (rc3f) with end-of-game phase-timing log,
  partial-depth recovery on abort, bench command (16 FENs), external SPRT
  pipeline (Cute Chess, 40/10s and 40/15+inc). Offline Texel tuner
  (pasknight_texel_tuner.pas): Adam optimizer, L2 anchoring to seeds,
  per-sub-table gradient projection + re-centering for the gauge-redundant
  blocks (PSTs, mobility), TuneFreezeUnseenRange for zero-coverage cells,
  exact-residual verification (0 mismatches required on both dataset
  formats), dual dataset support (Zurichess quiet-labeled.epd,
  lichess-big3-resolved), and a writer emitting the tuned block as
  drop-in Pascal. TUNE_NPARAMS = 992.
  Not implemented: Endgame tablebases (Syzygy), Lazy SMP, NNUE.

Principal lessons carried forward:
  (1) v0997b/v0997c make main history exceptionally strong. Both
      override-style ordering changes (v0989, v0998 counter-move) and
      supplementary-table additive changes (v0998a/b/c cont-history)
      have failed to add Elo. The engine is at the ordering saturation
      point for context-additive features at the current eval
      calibration. Remaining ordering gains likely come from REFINING
      main history rather than supplementing it.
  (2) Sparse auxiliary tables (cont-history's ~1.8M-entry indexing)
      cannot compete with dense main-history signal in malus-driven
      self-correction regimes.
  (3) Two failures of single-slot counter-move (v0989 -38.8, v0998
      -5.0) and four failures of cont-history (v0998a/b/c, v09995)
      close out the "supplementary (PrevMove, OurMove)-indexed
      ordering" design space for this engine.
  (4) Bonus/malus magnitude asymmetry has been tested in both
      directions (v0999 -15.4, v0999b -8.0) and retired. The
      symmetric v0997b calibration is load-bearing.
  (5) v09993 tested the CellGravity update rule on main History[]:
      -0.1 +/- 10.0 over 2342 (neutral). Gravity implicitly applies
      state-dependent asymmetric updates - the lever lesson (4)
      closed. Gravity remains the right primitive for SPARSE tables.
  (6) v09994 correction history Phase 1: -14.5 +/- 11.7 (regression).
      CorrHist needs DEEP-write / SHALLOW-read asymmetry; PasKnight's
      old eval gate restricted both to Depth<=3. Now that rc9 computes
      StaticEval at all non-check nodes, CorrHist Phase 2 is unblocked
      as a post-v1.00 candidate (the rc8 pawn key is its index).
  (7) Five consecutive non-positive history-class results (gravity,
      correction Phase 1, multi-ply cont-history, capture history, plus
      the earlier counter-move / cont-history variants). The
      history-class lever is closed; gains come from search-shape, NPS,
      eval quality, or infrastructure unlocking new pruning conditions.
      CONFIRMED (v1.00-rc4): SEE capture pruning, a new pruning
      condition, delivered ~+35 -- the largest single search gain since
      v0997b.
  (8) Adding a selectivity feature that shares fire conditions with an
      existing one requires a removal-SPRT of the existing feature
      afterwards (v09997 razoring inverted the sign of Depth-2 futility;
      exposed by v09998d3 -4.6, resolved by v09998d1 +10.5).
  (9) v1.00-rc5 (packed TT): "more instructions = slower" does not apply
      to memory-bound operations. Verify pure-infrastructure changes at
      EQUAL ENTRY COUNT, not equal MB.
  (10) EVAL BATCHING + JOINT TUNING (rc15-rc21). Once individual eval
      terms drop below SPRT resolution (a few Elo each), the
      one-change-per-SPRT discipline stops paying: the terms drown in
      noise and each demands a full match. The productive pattern
      instead: implement a batch behind three cheap deterministic gates
      (compile both TUNER modes, colour-flip symmetry, exact-residual =
      the tuner's linear model reproduces Evaluate bit-for-bit), keep
      hand-seeds as PLACEHOLDERS (never hand-tune between features),
      register every term, then retune the whole vector ONCE and run a
      SINGLE aggregate SPRT. The exact-residual gate is what makes this
      safe: it catches extraction/registration bugs deterministically,
      so a passing batch cannot silently mis-tune. Corollary: exact-
      residual proves the tuner MODEL matches the engine, not that a
      term is good chess; a correct-but-marginal term (e.g. rc19
      king-passer distance) can look flat in a short interim SPRT yet be
      neutral-or-better after the joint retune -- do not act on
      few-hundred-game interim results. Corollary: a taper is a single
      floor over the whole MG/EG accumulator, so per-term delta
      predictions do not separate cleanly -- verify at phase 0 or 24, or
      trust the exact-residual gate.

Completed (per-version SPRT-validated)
    v0993          PeSTO MG PSTs                                 +57 Elo
    v0994          PeSTO pawn + king EG PSTs                     +15 Elo
    v0995          tapered piece values (MG/EG, Evaluate only)   +23 Elo
    v0996          aspiration windows                           +8.8 Elo
    v0996          dynamic TT + UCI Hash option                  infra
    v0997          history-LMR, binary threshold (vs v0996)     +3.8 Elo
    v0997a         continuous history-LMR (vs v0996)            +9.7 Elo
    v0997b         two-sided history (malus + symmetric          +52 Elo
                   ordering clamp, vs v0996)
    v0997c         restore missing killer ordering slot         neutral (fix)
    v0998          PrevMove plumbing through Search             neutral
    v09992         Singular extensions on TT moves              +10.1 Elo +/- 6.9
    v09996         Internal Iterative Reductions (IIR)          +11.1 Elo +/- 10.7
    v09997         Verified razoring, Depth 1-2, non-PV         +13.1 Elo +/- 11.0
    v09998d1       Futility restricted to Depth 1               +10.5 Elo +/- 11.1
    v1.00-pr1      Lazy-SEE precompute (bit-identical order)    +4.3% NPS, small +ve
    v1.00-rc3f     Stability-based time management (vs pr1)     +34.2 Elo +/- 18.3
                                                                (683 games, LOS
                                                                100.0%, DrawRatio
                                                                50.7%)
    v1.00-rc4      SEE capture pruning in main search           ~+35 Elo (SPRT passed)
    v1.00-rc5      Packed TT entry (48 -> 16 B)                 no Elo reduction at
                                                                40/10; adopted
    v1.00-rc6      Depth-scaled null-move reduction             ~+8 Elo
    v1.00-rc7      Magic bitboards (pure NPS)                   ~+19 Elo
    v1.00-rc8      Pawn hash table (pure NPS)                   ~+11 Elo
    v1.00-rc9      StaticEval-everywhere + Improving (RFP use)  small; enabler
    v1.00-rc10     Passed-pawn bonus by rank                    eval batch (see rc13)
    v1.00-rc11     Mobility tables by move count                eval batch (see rc13)
    v1.00-rc12     King safety attack-units table               eval batch (see rc13)
    v1.00-rc13     Threat terms; joint retune of the            aggregate SPRT
                   rc10-rc13 eval set vs the pre-eval baseline  positive
    v1.00-rc15..21 Batched eval features (connected pawns,      aggregate SPRT vs
                   per-rank outposts, blocked-central bad       rc13 positive;
                   bishop, rook terms, king-passer distance,    measured ~2510-2540
                   pawn-shield table, safe mobility) + full     (see strength est.)
                   registration sweep + single joint Texel
                   retune of the entire 992-parameter vector

Abandoned
    v0998 (old)    single-slot counter-move at 7800              -5.0 Elo (1541)
    v0998a         cont-history, equal weight/magnitude          +0.9 Elo (3125, neutral)
    v0998b         v0998a, cont-history malus halved             +3.1 Elo (4857, noise)
    v0998c         v0998b, ordering contribution halved          -0.5 Elo (2626, neutral)
    v0999          asymmetric main-history malus, 2/3 ratio     -15.4 Elo +/- 13.5 (LOS 1.3%)
    v0999b         inverse-asymmetric malus, 4/3 ratio           -8.0 Elo +/- 12.6 (LOS 10.7%)
    v09991         history decay at root by 7/8                 -11.4 Elo +/- 15.8 (LOS 8.0%)
    v09993         history gravity on main History[]             -0.1 Elo +/- 10.0 (lesson 5)
    v09994         correction history Phase 1 (pawn-key)        -14.5 Elo +/- 11.7 (lesson 6)
    v09995         multi-ply continuation history (1+2+4)        -3.6 Elo +/- 11.9 (lesson 7)
    v09998d3       futility extended to Depth 3                  -4.6 Elo +/- 14.1 (lesson 8)
    v09999         ProbCut, Depth >= 5, non-PV                   +2.1 Elo +/- 9.6 (inconclusive)
    v1.00-pr2      capture history (two-sided, MVV-LVA suppl.)   -4.1 Elo +/- 10.1
                                                                (2301, LOS 21.5%, lesson 7)
    v0982          king-safety zone (attacker-weighted)          ~-8 Elo (superseded by
                                                                the rc12 attack-units table)

v1.00 RELEASE CHECKLIST (before tagging rc21 as v1.00)

    Reviewed the followed additional options:
    - [No gain expected] Backward pawns test only the rear pawn per file. A doubled pair where the front pawn is the genuinely backward one is missed. Most engines test each pawn (or at least the front pawn). Cheap to change, and it's already inside the pawn-hash-cached loop; would need a retune of the DIB pair.
    - [No gain expected] Remaining hardcoded scalars: bishop pair (30/30), rook open/semi-open (25/15), back-rank penalty (25/rank), castle bonus (30), EG centre-distance weight (10), tempo (10), and the SafetyTable shape. These are now the only eval terms outside the tuner; they're all extractable with the same pattern as the rc18 rook scalars, so a "tune everything" pass would be a natural v1.01 step. The back-rank/centre-distance terms in particular overlap with KingPST_MG/EG and might tune toward zero.
    - [v100RC22, Not succesfull] Blockaded passers: your passed-pawn term ignores a piece sitting on the stop square. A blocked passer is worth notably less in EG; a simple "stop square occupied by enemy piece → scale the bonus" is a classic small gain. (It would need to live outside the pawn hash, like the KPD term, since it depends on piece placement.)
    - [No gain expected] Doubled bishops on one colour double-count the bad-bishop penalty (per-bishop loop). Arguably correct chess-wise; just noting the behavior is intentional-looking and tuner-consistent.

Roadmap (POST-v1.00 candidates, rough EV order; nothing below blocks the
         v1.00 release -- the feature set is frozen)
    A. NNUE -- the standard path beyond the HCE ceiling; obsoletes the hand
       eval. The usual sequencing (exhaust cheap HCE/NPS levers first, since
       NPS gains carry over) is now essentially complete: magics, pawn hash,
       lazy-SEE, packed TT and the full eval programme are all in. NNUE is
       the natural next major direction after v1.00 ships.
    B. Search-shape candidates unblocked by rc9, each its own SPRT (with the
       lesson-8 paired removal-SPRT where fire conditions overlap):
         - eval-margin NMP term min((StaticEval-Beta) div 200, 2), now that
           StaticEval exists at all nodes;
         - improving-conditioned LMR (reduce less when improving) and
           futility-margin adjustment;
         - NMP verification-search restriction/removal at high depth (+2..+5).
    C. Correction history Phase 2 -- unblocked by rc8 (pawn key) + rc9
       (StaticEval everywhere); needs the DEEP-write / SHALLOW-read asymmetry
       lesson 6 identified. ~80-line refactor.
    D. Quiet-move SEE pruning (the open half of the rc4 candidate): extend
       SEE() to non-captures (currently defensive Exit(0) on quiets). Own SPRT.
    E. Aggressiveness re-tunes of adopted features, one constant each:
       SEE_PRUNE_MAX_DEPTH 6->8, SEE_PRUNE_MARGIN 100->80-90; qchecks re-test;
       LMR log-log re-tune; ProbCut margin/depth re-tune. Small (+1..+3 each).
    F. Further eval only if a specific deficiency shows up in game analysis
       (king-attack tropism, trapped pieces, square-of-the-pawn). New terms
       would be born tuned via the existing exact-residual tuner, but the
       HCE eval is considered feature-complete for v1.00.
    G. Time-management polish (the three open items above): ceiling clamp for
       repeating movestogo controls, optional MoveOverhead, continued
       STABLE_* fine-tuning.

Out of scope for v1.00 / HCE phase
    NNUE (see roadmap A), Lazy SMP, Syzygy tablebases.

Estimated playing strength
    Pre-PeSTO baseline (~v0988):              ~2250
    After PeSTO + tapered (v0995):            ~2330-2370
    After aspiration windows (v0996):         ~2340-2380
    After v0997b/v0997c:                      ~2390-2430
    After v09992 (singular extensions):       ~2400-2440
    After v09996 (IIR):                       ~2410-2450
    After v09997 (razoring):                  ~2420-2460
    After v09998d1 (futility restricted):     ~2430-2470
    After v1.00-pr1 (lazy-SEE, +NPS):         ~2450-2475
    After v1.00-rc3f (time management, +30):  ~2475-2500
    After v1.00-rc4 (SEE pruning, +35):       ~2510-2535
    After v1.00-rc5 (packed TT, neutral):     ~2510-2540
    After v1.00-rc7/rc8 (magics + pawn hash,
      pure NPS; strength via deeper search):  ~2520-2555
    After the rc10-rc21 eval programme +
      joint Texel retune (measured):          ~2510-2540 self-play est.
    HCE ceiling for this design:              ~2550-2600 with the post-v1.00
                                              search-shape / correction-history
                                              items; NNUE required beyond.

    }
type
  TPiece = (EMPTY, wP, wN, wB, wR, wQ, wK, bP, bN, bB, bR, bQ, bK);
  TBoard = array[0..7, 0..7] of TPiece;
  TMoveType = (MT_NORMAL, MT_EN_PASSANT, MT_CASTLE_WK, MT_CASTLE_WQ,
    MT_CASTLE_BK, MT_CASTLE_BQ);

  TMove = record
    FromR, FromC, ToR, ToC: integer;
    Promotion: TPiece;
    MoveType: TMoveType;
  end;

  TMoveList = array[0..255] of TMove;

  TGameState = record
    Board: TBoard;

    // v0967: bitboards (LERF: bit 0 = a1, bit 63 = h8). Maintained in
    // parallel with Board[] during the bitboard migration. SquareIndex(r,c)
    // converts mailbox coords (mailbox uses [0,0]=a8) to bit index. Both
    // representations are kept in sync by DoMakeMove until the mailbox
    // is fully retired in a later version.
    Pieces:      array[wP..bK] of QWord; // 12 piece bitboards
    Occupied:    array[0..1]   of QWord; // 0 = white, 1 = black
    AllOccupied: QWord;                  // White | Black

    SideToMove: integer; // 0 = White, 1 = Black
    CastleMask: integer; // Bit 0: wK, 1: wQ, 2: bK, 3: bQ
    EPR, EPC: integer;   // En Passant target row and col (-1 if none)
    WhiteKingR, WhiteKingC: integer;
    BlackKingR, BlackKingC: integer;
    HalfMoveClock: integer; // For 50-move rule
    Hash: QWord;           // Zobrist Hash for Transposition Table & Repetition
    // v1.00-rc8: pawn-only Zobrist key. XOR of ZobristPiece[wP/bP,r,c]
    // over every pawn on the board (nothing else — no side, castle or EP
    // terms, because PASS 3 of Evaluate depends only on pawn placement).
    // Maintained incrementally in DoMakeMove in lockstep with Hash, and
    // computed from scratch by ComputePawnHash in InitState / ParseFEN.
    // Because the engine searches by copy-restore (OldState := State ...
    // State := OldState), this field is snapshotted and restored for free
    // on every move undo — there is no separate unmake path to update.
    PawnHash: QWord;       // v1.00-rc8: index into the pawn hash table
    GamePly: integer;      // Tracks repetition correctly inside Search
    FullMoveNumber: integer; // v1.00-rc3: standard FEN full-move number
                             // (starts at 1, increments after each Black
                             // move). Parsed from FEN field 6 and maintained
                             // in DoMakeMove so it is GUI-independent (does
                             // not depend on the GUI sending a move list).
                             // Used by the opening-ramp time allocation.
  end;

  // =========================================================================
  // v1.00-rc5: packed transposition-table entry (48 -> 16 bytes).
  //
  // The old record (QWord + 3 x 4-byte integer + enum + 24-byte TMove,
  // ~48 B with alignment) wasted the dominant TT resource: a random-index
  // probe is a DRAM round-trip (~100 ns, hundreds of cycles), and a 48-byte
  // entry can straddle two 64-byte cache lines, paying that latency twice.
  // The packed 16-byte layout fits four entries per cache line, never
  // straddles, and triples entry density (Hash=128 MB: ~2.8M -> 8.4M
  // entries), which reduces index collisions and therefore overwrites of
  // useful deep entries. The unpacking arithmetic (a few 1-cycle shifts and
  // masks on an already-loaded register) is noise against the memory cost.
  //
  // Field ranges (the packing contract — see also PackMove/UnpackMove):
  //   Score: SmallInt (-32768..32767). Engine scores are bounded by the
  //          full aspiration window +/-30000; mate scores after ScoreToTT
  //          reach at most +/-(29000 + MaxPly) ~ +/-29100. Both fit.
  //   Depth: ShortInt (-128..127). Stored remaining depth is 0..~100.
  //   Flag:  TTTFlag under {$PACKENUM 1} so the enum field is 1 byte and
  //          every existing "TTE^.Flag = ttExact"-style comparison compiles
  //          unchanged. {$PACKENUM 4} restores the platform default for any
  //          enum declared later.
  //   MoveData: the TMove packed into 19 bits by PackMove (rows/cols 3 bits
  //          each, Promotion 4 bits, MoveType 3 bits); High(Cardinal) is
  //          the sentinel for "no move" (FromR = -1). A zero-filled entry
  //          (ClearTT) decodes to the all-zero a1a1 move — exactly what the
  //          old zero-filled TMove field held, so probe behaviour on empty
  //          slots is unchanged (it is gated on HashKey matching anyway).
  //
  // 'packed record' removes alignment padding: 8 + 4 + 2 + 1 + 1 = 16 B
  // exactly, a power of two, so entries never straddle cache lines.
  //
  // Behaviour contract: every field round-trips EXACTLY, so search
  // decisions are bit-identical to v1.00-rc4 AT EQUAL ENTRY COUNT.
  // Verified: rc5 with Hash=32 MB (2^21 entries) reproduces rc4's
  // Hash=128 MB (also 2^21 entries) bench node count exactly. At equal
  // MB the entry count triples, so the index mask widens and collision
  // patterns shift — node counts then differ trivially (the intended
  // density effect, observed as a 1-node bench delta). The Elo, if any,
  // comes from cache behaviour and the higher entry density at long
  // time controls, not from a search change.
  // =========================================================================
  {$PACKENUM 1}
  TTTFlag = (ttExact, ttAlpha, ttBeta);
  {$PACKENUM 4}
  TTTEntry = packed record
    HashKey:  QWord;    // 8 B — full 64-bit Zobrist key (verification)
    MoveData: Cardinal; // 4 B — TMove packed by PackMove / UnpackMove
    Score:    SmallInt; // 2 B — ScoreToTT-adjusted score
    Depth:    ShortInt; // 1 B — remaining search depth of the stored bound
    Flag:     TTTFlag;  // 1 B — bound type ({$PACKENUM 1} above)
  end;

  // v1.00-rc8: pawn hash table entry. Caches the PASS 3 (pawn-structure)
  // contribution of Evaluate — two integers, the middlegame and endgame
  // deltas summed over all files — keyed by the pawn-only Zobrist key
  // (State.PawnHash). See the PawnHashTable var and the PASS 3 probe in
  // Evaluate for the full rationale. Not packed: this tiny table wants speed,
  // not density, and the few padding bytes are irrelevant next to the TT.
  TPawnHashEntry = record
    Key:   QWord;      // 8 B — full pawn Zobrist key (collision verification)
    dMG:   integer;    // 4 B — PASS 3 middlegame contribution for this key
    dEG:   integer;    // 4 B — PASS 3 endgame   contribution for this key
    Valid: boolean;    // 1 B — slot has been written (distinguishes true 0)
  end;

const
  PieceChar: array[TPiece] of char =
    ('.', 'P', 'N', 'B', 'R', 'Q', 'K', 'p', 'n', 'b', 'r', 'q', 'k');
  PieceValue: array[TPiece] of integer =
    (0, 100, 320, 330, 500, 900, 20000, -100, -320, -330, -500, -900, -20000);



  // =========================================================================
  // TEXEL-TUNABLE PARAMETER BLOCK  (best-validation snapshot).
  //
  // This whole region is the linear evaluation vector. Under -dTUNER it is
  // `var` (the tuner overwrites it); otherwise `const`. The offline Texel
  // tuner (pasknight_texel_tuner.pas) emits this entire block as drop-in
  // Pascal — paste its output here verbatim to update the tuned values.
  // Declaration ORDER below is load-bearing: the tuner's coefficient layout
  // (TUNE_*_BASE offsets) mirrors it. Do not reorder, insert, or remove a
  // declaration without updating the tuner; comment-only edits are safe.
  //
  // The single NONLINEAR term (SafetyTable, rc12 king safety) is NOT here —
  // it lives outside this block and lands in the tuner's fixed residual.
  // Everything below is linear in its entries and exact-residual verified
  // (the tuner's linear model reproduces Evaluate bit-for-bit).
  //
  // TUNER MECHANICS THAT AFFECT THESE VALUES:
  //   - "projected/re-centered": PSTs, piece values, and mobility tables
  //     share a material/PST gauge (a constant added across a whole
  //     sub-table is a per-piece material shift in disguise), so the tuner
  //     removes each sub-table's mean from the gradient and re-centers it.
  //     Terms that reach only a SUBSET of pieces/pawns (passed, connected,
  //     outpost, threat, rook, king-passer, shield, doubled/iso/backward)
  //     are NOT projected — their means are genuine signal and stay free.
  //   - "frozen": unreachable or zero-coverage cells keep their seed through
  //     tuning. If you paste a fresh tuned block, those remain exactly as
  //     the writer emitted them — that is correct, not stale.
  //   - Seeds are PLACEHOLDERS. Per the batch discipline, values are never
  //     hand-tuned between features; the single joint retune sets them all.
  //
  // ---- Contents, in declaration order (phase / where / rationale) --------
  //
  //   PieceValueMG/EG[TPiece]            — material. MG & EG. PASS 1.
  //   {Pawn,Knight,Bishop,Rook,Queen,King}PST_MG / _EG  — PSTs. PASS 1.
  //       PeSTO-derived. Projected/re-centered per sub-table (see above).
  //       Pawn PST ranks 1 & 8 (rows 0 and 7) are unreachable → frozen at 0.
  //
  //   PassedPawnMG/EG[0..7]              — passed pawns by RELATIVE rank.
  //       MG & EG. PASS 3 (pawn-hash cached; depends only on pawn placement).
  //       A passer's value is strongly nonlinear in rank, which a flat bonus
  //       cannot express — hence the per-rank table. One shared table serves
  //       both colours: white relRank = LERF rank; black = 7 − LERF rank.
  //       Only the MOST ADVANCED pawn per file is tested. Entries 0 & 7
  //       unreachable → frozen. NOT projected (bonus reaches only passers).
  //
  //   {Knight,Bishop,Rook,Queen}MobMG/EG[…] — mobility by SAFE move count.
  //       MG & EG. PASS 5. Mobility value SATURATES (0→3 moves huge, 20→23
  //       negligible), which a linear term cannot express — hence tables.
  //       Index = PopCnt(attacks AND NOT own AND NOT enemy-pawn-attacks):
  //       a square an enemy pawn guards is not real mobility (safe mobility,
  //       rc21). Projected/re-centered like the PSTs (every piece of a type
  //       lands in exactly one cell → same gauge as material). Safe mobility
  //       lowers the reachable ceiling, so several TOP cells are unreachable
  //       and frozen at seed — expected, not a bug.
  //
  //   PawnThreat{Minor,Rook,Queen}MG/EG, MinorThreat{Rook,Queen}MG/EG,
  //   Hanging MG/EG                      — threat scalars (rc13). MG & EG.
  //       PASS 7, from the PASS 5 attack maps. Count × scalar. Kept MODEST
  //       on purpose: search already resolves one-move threats tactically;
  //       these only nudge QUIET nodes toward pressure / keeping pieces
  //       defended. Pawn→queen is MG-heavy (initiative), pawn→minor/rook
  //       grow toward EG (fewer defensive resources). Hanging is small and
  //       DELIBERATELY double-counts the specific threats (a queen both
  //       attacked-by-pawn and undefended is worse than either alone).
  //       Not projected/re-centered.
  //
  //   BadBishopPawnMG/EG                 — bad bishop, blocked-central form
  //       (rc17). MG & EG (EG-heavy: a bishop hemmed by fixed pawns is an
  //       endgame liability). PASS 5. Penalty per own pawn that is
  //       simultaneously (a) on the bishop's colour complex, (b) BLOCKED
  //       (a piece sits directly ahead in the advance direction), and (c) on
  //       a central file (c–f). This isolates the true "bad bishop" (entombed
  //       behind its own fixed central chain); counting every complex pawn,
  //       as the old form did, over-penalised advanceable and rim pawns.
  //       Positive magnitude, SUBTRACTED for white (white coeff negative).
  //       Not projected/re-centered.
  //
  //   ConnectedMG/EG[0..7]               — connected/phalanx pawns by
  //       relative rank (rc15). MG & EG. PASS 3 (pawn-hash cached — all
  //       flags are pawn-placement-only). Per pawn that is supported or
  //       phalanx: bonus = (2 + phalanx − opposed) × Connected[relRank];
  //       the integer multiplier m∈{1,2,3} keeps it LINEAR, so the
  //       coefficient of a cell is the net Σ of m. DELIBERATELY stacks with
  //       doubled/isolated/backward/passed (different structural axes; an
  //       isolated pawn is never connected, so those two cannot co-fire; a
  //       connected passer SHOULD score both). Entries 0 & 7 unreachable →
  //       frozen. Not projected/re-centered.
  //
  //   OutpostMG/EG[0..7]                 — knight outpost by relative rank
  //       (rc15/rc16). MG & EG (MG-heavy). PASS 5. Conditions: relative
  //       rank 4–6, defended by an own pawn, on a square no enemy pawn can
  //       ever attack (WhiteOutpostMask/BlackOutpostMask). Only ranks 3,4,5
  //       can fire → entries 0,1,2,6,7 frozen. Not projected/re-centered.
  //   BishopOutpostMG/EG                 — half-weight bishop outpost, SAME
  //       three conditions. A knight and a bishop on the same hole each
  //       score their own term (two pieces, two outposts — not double count).
  //
  //   RookOn7thMG/EG,
  //   RookBehindOwnPassedMG/EG,
  //   RookBehindEnemyPassedMG/EG         — rook terms (rc18). MG & EG.
  //       PASS 4. Rank-7: rook on relative rank 6/1 with the enemy king on
  //       its back rank OR an enemy pawn still on its 2nd rank. Behind-passer
  //       ("behind" = origin side of the pawn's advance) uses two LOCAL
  //       bitboards wPassed/bPassed rebuilt fresh at the top of PASS 4 from
  //       pawn placement — deliberately NOT added to the pawn-hash entry (no
  //       layout change, no cache re-verification). A rook may score rank-7
  //       AND a behind-passer term at once (distinct facts, not double
  //       counting). LESSON: use (sq shr 3) for the LERF rank — SquareCoords
  //       returns the MAILBOX ROW (7 − rank), which silently disabled the
  //       rank-7 term in the first cut. Not projected/re-centered.
  //
  //   KingPassedEnemyEG, KingPassedOwnEG — king/passed-pawn distance (rc19).
  //       EG-ONLY (no MG coefficient — king activity is an endgame concept;
  //       in the middlegame the king wants shelter, handled by king safety /
  //       shield). Per passer: + enemy × Cheb(enemyKing, front)
  //       − own × Cheb(ownKing, front); front = advance square, Chebyshev
  //       distance 0..7; two scalars so defender vs attacker proximity tune
  //       independently. CACHE SAFETY: depends on KING squares, so it is
  //       computed in the end-of-Evaluate king block, OUTSIDE the pawn hash
  //       (caching a king-dependent term against the pawn key is a bug).
  //       Distance-weighted coefficient. Not projected/re-centered.
  //
  //   ShieldMG[0..3]                     — pawn shield by advancement bucket
  //       (rc20). MG-ONLY (shelter is irrelevant once the king must
  //       activate). King-dependent → OUTSIDE the pawn hash. Per king-front
  //       file, bucket = nearest shield pawn's advancement: 0 = directly in
  //       front (ideal) … 3 = missing. SIGNED penalties (≤ 0): the function
  //       returns their sum, ADDED for white / SUBTRACTED for black. Only
  //       fires when the king is on its own first two ranks; off-board
  //       shield files (a/h king) are skipped, not counted as missing.
  //
  //   DoubledPawnMG/EG, IsolatedPawnMG/EG, BackwardPawnMG/EG — pawn-structure
  //       penalties (rc21 sweep; formerly hard-coded literals). MG & EG.
  //       PASS 3 (pawn-hash cached). Positive magnitudes, SUBTRACTED for
  //       white. Doubled is PER EXTRA pawn on a file (× (count − 1));
  //       isolated = no own pawn on an adjacent file; backward = rear pawn
  //       unsupported by adjacent files with its stop square attacked by an
  //       enemy pawn. Not projected/re-centered.
  // =========================================================================

  {$IFDEF TUNER}var{$ELSE}const{$ENDIF}
  // Texel-tuned PST + piece values (best-validation snapshot).
  {$I pasknight_tuned_weights.pas}//External file, all weights and factors. Tuned with texel tuner
  {$IFDEF TUNER}const{$ENDIF}

  // =========================================================================
  // v1.00-rc12 — King safety via attack units (CPW scheme).
  //
  // For each side, the "king zone" is the king ring (KingAttacks[ksq])
  // plus the king square itself. During PASS 5 the raw attack set of
  // every enemy knight/bishop/rook/queen — already computed there for
  // mobility — is intersected with the zone. Each attacking piece
  // contributes  weight * PopCnt(attacks AND zone)  attack units:
  //     Knight 2   Bishop 2   Rook 3   Queen 5
  // and bumps an attacker count. If a king has >= 2 distinct attackers,
  // SafetyTable[min(units, 99)] is subtracted from that side's ScoreMG.
  //
  // Design notes:
  //   - MG-only: in the endgame king exposure is handled by KingPST_EG
  //     and the centre-distance term; the tapered blend fades this to
  //     zero automatically, same as the pawn shield.
  //   - The >= 2 attacker gate is the standard noise filter: one loose
  //     piece near the king is not an attack, and without the gate the
  //     term fires constantly in quiet positions.
  //   - The table is convex: early units are nearly free, stacked
  //     attackers escalate sharply. This is what a linear per-attacker
  //     bonus cannot express and is the whole point of the table form.
  //   - Deliberately NOT in the {$IFDEF TUNER}var block: the table is
  //     indexed by a nonlinear function of the position (summed units),
  //     so it does not fit the linear coefficient model. Its effect
  //     lands in the tuner's fixed residual (TunerLastMG minus the
  //     reconstructed tunable part), which is exactly where it belongs.
  //     No tuner code change is required.
  //   - Pawns and kings are not counted as attackers (standard; pawn
  //     storms are a separate future term).
  //
  // Table and weights are the reference values from the chessprogramming
  // wiki "King Safety" page (Glaurung-era lineage). Plateau at 500 cp.
  // =========================================================================
  SafetyTable: array[0..99] of integer = (
      0,   0,   1,   2,   3,   5,   7,   9,  12,  15,
     18,  22,  26,  30,  35,  39,  44,  50,  56,  62,
     68,  75,  82,  88,  94,  97, 105, 113, 122, 131,
    140, 150, 169, 180, 191, 202, 213, 225, 237, 248,
    260, 272, 283, 295, 307, 319, 330, 342, 354, 366,
    377, 389, 401, 412, 424, 436, 448, 459, 471, 483,
    494, 500, 500, 500, 500, 500, 500, 500, 500, 500,
    500, 500, 500, 500, 500, 500, 500, 500, 500, 500,
    500, 500, 500, 500, 500, 500, 500, 500, 500, 500,
    500, 500, 500, 500, 500, 500, 500, 500, 500, 500);




  KnightDR: array[0..7] of integer = (-2, -2, -1, -1, 1, 1, 2, 2);
  KnightDC: array[0..7] of integer = (-1, 1, -2, 2, -2, 2, -1, 1);
  KingDR: array[0..7] of integer = (-1, -1, -1, 0, 0, 1, 1, 1);
  KingDC: array[0..7] of integer = (-1, 0, 1, -1, 1, -1, 0, 1);
  SlideDR: array[0..7] of integer = (-1, 1, 0, 0, -1, -1, 1, 1);
  SlideDC: array[0..7] of integer = (0, 0, -1, 1, -1, 1, -1, 1);
  // v0970 — for each SlideDR/SlideDC direction index, true iff stepping
  // in that direction increases the LERF bit index (so the nearest
  // blocker on a masked ray is the lowest-bit hit, found via BsfQWord).
  // For "negative" directions the nearest blocker is the highest-bit
  // hit, found via BsrQWord. See InitAttackTables for the RayMask table.
  //   dir 0 (N , dr=-1, dc= 0): LERF +8   → True
  //   dir 1 (S , dr=+1, dc= 0): LERF -8   → False
  //   dir 2 (W , dr= 0, dc=-1): LERF -1   → False
  //   dir 3 (E , dr= 0, dc=+1): LERF +1   → True
  //   dir 4 (NW, dr=-1, dc=-1): LERF +7   → True
  //   dir 5 (NE, dr=-1, dc=+1): LERF +9   → True
  //   dir 6 (SW, dr=+1, dc=-1): LERF -9   → False
  //   dir 7 (SE, dr=+1, dc=+1): LERF -7   → False
  SlideDirIsPositive: array[0..7] of boolean = (True, False, False, True, True, True, False, False);
  // v0971 — LERF rank masks. RankMask[r] is the bitboard of all 8 squares
  // on LERF rank r (0=chess rank 1, 7=chess rank 8). Used by the bitboard
  // pawn-push generator to detect promotion-rank targets and the
  // intermediate rank for double-push validation. Also useful for future
  // pawn-structure and king-safety evaluators.
  RankMask: array[0..7] of QWord = (
    QWord($00000000000000FF), // Rank 1 (LERF bits 0..7)
    QWord($000000000000FF00), // Rank 2 (LERF bits 8..15)
    QWord($0000000000FF0000), // Rank 3 (LERF bits 16..23)
    QWord($00000000FF000000), // Rank 4 (LERF bits 24..31)
    QWord($000000FF00000000), // Rank 5 (LERF bits 32..39)
    QWord($0000FF0000000000), // Rank 6 (LERF bits 40..47)
    QWord($00FF000000000000), // Rank 7 (LERF bits 48..55)
    QWord($FF00000000000000));// Rank 8 (LERF bits 56..63)
  // v0972 — LERF file masks. FileMask[c] is the bitboard of all 8 squares
  // on file (column) c (0=a-file, 7=h-file). Used by the bitboard pawn-
  // capture generator to prevent wraparound when shifting by ±7 and ±9
  // across rank boundaries. Also useful for future pawn-structure
  // evaluators (doubled, isolated, passed pawns).
  FileMask: array[0..7] of QWord = (
    QWord($0101010101010101), // File A (LERF bits 0, 8, 16, ..., 56)
    QWord($0202020202020202), // File B
    QWord($0404040404040404), // File C
    QWord($0808080808080808), // File D
    QWord($1010101010101010), // File E
    QWord($2020202020202020), // File F
    QWord($4040404040404040), // File G
    QWord($8080808080808080));  // File H (LERF bits 7, 15, 23, ..., 63)

  // v0984 — LERF rank inclusive bands. RanksAtOrBelow[r] is the bitboard
  // of every square whose LERF rank is <= r (i.e. rank r itself plus all
  // ranks below it in LERF order). RanksAtOrAbove[r] is the symmetric
  // bitboard for "LERF rank >= r". Used by the v0984 pawn-structure
  // evaluator to express the v0983 row comparisons (e.g. "adjacent-file
  // pawn with row >= wPawnRear[c]") as single AND operations against
  // the rear-most LERF rank of the candidate.
  RanksAtOrBelow: array[0..7] of QWord = (
    QWord($00000000000000FF),  // ranks <= 0
    QWord($000000000000FFFF),  // ranks <= 1
    QWord($0000000000FFFFFF),  // ranks <= 2
    QWord($00000000FFFFFFFF),  // ranks <= 3
    QWord($000000FFFFFFFFFF),  // ranks <= 4
    QWord($0000FFFFFFFFFFFF),  // ranks <= 5
    QWord($00FFFFFFFFFFFFFF),  // ranks <= 6
    QWord($FFFFFFFFFFFFFFFF)); // ranks <= 7 (all)
  RanksAtOrAbove: array[0..7] of QWord = (
    QWord($FFFFFFFFFFFFFFFF),  // ranks >= 0 (all)
    QWord($FFFFFFFFFFFFFF00),  // ranks >= 1
    QWord($FFFFFFFFFFFF0000),  // ranks >= 2
    QWord($FFFFFFFFFF000000),  // ranks >= 3
    QWord($FFFFFFFF00000000),  // ranks >= 4
    QWord($FFFFFF0000000000),  // ranks >= 5
    QWord($FFFF000000000000),  // ranks >= 6
    QWord($FF00000000000000)); // ranks >= 7

  // =========================================================================
  // v1.00-rc14 — Colour-complex masks (bad-bishop term).
  //
  // LERF square sq is LIGHT iff (rank + file) is odd, i.e. a1 (bit 0) is
  // dark, b1 light, a2 light, ... The two constants below are the standard
  // checkerboard bitboards. Used by the PASS 5 bishop loops: a bishop's
  // colour complex is determined by testing its square bit against
  // LightSquaresBB, and the bad-bishop penalty counts own pawns on that
  // same complex with a single AND + PopCnt.
  // =========================================================================
  LightSquaresBB = QWord($55AA55AA55AA55AA);  // b1, d1, ..., a2, c2, ...
  DarkSquaresBB  = QWord($AA55AA55AA55AA55);  // a1, c1, ..., b2, d2, ...

  // v1.00-rc17 step 3: files c, d, e, f as a bitboard (LERF file indices
  // 2..5). The improved bad-bishop term counts only BLOCKED own pawns on
  // the bishop's colour complex, restricted to these central files — a
  // blocked pawn on the a/b/g/h files barely obstructs a bishop's
  // diagonals, whereas a blocked central pawn on the bishop's own colour
  // is the textbook "bad bishop" that sits behind its own fixed pawn
  // chain. Restriction is a single extra AND; dropping it (should the
  // joint retune prefer all files) is just removing "and CentralFilesBB".
  CentralFilesBB = QWord($3C3C3C3C3C3C3C3C); // files c..f on every rank

  CM_WK = 1;
  CM_WQ = 2;
  CM_BK = 4;
  CM_BQ = 8;

  // v0973 — Castling path-empty masks (LERF). For each castling type,
  // the bitboard of squares that must be empty between king and rook.
  // The king's starting square, transit square, and destination are NOT
  // included here — those are tested via IsAttacked in the move
  // generator. Rook home squares are not tested either; the CastleMask
  // bits guarantee the rook hasn't moved.
  //   CM_WK_EMPTY: f1, g1     (between e1 and h1)
  //   CM_WQ_EMPTY: b1, c1, d1 (between e1 and a1)
  //   CM_BK_EMPTY: f8, g8     (between e8 and h8)
  //   CM_BQ_EMPTY: b8, c8, d8 (between e8 and a8)
  CM_WK_EMPTY = QWord($0000000000000060);
  CM_WQ_EMPTY = QWord($000000000000000E);
  CM_BK_EMPTY = QWord($6000000000000000);
  CM_BQ_EMPTY = QWord($0E00000000000000);

  FenPieces: string = 'PNBRQKpnbrqk';

  // v0997: runtime-configurable transposition table size.
  // Default is sized so the entry count equals the v0996 hardcoded value
  // (1 shl 20 entries) when SizeOf(TTTEntry) is in the 48..64 B range,
  // so an SPRT of v0997 vs v0996 with no explicit 'setoption name Hash'
  // measures only the History-LMR change.
  // v1.00-rc5: SizeOf(TTTEntry) is now 16 B (packed entry), so the same
  // HASH_DEFAULT_MB holds ~3x the entries (128 MB: ~2.8M -> 8.4M). The
  // ResizeHash arithmetic adapts automatically via SizeOf.
  // Max is bounded by the Integer cast in Search/GetPVLine — at 16 B/entry,
  // 4096 MB gives 256M entries which still fits comfortably in Int32.
  // Raising HASH_MAX_MB further requires switching TTIdx to NativeInt and
  // re-verifying every indexing site, so that is a separate, later change.
  HASH_DEFAULT_MB = 256;// ~16 million entries (16 B/entry, v1.00-rc5)
  HASH_MIN_MB     = 1;
  HASH_MAX_MB     = 4096;

  // v1.00-rc8: pawn hash table sizing. The pawn structure repeats at very
  // high rates during search, so a small direct-mapped table already gives
  // a hit rate in the high-90s%. We do NOT tie its size to the main Hash MB
  // option (which is deliberately spent on the TT); instead the pawn table
  // is a fixed power-of-two count of entries. 2^16 = 65536 entries at
  // SizeOf(TPawnHashEntry) = 24 B is ~1.5 MB — trivial next to the TT and
  // small enough to stay largely resident in L2/L3, which is the whole
  // point of the cache. PAWN_HASH_BITS is the log2 of the entry count; the
  // index mask is (1 shl PAWN_HASH_BITS) - 1.
  PAWN_HASH_BITS  = 16;               // 65536 entries
  PAWN_HASH_SIZE  = 1 shl PAWN_HASH_BITS;
  PAWN_HASH_MASK  = PAWN_HASH_SIZE - 1;

  // =========================================================================
  // Tapered evaluation phase weights (v0960).
  // Each non-pawn non-king piece contributes a weight to the "game phase".
  // The sum across both sides at the start of a game is MaxPhase = 24.
  // As pieces are exchanged, the running phase decreases toward 0 (pure
  // endgame). The blended score is then
  //     (ScoreMG * phase + ScoreEG * (MaxPhase - phase)) div MaxPhase
  // where phase=MaxPhase means full middlegame weight and phase=0 means
  // full endgame weight. Weights are PeSTO/Rofchade
  // =========================================================================
  PhaseN  = 1;
  PhaseB  = 1;
  PhaseR  = 2;
  PhaseQ  = 4;
  MaxPhase = 24;

  // Delta pruning margin (queen value approximation)
  DELTA_MARGIN = 900;

  // v0996 — Aspiration window tunables.
  //
  // Behaviour: at iterative-deepening depth >= ASP_MIN_DEPTH and when
  // the previous depth's score is not a mate score, the root window is
  // centred on LastCompletedScore with half-width ASP_INIT_DELTA. On a
  // fail-high (PartialBestScore >= WindowBeta) Beta widens; on a
  // fail-low (PartialBestScore <= OriginalAlpha) Alpha widens. Widening
  // is asymmetric — the opposite bound is preserved across the retry.
  // AspDelta doubles each retry. Once AspDelta exceeds ASP_MAX_DELTA
  // the depth falls through to a full (-30000, +30000) window so we
  // never spin forever.
  //
  // Rationale for re-testing now: v0958/v0959 ran aspiration against a
  // noisier eval signal and produced neutral SPRT results. After the
  // PeSTO migration (v0993..v0995) consecutive-depth scores are much
  // more stable, which is the precondition that makes narrow windows
  // payoff-positive. The known Alpha-mutation issue from earlier
  // attempts is avoided by capturing OriginalAlpha before the root
  // PVS loop runs (the loop's `if Score > Alpha then Alpha := Score`
  // mutation is necessary for PVS at the root and is kept).
  ASP_MIN_DEPTH    = 5;       // skip aspiration at shallow depths
  ASP_INIT_DELTA   = 25;      // initial half-width in centipawns
  ASP_MAX_DELTA    = 900;     // fall through to full window above this
  ASP_MATE_BOUND   = 28000;   // |score| above this -> use full window

  // v1.00-rc3: opening-ramp time-allocation constants. Global because they
  // are used in the UCI 'go' handler (main program body), not inside
  // GetBestMove. Underspend the first few moves out of book and bank the
  // time for the middlegame.
  // AllocatedTimeMs at or above this is treated as 'no time management'
  // (bench, debug play, go infinite). 100000000 ms = ~27.7 hours, well
  // above any real per-move budget and below int32 limits after scaling.
  TM_UNLIMITED_MS        = 100000000;

  // =====================================================================
  // TIME MANAGEMENT (v1.00-rc3f) - two tuning knobs, no phase, no soft/panic.
  // DERIVED SAFETY VALUE (not a tuning knob):
  //   EXCEED_CEILING_FACTOR_PCT  the mid-search abort ceiling
  //                          (ExceedCeilingAbortMs) = allocation * this / 100.
  //                          >100 gives a long-but-promising single iteration
  //                          a little room to finish before the emergency
  //                          brake fires. Purely a runaway-iteration backstop.
  // =====================================================================
  EXCEED_CEILING_FACTOR_PCT = 150;  // abort ceiling = allocation * 150%
//  EXCEED_CEILING_FACTOR_PCT = 200;  // abort ceiling = allocation * 200%

var
  TMSumAllocMs: QWord = 0;   // sum of AllocatedTimeMs over past moves this game
  TMSumUsedMs:  QWord = 0;   // sum of actually elapsed search time

var
  InputLine, BestMoveStr,ParamName,ParamValue, FENstr,MovesStr: string;
  SL: TStringList;
  WTime, BTime, WInc, BInc, MyTime, MyInc, AllocatedTimeMs, HardDepthLimit, Movestogo,valpos,MovePos,FenStartPos,perftdepth,perror: integer;
  TimeDivisor: integer;    // effective moves-remaining divisor for this move
  EstMovesLeft: integer;   // sudden-death estimate of moves remaining
  MinAlloc: integer;   // v1.00-rc3e: control-relative minimum allocation
  CeilingCapAlloc: integer;
  BookInitialized,display: boolean;

  State: TGameState;
  SearchDepth: integer;
  SearchNodes: int64;
  NodeLimit:   int64;   // Hard node limit for the current search. 0 = no limit.
  SearchStartTime: QWord;
  // v1.00-rc3f: the mid-search abort ceiling. During the search, the clock
  // is polled every ~10000 nodes; if elapsed time exceeds this value the
  // search is aborted immediately, wherever it is. This is the emergency
  // brake for a single iterative-deepening iteration that runs much longer
  // than the allocation predicted; in a normal move the between-iterations
  // stability check stops the search first and this never fires. It is
  // derived from the per-move allocation (allocation * EXCEED_CEILING_FACTOR)
  // and is NOT a tuning knob. 0 = no time management (fixed depth / nodes /
  // infinite): the abort is disabled and the depth/node limit is the bound.
  ExceedCeilingAbortMs: integer;
  AbortSearch: boolean;
  NodeCheckCount: integer;
  // v1.00-rc3b: selective depth. The deepest ply reached anywhere in the
  // tree during the current iteration (extensions + quiescence push some
  // lines far past the nominal depth). Reset to 0 at the start of each
  // GetBestMove depth iteration and updated at every node with the current
  // ply. Reported to the GUI as 'seldepth' alongside 'depth'.
  SelDepth: integer;
  logname: string;

  // Transposition Table — v0997: dynamic, resized via 'setoption name Hash'.
  // TTSize is always a power of 2; TTMask = TTSize - 1 is precomputed so the
  // indexing site does one masked AND instead of recomputing TTSize-1 per
  // probe. Initial allocation is performed by ResizeHash(HASH_DEFAULT_MB)
  // in the main program block.
  TT:     array of TTTEntry;
  TTMask: QWord;

  // =========================================================================
  // v1.00-rc8: pawn hash table.
  //
  // PASS 3 of Evaluate (doubled / isolated / passed / backward pawn terms)
  // reads ONLY the two pawn bitboards and precomputed mask/attack tables. Its
  // entire output is two integers: a middlegame delta (dMG) and an endgame
  // delta (dEG), each already summed over all eight files. Those two numbers
  // are a pure function of the pawn placement, which is captured exactly by
  // State.PawnHash. So we cache (dMG, dEG) keyed by the pawn key.
  //
  // Layout: direct-mapped, index = PawnHash and PAWN_HASH_MASK. Each slot
  // stores the full 64-bit key for verification (a mask collision between two
  // different pawn structures must NOT return the wrong deltas) plus the two
  // deltas. 'Valid' distinguishes a genuinely-stored zero-delta position
  // (which is common — the initial pawn wall scores 0 in PASS 3) from an
  // empty slot; without it a freshly-cleared table (Key = 0) could alias the
  // real pawn key 0 and be read as a spurious hit.
  //
  // No aging / replacement policy is needed: the table is always-overwrite
  // (last writer wins). A displaced entry simply causes a recompute next time
  // that structure recurs, which is cheap and self-correcting. Because the
  // cached value is the EXACT pass-3 result, a hit is bit-identical to the
  // miss path — the table can never change a search decision, only its speed.
  // (The TPawnHashEntry record itself is declared in the type section beside
  // TTTEntry; only the array variable lives here.)
  // =========================================================================

  // Fixed-size direct-mapped pawn hash table (see PAWN_HASH_* constants).
  // Allocated once by InitPawnHash at startup; never resized during search.
  PawnHashTable: array of TPawnHashEntry;

  // Zobrist Hashing Keys
  ZobristPiece: array[0..12, 0..7, 0..7] of QWord;
  ZobristSide: QWord;
  ZobristCastle: array[0..15] of QWord;
  ZobristEP: array[0..7] of QWord;

  // Repetition Detection History (removed global GamePly, use State.GamePly)
  GameHistory: array[0..2048] of QWord;

  // Killer Moves for Move Ordering
  Killers: array[0..100, 0..1] of TMove;

  // History Heuristic for Move Ordering
  // Indexed by [Side, FromR, FromC, ToR, ToC]. Incremented by Depth*Depth
  // whenever a quiet move causes a beta cutoff, so quiet moves that have
  // produced cutoffs elsewhere in the tree are searched earlier in
  // sibling and descendant nodes. This compensates for the absence of
  // an evaluator-aware ordering signal for non-killer non-capture moves
  // and is a prerequisite for effective Late Move Reductions later.
  History: array[0..1, 0..7, 0..7, 0..7, 0..7] of integer;

type // Opening Book
   TBookEntry = record
     Hash: QWord;
     MoveUCI: string;
   end;
var // Opening Book
   BookEntries: array of TBookEntry;
   BookCount: integer;
   BookLoaded: boolean;
   bookFileName : string='*';
   logfile: boolean=false;



   function InputReadyOLD: Boolean; //**Non-blocking check for GUI input (detects "stop" command during search).**
   {$IFDEF UNIX}
   var
     FDSet: TFDSet;
     TimeVal: TTimeVal;
   begin
     fpFD_ZERO(FDSet);
     fpFD_SET(0, FDSet);
     TimeVal.tv_sec := 0;
     TimeVal.tv_usec := 0;
     Result := fpSelect(1, @FDSet, nil, nil, @TimeVal) > 0;
   end;
   {$ELSE}
   var
     Avail: DWORD;
   begin
     PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE), nil, 0, nil, @Avail, nil);
     Result := Avail > 0;
   end;
   {$ENDIF}

 function InputReady: Boolean;
 {$IFDEF UNIX}
 var
   FDSet: TFDSet;
   TimeVal: TTimeVal;
   StdIn: Integer;
   SelectResult: Integer;
 begin
   StdIn := 0; // Standard input file descriptor (STDIN_FILENO)

   // Initialize the file descriptor set using fpFD_ZERO
   fpFD_ZERO(FDSet);

   // Add stdin to the set using fpFD_SET
   fpFD_SET(StdIn, FDSet);

   // Set timeout to 0 milliseconds (non-blocking check)
   TimeVal.tv_sec := 0;
   TimeVal.tv_usec := 0;

   // Check if data is available on stdin
   // fpSelect monitors the file descriptors we set up
   SelectResult := fpSelect(StdIn + 1, @FDSet, nil, nil, @TimeVal);

   if SelectResult > 0 then
     Result := True   // Data is available to read
   else
     Result := False; // No data available or error
 end;
 {$ELSE}
 var
   Avail: DWORD;
   Ok: Boolean;
 begin
   // Windows implementation using PeekNamedPipe
   Ok := PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE), nil, 0, nil, @Avail, nil);
   if Ok then
     Result := Avail > 0
   else
     Result := False;
 end;
 {$ENDIF}


procedure Log(const Msg: string);
var
  F: TextFile;
begin
  if logfile=false then
    exit;//write no log
  try
    AssignFile(F, logname);
    if FileExists(logname) then Append(F)
    else
      Rewrite(F);
    WriteLn(F, FormatDateTime('hh:nn:ss', Now) + ' | ' + Msg);
    CloseFile(F);
  except
    on E: Exception do ; // Silent fail for logging
  end;
end;


var
  LogBuffer: string;  // Accumulates buffered log lines until FlushLog is called

procedure BufferedLog(const Msg: string);
{**Appends a line to the in-memory log buffer without touching the disk.
Use this instead of Log() inside the search hot path. The buffer is
flushed to disk once per move by FlushLog() at the end of GetBestMove,
collapsing 10-15 per-depth file open/write/close cycles into a single
file operation. Saves roughly 50-250 ms per move on Windows NTFS, which
in time-controlled games is the difference between v0951 and v0951a
playing strength.}
begin
  if logfile=false then
    exit;//write no log

  LogBuffer := LogBuffer + FormatDateTime('hh:nn:ss', Now) + ' | ' + Msg + #10;
end;

procedure FlushLog;
{**Writes the accumulated log buffer to disk in a single open/write/close
cycle, then clears the buffer. Called at the end of GetBestMove. If the
buffer is empty this is a no-op.}
var
  F: TextFile;
begin
  if logfile=false then
    exit;//write no log
  if LogBuffer = '' then Exit;
  try
    AssignFile(F, logname);
    if FileExists(logname) then Append(F)
    else
      Rewrite(F);
    Write(F, LogBuffer);  // Single write — line endings already in buffer
    CloseFile(F);
  except
    on E: Exception do ;  // Silent fail for logging
  end;
  LogBuffer := '';
end;


// =====================================================================
// v0967 — Bitboard support.
// Mailbox indexing: Board[r,c] with [0,0]=a8, [7,7]=h1.
// Bitboard indexing: LERF (Little-Endian Rank-File): bit 0=a1, bit 63=h8.
// The two conventions don't agree, so SquareIndex() does the bridge.
// =====================================================================
var
  PawnAttacks:   array[0..1, 0..63] of QWord; // [BySide][sq] = squares from which a pawn of BySide attacks sq
  KnightAttacks: array[0..63] of QWord;
  KingAttacks:   array[0..63] of QWord;
  RayMask:       array[0..7, 0..63] of QWord; // v0970 — classical bitboard slider rays

  // v0984 — Pawn-structure mask tables. Populated by InitPawnMasks at
  // startup. Replace the per-file integer arrays wPawnCount / wPawnFront
  // / wPawnRear (and the black equivalents) that v0975..v0983 maintained
  // inside Evaluate. Each per-file quantity is now derived on the fly
  // via PopCnt / BsfQWord / BsrQWord against a file-mask AND with the
  // side's pawn bitboard.
  //
  // AdjacentFileMask[c]   = FileMask[c-1] OR FileMask[c+1], with the
  //   off-board neighbour for c=0 and c=7 dropped. Used for the
  //   isolated-pawn test and for the rear-support side of the
  //   backward-pawn heuristic.
  // WhitePassedMask[sq]   = the squares an enemy black pawn would have
  //   to occupy to block / capture a white pawn advancing from sq:
  //   strictly in front of sq on file(sq), plus at-or-in-front of sq's
  //   rank on the two adjacent files (off-board files dropped). A white
  //   pawn at sq is passed iff (WhitePassedMask[sq] AND blackPawns) = 0.
  //   Reproduces exactly the v0983 triple-condition row comparison on
  //   bPawnFront[c-1..c+1] (strict on own file, <= on adjacent).
  // BlackPassedMask[sq]   = symmetric for black: own-file strict and
  //   adjacent-file at-or-in-front measured in the black advance
  //   direction (falling LERF rank).
  AdjacentFileMask: array[0..7]  of QWord;
  WhitePassedMask:  array[0..63] of QWord;
  BlackPassedMask:  array[0..63] of QWord;

  // v1.00-rc14 — Outpost masks. WhiteOutpostMask[sq] is the bitboard of
  // every square from which an enemy black pawn could NOW OR EVER attack
  // sq: adjacent files, ranks strictly ahead of sq in the white advance
  // direction (a black pawn on (lr+1, c±1) attacks (lr, c); one further
  // back it can advance into that attacking post). A white knight on sq
  // sits on a permanent hole iff (WhiteOutpostMask[sq] AND bPawns) = 0.
  // Note this is exactly the adjacent-file half of WhitePassedMask
  // shifted one rank forward (strict instead of at-or-above): the
  // own-file component is irrelevant because a pawn never attacks
  // straight ahead. BlackOutpostMask is the mirror. Populated by
  // InitPawnMasks.
  WhiteOutpostMask: array[0..63] of QWord;
  BlackOutpostMask: array[0..63] of QWord;

// =====================================================================
// v1.00-rc7 — Plain magic bitboards (the one and only slider baseline;
// universal, no PEXT). One multiply + shift + table read yields the
// full attack set of a rook/bishop for any occupancy:
//
//   index  := ((occ AND Mask[sq]) * Magic[sq]) SHR Shift[sq]
//   attacks:= AttackTable[sq, index]
//
// Mask[sq] is the "relevant occupancy": the slider rays from sq minus
// the far edge square of each ray (an edge blocker never changes the
// attack set, so it need not be indexed). Shift[sq] = 64 - popcount
// (Mask[sq]), i.e. the index uses exactly as many bits as the mask has
// squares: at most 12 for a corner rook (4096 entries) and at most 9
// for a central bishop (512 entries). Fixed-size per-square rows give
// simple 2-D static arrays:
//   rook   64 x 4096 x 8 bytes = 2 MB
//   bishop 64 x  512 x 8 bytes = 256 KB
// The returned set contains the first occupied square in every
// direction (same convention as the classical scan): AND with NOT
// own-occupancy at the call site to drop own-piece blockers while
// keeping capturable enemy blockers.
//
// The magic constants below were found offline by random sparse search
// with exhaustive verification (every blocker subset of every mask maps
// collision-free, or to an identical attack set). InitMagicTables
// re-verifies this constructively while filling the tables and Halts on
// any mismatch, so a transcription error cannot go unnoticed.
//
// DirIndexTab[from, to] gives the SlideDR/SlideDC direction index 0..7
// of the ray from 'from' through 'to' (255 if not on a common ray). It
// exists only so SEE's FindLVA can break ties between equal-valued
// slider attackers in the exact ray order 0..7 the classical per-ray
// scan used, keeping SEE - and therefore bench - bit-identical to rc5.
// =====================================================================

const
  RookMagic: array[0..63] of QWord = (
    QWord($1080004008801020),     QWord($0840092002C03000),
    QWord($1900200010400900),     QWord($0880100008000480),
    QWord($4200100420080200),     QWord($8100020100080400),
    QWord($0200040110886200),     QWord($0200008040220411),
    QWord($0404800084400220),     QWord($0000401000402000),
    QWord($0086001081220440),     QWord($0408800800100280),
    QWord($000A001201040820),     QWord($8848800200840080),
    QWord($4001000100040200),     QWord($0442000102105084),
    QWord($9080010020804100),     QWord($0040404000201009),
    QWord($0000808010002009),     QWord($2200090021D00100),
    QWord($0008008008040080),     QWord($0004004002010040),
    QWord($0011040008015042),     QWord($00000A0001768104),
    QWord($0000800080204009),     QWord($2010004140002001),
    QWord($9800200280100080),     QWord($1000100080080080),
    QWord($0442000A00049020),     QWord($2100040080020080),
    QWord($0800120400900148),     QWord($0010040A00128541),
    QWord($2800804000800030),     QWord($1010002000400041),
    QWord($4000200011004100),     QWord($0610008410800800),
    QWord($0400802402800800),     QWord($C100020080800400),
    QWord($0002000802000401),     QWord($0182085882000401),
    QWord($0220204000808000),     QWord($2860100040024022),
    QWord($0001002004110040),     QWord($99101042000A0020),
    QWord($0004080004008080),     QWord($0010040002008080),
    QWord($2012004881020004),     QWord($8300842444820011),
    QWord($0088403882010200),     QWord($0820400080210100),
    QWord($0110910040A00300),     QWord($0801100280080480),
    QWord($0242009008200600),     QWord($1002000489500200),
    QWord($0040800200010080),     QWord($0091800041000080),
    QWord($0000209300488001),     QWord($04C1002414824001),
    QWord($020020000B001041),     QWord($7000100004200901),
    QWord($8002002004100802),     QWord($30010002084C0007),
    QWord($0888221800813004),     QWord($4000002840840112));

  BishopMagic: array[0..63] of QWord = (
    QWord($A010041108003100),     QWord($006082020A002900),
    QWord($6810010619200000),     QWord($08281A0520000408),
    QWord($0001104001000400),     QWord($0018901008048400),
    QWord($00040A0210245280),     QWord($000200210808A402),
    QWord($9140048410821200),     QWord($0800091010820041),
    QWord($20504804832202C0),     QWord($0100091401081000),
    QWord($8021011140000012),     QWord($0810020804450400),
    QWord($208B0542109008A2),     QWord($0080084A08040204),
    QWord($0040E2A80811244C),     QWord($2505022008008108),
    QWord($0430220100420040),     QWord($010A040420220040),
    QWord($1105000290400000),     QWord($0093001200822120),
    QWord($4000A62048043004),     QWord($280120048A015004),
    QWord($006090002A020814),     QWord($44042000240800D0),
    QWord($01102800040A4400),     QWord($1004080080220040),
    QWord($0001001011004024),     QWord($0010044000805040),
    QWord($0914041200820100),     QWord($0004821012821480),
    QWord($0024040500C05021),     QWord($0088611002080200),
    QWord($0116080A00040020),     QWord($4000020080080080),
    QWord($2450450140840040),     QWord($0000880201484100),
    QWord($0222020404020092),     QWord($8081110600002E00),
    QWord($2842101105000801),     QWord($1100809008001025),
    QWord($00020202221C0400),     QWord($0422014022009020),
    QWord($0210046102100C00),     QWord($C004008082029102),
    QWord($00AA461801101200),     QWord($0404080080201108),
    QWord($020542108C205002),     QWord($0410544804100100),
    QWord($0040910841100000),     QWord($0400200042021100),
    QWord($00004204850400C0),     QWord($0200100410A42102),
    QWord($1040020801210102),     QWord($0805040410420000),
    QWord($2884804130100200),     QWord($800C262201242000),
    QWord($1058000194108800),     QWord($0014221054420204),
    QWord($0104000012A02200),     QWord($0200881003300100),
    QWord($0140400202840100),     QWord($0402020801010201));

var
  RookMask,  BishopMask:  array[0..63] of QWord;   // relevant-occupancy masks
  RookShift, BishopShift: array[0..63] of integer; // 64 - popcount(mask)
  RookAttackTable:   array[0..63, 0..4095] of QWord; // 2 MB
  BishopAttackTable: array[0..63, 0..511]  of QWord; // 256 KB
  DirIndexTab: array[0..63, 0..63] of byte;          // SEE tie-break only



function SquareIndex(r, c: integer): integer; inline;
// Mailbox (r,c) -> LERF bit index. a1=(7,0)->0, h8=(0,7)->63, e4=(4,4)->28.
begin
  Result := (7 - r) * 8 + c;
end;

procedure SquareCoords(sq: integer; out r, c: integer); inline;
// Inverse of SquareIndex. Used when iterating bitboards back into
// mailbox-aware code (move construction, debugging).
begin
  r := 7 - (sq shr 3);
  c := sq and 7;
end;


procedure InitAttackTables;
{**Builds the pawn, knight, king, and sliding-ray attack tables once at startup.**
 PawnAttacks[s][sq] is the set of squares from which a pawn of side s
 attacks sq — i.e. *attackers* of sq, not attacks *from* sq. This is the
 form IsAttacked needs (AND with the side's pawn bitboard, check non-zero).

 v0970: RayMask[d, sq] is added — the bitboard of all squares strictly
 in SlideDR/SlideDC direction d from sq, walking to the edge of the
 board (sq itself is NOT included). Used by the classical bitboard
 slider move generator (B/R/Q). No magics yet.}
var
  sq, r, c, i, tr, tc, d: integer;
begin
  for sq := 0 to 63 do
  begin
    SquareCoords(sq, r, c);

    // Pawn attackers of sq. White pawns attack diagonally toward lower
    // mailbox rows (toward rank 8), so a WP attacking sq sits at (r+1, c±1).
    // Black pawns the mirror: BP attacking sq sits at (r-1, c±1).
    PawnAttacks[0, sq] := 0;
    if r < 7 then
    begin
      if c > 0 then PawnAttacks[0, sq] := PawnAttacks[0, sq] or (QWord(1) shl SquareIndex(r + 1, c - 1));
      if c < 7 then PawnAttacks[0, sq] := PawnAttacks[0, sq] or (QWord(1) shl SquareIndex(r + 1, c + 1));
    end;
    PawnAttacks[1, sq] := 0;
    if r > 0 then
    begin
      if c > 0 then PawnAttacks[1, sq] := PawnAttacks[1, sq] or (QWord(1) shl SquareIndex(r - 1, c - 1));
      if c < 7 then PawnAttacks[1, sq] := PawnAttacks[1, sq] or (QWord(1) shl SquareIndex(r - 1, c + 1));
    end;

    KnightAttacks[sq] := 0;
    for i := 0 to 7 do
    begin
      tr := r + KnightDR[i]; tc := c + KnightDC[i];
      if (Cardinal(tr) <= 7) and (Cardinal(tc) <= 7) then
        KnightAttacks[sq] := KnightAttacks[sq] or (QWord(1) shl SquareIndex(tr, tc));
    end;

    KingAttacks[sq] := 0;
    for i := 0 to 7 do
    begin
      tr := r + KingDR[i]; tc := c + KingDC[i];
      if (Cardinal(tr) <= 7) and (Cardinal(tc) <= 7) then
        KingAttacks[sq] := KingAttacks[sq] or (QWord(1) shl SquareIndex(tr, tc));
    end;

    // v0970 — Sliding ray masks. RayMask[d, sq] is the bitboard of all
    // squares strictly in SlideDR/SlideDC direction d from sq, walking
    // to the edge of the board (sq itself is NOT included). Used by the
    // classical bitboard slider move generator in GeneratePseudoLegalMoves.
    // Direction layout matches SlideDR/SlideDC: 0..3 orthogonal,
    // 4..7 diagonal. SlideDirIsPositive[] (declared with SlideDR/SlideDC)
    // tags whether the nearest blocker is BSF or BSR.
    for d := 0 to 7 do
    begin
      RayMask[d, sq] := 0;
      tr := r + SlideDR[d]; tc := c + SlideDC[d];
      while (Cardinal(tr) <= 7) and (Cardinal(tc) <= 7) do
      begin
        RayMask[d, sq] := RayMask[d, sq] or (QWord(1) shl SquareIndex(tr, tc));
        tr := tr + SlideDR[d]; tc := tc + SlideDC[d];
      end;
    end;
  end;
end;


{$push}{$Q-}{$R-} // magic index multiply relies on 64-bit wraparound
function RookAttacksBB(sq: integer; occ: QWord): QWord; inline;
{**Rook attack set from sq under the given occupancy, via plain magic
   lookup (v1.00-rc7). Contains the first occupied square in each of the
   four orthogonal directions; AND with NOT own-occupancy at the call
   site to obtain move destinations.}
begin
  Result := RookAttackTable[sq,
    ((occ and RookMask[sq]) * RookMagic[sq]) shr RookShift[sq]];
end;

function BishopAttacksBB(sq: integer; occ: QWord): QWord; inline;
{**Bishop attack set from sq under the given occupancy, via plain magic
   lookup (v1.00-rc6). Same blocker convention as RookAttacksBB.}
begin
  Result := BishopAttackTable[sq,
    ((occ and BishopMask[sq]) * BishopMagic[sq]) shr BishopShift[sq]];
end;

function QueenAttacksBB(sq: integer; occ: QWord): QWord; inline;
{**Queen attack set = rook set OR bishop set (v1.00-rc6).}
begin
  Result := RookAttacksBB(sq, occ) or BishopAttacksBB(sq, occ);
end;

procedure InitMagicTables;
{**v1.00-rc7 — build the plain-magic slider tables and DirIndexTab.**
 Called once at startup, after InitAttackTables (needs RayMask and
 SlideDirIsPositive as the trusted reference).

 For each square and each piece kind (rook, bishop):
   1. Build the relevant-occupancy mask: the union of the piece's rays
      with the far edge square of each ray removed.
   2. Shift := 64 - popcount(mask).
   3. Enumerate every blocker subset of the mask (Carry-Rippler:
      sub := (sub - mask) AND mask cycles through all subsets), compute
      the true attack set with the classical RayMask nearest-blocker
      scan, and store it at ((sub * magic) SHR shift).
   4. Any two subsets that map to the same index MUST have the same
      attack set ("constructive collision" - the whole point of magic
      numbers). A differing collision means a bad constant: report and
      Halt rather than run with a corrupt table.
 Step 3/4 is a full re-verification of the offline magic search, so the
 constants embedded above are proven correct on every startup (~10 ms).

 DirIndexTab[from, to] is filled from RayMask: direction d if 'to' lies
 on RayMask[d, from], 255 otherwise. Used only by SEE's FindLVA for
 rc5-identical tie-breaking between equal-valued slider attackers.}
var
  sq, d: integer;
  ray: QWord;

  function RefAttacks(s: integer; occ: QWord; d0, d1: integer): QWord;
  // Classical nearest-blocker scan, verbatim logic of the pre-rc6
  // SliderAttacks. Trusted reference for the table fill only.
  var
    dd, bsq: integer;
    r, b: QWord;
  begin
    Result := 0;
    for dd := d0 to d1 do
    begin
      r := RayMask[dd, s];
      b := r and occ;
      if b <> 0 then
      begin
        if SlideDirIsPositive[dd] then bsq := BsfQWord(b)
                                  else bsq := BsrQWord(b);
        r := r xor RayMask[dd, bsq];
      end;
      Result := Result or r;
    end;
  end;

  procedure BuildTable(IsRook: boolean);
  var
    s, d0, d1, dd, endSq, shift: integer;
    mask, sub, att, r: QWord;
    idx: QWord;
    Used: array[0..4095] of boolean; // 512 suffices for bishops; shared
  begin
    if IsRook then begin d0 := 0; d1 := 3; end
              else begin d0 := 4; d1 := 7; end;
    for s := 0 to 63 do
    begin
      // 1. relevant-occupancy mask: rays minus the far edge square.
      //    The far end of a "positive" (bit-ascending) ray is its
      //    highest bit (BSR); of a "negative" ray its lowest (BSF).
      mask := 0;
      for dd := d0 to d1 do
      begin
        r := RayMask[dd, s];
        if r <> 0 then
        begin
          if SlideDirIsPositive[dd] then endSq := BsrQWord(r)
                                    else endSq := BsfQWord(r);
          mask := mask or (r and not (QWord(1) shl endSq));
        end;
      end;
      shift := 64 - Integer(PopCnt(mask));
      if IsRook then begin RookMask[s]   := mask; RookShift[s]   := shift; end
                else begin BishopMask[s] := mask; BishopShift[s] := shift; end;

      // 3./4. fill + constructive verification over ALL blocker subsets.
      FillChar(Used, SizeOf(Used), 0);
      sub := 0;
      repeat
        att := RefAttacks(s, sub, d0, d1);
        if IsRook then idx := (sub * RookMagic[s])   shr shift
                  else idx := (sub * BishopMagic[s]) shr shift;
        if Used[idx] then
        begin
          if (IsRook     and (RookAttackTable[s, idx]   <> att)) or
             (not IsRook and (BishopAttackTable[s, idx] <> att)) then
          begin
            Writeln('info string FATAL: magic verification failed, sq=', s);
            Halt(1);
          end;
        end
        else
        begin
          Used[idx] := True;
          if IsRook then RookAttackTable[s, idx]   := att
                    else BishopAttackTable[s, idx] := att;
        end;
        sub := (sub - mask) and mask; // Carry-Rippler: next subset
      until sub = 0;
    end;
  end;

begin
  BuildTable(True);   // rooks:   2 MB table
  BuildTable(False);  // bishops: 256 KB table

  // DirIndexTab for SEE tie-breaking (see declaration comment).
  for sq := 0 to 63 do
  begin
    FillChar(DirIndexTab[sq], 64, 255);
    for d := 0 to 7 do
    begin
      ray := RayMask[d, sq];
      while ray <> 0 do
      begin
        DirIndexTab[sq, BsfQWord(ray)] := d;
        ray := ray and (ray - 1);
      end;
    end;
  end;
end;
{$pop}


procedure InitPawnMasks;
{**v0984 — populate the pawn-structure mask tables.**
 Called once at startup, after InitAttackTables. Independent of state.

 AdjacentFileMask[c]  - bitboard of all squares on files c-1 and c+1.
                        The off-board neighbour for c=0 and c=7 is
                        silently dropped, so the (c>0)/(c<7) guards of
                        v0983 are no longer needed at the call site.
                        Used by the isolated-pawn test and by the
                        rear-support side of the backward-pawn test.
 WhitePassedMask[sq]  - bitboard of every square an enemy black pawn
                        would have to occupy (now or after the white
                        pawn at sq advances) to stop the white pawn
                        from queening on its own file. Specifically:
                          - strictly in front of sq on file(sq), and
                          - at-or-in-front of sq's rank on files c-1
                            and c+1 (off-board files dropped).
                        A white pawn at sq is passed iff
                          (WhitePassedMask[sq] AND blackPawns) = 0.
 BlackPassedMask[sq]  - symmetric for black: the file is read top-down
                        (advancing = lower LERF rank) and the masks
                        cover strictly in front on own file plus
                        at-or-in-front on adjacent files in the black
                        advance direction.

 Equivalence proof (white, file c, wFront = wPawnFront[c]):
   v0983 "blocked" tests:
     bPawnFront[c]   <  wPawnFront[c]   (own file, strict)
     bPawnFront[c-1] <= wPawnFront[c]   (left  neighbour, inclusive)
     bPawnFront[c+1] <= wPawnFront[c]   (right neighbour, inclusive)
   These three are taken over the front-most black pawn on each file,
   but "front-most black <= R" is logically the same as "exists black
   pawn with row <= R" — which is exactly what
   (WhitePassedMask[wFrontSq] AND bPawns) <> 0 asks, with off-board
   files already trimmed and "strict on own file" encoded by the
   RanksAtOrAbove[lr+1] shift below.

 The masks also seed future work (v0984+): pawn span, candidate
 passers, connected/phalanx pawns, and outpost squares all reduce to
 a single AND against a precomputed mask of this shape.}
var
  sq, c, lr: integer;
begin
  // -------- Adjacent-file masks (8 entries) --------
  for c := 0 to 7 do
  begin
    AdjacentFileMask[c] := 0;
    if c > 0 then AdjacentFileMask[c] := AdjacentFileMask[c] or FileMask[c - 1];
    if c < 7 then AdjacentFileMask[c] := AdjacentFileMask[c] or FileMask[c + 1];
  end;

  // -------- Per-square passed-pawn masks --------
  // lr = LERF rank of sq (0..7), c = file of sq (0..7).
  for sq := 0 to 63 do
  begin
    lr := sq shr 3;
    c  := sq and 7;

    // White passed mask: own file strictly above (lr+1..7), adjacent
    // files at-or-above (lr..7). White advance direction = rising LERF
    // rank, so "in front" = higher LERF rank.
    WhitePassedMask[sq] := AdjacentFileMask[c] and RanksAtOrAbove[lr];
    if lr < 7 then
      WhitePassedMask[sq] := WhitePassedMask[sq] or
                             (FileMask[c] and RanksAtOrAbove[lr + 1]);

    // Black passed mask: own file strictly below (0..lr-1), adjacent
    // files at-or-below (0..lr). Black advance direction = falling
    // LERF rank, so "in front" = lower LERF rank.
    BlackPassedMask[sq] := AdjacentFileMask[c] and RanksAtOrBelow[lr];
    if lr > 0 then
      BlackPassedMask[sq] := BlackPassedMask[sq] or
                             (FileMask[c] and RanksAtOrBelow[lr - 1]);

    // v1.00-rc14 — Outpost masks: adjacent files, ranks STRICTLY ahead.
    // White: a black pawn anywhere on files c±1, LERF rank lr+1 or
    // higher, can (after zero or more advances) attack sq. Same rank or
    // behind can never attack sq — black pawns only move down. Black is
    // the mirror. On the last rank in the advance direction the mask is
    // empty (no rank strictly ahead), which is correct: nothing can
    // ever attack the square by pawn.
    if lr < 7 then
      WhiteOutpostMask[sq] := AdjacentFileMask[c] and RanksAtOrAbove[lr + 1]
    else
      WhiteOutpostMask[sq] := 0;
    if lr > 0 then
      BlackOutpostMask[sq] := AdjacentFileMask[c] and RanksAtOrBelow[lr - 1]
    else
      BlackOutpostMask[sq] := 0;
  end;
end;


function IsWhite(Piece: TPiece): boolean;
begin
  Result := (Piece >= wP) and (Piece <= wK);
end;


procedure BB_PlacePiece(P: TPiece; sq: integer); inline;
// Adds piece P at bit position sq to the State bitboards. Maintains
// piece, color-occupancy, and total-occupancy in one place.
var bit: QWord;
begin
  bit := QWord(1) shl sq;
  State.Pieces[P] := State.Pieces[P] or bit;
  if IsWhite(P) then
    State.Occupied[0] := State.Occupied[0] or bit
  else
    State.Occupied[1] := State.Occupied[1] or bit;
  State.AllOccupied := State.AllOccupied or bit;
end;

procedure BB_RemovePiece(P: TPiece; sq: integer); inline;
var bit: QWord;
begin
  bit := QWord(1) shl sq;
  State.Pieces[P] := State.Pieces[P] and not bit;
  if IsWhite(P) then
    State.Occupied[0] := State.Occupied[0] and not bit
  else
    State.Occupied[1] := State.Occupied[1] and not bit;
  State.AllOccupied := State.AllOccupied and not bit;
end;

procedure RebuildBitboardsFromBoard;
{**One-shot rebuild of all bitboards from the mailbox.**
 Called from InitState and ParseFEN where the mailbox is set up by
 bulk assignment without going through DoMakeMove. Also useful as a
 validation aid: after any operation, calling this and comparing
 against the existing bitboards detects drift.}
var
  r, c, sq: integer;
  P: TPiece;
begin
  for P := wP to bK do State.Pieces[P] := 0;
  State.Occupied[0] := 0; State.Occupied[1] := 0; State.AllOccupied := 0;
  for r := 0 to 7 do
    for c := 0 to 7 do
    begin
      P := State.Board[r, c];
      if P <> EMPTY then
      begin
        sq := SquareIndex(r, c);
        State.Pieces[P] := State.Pieces[P] or (QWord(1) shl sq);
        if IsWhite(P) then
          State.Occupied[0] := State.Occupied[0] or (QWord(1) shl sq)
        else
          State.Occupied[1] := State.Occupied[1] or (QWord(1) shl sq);
      end;
    end;
  State.AllOccupied := State.Occupied[0] or State.Occupied[1];
end;


procedure VerifyBitboards(const Context: string);
{**Asserts bitboards agree with the mailbox; logs and halts on mismatch.**
 Call this from suspect code paths during validation. It rebuilds a
 fresh snapshot from State.Board and compares with the live bitboards.

 v0967a: defensive — if State.Board contains an out-of-range value
 (which means we were called with the board mid-update or before it
 was initialised) we log the offending square instead of indexing
 Snap[] with garbage and getting an opaque memory-read crash.}
var
  Snap: array[wP..bK] of QWord;
  SnapWhite, SnapBlack: QWord;
  r, c, sq: integer;
  P: TPiece;
  PVal: integer;
begin
  for P := wP to bK do Snap[P] := 0;
  SnapWhite := 0; SnapBlack := 0;
  for r := 0 to 7 do
    for c := 0 to 7 do
    begin
      P    := State.Board[r, c];
      PVal := Ord(P);
      // EMPTY is the common case and is silently skipped.
      // wP..bK (1..12) are the valid populated values.
      // Anything else means the board is corrupt or being read
      // mid-update; complain loudly with the offending square so we
      // can localise the caller instead of trapping on Snap[] access.
      if PVal = Ord(EMPTY) then Continue;
      if (PVal < Ord(wP)) or (PVal > Ord(bK)) then
      begin
        Log('VerifyBitboards: invalid piece at (' + IntToStr(r) + ',' +
            IntToStr(c) + ') Ord=' + IntToStr(PVal) +
            ' Context=' + Context);
        WriteLn('VerifyBitboards: invalid piece at (', r, ',', c,
                ') Ord=', PVal, ' Context=', Context);
        Flush(Output);
        Halt(1);
      end;
      sq := SquareIndex(r, c);
      Snap[P] := Snap[P] or (QWord(1) shl sq);
      if IsWhite(P) then SnapWhite := SnapWhite or (QWord(1) shl sq)
                    else SnapBlack := SnapBlack or (QWord(1) shl sq);
    end;
  for P := wP to bK do
    if State.Pieces[P] <> Snap[P] then
    begin
      Log('VerifyBitboards: BB mismatch (' + Context + '): piece ' +
          PieceChar[P] + ' bb=' + IntToHex(State.Pieces[P], 16) +
          ' expected=' + IntToHex(Snap[P], 16));
      WriteLn('VerifyBitboards: BB mismatch (', Context, '): piece ',
              PieceChar[P], ' bb=', IntToHex(State.Pieces[P], 16),
              ' expected=', IntToHex(Snap[P], 16));
      Flush(Output);
      Halt(1);
    end;
  if (State.Occupied[0] <> SnapWhite) or (State.Occupied[1] <> SnapBlack) or
     (State.AllOccupied <> (SnapWhite or SnapBlack)) then
  begin
    Log('VerifyBitboards: occupancy mismatch (' + Context + ')' +
        ' w=' + IntToHex(State.Occupied[0], 16) +
        ' expW=' + IntToHex(SnapWhite, 16) +
        ' b=' + IntToHex(State.Occupied[1], 16) +
        ' expB=' + IntToHex(SnapBlack, 16));
    WriteLn('VerifyBitboards: occupancy mismatch (', Context, ')');
    Flush(Output);
    Halt(1);
  end;
end;



function NewMove(FR, FC, TR, TC: integer; Promo: TPiece; MT: TMoveType): TMove;
begin
  Result.FromR := FR;
  Result.FromC := FC;
  Result.ToR := TR;
  Result.ToC := TC;
  Result.Promotion := Promo;
  Result.MoveType := MT;
end;

// =========================================================================
// v1.00-rc5: TMove <-> 32-bit packing for the transposition table.
//
// Bit layout (19 bits used, rest zero):
//   bits  0.. 2  FromC   (0..7)
//   bits  3.. 5  FromR   (0..7)
//   bits  6.. 8  ToC     (0..7)
//   bits  9..11  ToR     (0..7)
//   bits 12..15  Ord(Promotion)  (TPiece, 0..12 — 4 bits)
//   bits 16..18  Ord(MoveType)   (TMoveType, 0..5 — 3 bits)
//
// Sentinel: the "no move" TMove (FromR = -1, used by BestMoveFound before
// any TT hit and by fail-low nodes that never improved alpha) cannot be
// expressed in 3 bits, so it is encoded as High(Cardinal). No real move
// can collide with it because real encodings never set bit 19 or above.
//
// The round-trip is exact for every move the engine constructs (all fields
// in range by construction in AddMove/NewMove/ParseSANToMove), so TT-stored
// moves are bit-identical to the pre-packing TMove field and search
// behaviour is unchanged. A zero Data value decodes to the all-zero a1a1
// move, matching what a FillChar'd (ClearTT) entry held before.
// =========================================================================
function PackMove(const M: TMove): Cardinal; inline;
begin
  if M.FromR < 0 then Exit(High(Cardinal)); // sentinel: no move
  Result := Cardinal(M.FromC)
         or (Cardinal(M.FromR) shl 3)
         or (Cardinal(M.ToC)   shl 6)
         or (Cardinal(M.ToR)   shl 9)
         or (Cardinal(Ord(M.Promotion)) shl 12)
         or (Cardinal(Ord(M.MoveType))  shl 16);
end;

function UnpackMove(Data: Cardinal): TMove; inline;
begin
  //Result := Default(TMove); could remove warning but slows down a little.
  if Data = High(Cardinal) then
  begin
    Result := Default(TMove);
    Result.FromR := -1; // sentinel: no move
    Exit;
  end;
  Result.FromC     := integer(Data         and 7);
  Result.FromR     := integer((Data shr 3) and 7);
  Result.ToC       := integer((Data shr 6) and 7);
  Result.ToR       := integer((Data shr 9) and 7);
  Result.Promotion := TPiece((Data shr 12) and 15);
  Result.MoveType  := TMoveType((Data shr 16) and 7);
end;

procedure InitZobrist;
var
  p, r, c, i: integer;
begin
  RandSeed := 1070372; // Deterministic seed for consistent hashes across runs
  for p := 0 to 12 do
    for r := 0 to 7 do
      for c := 0 to 7 do
        ZobristPiece[p, r, c] := QWord(Random($FFFFFFFF)) shl 32 or QWord(Random($FFFFFFFF));
  ZobristSide := QWord(Random($FFFFFFFF)) shl 32 or QWord(Random($FFFFFFFF));
  for i := 0 to 15 do
    ZobristCastle[i] := QWord(Random($FFFFFFFF)) shl 32 or QWord(Random($FFFFFFFF));
  for i := 0 to 7 do
    ZobristEP[i] := QWord(Random($FFFFFFFF)) shl 32 or QWord(Random($FFFFFFFF));
end;

function ComputeHash: QWord;
{**Calculates the Zobrist hash for the current board position from scratch.**
Zobrist hashing assigns random 64-bit numbers to every piece on every square, plus side to move, castling rights, and en passant squares. The hash is an XOR of all these values. Properties:
- Same position always produces same hash (deterministic)
- Different positions almost always produce different hashes
- XOR allows incremental updates (fast during move making)
- Used for transposition table lookup and repetition detection
This function computes from scratch (slow), but is only called during initialization. During search, the engine uses incremental updates.}
var
  r, c: integer;
  P: TPiece;
begin
  Result := 0;
  for r := 0 to 7 do
    for c := 0 to 7 do
    begin
      P := State.Board[r, c];
      if P <> EMPTY then
        Result := Result xor ZobristPiece[Ord(P), r, c];
    end;
  if State.SideToMove = 1 then Result := Result xor ZobristSide;
  Result := Result xor ZobristCastle[State.CastleMask];
  if State.EPC <> -1 then Result := Result xor ZobristEP[State.EPC];
end;


function ComputePawnHash: QWord;
{**Calculates the pawn-only Zobrist key from scratch (v1.00-rc8).**

 This is the pawn-hash-table analogue of ComputeHash: it XORs together the
 SAME ZobristPiece constants that the full key uses, but only for the white
 and black pawns, and deliberately omits side-to-move, castling and en-passant
 terms — PASS 3 of Evaluate depends on none of those. Two positions with the
 identical pawn skeleton therefore share a pawn key even if they differ in
 side to move or castling rights, which is exactly what makes the >95% hit
 rate possible.

 Slow (scans both pawn bitboards), so like ComputeHash it is only called at
 setup time (InitState / ParseFEN). During search the key is maintained
 incrementally in DoMakeMove.}
var
  bb: QWord;
  sq, r, c: integer;
begin
  Result := 0;
  // White pawns
  bb := State.Pieces[wP];
  while bb <> 0 do
  begin
    sq := Integer(BsfQWord(bb));
    bb := bb and (bb - 1);
    SquareCoords(sq, r, c);
    Result := Result xor ZobristPiece[Ord(wP), r, c];
  end;
  // Black pawns
  bb := State.Pieces[bP];
  while bb <> 0 do
  begin
    sq := Integer(BsfQWord(bb));
    bb := bb and (bb - 1);
    SquareCoords(sq, r, c);
    Result := Result xor ZobristPiece[Ord(bP), r, c];
  end;
end;


procedure InitPawnHash;
{**Allocates and clears the pawn hash table (v1.00-rc8).**
 Called once at program startup. The table is a fixed power-of-two size
 (PAWN_HASH_SIZE) and is never resized afterwards, so unlike the TT there is
 no runtime ResizeHash counterpart — a single SetLength here is enough.}
begin
  SetLength(PawnHashTable, PAWN_HASH_SIZE);
end;


procedure ClearPawnTT;
{**Empties the pawn hash table (v1.00-rc8).**
 Zeroing the record array sets Key = 0 and Valid = False in every slot, so no
 stale entry from a previous position/game can be read as a hit. Called at the
 same points as ClearTT (new game / 'ucinewgame'), keeping the two caches in
 sync — a pawn-structure delta from a different game is never reused.}
begin
  if Length(PawnHashTable) > 0 then
    FillChar(PawnHashTable[0],
             SizeInt(Length(PawnHashTable)) * SizeInt(SizeOf(TPawnHashEntry)), 0);
end;


procedure ClearTT;
{**Zero the transposition table.**
 Replaces the v0996 pattern FillChar(TT, SizeOf(TT), 0), which relied on the
 TT being a static array of compile-time-known size. With the v0997 dynamic
 TT (resizable at runtime via 'setoption name Hash value N'), the size is
 only known at runtime, so we go through Length(TT) and SizeOf(TTTEntry).
 Guards against an empty array — calling FillChar(TT[0],...) on a zero-length
 dynamic array dereferences an unallocated pointer.}
begin
  if Length(TT) > 0 then
    FillChar(TT[0], SizeInt(Length(TT)) * SizeInt(SizeOf(TTTEntry)), 0);
end;


procedure ResizeHash(NewSizeMB: integer);
{**Reallocate the transposition table to approximately NewSizeMB megabytes.**
 The actual entry count is rounded DOWN to the largest power of 2 that fits
 within the requested byte budget, so TTMask = TTSize - 1 stays a simple
 bitmask. The table is fully cleared after resize — any previously stored
 entries are discarded, which is correct because the new mask would alias
 old entries into wrong slots anyway.

 Out-of-range MB values are silently clamped to the UCI-advertised range
 [HASH_MIN_MB..HASH_MAX_MB] rather than rejected, matching what most GUIs
 expect (they will not retry on rejection).

 Called once at startup with HASH_DEFAULT_MB, and again on every UCI
 'setoption name Hash value N' command. Allocation cost is one SetLength
 call plus one FillChar over the new region — both O(N) in entries, but
 only done at game start and on explicit hash changes, never inside
 Search.}
var
  EntrySize, TargetEntries, NewEntries: int64;
begin
  // Clamp to advertised range
  if NewSizeMB < HASH_MIN_MB then NewSizeMB := HASH_MIN_MB;
  if NewSizeMB > HASH_MAX_MB then NewSizeMB := HASH_MAX_MB;

  EntrySize := SizeOf(TTTEntry);

  // How many entries fit in the requested byte budget, before power-of-2
  // rounding. int64 arithmetic to avoid overflow for the largest sizes.
  TargetEntries := (int64(NewSizeMB) * 1024 * 1024) div EntrySize;

  // Round DOWN to the nearest power of 2. HASH_MIN_MB = 1 guarantees
  // TargetEntries >= 1 for any reasonable EntrySize, so the loop produces
  // at least NewEntries = 1.
  NewEntries := 1;
  while (NewEntries * 2) <= TargetEntries do
    NewEntries := NewEntries * 2;

  SetLength(TT, NewEntries);
  TTMask := QWord(NewEntries - 1);

  ClearTT;
end;


procedure InitState;
var
  r, c: integer;
begin
  for r := 0 to 7 do for c := 0 to 7 do State.Board[r, c] := EMPTY;
  State.Board[0, 0] := bR; State.Board[0, 1] := bN; State.Board[0, 2] := bB;
  State.Board[0, 3] := bQ; State.Board[0, 4] := bK; State.Board[0, 5] := bB;
  State.Board[0, 6] := bN; State.Board[0, 7] := bR;
  for c := 0 to 7 do State.Board[1, c] := bP;
  for c := 0 to 7 do State.Board[6, c] := wP;
  State.Board[7, 0] := wR; State.Board[7, 1] := wN; State.Board[7, 2] := wB;
  State.Board[7, 3] := wQ; State.Board[7, 4] := wK; State.Board[7, 5] := wB;
  State.Board[7, 6] := wN; State.Board[7, 7] := wR;
  State.SideToMove := 0;
  State.CastleMask := CM_WK or CM_WQ or CM_BK or CM_BQ;
  State.EPR := -1;
  State.EPC := -1;
  State.WhiteKingR := 7; State.WhiteKingC := 4;
  State.BlackKingR := 0; State.BlackKingC := 4;
  State.HalfMoveClock := 0;
  State.FullMoveNumber := 1; // v1.00-rc3: start position is full move 1
  State.Hash := ComputeHash;
  State.GamePly := 0;
  GameHistory[0] := State.Hash;
  FillChar(Killers, SizeOf(Killers), 0);
  FillChar(History, SizeOf(History), 0);

  RebuildBitboardsFromBoard; // v0967: derive bitboards from the freshly-filled mailbox
  // v1.00-rc8: pawn key computed AFTER the bitboards exist (ComputePawnHash
  // scans State.Pieces[wP]/[bP], which RebuildBitboardsFromBoard just filled).
  State.PawnHash := ComputePawnHash;
end;


function IsAttacked_mailbox(r, c, BySide: integer): boolean;
{**Determines if a square is attacked by any piece of a given side.**
This critical function checks if a square (row,column) is under attack by
White (BySide=0) or Black (BySide=1).
It tests:
- Pawn attacks (diagonally forward, direction depends on side)
- Knight attacks (8 possible squares)
- King attacks (8 adjacent squares)
- Rook/Queen orthogonal attacks (4 directions, indices 0..3 in SlideDR/DC)
- Bishop/Queen diagonal attacks (4 directions, indices 4..7 in SlideDR/DC)

The function returns True immediately when any attack is found (early exit).
This is used for:
- Checking if king is in check
- Validating castling (can't castle through/into check)
- Determining checkmate/stalemate

Speed notes:
- Target piece variables are set once at the top, eliminating a BySide branch
  inside every loop iteration.
- Pawn attacks are checked before the loops so the common no-pawn case exits
  immediately without entering any loop.
- Bounds checking uses Cardinal() cast: a negative integer becomes a very
  large unsigned value, so (Cardinal(x) <= 7) catches both x < 0 and x > 7
  in a single comparison, halving the number of branch instructions.
- The sliding piece loop runs indices 0..7 in one pass; indices 0..3 are
  orthogonal (rook/queen) and 4..7 are diagonal (bishop/queen), matching
  the layout of SlideDR/SlideDC.}
var
  i, tr, tc: integer;
  P: TPiece;
  TargetN, TargetK, TargetR, TargetB, TargetQ: TPiece;
  TargetRQ, TargetBQ: boolean; // Sliding piece match flags
begin
  // Set up target piece types for the attacking side once, eliminating
  // repeated BySide checks inside every loop that follows.
  if BySide = 0 then
  begin
    TargetN := wN; TargetK := wK; TargetR := wR; TargetB := wB; TargetQ := wQ;

    // Pawn attacks - White pawns stand on higher row numbers and attack diagonally
    // downward toward lower row numbers. A white pawn at (r+1, c±1) attacks (r, c).
    if r < 7 then
    begin
      if (c > 0) and (State.Board[r + 1, c - 1] = wP) then Exit(True);
      if (c < 7) and (State.Board[r + 1, c + 1] = wP) then Exit(True);
    end;
  end
  else
  begin
    TargetN := bN; TargetK := bK; TargetR := bR; TargetB := bB; TargetQ := bQ;

    // Pawn attacks - Black pawns stand on lower row numbers and attack diagonally
    // upward toward higher row numbers. A black pawn at (r-1, c±1) attacks (r, c).
    if r > 0 then
    begin
      if (c > 0) and (State.Board[r - 1, c - 1] = bP) then Exit(True);
      if (c < 7) and (State.Board[r - 1, c + 1] = bP) then Exit(True);
    end;
  end;

  // Knight attacks: up to 8 L-shaped jumps from the target square.
  // Cardinal() cast turns negative offsets into large unsigned values so
  // a single <= 7 check covers both out-of-range directions at once.
  for i := 0 to 7 do
  begin
    tr := r + KnightDR[i];
    tc := c + KnightDC[i];
    if (Cardinal(tr) <= 7) and (Cardinal(tc) <= 7) then
      if State.Board[tr, tc] = TargetN then Exit(True);
  end;

  // King attacks: 8 adjacent squares (used when checking if a king move is safe,
  // and to prevent kings from standing next to each other).
  for i := 0 to 7 do
  begin
    tr := r + KingDR[i];
    tc := c + KingDC[i];
    if (Cardinal(tr) <= 7) and (Cardinal(tc) <= 7) then
      if State.Board[tr, tc] = TargetK then Exit(True);
  end;

  // Sliding piece attacks (rooks, bishops, queens) in all 8 directions.
  // SlideDR/SlideDC layout: indices 0..3 = orthogonal (rook/queen lines),
  //                          indices 4..7 = diagonal (bishop/queen lines).
  // Running both in one loop avoids a separate loop setup for each group.
  // The relevant attacker for each direction is checked with explicit
  // comparisons against the pre-set Target variables (no BySide branch needed).
  for i := 0 to 7 do
  begin
    tr := r + SlideDR[i];
    tc := c + SlideDC[i];
    // Determine which sliding pieces can attack along this ray.
    // Orthogonal rays (i=0..3): rook or queen. Diagonal rays (i=4..7): bishop or queen.
    TargetRQ := i <= 3; // True for orthogonal directions
    TargetBQ := i >= 4; // True for diagonal directions
    while (Cardinal(tr) <= 7) and (Cardinal(tc) <= 7) do
    begin
      P := State.Board[tr, tc];
      if P <> EMPTY then
      begin
        if TargetRQ and ((P = TargetR) or (P = TargetQ)) then Exit(True);
        if TargetBQ and ((P = TargetB) or (P = TargetQ)) then Exit(True);
        Break; // Any piece (even a friendly one) blocks the ray
      end;
      tr := tr + SlideDR[i];
      tc := tc + SlideDC[i];
    end;
  end;

  Result := False;
end;


function IsAttacked(r, c, BySide: integer): boolean;
{**Bitboard implementation. Equivalent to IsAttacked_Mailbox; tested via
   perft and the validation harness. See IsAttacked_Mailbox above for
   the original algorithm description.

   Strategy:
     1. Pawn/knight/king: single precomputed-mask AND against the side's
        piece bitboard. Three branchless tests, returns early on hit.
     2. Sliders: RayMask + nearest-blocker bit-scan (BSF for "positive"
        LERF directions, BSR for "negative"), single bit-AND against the
        side's rook/queen or bishop/queen bitboard. No ray-walk loop.

   v0976: slider scan rewritten to use RayMask + BsfQWord/BsrQWord, the
   same technique already used by the slider move generator (v0970) and
   by SEE's FindLVA (v0974). The mailbox is no longer consulted anywhere
   in IsAttacked. This is purely a speed change — the answer for every
   (r, c, BySide) is mathematically identical to the previous version.}
var
  sq: integer;
  pawns, knights, kingBB, bishopsQueens, rooksQueens: QWord;
begin
  sq := SquareIndex(r, c);

  if BySide = 0 then
  begin
    pawns         := State.Pieces[wP];
    knights       := State.Pieces[wN];
    kingBB        := State.Pieces[wK];
    bishopsQueens := State.Pieces[wB] or State.Pieces[wQ];
    rooksQueens   := State.Pieces[wR] or State.Pieces[wQ];
  end
  else
  begin
    pawns         := State.Pieces[bP];
    knights       := State.Pieces[bN];
    kingBB        := State.Pieces[bK];
    bishopsQueens := State.Pieces[bB] or State.Pieces[bQ];
    rooksQueens   := State.Pieces[bR] or State.Pieces[bQ];
  end;

  if (PawnAttacks[BySide, sq] and pawns)   <> 0 then Exit(True);
  if (KnightAttacks[sq]      and knights)  <> 0 then Exit(True);
  if (KingAttacks[sq]        and kingBB)   <> 0 then Exit(True);

  // Sliders via plain magic lookup (v1.00-rc7). One table probe per
  // line type replaces the eight per-ray nearest-blocker scans. The
  // probed set contains exactly the first occupied square in every
  // direction, so ANDing it with the side's rook/queen (orthogonal) or
  // bishop/queen (diagonal) bitboard is the same test the per-ray
  // version performed - a slider anywhere in the set attacks sq.
  if (RookAttacksBB(sq, State.AllOccupied)   and rooksQueens)   <> 0 then Exit(True);
  if (BishopAttacksBB(sq, State.AllOccupied) and bishopsQueens) <> 0 then Exit(True);

  Result := False;
end;




function AttackSelfTest: boolean;
{**v1.00-rc8a self-test: the mailbox attack oracle (IsAttacked_mailbox) is an
 INDEPENDENT reference for the live magic-bitboard IsAttacked — they share no
 slider code, so a bad magic constant cannot hide behind a common bug. This
 walks every square x both sides on the CURRENT position and asserts the two
 agree; it also runs VerifyBitboards to confirm the mailbox and bitboards are
 in sync (the precondition that makes the oracle valid). Returns True on
 success, False (with a diagnostic line) on any disagreement. Called from
 'go perftauto' after each ParseFEN.}
var
  rr, cc, bs: integer;
begin
  Result := True;
  VerifyBitboards('AttackSelfTest'); // halts on mailbox/bitboard divergence
  for bs := 0 to 1 do
    for rr := 0 to 7 do
      for cc := 0 to 7 do
        if IsAttacked_mailbox(rr, cc, bs) <> IsAttacked(rr, cc, bs) then
        begin
          WriteLn('AttackSelfTest MISMATCH sq=(', rr, ',', cc, ') by=', bs,
                  ' mailbox=', IsAttacked_mailbox(rr, cc, bs),
                  ' magic=', IsAttacked(rr, cc, bs));
          Result := False;
        end;
end;



function IsInCheck(Side: integer): boolean;
begin
  if Side = 0 then Exit(IsAttacked(State.WhiteKingR, State.WhiteKingC, 1))
  else Exit(IsAttacked(State.BlackKingR, State.BlackKingC, 0));
end;


procedure GeneratePseudoLegalMoves(out Moves: TMoveList; out MoveCount: integer;  CapturesOnly: boolean = False);
{**Generates all pseudo-legal moves without checking if they leave the king in check.**
This is a fast move generator that ignores king safety. It generates:
- Pawn moves (single/double pushes, captures, promotions, en passant)
- Knight moves (all 8 L-shaped jumps)
- Sliding piece moves (bishop, rook, queen using direction vectors)
- King moves and castling (with square emptiness checks)
The `CapturesOnly` parameter allows generating only capturing moves (used in quiescence search). Moves are stored in a TMoveList array with from/to coordinates, promotion piece, and move type.

v0968: knight move generation has been moved out of the per-square case
statement and into a bitboard block at the top of the procedure. The
move set is identical to v0967; only the iteration order within knight
moves differs (low-bit-first vs row-by-row). All other piece types
continue to use the mailbox case statement and will be migrated to
bitboards in subsequent versions.

v0969: king non-castling moves have been moved out of the wK/bK case
statements into a second bitboard block at the top of the procedure.
The destination mask is KingAttacks[from] AND NOT own_occupancy,
further restricted to enemy_occupancy in CapturesOnly mode.

v0970: bishop, rook, and queen moves have been moved out of the
wB/bB/wR/bR/wQ/bQ case into a third bitboard block at the top of the
procedure, using the classical ray-walk technique (RayMask + BSF/BSR
blocker selection, XOR-trim past blocker, mask own-piece blocker).
No magic bitboards yet.

v0971: pawn pushes (single, double, promotion-by-push) have been moved
out of the wP/bP cases into a fourth bitboard block at the top of the
procedure, using shifts and rank masks. Promotion pushes are always
generated, including in CapturesOnly mode.

v0972: pawn captures (left, right, en-passant, capture-promotion) have
been moved out of the wP/bP cases into a fifth bitboard block at the
top of the procedure, using shifts and file masks. After v0972 the
mailbox case statement contained only wK and bK (castling-only).

v0973: castling has been lifted out of the wK/bK mailbox cases. Path
emptiness is now tested via constant bitboard masks
(CM_WK_EMPTY / CM_WQ_EMPTY / CM_BK_EMPTY / CM_BQ_EMPTY) AND'd against
State.AllOccupied. Path safety still uses IsAttacked with mailbox
coordinates. The king's home-square check is implicit in the
CastleMask bits (any king move clears them), so no explicit
king-position test is needed. After this version the entire
mailbox iteration loop (for r := 0 to 7 do for c := 0 to 7 do) and
its case statement are gone — move generation is now fully bitboard-
driven.}
var
  tr, tc, d, StartDir, EndDir: integer;
  r, c: integer;
  // v0968 — bitboard knight generation
  // v0969 — bitboard king (non-castling) generation
  // v0970 — bitboard sliding (B/R/Q) generation
  // v0971 — bitboard pawn-push generation
  // v0972 — bitboard pawn-capture generation
  KnightBB, KingBB, SlidersBB, PawnBB: QWord;
  EmptyBB, PushOnce, PushTwice: QWord;
  CapTargets, EPTargetBB: QWord;
  Targets, Attacks, OwnOcc, EnemyOcc: QWord;
  FromSq, ToSq, SlideKind: integer;

  procedure AddMove(FR, FC, TR, TC: integer; Promo: TPiece; MT: TMoveType);
  begin
    if MoveCount >= 256 then Exit; // Array is [0..255], max index 255
    Moves[MoveCount] := NewMove(FR, FC, TR, TC, Promo, MT);
    Inc(MoveCount);
  end;

begin
  MoveCount := 0;

  // =====================================================================
  // v0968 — Bitboard knight move generation.
  // For each knight of the side-to-move:
  //   destinations := KnightAttacks[from] AND NOT own_occupancy
  // In CapturesOnly mode the destinations are further restricted to
  // enemy_occupancy. The mailbox wN/bN case has been removed below.
  // Iteration order is low-bit-first (rank 1 -> rank 8), which differs
  // from the mailbox loop's row-by-row order; the move set is identical.
  // =====================================================================
  OwnOcc   := State.Occupied[State.SideToMove];
  EnemyOcc := State.Occupied[1 - State.SideToMove];
  if State.SideToMove = 0 then KnightBB := State.Pieces[wN]
                          else KnightBB := State.Pieces[bN];

  while KnightBB <> 0 do
  begin
    FromSq   := BsfQWord(KnightBB);
    KnightBB := KnightBB and (KnightBB - 1); // clear lowest bit
    SquareCoords(FromSq, r, c);
    Targets  := KnightAttacks[FromSq] and not OwnOcc;
    if CapturesOnly then
      Targets := Targets and EnemyOcc;
    while Targets <> 0 do
    begin
      ToSq    := BsfQWord(Targets);
      Targets := Targets and (Targets - 1);
      SquareCoords(ToSq, tr, tc);
      AddMove(r, c, tr, tc, EMPTY, MT_NORMAL);
    end;
  end;

  // =====================================================================
  // v0969 — Bitboard king (non-castling) move generation.
  // For the king of the side-to-move (exactly one bit set in any legal
  // position):
  //   destinations := KingAttacks[from] AND NOT own_occupancy
  // In CapturesOnly mode the destinations are further restricted to
  // enemy_occupancy. The eight-direction adjacency loop has been removed
  // from the wK/bK mailbox cases; only castling remains there.
  // OwnOcc/EnemyOcc are reused from the knight block above — same
  // side-to-move, no state change between the two blocks.
  // Iteration order is low-bit-first within KingAttacks[from], which
  // differs from the previous KingDR/KingDC[0..7] array order; the
  // move set is identical.
  // =====================================================================
  if State.SideToMove = 0 then KingBB := State.Pieces[wK]
                          else KingBB := State.Pieces[bK];

  while KingBB <> 0 do
  begin
    FromSq := BsfQWord(KingBB);
    KingBB := KingBB and (KingBB - 1); // clear lowest bit
    SquareCoords(FromSq, r, c);
    Targets := KingAttacks[FromSq] and not OwnOcc;
    if CapturesOnly then
      Targets := Targets and EnemyOcc;
    while Targets <> 0 do
    begin
      ToSq    := BsfQWord(Targets);
      Targets := Targets and (Targets - 1);
      SquareCoords(ToSq, tr, tc);
      AddMove(r, c, tr, tc, EMPTY, MT_NORMAL);
    end;
  end;

  // =====================================================================
  // v0970 — Bitboard sliding move generation (B, R, Q).
  // v1.00-rc6 — the classical per-ray nearest-blocker scan is replaced
  // by ONE plain-magic table probe per slider:
  //   Attacks := Bishop/Rook/QueenAttacksBB(FromSq, State.AllOccupied)
  //   Attacks := Attacks and not OwnOcc            { drop own-piece blocker }
  //   if CapturesOnly then Attacks := Attacks and EnemyOcc
  // Emission then walks the SAME direction loop as before, restricting
  // the probed set to one ray at a time (Attacks AND RayMask[d, FromSq])
  // and popping bits low-to-high within the ray. This reproduces the
  // pre-rc6 move ordering EXACTLY (per-direction blocks d = StartDir..
  // EndDir, bit-ascending inside each block), which matters because the
  // selection sort in the search breaks equal-score ties by generation
  // order - emitting in global bit order instead would silently change
  // node counts. Three sub-blocks selected by SlideKind:
  //   0: bishops, directions 4..7 (diagonals)
  //   1: rooks,   directions 0..3 (orthogonals)
  //   2: queens,  directions 0..7 (both)
  // OwnOcc/EnemyOcc are reused from the knight block; AllOccupied is the
  // full board occupancy.
  // Promoted queens/rooks/bishops are picked up automatically because
  // DoMakeMove updates the appropriate Pieces[] entry on promotion.
  // =====================================================================
  for SlideKind := 0 to 2 do
  begin
    case SlideKind of
      0: begin // Bishops — diagonals only.
        if State.SideToMove = 0 then SlidersBB := State.Pieces[wB]
                                else SlidersBB := State.Pieces[bB];
        StartDir := 4; EndDir := 7;
      end;
      1: begin // Rooks — orthogonals only.
        if State.SideToMove = 0 then SlidersBB := State.Pieces[wR]
                                else SlidersBB := State.Pieces[bR];
        StartDir := 0; EndDir := 3;
      end;
      2: begin // Queens — all eight directions.
        if State.SideToMove = 0 then SlidersBB := State.Pieces[wQ]
                                else SlidersBB := State.Pieces[bQ];
        StartDir := 0; EndDir := 7;
      end;
      else
        begin
          SlidersBB := 0; StartDir := 0; EndDir := -1;   // empty loop
        end;
    end;

    while SlidersBB <> 0 do
    begin
      FromSq    := BsfQWord(SlidersBB);
      SlidersBB := SlidersBB and (SlidersBB - 1); // clear lowest bit
      SquareCoords(FromSq, r, c);

      // v1.00-rc6: one magic probe for the whole piece...
      case SlideKind of
        0:   Attacks := BishopAttacksBB(FromSq, State.AllOccupied);
        1:   Attacks := RookAttacksBB(FromSq, State.AllOccupied);
        else Attacks := QueenAttacksBB(FromSq, State.AllOccupied);
      end;
      Attacks := Attacks and not OwnOcc;
      if CapturesOnly then
        Attacks := Attacks and EnemyOcc;

      // ...emitted per ray to preserve the pre-rc6 move order exactly.
      for d := StartDir to EndDir do
      begin
        Targets := Attacks and RayMask[d, FromSq];
        while Targets <> 0 do
        begin
          ToSq    := BsfQWord(Targets);
          Targets := Targets and (Targets - 1);
          SquareCoords(ToSq, tr, tc);
          AddMove(r, c, tr, tc, EMPTY, MT_NORMAL);
        end;
      end;
    end;
  end;

  // =====================================================================
  // v0971 — Bitboard pawn-push generation (single, double, promotion-by-push).
  // Push direction is color-dependent, so this block has two arms.
  //   White: PushOnce := (Pieces[wP] shl 8) and not AllOccupied
  //   Black: PushOnce := (Pieces[bP] shr 8) and not AllOccupied
  // Promotion-rank destinations (rank 8 white, rank 1 black) are emitted
  // with all four promotion pieces, ALWAYS — including in CapturesOnly
  // mode, matching the previous mailbox behavior. Non-promotion single
  // pushes and double pushes are skipped when CapturesOnly is true.
  // Double-push uses the trick: only pawns originally on the starting
  // rank can produce a single-push target on the 3rd rank (white) or
  // 6th rank (black). Filter PushOnce by that rank mask, shift up one
  // more rank, mask against empty squares.
  // From-square mailbox coordinates are derived directly from the
  // destination's mailbox row: r := tr + 1 (white single), tr + 2
  // (white double), tr - 1 (black single), tr - 2 (black double).
  // EmptyBB is computed once and reused for both PushOnce and PushTwice.
  // =====================================================================
  EmptyBB := not State.AllOccupied;

  if State.SideToMove = 0 then
  begin
    // White pawn pushes
    PawnBB   := State.Pieces[wP];
    PushOnce := (PawnBB shl 8) and EmptyBB;

    // Promotion pushes (always generated, including under CapturesOnly).
    Targets := PushOnce and RankMask[7];
    while Targets <> 0 do
    begin
      ToSq    := BsfQWord(Targets);
      Targets := Targets and (Targets - 1);
      SquareCoords(ToSq, tr, tc);
      AddMove(tr + 1, tc, tr, tc, wQ, MT_NORMAL);
      AddMove(tr + 1, tc, tr, tc, wR, MT_NORMAL);
      AddMove(tr + 1, tc, tr, tc, wB, MT_NORMAL);
      AddMove(tr + 1, tc, tr, tc, wN, MT_NORMAL);
    end;

    if not CapturesOnly then
    begin
      // Non-promotion single pushes
      Targets := PushOnce and not RankMask[7];
      while Targets <> 0 do
      begin
        ToSq    := BsfQWord(Targets);
        Targets := Targets and (Targets - 1);
        SquareCoords(ToSq, tr, tc);
        AddMove(tr + 1, tc, tr, tc, EMPTY, MT_NORMAL);
      end;

      // Double pushes: single-push targets on rank 3 came from rank 2
      // pawns; shift up one more rank, must be empty.
      PushTwice := ((PushOnce and RankMask[2]) shl 8) and EmptyBB;
      while PushTwice <> 0 do
      begin
        ToSq      := BsfQWord(PushTwice);
        PushTwice := PushTwice and (PushTwice - 1);
        SquareCoords(ToSq, tr, tc);
        AddMove(tr + 2, tc, tr, tc, EMPTY, MT_NORMAL);
      end;
    end;
  end
  else
  begin
    // Black pawn pushes
    PawnBB   := State.Pieces[bP];
    PushOnce := (PawnBB shr 8) and EmptyBB;

    // Promotion pushes (always generated, including under CapturesOnly).
    Targets := PushOnce and RankMask[0];
    while Targets <> 0 do
    begin
      ToSq    := BsfQWord(Targets);
      Targets := Targets and (Targets - 1);
      SquareCoords(ToSq, tr, tc);
      AddMove(tr - 1, tc, tr, tc, bQ, MT_NORMAL);
      AddMove(tr - 1, tc, tr, tc, bR, MT_NORMAL);
      AddMove(tr - 1, tc, tr, tc, bB, MT_NORMAL);
      AddMove(tr - 1, tc, tr, tc, bN, MT_NORMAL);
    end;

    if not CapturesOnly then
    begin
      // Non-promotion single pushes
      Targets := PushOnce and not RankMask[0];
      while Targets <> 0 do
      begin
        ToSq    := BsfQWord(Targets);
        Targets := Targets and (Targets - 1);
        SquareCoords(ToSq, tr, tc);
        AddMove(tr - 1, tc, tr, tc, EMPTY, MT_NORMAL);
      end;

      // Double pushes: single-push targets on rank 6 came from rank 7
      // pawns; shift down one more rank, must be empty.
      PushTwice := ((PushOnce and RankMask[5]) shr 8) and EmptyBB;
      while PushTwice <> 0 do
      begin
        ToSq      := BsfQWord(PushTwice);
        PushTwice := PushTwice and (PushTwice - 1);
        SquareCoords(ToSq, tr, tc);
        AddMove(tr - 2, tc, tr, tc, EMPTY, MT_NORMAL);
      end;
    end;
  end;

  // =====================================================================
  // v0972 — Bitboard pawn-capture generation (left, right, en-passant,
  // capture-promotion). Two arms by side-to-move because shift directions
  // differ.
  //
  //   White "captures left"  (NW, shl 7): pawns NOT on FileMask[0]
  //   White "captures right" (NE, shl 9): pawns NOT on FileMask[7]
  //   Black "captures left"  (SW, shr 9): pawns NOT on FileMask[0]
  //   Black "captures right" (SE, shr 7): pawns NOT on FileMask[7]
  //
  // The source-side file mask prevents wraparound: a pawn on the A-file
  // shifted by +7 would land on the H-file one rank up, which is wrong;
  // masking off the A-file before the shift suppresses that. Mirror
  // logic for the H-file and the opposite-diagonal shifts.
  //
  // Destination mask is EnemyOcc OR EPTargetBB, where EPTargetBB is the
  // single bit of State.EPR/EPC if EP is available, else 0. The EP
  // target square is by definition empty (the enemy pawn passed through
  // it on its double push), so the union has no overlap.
  //
  // Per destination, source mailbox coords come from the destination's
  // (tr, tc):
  //   White NW: source = (tr + 1, tc + 1)
  //   White NE: source = (tr + 1, tc - 1)
  //   Black SW: source = (tr - 1, tc + 1)
  //   Black SE: source = (tr - 1, tc - 1)
  //
  // Move-type dispatch per destination:
  //   - EP target square (tr=EPR, tc=EPC) → MT_EN_PASSANT
  //   - Promotion rank (tr=0 white / tr=7 black) → four MT_NORMAL with Q/R/B/N
  //   - Otherwise → MT_NORMAL
  // Promotion ranks (8/1) and EP ranks (6/3) are disjoint, so the
  // check order is irrelevant for correctness.
  //
  // All pawn captures are emitted unconditionally — they are captures
  // by definition, never gated by CapturesOnly. Matches the previous
  // mailbox behavior.
  //
  // EnemyOcc is reused from the knight block. PawnBB is rebound here
  // (the v0971 push block leaves it set to the same side's pawns, but
  // we re-fetch for clarity).
  // =====================================================================
  if State.EPR >= 0 then
    EPTargetBB := QWord(1) shl SquareIndex(State.EPR, State.EPC)
  else
    EPTargetBB := 0;
  CapTargets := EnemyOcc or EPTargetBB;

  if State.SideToMove = 0 then
  begin
    // White pawn captures
    PawnBB := State.Pieces[wP];

    // "Captures left" — NW (shl 7), source pawns not on A-file.
    Targets := ((PawnBB and not FileMask[0]) shl 7) and CapTargets;
    while Targets <> 0 do
    begin
      ToSq    := BsfQWord(Targets);
      Targets := Targets and (Targets - 1);
      SquareCoords(ToSq, tr, tc);
      if (tr = State.EPR) and (tc = State.EPC) then
        AddMove(tr + 1, tc + 1, tr, tc, EMPTY, MT_EN_PASSANT)
      else if tr = 0 then // Promotion with capture
      begin
        AddMove(tr + 1, tc + 1, tr, tc, wQ, MT_NORMAL);
        AddMove(tr + 1, tc + 1, tr, tc, wR, MT_NORMAL);
        AddMove(tr + 1, tc + 1, tr, tc, wB, MT_NORMAL);
        AddMove(tr + 1, tc + 1, tr, tc, wN, MT_NORMAL);
      end
      else
        AddMove(tr + 1, tc + 1, tr, tc, EMPTY, MT_NORMAL);
    end;

    // "Captures right" — NE (shl 9), source pawns not on H-file.
    Targets := ((PawnBB and not FileMask[7]) shl 9) and CapTargets;
    while Targets <> 0 do
    begin
      ToSq    := BsfQWord(Targets);
      Targets := Targets and (Targets - 1);
      SquareCoords(ToSq, tr, tc);
      if (tr = State.EPR) and (tc = State.EPC) then
        AddMove(tr + 1, tc - 1, tr, tc, EMPTY, MT_EN_PASSANT)
      else if tr = 0 then // Promotion with capture
      begin
        AddMove(tr + 1, tc - 1, tr, tc, wQ, MT_NORMAL);
        AddMove(tr + 1, tc - 1, tr, tc, wR, MT_NORMAL);
        AddMove(tr + 1, tc - 1, tr, tc, wB, MT_NORMAL);
        AddMove(tr + 1, tc - 1, tr, tc, wN, MT_NORMAL);
      end
      else
        AddMove(tr + 1, tc - 1, tr, tc, EMPTY, MT_NORMAL);
    end;
  end
  else
  begin
    // Black pawn captures
    PawnBB := State.Pieces[bP];

    // "Captures left" — SW (shr 9), source pawns not on A-file.
    Targets := ((PawnBB and not FileMask[0]) shr 9) and CapTargets;
    while Targets <> 0 do
    begin
      ToSq    := BsfQWord(Targets);
      Targets := Targets and (Targets - 1);
      SquareCoords(ToSq, tr, tc);
      if (tr = State.EPR) and (tc = State.EPC) then
        AddMove(tr - 1, tc + 1, tr, tc, EMPTY, MT_EN_PASSANT)
      else if tr = 7 then // Promotion with capture
      begin
        AddMove(tr - 1, tc + 1, tr, tc, bQ, MT_NORMAL);
        AddMove(tr - 1, tc + 1, tr, tc, bR, MT_NORMAL);
        AddMove(tr - 1, tc + 1, tr, tc, bB, MT_NORMAL);
        AddMove(tr - 1, tc + 1, tr, tc, bN, MT_NORMAL);
      end
      else
        AddMove(tr - 1, tc + 1, tr, tc, EMPTY, MT_NORMAL);
    end;

    // "Captures right" — SE (shr 7), source pawns not on H-file.
    Targets := ((PawnBB and not FileMask[7]) shr 7) and CapTargets;
    while Targets <> 0 do
    begin
      ToSq    := BsfQWord(Targets);
      Targets := Targets and (Targets - 1);
      SquareCoords(ToSq, tr, tc);
      if (tr = State.EPR) and (tc = State.EPC) then
        AddMove(tr - 1, tc - 1, tr, tc, EMPTY, MT_EN_PASSANT)
      else if tr = 7 then // Promotion with capture
      begin
        AddMove(tr - 1, tc - 1, tr, tc, bQ, MT_NORMAL);
        AddMove(tr - 1, tc - 1, tr, tc, bR, MT_NORMAL);
        AddMove(tr - 1, tc - 1, tr, tc, bB, MT_NORMAL);
        AddMove(tr - 1, tc - 1, tr, tc, bN, MT_NORMAL);
      end
      else
        AddMove(tr - 1, tc - 1, tr, tc, EMPTY, MT_NORMAL);
    end;
  end;

  // =====================================================================
  // v0973 — Bitboard castling.
  // Path emptiness via constant bitboard masks AND'd against AllOccupied.
  // Path safety via IsAttacked on mailbox coords (unchanged from earlier
  // versions — castling is the only consumer of IsAttacked in this
  // procedure, and migrating IsAttacked itself is out of scope here).
  // King home-square is implicit in CastleMask (any king move clears
  // CM_W* or CM_B* respectively, so a set bit guarantees the king is
  // still on e1/e8). Same for the rook home squares vs CM_xQ/CM_xK.
  // Skipped entirely in CapturesOnly mode (castling is not a capture).
  // After this block the procedure has no mailbox iteration at all.
  // =====================================================================
  if not CapturesOnly then
  begin
    if State.SideToMove = 0 then
    begin
      // White king-side: f1, g1 empty; e1, f1, g1 not attacked.
      if ((State.CastleMask and CM_WK) <> 0) and
         ((State.AllOccupied and CM_WK_EMPTY) = 0) then
        if not IsAttacked(7, 4, 1) and not IsAttacked(7, 5, 1) and
           not IsAttacked(7, 6, 1) then
          AddMove(7, 4, 7, 6, EMPTY, MT_CASTLE_WK);
      // White queen-side: b1, c1, d1 empty; e1, d1, c1 not attacked.
      if ((State.CastleMask and CM_WQ) <> 0) and
         ((State.AllOccupied and CM_WQ_EMPTY) = 0) then
        if not IsAttacked(7, 4, 1) and not IsAttacked(7, 3, 1) and
           not IsAttacked(7, 2, 1) then
          AddMove(7, 4, 7, 2, EMPTY, MT_CASTLE_WQ);
    end
    else
    begin
      // Black king-side: f8, g8 empty; e8, f8, g8 not attacked.
      if ((State.CastleMask and CM_BK) <> 0) and
         ((State.AllOccupied and CM_BK_EMPTY) = 0) then
        if not IsAttacked(0, 4, 0) and not IsAttacked(0, 5, 0) and
           not IsAttacked(0, 6, 0) then
          AddMove(0, 4, 0, 6, EMPTY, MT_CASTLE_BK);
      // Black queen-side: b8, c8, d8 empty; e8, d8, c8 not attacked.
      if ((State.CastleMask and CM_BQ) <> 0) and
         ((State.AllOccupied and CM_BQ_EMPTY) = 0) then
        if not IsAttacked(0, 4, 0) and not IsAttacked(0, 3, 0) and
           not IsAttacked(0, 2, 0) then
          AddMove(0, 4, 0, 2, EMPTY, MT_CASTLE_BQ);
    end;
  end;
end;


procedure DoMakeMove(Move: TMove);
{**Executes a move on the board and updates all associated state information.**
 [comment block preserved verbatim — see v0965]
 v0967: bitboards are updated incrementally alongside the mailbox. Every
 mailbox write has a BB_PlacePiece / BB_RemovePiece counterpart.}
var
  MovingPiece, CapturedPiece: TPiece;
  OldCastleMask, OldEPC: integer;
  FromSq, ToSq: integer; // v0967
begin
  MovingPiece := State.Board[Move.FromR, Move.FromC];
  CapturedPiece := State.Board[Move.ToR, Move.ToC];

  FromSq := SquareIndex(Move.FromR, Move.FromC);
  ToSq   := SquareIndex(Move.ToR,   Move.ToC);

  // Incremental Hashing Update - remove pieces from their old positions
  State.Hash := State.Hash xor ZobristPiece[Ord(MovingPiece), Move.FromR, Move.FromC];
  if CapturedPiece <> EMPTY then
    State.Hash := State.Hash xor ZobristPiece[Ord(CapturedPiece), Move.ToR, Move.ToC];

  // v1.00-rc8: mirror the pawn-relevant part of the removal into the
  // pawn-only key. A moving pawn leaves its origin square; a captured pawn
  // (normal capture on the destination — en passant is handled in its own
  // block below) leaves the target square. We reuse the identical
  // ZobristPiece constants the full key just XORed, so the two keys stay in
  // lockstep by construction.
  if (MovingPiece = wP) or (MovingPiece = bP) then
    State.PawnHash := State.PawnHash xor ZobristPiece[Ord(MovingPiece), Move.FromR, Move.FromC];
  if (CapturedPiece = wP) or (CapturedPiece = bP) then
    State.PawnHash := State.PawnHash xor ZobristPiece[Ord(CapturedPiece), Move.ToR, Move.ToC];

  // 50-Move Rule Clock - reset on pawn move or capture
  if (MovingPiece = wP) or (MovingPiece = bP) or (CapturedPiece <> EMPTY) then
    State.HalfMoveClock := 0
  else
    Inc(State.HalfMoveClock);

  // v0967: remove the captured piece from the bitboards (a normal capture).
  // En-passant has its own captured-square logic below, so we don't touch
  // bitboards here for EP — CapturedPiece was loaded from the destination
  // square which is empty for EP.
  if (Move.MoveType <> MT_EN_PASSANT) and (CapturedPiece <> EMPTY) then
    BB_RemovePiece(CapturedPiece, ToSq);

  // Handle special moves (en passant, castling)
  case Move.MoveType of
    MT_EN_PASSANT: begin
      if State.SideToMove = 0 then // White capturing en passant
      begin
        CapturedPiece := State.Board[Move.ToR + 1, Move.ToC]; // Black pawn
        State.Hash := State.Hash xor ZobristPiece[Ord(CapturedPiece), Move.ToR + 1, Move.ToC];
        // v1.00-rc8: the en-passant victim is always a pawn, so its removal
        // always affects the pawn key (unconditional mirror).
        State.PawnHash := State.PawnHash xor ZobristPiece[Ord(CapturedPiece), Move.ToR + 1, Move.ToC];
        State.Board[Move.ToR + 1, Move.ToC] := EMPTY;
        BB_RemovePiece(CapturedPiece, SquareIndex(Move.ToR + 1, Move.ToC));
      end
      else // Black capturing en passant
      begin
        CapturedPiece := State.Board[Move.ToR - 1, Move.ToC]; // White pawn
        State.Hash := State.Hash xor ZobristPiece[Ord(CapturedPiece), Move.ToR - 1, Move.ToC];
        // v1.00-rc8: en-passant victim is always a pawn (unconditional mirror).
        State.PawnHash := State.PawnHash xor ZobristPiece[Ord(CapturedPiece), Move.ToR - 1, Move.ToC];
        State.Board[Move.ToR - 1, Move.ToC] := EMPTY;
        BB_RemovePiece(CapturedPiece, SquareIndex(Move.ToR - 1, Move.ToC));
      end;
      State.HalfMoveClock := 0;
    end;
    MT_CASTLE_WK: begin
      State.Hash := State.Hash xor ZobristPiece[Ord(wR), 7, 7];
      State.Hash := State.Hash xor ZobristPiece[Ord(wR), 7, 5];
      State.Board[7, 7] := EMPTY; State.Board[7, 5] := wR;
      BB_RemovePiece(wR, SquareIndex(7, 7));
      BB_PlacePiece (wR, SquareIndex(7, 5));
    end;
    MT_CASTLE_WQ: begin
      State.Hash := State.Hash xor ZobristPiece[Ord(wR), 7, 0];
      State.Hash := State.Hash xor ZobristPiece[Ord(wR), 7, 3];
      State.Board[7, 0] := EMPTY; State.Board[7, 3] := wR;
      BB_RemovePiece(wR, SquareIndex(7, 0));
      BB_PlacePiece (wR, SquareIndex(7, 3));
    end;
    MT_CASTLE_BK: begin
      State.Hash := State.Hash xor ZobristPiece[Ord(bR), 0, 7];
      State.Hash := State.Hash xor ZobristPiece[Ord(bR), 0, 5];
      State.Board[0, 7] := EMPTY; State.Board[0, 5] := bR;
      BB_RemovePiece(bR, SquareIndex(0, 7));
      BB_PlacePiece (bR, SquareIndex(0, 5));
    end;
    MT_CASTLE_BQ: begin
      State.Hash := State.Hash xor ZobristPiece[Ord(bR), 0, 0];
      State.Hash := State.Hash xor ZobristPiece[Ord(bR), 0, 3];
      State.Board[0, 0] := EMPTY; State.Board[0, 3] := bR;
      BB_RemovePiece(bR, SquareIndex(0, 0));
      BB_PlacePiece (bR, SquareIndex(0, 3));
    end;
  end;

  // Move the piece in the mailbox AND in the bitboards. Remove from
  // origin, place at destination — the destination piece type might
  // change (promotion) below, in which case we replace.
  State.Board[Move.ToR, Move.ToC] := MovingPiece;
  State.Board[Move.FromR, Move.FromC] := EMPTY;
  BB_RemovePiece(MovingPiece, FromSq);
  BB_PlacePiece (MovingPiece, ToSq);

  // Handle promotion
  if Move.Promotion <> EMPTY then
  begin
    State.Hash := State.Hash xor ZobristPiece[Ord(MovingPiece), Move.ToR, Move.ToC]; // Remove pawn from target
    // v1.00-rc8: pawn-key bookkeeping on promotion. The pawn's ORIGIN-square
    // term was already XORed out at the top of DoMakeMove (the unconditional
    // "moving pawn leaves its origin" mirror). The promoted piece is not a
    // pawn, so it contributes nothing to the pawn key. Crucially, the pawn is
    // NEVER added to the destination square in the pawn key on a promoting
    // move (that add lives only in the non-promotion 'else' branch below), so
    // there is nothing to XOR out here — doing so would wrongly toggle a
    // target-square pawn term that was never set. Net pawn-key effect of a
    // promotion is therefore exactly "remove one pawn from the origin", which
    // the top-of-procedure mirror already applied. Hence: no PawnHash update
    // in this branch.
    State.Board[Move.ToR, Move.ToC] := Move.Promotion;
    State.Hash := State.Hash xor ZobristPiece[Ord(Move.Promotion), Move.ToR, Move.ToC]; // Add promoted piece
    State.HalfMoveClock := 0;
    // v0967: swap the pawn we just placed on ToSq for the promoted piece.
    BB_RemovePiece(MovingPiece,    ToSq);
    BB_PlacePiece (Move.Promotion, ToSq);
  end
  else
  begin
    State.Hash := State.Hash xor ZobristPiece[Ord(MovingPiece), Move.ToR, Move.ToC]; // Add moving piece to target
    // v1.00-rc8: a non-promoting pawn arrives on its destination square —
    // mirror that placement into the pawn key. (For a non-pawn mover this is
    // skipped, so the pawn key is untouched, exactly as required.)
    if (MovingPiece = wP) or (MovingPiece = bP) then
      State.PawnHash := State.PawnHash xor ZobristPiece[Ord(MovingPiece), Move.ToR, Move.ToC];
  end;

  // Update king positions
  if MovingPiece = wK then begin State.WhiteKingR := Move.ToR; State.WhiteKingC := Move.ToC; end
  else if MovingPiece = bK then begin State.BlackKingR := Move.ToR; State.BlackKingC := Move.ToC; end;

  // Update castling rights
  OldCastleMask := State.CastleMask;
  if (Move.FromR = 7) and (Move.FromC = 0) then State.CastleMask := State.CastleMask and (not CM_WQ);
  if (Move.FromR = 7) and (Move.FromC = 7) then State.CastleMask := State.CastleMask and (not CM_WK);
  if (Move.FromR = 7) and (Move.FromC = 4) then State.CastleMask := State.CastleMask and (not (CM_WK or CM_WQ));
  if (Move.ToR = 7) and (Move.ToC = 0) then State.CastleMask := State.CastleMask and (not CM_WQ);
  if (Move.ToR = 7) and (Move.ToC = 7) then State.CastleMask := State.CastleMask and (not CM_WK);
  if (Move.FromR = 0) and (Move.FromC = 0) then State.CastleMask := State.CastleMask and (not CM_BQ);
  if (Move.FromR = 0) and (Move.FromC = 7) then State.CastleMask := State.CastleMask and (not CM_BK);
  if (Move.FromR = 0) and (Move.FromC = 4) then State.CastleMask := State.CastleMask and (not (CM_BK or CM_BQ));
  if (Move.ToR = 0) and (Move.ToC = 0) then State.CastleMask := State.CastleMask and (not CM_BQ);
  if (Move.ToR = 0) and (Move.ToC = 7) then State.CastleMask := State.CastleMask and (not CM_BK);

  // Update hash for castling rights change
  State.Hash := State.Hash xor ZobristCastle[OldCastleMask];
  State.Hash := State.Hash xor ZobristCastle[State.CastleMask];

  // Update en passant square
  OldEPC := State.EPC;
  State.EPR := -1; State.EPC := -1;
  if (MovingPiece = wP) and (Move.FromR = 6) and (Move.ToR = 4) then begin State.EPR := 5; State.EPC := Move.ToC; end;
  if (MovingPiece = bP) and (Move.FromR = 1) and (Move.ToR = 3) then begin State.EPR := 2; State.EPC := Move.ToC; end;

  // Update hash for en passant change
  if OldEPC <> -1 then State.Hash := State.Hash xor ZobristEP[OldEPC];
  if State.EPC <> -1 then State.Hash := State.Hash xor ZobristEP[State.EPC];

  // Change side to move
  State.Hash := State.Hash xor ZobristSide;
  State.SideToMove := 1 - State.SideToMove;

  // v1.00-rc3: the full-move number increments after Black's move, i.e.
  // whenever the side to move has just flipped back to White (0).
  if State.SideToMove = 0 then Inc(State.FullMoveNumber);

  // Update game history for repetition detection
  Inc(State.GamePly);
  GameHistory[State.GamePly] := State.Hash;

  //temporary
//   VerifyBitboards('after DoMakeMove')
end;


//corrected 2026/06/05/2330
procedure GenerateLegalMoves(out Moves: TMoveList; out MoveCount: integer);
{**Filters pseudo-legal moves to only include those that don't leave the king in check.**
This function calls `GeneratePseudoLegalMoves` first, then tests each move by:
- Making the move temporarily
- Checking if the current player's king is under attack
- Only keeping moves that keep the king safe
This two-step approach (generate all, then filter) is simpler but slower than generating only legal moves directly. It's acceptable for this engine's complexity level.}

var
  Pseudo: TMoveList;
  PseudoCount, i: integer;
  OldState: TGameState;
begin
  MoveCount := 0;
  GeneratePseudoLegalMoves(Pseudo, PseudoCount);
  for i := 0 to PseudoCount - 1 do
  begin
    OldState := State;
    DoMakeMove(Pseudo[i]);
    // A move is legal if it doesn't leave OUR king in check
    if not IsInCheck(1 - State.SideToMove) then
    begin
      Moves[MoveCount] := Pseudo[i];
      Inc(MoveCount);
    end;
    State := OldState;
  end;
end;


function MoveToStr(M: TMove): string;//**Converts a TMove record to UCI format string (e.g., "e2e4", "e7e8q" for promotion).**
var
  PromoChar: char;
begin
  Result := Chr(Ord('a') + M.FromC) + Chr(Ord('8') - M.FromR) +
    Chr(Ord('a') + M.ToC) + Chr(Ord('8') - M.ToR);
  if M.Promotion <> EMPTY then
  begin
    PromoChar := PieceChar[M.Promotion];
    Result := Result + LowerCase(PromoChar);
  end;
end;


// ============================================
// OPENING BOOK - PGN PARSER AND LOOKUP
// ============================================

function ParseSANToMove(const SAN: string; out AMove: TMove): boolean;
var
  LegalMoves: TMoveList;
  LegalCount, i: integer;
  CleanSAN: string;
  Piece: TPiece;
  DestR, DestC, DisambigFile, DisambigRank: integer;
  IsPromotion: boolean;
  PromoPiece: TPiece;
  M: TMove;
  FromPiece : TPiece;
  Ch: char;
begin
  Result := False;
  AMove := Default(TMove);
  GenerateLegalMoves(LegalMoves, LegalCount);

  CleanSAN := SAN;

  // Remove check/checkmate indicators from the end
  while (Length(CleanSAN) > 0) and (CleanSAN[Length(CleanSAN)] in ['+', '#']) do
    CleanSAN := Copy(CleanSAN, 1, Length(CleanSAN) - 1);
  // Remove annotation symbols
  while (Length(CleanSAN) > 0) and (CleanSAN[Length(CleanSAN)] in ['!', '?']) do
    CleanSAN := Copy(CleanSAN, 1, Length(CleanSAN) - 1);
  // Remove capture indicator (we match by piece+destination instead)
  CleanSAN := StringReplace(CleanSAN, 'x', '', [rfReplaceAll]);

  // Handle castling
  if (CleanSAN = 'O-O') or (CleanSAN = '0-0') then
  begin
    for i := 0 to LegalCount - 1 do
    begin
      if State.SideToMove = 0 then
      begin
        if LegalMoves[i].MoveType = MT_CASTLE_WK then begin AMove := LegalMoves[i]; Result := True; Exit; end;
      end
      else
      begin
        if LegalMoves[i].MoveType = MT_CASTLE_BK then begin AMove := LegalMoves[i]; Result := True; Exit; end;
      end;
    end;
    Exit;
  end;
  if (CleanSAN = 'O-O-O') or (CleanSAN = '0-0-0') then
  begin
    for i := 0 to LegalCount - 1 do
    begin
      if State.SideToMove = 0 then
      begin
        if LegalMoves[i].MoveType = MT_CASTLE_WQ then begin AMove := LegalMoves[i]; Result := True; Exit; end;
      end
      else
      begin
        if LegalMoves[i].MoveType = MT_CASTLE_BQ then begin AMove := LegalMoves[i]; Result := True; Exit; end;
      end;
    end;
    Exit;
  end;

  // Parse promotion (e.g., "e8=Q")
  IsPromotion := False;
  PromoPiece := EMPTY;
  if Pos('=', CleanSAN) > 0 then
  begin
    IsPromotion := True;
    case UpCase(CleanSAN[Length(CleanSAN)]) of
      'Q': PromoPiece := wQ;
      'R': PromoPiece := wR;
      'B': PromoPiece := wB;
      'N': PromoPiece := wN;
    end;
    CleanSAN := Copy(CleanSAN, 1, Pos('=', CleanSAN) - 1);
  end;

  // Determine moving piece type and strip piece letter
  DisambigFile := -1;
  DisambigRank := -1;

  // FIX: Removed UpCase() so 'b' file pawn moves aren't confused with 'B' bishop moves
  Piece := EMPTY;
  if (Length(CleanSAN) > 0) and (CleanSAN[1] in ['N', 'B', 'R', 'Q', 'K']) then
  begin
    case CleanSAN[1] of
      'N': if State.SideToMove = 0 then Piece := wN else Piece := bN;
      'B': if State.SideToMove = 0 then Piece := wB else Piece := bB;
      'R': if State.SideToMove = 0 then Piece := wR else Piece := bR;
      'Q': if State.SideToMove = 0 then Piece := wQ else Piece := bQ;
      'K': if State.SideToMove = 0 then Piece := wK else Piece := bK;
    end;
    CleanSAN := Copy(CleanSAN, 2, Length(CleanSAN));
  end
  else
  begin
    if State.SideToMove = 0 then Piece := wP else Piece := bP;
  end;

  // Last two characters are the destination square
  if Length(CleanSAN) < 2 then Exit;
  DestC := Ord(CleanSAN[Length(CleanSAN) - 1]) - Ord('a');
  DestR := Ord('8') - Ord(CleanSAN[Length(CleanSAN)]);

  // Validate destination square
  if (DestC < 0) or (DestC > 7) or (DestR < 0) or (DestR > 7) then Exit;

  // Any remaining characters are disambiguation (file, rank, or both)
  for i := 1 to Length(CleanSAN) - 2 do
  begin
    Ch := CleanSAN[i];
    if Ch in ['a'..'h'] then
      DisambigFile := Ord(Ch) - Ord('a')
    else if Ch in ['1'..'8'] then
      DisambigRank := Ord('8') - Ord(Ch);
  end;

  // Find the matching legal move
  for i := 0 to LegalCount - 1 do
  begin
    M := LegalMoves[i];
    FromPiece := State.Board[M.FromR, M.FromC];

    if FromPiece <> Piece then Continue;
    if (M.ToR <> DestR) or (M.ToC <> DestC) then Continue;
    if (DisambigFile >= 0) and (M.FromC <> DisambigFile) then Continue;
    if (DisambigRank >= 0) and (M.FromR <> DisambigRank) then Continue;

    if IsPromotion then
    begin
      if State.SideToMove = 1 then PromoPiece := TPiece(Ord(PromoPiece) + 6);
      if M.Promotion <> PromoPiece then Continue;
    end
    else
    begin
      if M.Promotion <> EMPTY then Continue;
    end;



    AMove := M;
    Result := True;
    Exit;
  end;
end;


procedure QuickSortBook(Lo, Hi: integer);
var
  i, j: integer;
  Pivot, Temp: TBookEntry;
begin
  if Lo >= Hi then Exit;
  Pivot := BookEntries[(Lo + Hi) div 2];
  i := Lo;
  j := Hi;
  while i <= j do
  begin
    while BookEntries[i].Hash < Pivot.Hash do Inc(i);
    while BookEntries[j].Hash > Pivot.Hash do Dec(j);
    if i <= j then
    begin
      Temp := BookEntries[i];
      BookEntries[i] := BookEntries[j];
      BookEntries[j] := Temp;
      Inc(i);
      Dec(j);
    end;
  end;
  QuickSortBook(Lo, j);
  QuickSortBook(i, Hi);
end;


procedure LoadOpeningBook(const FileName: string);
{**Parses a PGN file and loads all opening positions into the book.**
Each game is played through from the starting position. At each position,
the (Zobrist hash, UCI move string) pair is stored. Moves appearing
multiple times in the book get multiple entries, which naturally weights
them higher during random selection. Handles line wrapping, semicolon
comments, and percent comments.}
var
  F: TextFile;
  Line, MoveText: string;
  SavedState: TGameState;
  SavedGameHistory: array[0..2048] of QWord;
  InMoveText: boolean;
  GamesLoaded, EntriesBefore: integer;
  SemiPos: integer;
      procedure ProcessGame(const MT: string);
      var
        PP, Depth: integer;
        TT: string;
        MM: TMove;
        CH: QWord;
        MU: string;
      begin
        InitState; // Reset board to starting position

        PP := 1;
        while PP <= Length(MT) do
        begin
          // Skip whitespace
          while (PP <= Length(MT)) and (MT[PP] = ' ') do Inc(PP);
          if PP > Length(MT) then Break;

          // Skip comments in curly braces
          if MT[PP] = '{' then
          begin
            while (PP <= Length(MT)) and (MT[PP] <> '}') do Inc(PP);
            if PP <= Length(MT) then Inc(PP);
            Continue;
          end;

          // Skip variations in parentheses (handles nested parentheses)
          if MT[PP] = '(' then
          begin
            Depth := 1;
            Inc(PP);
            while (PP <= Length(MT)) and (Depth > 0) do
            begin
              if MT[PP] = '(' then Inc(Depth)
              else if MT[PP] = ')' then Dec(Depth);
              Inc(PP);
            end;
            Continue;
          end;

          // Read token (delimited by space, opening brace, or parenthesis)
          TT := '';
          while (PP <= Length(MT)) and (MT[PP] <> ' ') and (MT[PP] <> '{') and (MT[PP] <> '(') do
          begin
            TT := TT + MT[PP];
            Inc(PP);
          end;

          if TT = '' then Continue;

          // Skip result markers
          if (TT = '*') or (TT = '1-0') or (TT = '0-1') or (TT = '1/2-1/2') then Break;

          // Handle move numbers (e.g., "1.", "1...", "2.b4")
          if (Length(TT) > 0) and (TT[1] in ['0'..'9']) then
          begin
            if Pos('...', TT) > 0 then
            begin
              TT := Copy(TT, Pos('...', TT) + 3, Length(TT));
              if TT = '' then Continue;
            end
            else if Pos('.', TT) > 0 then
            begin
              TT := Copy(TT, Pos('.', TT) + 1, Length(TT));
              if TT = '' then Continue;
            end;
          end;

          // Skip NAG annotations (e.g., "$1")
          if (Length(TT) > 0) and (TT[1] = '$') then Continue;

          // This should be a SAN move — parse it
          CH := State.Hash;
          if not ParseSANToMove(TT, MM) then
          begin
            Log('Book: Failed to parse move "' + TT + '" — skipping game');
            Break;
          end;

          MU := MoveToStr(MM);

          // Add entry to book
          if BookCount >= Length(BookEntries) then
            SetLength(BookEntries, Length(BookEntries) + 7000);//increase size

          BookEntries[BookCount].Hash := CH;
          BookEntries[BookCount].MoveUCI := MU;
          Inc(BookCount);

          // Play the move on the board to advance to next position
          DoMakeMove(MM);
        end;
      end;
begin
  if not FileExists(FileName) then
  begin
    Log('Book: File not found: ' + FileName);
    Exit;
  end;

  // Save current game state (will be restored after loading)
  SavedState := State;
  SavedGameHistory := GameHistory;

  EntriesBefore := BookCount;
  GamesLoaded := 0;

  AssignFile(F, FileName);
  try
    Reset(F);
  except
    Log('Book: Cannot open file: ' + FileName);
    State := SavedState;
    GameHistory := SavedGameHistory;
    Exit;
  end;

  MoveText := '';
  InMoveText := False;

  while not EOF(F) do
  begin
    ReadLn(F, Line);

    // Handle semicolon comments (everything after ; on the line is a comment)
    SemiPos := Pos(';', Line);
    if SemiPos > 0 then
      Line := Copy(Line, 1, SemiPos - 1);

    Line := Trim(Line);

    // Skip PGN standard percent comment lines (entire line is a comment)
    if (Length(Line) > 0) and (Line[1] = '%') then
      Continue;

    if Line = '' then
    begin
      // Blank line signals end of a game's move text
      if InMoveText and (MoveText <> '') then
      begin
        ProcessGame(Trim(MoveText));
        Inc(GamesLoaded);
        MoveText := '';
      end;
      InMoveText := False;
      Continue;
    end;

    if (Length(Line) > 0) and (Line[1] = '[') then
    begin
      // Header tag — if we were reading move text, process the game first
      if InMoveText and (MoveText <> '') then
      begin
        ProcessGame(Trim(MoveText));
        Inc(GamesLoaded);
        MoveText := '';
      end;
      InMoveText := False;
      Continue;
    end;

    // Non-header, non-blank, non-comment line is move text.
    // By appending with a space, we automatically fix line wraps!
    InMoveText := True;
    MoveText := MoveText + ' ' + Line;
  end;

  // Process any remaining game at end of file
  if MoveText <> '' then
  begin
    ProcessGame(Trim(MoveText));
    Inc(GamesLoaded);
  end;

  CloseFile(F);

  // Restore the original game state
  State := SavedState;
  GameHistory := SavedGameHistory;

  Log('Book: Loaded ' + IntToStr(BookCount - EntriesBefore) + ' positions from ' +
    IntToStr(GamesLoaded) + ' games in ' + FileName);
end;



procedure LoadAllOpeningBooks;
{**Finds all .pgn files in the program directory and loads them as opening books.**
Called once at program startup after InitZobrist and InitState.}
var
  SearchRec: TSearchRec;
  ProgDir: string;
begin
  BookCount := 0;
  BookLoaded := False;
  SetLength(BookEntries, 10000);

  ProgDir := ExtractFilePath(ParamStr(0));
  if ProgDir = '' then ProgDir := './';

  bookfilename:=changefileext(bookfilename,'.pgn');
  if FindFirst(ProgDir + bookfilename, faAnyFile, SearchRec) = 0 then
  begin
    repeat
      if (SearchRec.Attr and faDirectory) = 0 then
        LoadOpeningBook(ProgDir + SearchRec.Name);
    until FindNext(SearchRec) <> 0;
    FindClose(SearchRec);
  end;

  // Sort book entries by hash for efficient binary search lookup
  if BookCount > 1 then
    QuickSortBook(0, BookCount - 1);

  BookLoaded := BookCount > 0;
  if BookLoaded then
  begin
    Log('Book: Opening book '+bookfilename+' active with ' + IntToStr(BookCount) + ' positions');
    writeln('info Book: Opening book '+bookfilename+'  active with ' + IntToStr(BookCount) + ' positions')
  end
  else
  begin
    Log('Book: No .pgn opening book found — using engine search only');
    writeln('info Book: No .pgn opening book found — using engine search only');
  end;
end;



function GetBookMove: string;
{**Looks up the current position in the opening book and returns a random
matching move in UCI format. Returns empty string if no book move exists.
Moves that appear more frequently in the book are more likely to be selected,
providing natural weight-based random selection.}
var
  MatchCount, Lo, Hi, Mid, StartIdx, i: integer;
  CurrentHash: QWord;
begin
  Result := '';
  if not BookLoaded or (BookCount = 0) then Exit;

  CurrentHash := State.Hash;

  // Binary search for the first entry with this hash
  Lo := 0;
  Hi := BookCount - 1;
  StartIdx := -1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if BookEntries[Mid].Hash = CurrentHash then
    begin
      StartIdx := Mid;
      Hi := Mid - 1; // keep searching left for the first occurrence
    end
    else if BookEntries[Mid].Hash < CurrentHash then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;

  if StartIdx = -1 then Exit; // Position not in book

  // Count all matching entries (they are consecutive due to sorting)
  MatchCount := 0;
  i := StartIdx;
  while (i < BookCount) and (BookEntries[i].Hash = CurrentHash) do
  begin
    Inc(MatchCount);
    Inc(i);
  end;

  // Select a random move from the matching entries
  Result := BookEntries[StartIdx + Random(MatchCount)].MoveUCI;
  Log('Book: Selected move ' + Result + ' from ' + IntToStr(MatchCount) + ' candidates');
end;


function SliderAttacks(sq, StartDir, EndDir: integer): QWord; {inline; fpc can not inline in inline.}
{**Bitboard of squares reachable by a sliding piece at sq across the given
   direction range. Direction layout matches SlideDR/SlideDC and
   SlideDirIsPositive[]:
     0..3 = orthogonal  (rook lines)
     4..7 = diagonal    (bishop lines)
   For a queen pass (0..7) the result is the union of both.

   v1.00-rc6: the classical per-ray nearest-blocker scan is replaced by
   plain magic lookups. The three direction ranges the callers actually
   use (0..3 rook, 4..7 bishop, 0..7 queen - see the mobility loops in
   Evaluate) map directly onto Rook/Bishop/QueenAttacksBB. The returned
   set is mathematically identical to the pre-rc6 scan for every
   occupancy: it contains every square the slider attacks, including
   the first occupied square in each direction. Callers that want the
   move-destination set should AND with NOT own_occupancy: own-piece
   blockers are then dropped while enemy-piece blockers (capturable)
   are retained.

   v0981 (mobility evaluation). Same pattern as the slider move generator
   (v0970), IsAttacked (v0976), and SEE's FindLVA (v0974); factored once
   so that all four consumers switched to magics together in rc6.}
begin
  if StartDir >= 4 then
    Result := BishopAttacksBB(sq, State.AllOccupied)         // 4..7
  else if EndDir <= 3 then
    Result := RookAttacksBB(sq, State.AllOccupied)           // 0..3
  else
    Result := QueenAttacksBB(sq, State.AllOccupied);         // 0..7
end;

{$IFDEF TUNER}
var  //texel tuning
  TunerLastMG, TunerLastEG, TunerLastPhase: integer; // pre-blend white-POV sums exposed by Evaluate
{$ENDIF}

function Evaluate: integer;
{**Static evaluation function that scores the current position from the current player's perspective.**

Positive scores favour White, negative favour Black (before the side-to-move flip
at the end).

v0960: this function now uses **tapered evaluation**. Two parallel score
accumulators, ScoreMG (middlegame) and ScoreEG (endgame), are maintained
throughout the function. A "phase" value is computed from non-pawn material
(PhaseN/B/R/Q weights, MaxPhase total = 24 at game start). The final score
is a phase-weighted interpolation:
    Score := (ScoreMG * phase + ScoreEG * (MaxPhase - phase)) div MaxPhase
so a fresh position weighted entirely as MG smoothly transitions to pure EG
as material is exchanged off. This replaces v0957's binary "queens on board
or not" switch with a continuous blend.

Components include:

- **Material balance**: Piece values (Pawn=100, Knight=320, Bishop=330,
  Rook=500, Queen=900). Same in MG and EG.
- **Piece-Square Tables**: Knight, bishop, rook, queen use one PST applied
  to both MG and EG (positionally similar in both phases for this engine).
  Pawn uses PawnPST_MG (MG) + PawnPST_EG (EG). King uses KingPST_MG (MG) +
  KingPST_EG (EG) — the largest tapering effect, since king behaviour
  changes most between phases.
- **King safety bonuses** (king on own back rank, castled-square bonuses):
  applied to ScoreMG only. Fade automatically in endgame via tapering.
- **King centre-distance**: applied to ScoreEG only. Negligible in MG via
  tapering. Reinforces the EG king PST.
- **Pawn structure**:
    - Passed pawns: per-relative-rank tables PassedPawnMG[0..7] /
      PassedPawnEG[0..7] (v1.00-rc10; previously a flat bonus 1x MG /
      2x EG). EG entries are much larger than MG - passed pawns are
      far more valuable in endgame, where there are fewer pieces to
      block or capture them - and both curves rise convexly with rank.
    - Doubled pawns, isolated pawns: same in MG and EG.
    - Backward pawns (v0963): 8 MG / 15 EG. See PASS 3 for definition.
- **Bishop pair bonus**: same in MG and EG.
- **Rook open/semi-open file**: same in MG and EG.
- **Tempo bonus** (v0962a): +10 cp MG to the side to move. MG-only so
  it fades through tapered eval — tempo can become a burden (zugzwang)
  in deep endgames.

Notes:
The original v0957 doc string noted that evaluation refinements become
meaningful "above 2000 Elo where search depth alone no longer compensates
for positional blindness". v0960 reaches into evaluation explicitly because
v0958 (LMR tuning) and v0959 (aspiration windows) both produced statistically
neutral SPRT results — a strong signal that the engine had become evaluation-
limited rather than search-limited.

v0979: PASS 1 rewritten to iterate piece bitboards instead of scanning
all 64 mailbox squares. Material is computed as PopCnt * value per piece
type (12 PopCnts), phase as PopCnt of combined non-pawn non-king
bitboards, bishop-pair counts via PopCnt. PSTs are still indexed [r, c]
and we decode (r, c) from each bit via SquareCoords. Pawn structure
arrays (count / front / rear) are filled in during the pawn-bitboard
sweep. PASS 2, 3, 4 and everything below PASS 1 are unchanged.
The mathematical result of Evaluate is identical to v0975; bench node
counts must match.

v0984: per-file integer arrays (wPawnCount / wPawnFront / wPawnRear and
the black equivalents) are removed. The same per-file quantities are
now derived inside the PASS 3 file loop from a single AND with
FileMask[c]:
    wFile  := wPawns and FileMask[c];
    wCount := PopCnt(wFile);
    wFront row = 7 - (BsrQWord(wFile) shr 3);    // most advanced
    wRear  row = 7 - (BsfQWord(wFile) shr 3);    // rear-most
The blocked-passer triple-check on bPawnFront[c-1..c+1] collapses to a
single AND against WhitePassedMask[wFrontSq], built once by
InitPawnMasks. Rear-support for the backward-pawn test becomes
    (wPawns and AdjacentFileMask[c] and RanksAtOrBelow[wRearSq shr 3]) <> 0
PASS 4 (rook open/semi-open file) tests (wPawns and FileMask[c]) = 0
directly. PASS 1 still iterates the pawn bitboards (PSTs need the
square decode) but no longer accumulates structure data. Pure
refactor — bench node counts must match v0983 exactly; no Elo on its
own. Worth doing because future pawn-structure features (candidate
passers, connected pawns, pawn span) reduce to a single AND against a
mask of this same shape.
}
var
  r, c, ScoreMG, ScoreEG, Score: integer;
  sq: integer;                   // v0979 — current bit position during bitboard sweep
  gamePhase: integer;            // running phase total; clamped to MaxPhase at end of pass 1
  WhiteBishops, BlackBishops: integer; // Bishop pair: count of bishops per side
  pieceBB: QWord;                // v0979 — scratch bitboard for piece iteration

  // v0984 — pawn bitboards captured once, reused across PASS 1 (PSTs),
  // PASS 3 (pawn structure), and PASS 4 (rook open/semi-open file).
  // Replaces the per-file wPawnCount / wPawnFront / wPawnRear arrays.
  wPawns, bPawns: QWord;

  // v0984 — per-file scratch values, refreshed inside the PASS 3
  // file loop. wFile / bFile are the side's pawn bitboard intersected
  // with FileMask[c]; wAdj / bAdj are the same intersected with
  // AdjacentFileMask[c]. wCount / bCount are PopCnt(wFile / bFile).
  // wFrontSq / wRearSq are the LERF bit indices of the most-advanced
  // and rear-most white pawn on this file (via BsrQWord / BsfQWord);
  // bFrontSq / bRearSq are the symmetric black equivalents
  // (BsfQWord / BsrQWord, since black advances toward lower LERF
  // ranks). (The v0984 frontRow (7 - LERF_rank) row number is retired
  // in v1.00-rc10 - the passed-pawn term, its only consumer, now
  // indexes by relative rank via relRank below.)
  wFile, bFile, wAdj, bAdj: QWord;
  wCount, bCount: integer;
  wFrontSq, bFrontSq, wRearSq, bRearSq: integer;

  // v1.00-rc10: relative rank of the front pawn on this file, used to
  // index PassedPawnMG/PassedPawnEG. 0 = own back rank, 6 = one step
  // from promotion. White: relRank = LERF rank of wFrontSq; black:
  // relRank = 7 - LERF rank of bFrontSq. Replaces the old frontRow /
  // PassedBonus pair (frontRow was the 7-LERF row number feeding the
  // flat v0960 case table; both were used only by the passed-pawn term).
  relRank: integer;

  IsNotPassed:   boolean; // helper: true when a candidate passed pawn is in fact blocked
  IsIsolated:  boolean; // helper: true when a pawn has no friendly pawns on adjacent files

  // v1.00-rc18 step 4: passed-pawn bitboards, one per side, recomputed
  // fresh at the top of PASS 4 (NOT read from the pawn-hash entry — the
  // entry stores only dMG/dEG). wPassed holds every white passed pawn,
  // bPassed every black passed pawn. Consumed by the rook-behind-passer
  // terms in PASS 4 and available to later king-distance work.
  wPassed, bPassed: QWord;
  passFile: QWord;      // per-file scratch inside the passed-set builder
  passSq:   integer;    // front-pawn square inside the builder

  NotOwn: QWord;         // v0981 — mobility destination mask (= NOT own_occupancy)
  mobCount: integer;     // v0981 — popcount of mobility set per piece

  // v0963: backward pawn helper booleans (declared once here, reused per file)
  IsBackward, StopAttacked, HasRearSupport: boolean;
  stopSq: integer;       // v0983 — LERF bit index of the candidate backward pawn's stop square

  // v1.00-rc8: pawn hash table probe. pMG/pEG accumulate the PASS 3
  // contribution SEPARATELY from ScoreMG/ScoreEG so the (dMG, dEG) pair can be
  // cached and, on a later hit, added back directly without re-running the
  // per-file loop. pawnIdx is the direct-mapped table index; pawnHit records
  // whether the probed slot's key matched (a real hit) so we only recompute
  // on a miss and only write back on a miss.
  pMG, pEG, pawnIdx: integer;
  pawnHit: boolean;
  // v1.00-rc12: king-safety attack units. atk holds the raw attack set of
  // the piece currently being scored in PASS 5 (BEFORE the NotOwn mask —
  // a defended zone square is still an attacked zone square). zoneHits is
  // its intersection popcount with the enemy king zone. The zones are the
  // king ring plus the king square. wAttackUnits/wAttackers accumulate
  // pressure AGAINST the white king (i.e. from black pieces) and vice
  // versa; PASS 6 converts units to a SafetyTable penalty when the
  // attacker count reaches 2.
  atk: QWord;
  zoneHits: integer;
  wKingZone, bKingZone: QWord;
  wAttackUnits, bAttackUnits: integer;
  wAttackers,   bAttackers:   integer;

  // v1.00-rc13: threat evaluation. wPawnAtk/bPawnAtk are the squares
  // attacked by each side's pawns, built with the same anti-wraparound
  // shift pattern as the pawn-capture generator (shl 7 / shl 9 for
  // white with the a-/h-file source pawns masked off, shr 7 / shr 9
  // mirrored for black). wMinorAtk/bMinorAtk accumulate knight+bishop
  // attack sets during PASS 5; wAttackBB/bAttackBB accumulate ALL
  // attacks of a side (pawns + N + B + R + Q + king ring) and serve as
  // the attacked/defended maps for the hanging test. threatBB is a
  // per-family scratch intersection.
  wPawnAtk, bPawnAtk:   QWord;
  wMinorAtk, bMinorAtk: QWord;
  wAttackBB, bAttackBB: QWord;
  threatBB: QWord;
  wKsq, bKsq: integer;   // rc13: king squares bound once, reused for zone + king attack map

  // v1.00-rc14: knight-outpost / bad-bishop scratch. sqBB is the single-bit
  // board of the piece currently scored in PASS 5 (used for the pawn-defended
  // test against wPawnAtk/bPawnAtk and the colour-complex test). colorBB is
  // the bishop's colour complex (LightSquaresBB or DarkSquaresBB); badPawns
  // is the count of OWN pawns on that complex.
  sqBB, colorBB: QWord;
  badPawns: integer;

  // v1.00-rc15 step 1: connected-pawn scratch. connBB iterates the pawns
  // of the current file inside the PASS 3 loop (wFile/bFile are consumed
  // by BsrQWord/BsfQWord probes elsewhere, so a separate iterator keeps
  // them intact). IsSupported/IsPhalanx/IsOpposed are the three
  // pawn-placement-only flags; connM is the SF-classical multiplier
  // (2 + phalanx - opposed), an integer in 1..3.
  connBB: QWord;
  IsSupported, IsPhalanx, IsOpposed: boolean;
  connM: integer;


          function CentreDistance(row, col: integer): integer;
          begin
            Result := Min(Abs(row - 3), Abs(row - 4)) + Min(Abs(col - 3), Abs(col - 4));
          end;

          // v1.00-rc19 step 5: Chebyshev (king-move) distance between two
          // LERF squares = max(|file diff|, |rank diff|). Range 0..7.
          function ChebDist(sqA, sqB: integer): integer;
          begin
            Result := Max(Abs((sqA and 7) - (sqB and 7)),
                          Abs((sqA shr 3) - (sqB shr 3)));
          end;
        function PawnShieldPenalty(kingRow, kingCol, side: integer): integer;
          { **v0962: pawn shield penalty for one side.**
            Returns the penalty in centipawns (always >= 0); the caller applies
            the sign (subtract from ScoreMG for white, add to ScoreMG for black).

            Theory
            ------
            In the middlegame a castled king relies on the three pawns directly
            in front of it (files kingCol-1, kingCol, kingCol+1) for cover. Each
            file is scored independently:
              - Pawn on the rank immediately in front of king (best post):  0
              - Pawn on the next rank up the board (advanced, weakened post): -8
              - No friendly pawn on that file in the shield zone:           -15

            Scope
            -----
            Only applied when the king is on its own first two ranks (row 6/7
            for white, row 0/1 for black). A king that has wandered higher up
            the board is already being punished by the back-rank penalty
            handled in the surrounding code; counting shield gaps there would
            double-penalise and could even reward absurd lines where the king
            runs to a flank where his "shield" pawns happen to live.

            Edge files
            ----------
            For a king in the a- or h-file the shield range (kingCol-1 .. kingCol+1)
            spills off the board. Off-board files are simply skipped, not
            penalised — there is no pawn to be missing on a non-existent file.
            This deliberately gives an edge king a smaller maximum penalty,
            matching the chess intuition that an h1 king with f/g/h pawns
            intact is fully sheltered.

            Phase
            -----
            The caller adds this to ScoreMG only. In the endgame the king has
            to become active and a pawn shield is irrelevant; the tapered
            evaluation already fades the term to zero as the phase moves to EG.
          }
          var
            fileC, bestRank, advancedRank, veryAdvRank: integer;
            pawn: TPiece;
            shieldSum: integer;
          begin
            Result := 0;

            // Decide ranks and pawn colour. White king shields on the rank just
            // above (lower row number); black king shields on the rank just below.
            if side = 0 then
            begin
              // White: only evaluate if king is on its own first two ranks.
              if kingRow < 6 then Exit;
              bestRank     := kingRow - 1;      // rank immediately ahead of white king
              advancedRank := kingRow - 2;      // one rank further up the board
              veryAdvRank  := kingRow - 3;      // two ranks further up (v1.00-rc20)
              pawn := wP;
            end
            else
            begin
              // Black: mirror condition.
              if kingRow > 1 then Exit;
              bestRank     := kingRow + 1;
              advancedRank := kingRow + 2;
              veryAdvRank  := kingRow + 3;      // v1.00-rc20
              pawn := bP;
            end;

            shieldSum := 0;

            // Inspect the three files in front of the king: kingCol-1, kingCol, kingCol+1.
            // v1.00-rc20: bucket the nearest shield pawn by advancement and add the
            // matching ShieldMG entry (signed, <= 0). Buckets, nearest-first:
            //   ShieldMG[0] pawn on bestRank, [1] on advancedRank, [2] on veryAdvRank,
            //   [3] none of the above (missing from the shield zone).
            for fileC := kingCol - 1 to kingCol + 1 do
            begin
              // Off-board file (king on a- or h-file): skip, not penalised.
              if (fileC < 0) or (fileC > 7) then Continue;

              if State.Board[bestRank, fileC] = pawn then
                Inc(shieldSum, ShieldMG[0])
              else if (advancedRank >= 0) and (advancedRank <= 7) and
                      (State.Board[advancedRank, fileC] = pawn) then
                Inc(shieldSum, ShieldMG[1])
              else if (veryAdvRank >= 0) and (veryAdvRank <= 7) and
                      (State.Board[veryAdvRank, fileC] = pawn) then
                Inc(shieldSum, ShieldMG[2])
              else
                Inc(shieldSum, ShieldMG[3]);
            end;

            // Signed sum of the shield entries (<= 0 with penalty seeds). The
            // caller ADDS this to ScoreMG for white and SUBTRACTS for black
            // (see the v1.00-rc20 call sites), so a stored negative entry
            // reduces the mover's score exactly as the old positive penalty did.
            Result := shieldSum;
          end;
begin
  // v0960: ScoreMG and ScoreEG accumulators replace the single Score of v0957.
  // Both start at zero and are populated through the four passes below, then
  // blended by gamePhase at the very end.
  ScoreMG      := 0;
  ScoreEG      := 0;

  // v0984: pawn bitboards bound once, used in PASS 1 (PST), PASS 3
  // (structure terms), and PASS 4 (rook files). No per-file array
  // initialisation loop — those arrays no longer exist.
  wPawns := State.Pieces[wP];
  bPawns := State.Pieces[bP];

  // =========================================================================
  // PASS 1 (v0979): Material, PST, piece counting, and phase.
  // Iterates piece bitboards instead of scanning all 64 mailbox squares.
  //   Material: PopCnt(Pieces[P]) * PieceValue[P], summed per side.
  //   Phase:    PopCnt of combined non-pawn non-king bitboards * weight.
  //   Bishop pair: PopCnt of each side's bishop bitboard.
  //   PSTs:     iterate each piece bitboard via BsfQWord, decode (r,c)
  //             with SquareCoords, look up the PST. Black pieces use the
  //             vertically mirrored [7-r, c] index, identical to v0975.
  // v0984: the pawn loop no longer populates per-file structure arrays.
  //        PSTs still need (r, c) decoding so the bitboard iteration
  //        stays; the accumulator bumps just go away.
  // No mailbox iteration in this pass. State.Board is only consulted
  // below PASS 4 (king safety / etc.).
  // =========================================================================

  // Material balance (v0995) — split into MG and EG using PeSTO piece
  // values. Previously a single calculation copied into ScoreEG; now
  // each accumulator gets its own term sums. The non-pawn EG values
  // are notably different (N: 337→281, B: 365→297, R: 477→512,
  // Q: 1025→936) — pieces lose value in pure endgames except rooks,
  // which gain. This is the baseline against which the v0993/v0994
  // PeSTO PSTs were originally tuned.
  //
  // The Integer() casts are required: PopCnt(QWord) returns QWord,
  // so without them the right-hand side is evaluated in unsigned
  // 64-bit arithmetic and any intermediate that goes negative wraps
  // to ~2^64, tripping range checks on assignment to Integer. The
  // signs in PieceValueMG/EG (negative for black piece slots) flow
  // through the multiply naturally, so the expression is all
  // additions — no subtractions for the black side.
  ScoreMG := Integer(PopCnt(wPawns))           * PieceValueMG[wP] +
             Integer(PopCnt(State.Pieces[wN])) * PieceValueMG[wN] +
             Integer(PopCnt(State.Pieces[wB])) * PieceValueMG[wB] +
             Integer(PopCnt(State.Pieces[wR])) * PieceValueMG[wR] +
             Integer(PopCnt(State.Pieces[wQ])) * PieceValueMG[wQ] +
             Integer(PopCnt(State.Pieces[wK])) * PieceValueMG[wK] +
             Integer(PopCnt(bPawns))           * PieceValueMG[bP] +
             Integer(PopCnt(State.Pieces[bN])) * PieceValueMG[bN] +
             Integer(PopCnt(State.Pieces[bB])) * PieceValueMG[bB] +
             Integer(PopCnt(State.Pieces[bR])) * PieceValueMG[bR] +
             Integer(PopCnt(State.Pieces[bQ])) * PieceValueMG[bQ] +
             Integer(PopCnt(State.Pieces[bK])) * PieceValueMG[bK];
  ScoreEG := Integer(PopCnt(wPawns))           * PieceValueEG[wP] +
             Integer(PopCnt(State.Pieces[wN])) * PieceValueEG[wN] +
             Integer(PopCnt(State.Pieces[wB])) * PieceValueEG[wB] +
             Integer(PopCnt(State.Pieces[wR])) * PieceValueEG[wR] +
             Integer(PopCnt(State.Pieces[wQ])) * PieceValueEG[wQ] +
             Integer(PopCnt(State.Pieces[wK])) * PieceValueEG[wK] +
             Integer(PopCnt(bPawns))           * PieceValueEG[bP] +
             Integer(PopCnt(State.Pieces[bN])) * PieceValueEG[bN] +
             Integer(PopCnt(State.Pieces[bB])) * PieceValueEG[bB] +
             Integer(PopCnt(State.Pieces[bR])) * PieceValueEG[bR] +
             Integer(PopCnt(State.Pieces[bQ])) * PieceValueEG[bQ] +
             Integer(PopCnt(State.Pieces[bK])) * PieceValueEG[bK];


  // Bishop pair counts (used in PASS 2).
  WhiteBishops := PopCnt(State.Pieces[wB]);
  BlackBishops := PopCnt(State.Pieces[bB]);

  // Phase. PhaseN/B/R/Q weights sum to MaxPhase=24 at game start.
  // Promotions can in principle push gamePhase above MaxPhase, so we
  // clamp after the calculation.
  gamePhase := Integer(PopCnt(State.Pieces[wN] or State.Pieces[bN])) * PhaseN +
               Integer(PopCnt(State.Pieces[wB] or State.Pieces[bB])) * PhaseB +
               Integer(PopCnt(State.Pieces[wR] or State.Pieces[bR])) * PhaseR +
               Integer(PopCnt(State.Pieces[wQ] or State.Pieces[bQ])) * PhaseQ;
  if gamePhase > MaxPhase then gamePhase := MaxPhase;

  // -------------------------------------------------------------------------
  // Piece-Square Tables — iterate each piece bitboard.
  // -------------------------------------------------------------------------

  // White pawns — PST only (v0984: structure data is no longer
  // accumulated here; PASS 3 derives every per-file quantity from
  // wPawns / bPawns via file-mask intersections).
  pieceBB := wPawns;
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Inc(ScoreMG, PawnPST_MG   [r, c]);
    Inc(ScoreEG, PawnPST_EG[r, c]);
  end;

  // Black pawns — PST only.
  pieceBB := bPawns;
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Dec(ScoreMG, PawnPST_MG   [7 - r, c]);
    Dec(ScoreEG, PawnPST_EG[7 - r, c]);
  end;

  // White knights.
  pieceBB := State.Pieces[wN];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Inc(ScoreMG, KnightPST_MG[r, c]);
    Inc(ScoreEG, KnightPST_EG[r, c]);
  end;

  // Black knights.
  pieceBB := State.Pieces[bN];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Dec(ScoreMG, KnightPST_MG[7 - r, c]);
    Dec(ScoreEG, KnightPST_EG[7 - r, c]);
  end;


  // White bishops.
  pieceBB := State.Pieces[wB];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Inc(ScoreMG, BishopPST_MG[r, c]);
    Inc(ScoreEG, BishopPST_EG[r, c]);
  end;

  // Black bishops.
  pieceBB := State.Pieces[bB];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Dec(ScoreMG, BishopPST_MG[7 - r, c]);
    Dec(ScoreEG, BishopPST_EG[7 - r, c]);
  end;

  // White rooks.
  pieceBB := State.Pieces[wR];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Inc(ScoreMG, RookPST_MG[r, c]);
    Inc(ScoreEG, RookPST_EG[r, c]);
  end;

  // Black rooks.
  pieceBB := State.Pieces[bR];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Dec(ScoreMG, RookPST_MG[7 - r, c]);
    Dec(ScoreEG, RookPST_EG[7 - r, c]);
  end;

  // White queens.
  pieceBB := State.Pieces[wQ];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Inc(ScoreMG, QueenPST_MG[r, c]);
    Inc(ScoreEG, QueenPST_EG[r, c]);
  end;

  // Black queens.
  pieceBB := State.Pieces[bQ];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Dec(ScoreMG, QueenPST_MG[7 - r, c]);
    Dec(ScoreEG, QueenPST_EG[7 - r, c]);
  end;

  // White king (MG + EG PST).
  pieceBB := State.Pieces[wK];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Inc(ScoreMG, KingPST_MG[r, c]);
    Inc(ScoreEG, KingPST_EG   [r, c]);
  end;

  // Black king.
  pieceBB := State.Pieces[bK];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    Dec(ScoreMG, KingPST_MG[7 - r, c]);
    Dec(ScoreEG, KingPST_EG   [7 - r, c]);
  end;

  // =========================================================================
  // PASS 2: Bishop pair bonus
  // ~30cp, roughly a third of a pawn, consistent with engine consensus
  // =========================================================================
  if WhiteBishops >= 2 then
  begin
    Inc(ScoreMG, 30);
    Inc(ScoreEG, 30);
  end;
  if BlackBishops >= 2 then
  begin
    Dec(ScoreMG, 30);
    Dec(ScoreEG, 30);
  end;

  // =========================================================================
  // PASS 3: Pawn structure bonuses and penalties (per file)
  //
  // v0984 — per-file integer arrays gone. Each file's count / front /
  // rear is derived once from the side's pawn bitboard intersected
  // with FileMask[c] (PopCnt for count, BsrQWord for most-advanced,
  // BsfQWord for rear-most). The triple-check passed-pawn test
  // collapses to a single AND against WhitePassedMask[wFrontSq] /
  // BlackPassedMask[bFrontSq]. The rear-support side of the backward-
  // pawn test uses AdjacentFileMask[c] AND RanksAtOrBelow / Above of
  // the rear-most LERF rank.
  //
  // Bonus values, signs, MG/EG splits, and the per-rank case
  // statements are byte-for-byte the same as v0983; bench node counts
  // must match v0983 exactly.
  //
  // v1.00-rc8: the whole pass is now cached against State.PawnHash. Its
  // output is exactly two numbers — the middlegame and endgame contribution
  // summed over all eight files — and those depend ONLY on the pawn
  // placement, which the pawn key captures. So we first PROBE the pawn hash
  // table:
  //   * hit  -> add the cached (dMG, dEG) and skip the per-file loop entirely.
  //   * miss -> run the loop below into the pMG/pEG accumulators (identical
  //             arithmetic to v0983, only the accumulator names changed from
  //             ScoreMG/ScoreEG to pMG/pEG), store the result, then fold it in.
  // Because the cached value is the exact loop output, a hit is bit-identical
  // to a miss — this can only change speed, never a search decision.
  //
  // v1.00-rc15 step 1: the connected/phalanx term joins this pass. Cache-
  // safety verified: its three flags (supported / phalanx / opposed) are
  // functions of wPawns/bPawns and precomputed masks ONLY — no king, no
  // piece, no side-to-move input — so the pawn key fully determines the
  // term and the cached (dMG, dEG) stay exact.
  // =========================================================================
  pawnIdx := Integer(State.PawnHash and QWord(PAWN_HASH_MASK));
  pawnHit := PawnHashTable[pawnIdx].Valid and
             (PawnHashTable[pawnIdx].Key = State.PawnHash);

  if pawnHit then
  begin
    // Cache hit: apply the stored pass-3 contribution and fall through past
    // the per-file loop (guarded by 'not pawnHit' below).
    Inc(ScoreMG, PawnHashTable[pawnIdx].dMG);
    Inc(ScoreEG, PawnHashTable[pawnIdx].dEG);
  end;

  pMG := 0;
  pEG := 0;
  if not pawnHit then
  for c := 0 to 7 do
  begin
    // -------- Per-file scratch (v0984) --------
    wFile  := wPawns and FileMask[c];
    bFile  := bPawns and FileMask[c];
    wCount := Integer(PopCnt(wFile));
    bCount := Integer(PopCnt(bFile));
    wAdj   := wPawns and AdjacentFileMask[c];
    bAdj   := bPawns and AdjacentFileMask[c];

    // Doubled pawn penalty
    if wCount > 1 then
    begin
      Dec(pMG, (wCount - 1) * DoubledPawnMG);
      Dec(pEG, (wCount - 1) * DoubledPawnEG);
    end;
    if bCount > 1 then
    begin
      Inc(pMG, (bCount - 1) * DoubledPawnMG);
      Inc(pEG, (bCount - 1) * DoubledPawnEG);
    end;

    // Isolated pawn penalty
    // v0984: "no own pawn on file c-1 OR c+1" reduces to wAdj = 0
    // (AdjacentFileMask drops the off-board neighbour, so the (c>0)
    // and (c<7) guards of v0983 are baked into the mask construction).
    if wFile <> 0 then
    begin
      IsIsolated := (wAdj = 0);
      if IsIsolated then
      begin
        Dec(pMG, IsolatedPawnMG);
        Dec(pEG, IsolatedPawnEG);
      end;
    end;
    if bFile <> 0 then
    begin
      IsIsolated := (bAdj = 0);
      if IsIsolated then
      begin
        Inc(pMG, IsolatedPawnMG);
        Inc(pEG, IsolatedPawnEG);
      end;
    end;

    // Passed pawn bonus (white)
    // v0984: wFrontSq = MSB of wFile = highest LERF bit = highest
    // LERF rank = most-advanced row (lowest row number). The triple-
    // condition row comparison on bPawnFront[c-1..c+1] reduces to
    //   (WhitePassedMask[wFrontSq] AND bPawns) = 0.
    // v1.00-rc10: bonus is now a per-relative-rank table lookup
    // (PassedPawnMG / PassedPawnEG) instead of the flat v0960 case
    // (60/40/25/15, 1x MG / 2x EG). For white the relative rank IS
    // the LERF rank of the front pawn (wFrontSq shr 3): 1 = pawn
    // still on its start rank, 6 = one step from promotion.
    if wFile <> 0 then
    begin
      wFrontSq := Integer(BsrQWord(wFile));
      IsNotPassed := (WhitePassedMask[wFrontSq] and bPawns) <> 0;
      if not IsNotPassed then
      begin
        relRank := wFrontSq shr 3;   // LERF rank = white relative rank
        Inc(pMG, PassedPawnMG[relRank]);
        Inc(pEG, PassedPawnEG[relRank]);
      end;
    end;

    // Passed pawn bonus (black)
    // v0984: bFrontSq = LSB of bFile = lowest LERF bit = lowest LERF
    // rank = most-advanced black row (highest row number).
    // v1.00-rc10: same per-relative-rank table lookup as white. Black
    // advances toward LOWER LERF ranks, so the black relative rank is
    // the mirror: 7 - (bFrontSq shr 3). One shared table pair serves
    // both colours symmetrically.
    if bFile <> 0 then
    begin
      bFrontSq := Integer(BsfQWord(bFile));

      IsNotPassed := (BlackPassedMask[bFrontSq] and wPawns) <> 0;
      if not IsNotPassed then
      begin
        relRank := 7 - (bFrontSq shr 3);   // mirrored LERF rank = black relative rank
        Dec(pMG, PassedPawnMG[relRank]);
        Dec(pEG, PassedPawnEG[relRank]);
      end;
    end;

    // Backward pawn penalty (v0963) — white
    // v0983 form: HasRearSupport iff exists own pawn on adjacent file
    // with row >= wPawnRear[c]. In LERF that means: exists own pawn on
    // AdjacentFileMask[c] with LERF rank <= LERF rank of wRearSq.
    // wRearSq = LSB of wFile (rear-most = highest row = lowest LERF
    // rank on this file). RanksAtOrBelow[wRearSq shr 3] is the
    // inclusive band of LERF ranks <= wRearSq's rank.
    //
    // Stop-square attack test is unchanged from v0983: PawnAttacks[1,
    // stopSq] AND bPawns. stopSq is one LERF rank above wRearSq, i.e.
    // wRearSq + 8 — equivalent to SquareIndex(wPawnRear[c] - 1, c).
    if wFile <> 0 then
    begin
      wRearSq := Integer(BsfQWord(wFile));
      HasRearSupport := (wAdj and RanksAtOrBelow[wRearSq shr 3]) <> 0;

      stopSq := wRearSq + 8;  // one LERF rank above; = SquareIndex(rearRow - 1, c)
      StopAttacked := (PawnAttacks[1, stopSq] and bPawns) <> 0;

      IsBackward := (not HasRearSupport) and StopAttacked;
      if IsBackward then
      begin
        Dec(pMG, BackwardPawnMG);
        Dec(pEG, BackwardPawnEG);
      end;
    end;

    // Backward pawn penalty — black
    // v0984: symmetric. bRearSq = MSB of bFile (rear-most black =
    // lowest row = highest LERF rank). HasRearSupport iff exists own
    // black pawn on adjacent file with LERF rank >= bRearSq's, i.e.
    // bAdj AND RanksAtOrAbove[bRearSq shr 3] is non-zero. Stop square
    // is one LERF rank below bRearSq (= bRearSq - 8).
    if bFile <> 0 then
    begin
      bRearSq := Integer(BsrQWord(bFile));

      HasRearSupport := (bAdj and RanksAtOrAbove[bRearSq shr 3]) <> 0;

      stopSq := bRearSq - 8;  // one LERF rank below; = SquareIndex(rearRow + 1, c)
      StopAttacked := (PawnAttacks[0, stopSq] and wPawns) <> 0;

      IsBackward := (not HasRearSupport) and StopAttacked;
      if IsBackward then
      begin
        Inc(pMG, BackwardPawnMG);
        Inc(pEG, BackwardPawnEG);
      end;
    end;

    // Connected/phalanx pawns (v1.00-rc15 step 1) — white.
    // EVERY pawn on the file is tested (unlike the passed/backward terms,
    // which look only at the front/rear pawn). Flags, all pawn-placement
    // only (hence pawn-hash safe):
    //   supported: an own pawn defends sq. PawnAttacks[0, sq] is the set
    //     of squares FROM WHICH a white pawn attacks sq (see the table
    //     doc), so one AND against wPawns is the defender test.
    //   phalanx:   an own pawn on an adjacent file on the SAME rank.
    //     wAdj (= wPawns AND AdjacentFileMask[c]) AND RankMask[rank].
    //   opposed:   an enemy pawn somewhere STRICTLY ahead on the same
    //     file. bFile AND RanksAtOrAbove[rank+1]; a white pawn's LERF
    //     rank is 1..6, so rank+1 never exceeds 7.
    // Award: (2 + phalanx - opposed) * Connected??[relRank] when
    // supported or phalanx — see the const-block comment for the theory
    // and the linearity argument.
    connBB := wFile;
    while connBB <> 0 do
    begin
      sq := Integer(BsfQWord(connBB)); connBB := connBB and (connBB - 1);
      relRank     := sq shr 3;                       // white relRank = LERF rank
      IsSupported := (PawnAttacks[0, sq] and wPawns) <> 0;
      IsPhalanx   := (wAdj and RankMask[relRank]) <> 0;
      if IsSupported or IsPhalanx then
      begin
        IsOpposed := (bFile and RanksAtOrAbove[relRank + 1]) <> 0;
        connM     := 2 + Ord(IsPhalanx) - Ord(IsOpposed);
        Inc(pMG, connM * ConnectedMG[relRank]);
        Inc(pEG, connM * ConnectedEG[relRank]);
      end;
    end;

    // Connected/phalanx pawns — black mirror. Defenders come from
    // PawnAttacks[1, sq] (squares from which a BLACK pawn attacks sq);
    // "ahead" for black is LOWER LERF ranks, so opposed tests
    // wFile AND RanksAtOrBelow[rank-1] (black pawn LERF rank is 1..6,
    // so rank-1 never goes below 0). relRank is the mirror 7 - rank.
    connBB := bFile;
    while connBB <> 0 do
    begin
      sq := Integer(BsfQWord(connBB)); connBB := connBB and (connBB - 1);
      IsSupported := (PawnAttacks[1, sq] and bPawns) <> 0;
      IsPhalanx   := (bAdj and RankMask[sq shr 3]) <> 0;
      if IsSupported or IsPhalanx then
      begin
        IsOpposed := (wFile and RanksAtOrBelow[(sq shr 3) - 1]) <> 0;
        connM     := 2 + Ord(IsPhalanx) - Ord(IsOpposed);
        relRank   := 7 - (sq shr 3);                 // mirrored relative rank
        Dec(pMG, connM * ConnectedMG[relRank]);
        Dec(pEG, connM * ConnectedEG[relRank]);
      end;
    end;
  end; // for c (per-file pawn structure loop; runs only on a cache miss)

  // v1.00-rc8: on a miss we have just computed the full PASS 3 contribution
  // in (pMG, pEG). Fold it into the running score AND write it back to the
  // pawn hash table so the next occurrence of this pawn structure is a hit.
  // Always-overwrite replacement: last writer wins (see the table comment).
  // On a HIT this whole block is skipped — the cached deltas were already
  // added at the probe above and pMG/pEG stayed zero.
  if not pawnHit then
  begin
    Inc(ScoreMG, pMG);
    Inc(ScoreEG, pEG);
    PawnHashTable[pawnIdx].Key   := State.PawnHash;
    PawnHashTable[pawnIdx].dMG   := pMG;
    PawnHashTable[pawnIdx].dEG   := pEG;
    PawnHashTable[pawnIdx].Valid := True;
  end;

  // =========================================================================
  // PASS 4 (v0980): Rook open/semi-open file bonuses
  // Iterate rook bitboards. v0984 drops the wPawnCount / bPawnCount
  // array lookup in favour of a direct (wPawns AND FileMask[c]) = 0
  // test against the live bitboards. Mathematically identical to v0975.
  // =========================================================================

  // -------------------------------------------------------------------------
  // v1.00-rc18 step 4: build the passed-pawn bitboards ONCE, fresh from the
  // pawn placement. This deliberately does NOT read the pawn-hash entry
  // (which stores only dMG/dEG) and is NOT itself cached — recomputing per
  // Evaluate is cheap and keeps the pawn-hash infrastructure untouched
  // (the plan's requested simplest correct variant). The test is the SAME
  // one PASS 3 uses (most-advanced pawn per file vs the passed mask), so
  // wPassed/bPassed are guaranteed consistent with the cached passed-pawn
  // score. Exactly the front pawn of each file is tested — the one pawn
  // PASS 3 scored — so at most one bit per file is set.
  // -------------------------------------------------------------------------
  wPassed := 0;
  bPassed := 0;
  for c := 0 to 7 do
  begin
    passFile := wPawns and FileMask[c];
    if passFile <> 0 then
    begin
      passSq := Integer(BsrQWord(passFile));        // front (most-advanced) white pawn
      if (WhitePassedMask[passSq] and bPawns) = 0 then
        wPassed := wPassed or (QWord(1) shl passSq);
    end;
    passFile := bPawns and FileMask[c];
    if passFile <> 0 then
    begin
      passSq := Integer(BsfQWord(passFile));        // front (most-advanced) black pawn
      if (BlackPassedMask[passSq] and wPawns) = 0 then
        bPassed := bPassed or (QWord(1) shl passSq);
    end;
  end;

  pieceBB := State.Pieces[wR];
  while pieceBB <> 0 do
  begin
    sq := Integer(BsfQWord(pieceBB)); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    if (wPawns and FileMask[c]) = 0 then
    begin
      if (bPawns and FileMask[c]) = 0 then
      begin
        Inc(ScoreMG, 25);
        Inc(ScoreEG, 25);
      end
      else
      begin
        Inc(ScoreMG, 15);
        Inc(ScoreEG, 15);
      end;
    end;
    // v1.00-rc18 step 4 — white rook terms. Use the LERF rank (sq shr 3)
    // directly, NOT r from SquareCoords (which is the mailbox row 7-rank).
    // (1) Rook on relative rank 7 = white LERF rank 6, with the enemy king
    //     on LERF rank 7 OR a black pawn still on LERF rank 6.
    if (sq shr 3) = 6 then
      if ((State.Pieces[bK] and RankMask[7]) <> 0) or
         ((bPawns and RankMask[6]) <> 0) then
      begin
        Inc(ScoreMG, RookOn7thMG);
        Inc(ScoreEG, RookOn7thEG);
      end;
    // (2) Rook behind an OWN passed pawn: same file, rook on a LOWER LERF
    //     rank than the passer (origin side). One file holds at most one
    //     white passer, so test this file's passer (if any) and compare.
    if (wPassed and FileMask[c]) <> 0 then
    begin
      passSq := Integer(BsrQWord(wPassed and FileMask[c]));
      if sq < passSq then
      begin
        Inc(ScoreMG, RookBehindOwnPassedMG);
        Inc(ScoreEG, RookBehindOwnPassedEG);
      end;
    end;
    // (3) Rook behind an ENEMY passed pawn: same file, white rook on a
    //     HIGHER LERF rank than the black passer (between passer and its
    //     promotion square on rank 1 — i.e. the rook is "behind" the pawn
    //     from the pawn's advance direction).
    if (bPassed and FileMask[c]) <> 0 then
    begin
      passSq := Integer(BsfQWord(bPassed and FileMask[c]));
      if sq > passSq then
      begin
        Inc(ScoreMG, RookBehindEnemyPassedMG);
        Inc(ScoreEG, RookBehindEnemyPassedEG);
      end;
    end;
  end;

  pieceBB := State.Pieces[bR];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    SquareCoords(sq, r, c);
    if (bPawns and FileMask[c]) = 0 then
    begin
      if (wPawns and FileMask[c]) = 0 then
      begin
        Dec(ScoreMG, 25);
        Dec(ScoreEG, 25);
      end
      else
      begin
        Dec(ScoreMG, 15);
        Dec(ScoreEG, 15);
      end;
    end;
    // v1.00-rc18 step 4 — black rook terms, mirror of white. Use LERF
    // rank (sq shr 3) directly, not r from SquareCoords.
    // (1) Rook on relative rank 7 = black LERF rank 1, with the white king
    //     on LERF rank 0 OR a white pawn still on LERF rank 1.
    if (sq shr 3) = 1 then
      if ((State.Pieces[wK] and RankMask[0]) <> 0) or
         ((wPawns and RankMask[1]) <> 0) then
      begin
        Dec(ScoreMG, RookOn7thMG);
        Dec(ScoreEG, RookOn7thEG);
      end;
    // (2) Rook behind an OWN (black) passed pawn: same file, black rook on
    //     a HIGHER LERF rank than the passer (origin side for black, which
    //     advances toward lower ranks).
    if (bPassed and FileMask[c]) <> 0 then
    begin
      passSq := Integer(BsfQWord(bPassed and FileMask[c]));
      if sq > passSq then
      begin
        Dec(ScoreMG, RookBehindOwnPassedMG);
        Dec(ScoreEG, RookBehindOwnPassedEG);
      end;
    end;
    // (3) Rook behind an ENEMY (white) passed pawn: same file, black rook
    //     on a LOWER LERF rank than the white passer (between passer and
    //     its promotion square on rank 8).
    if (wPassed and FileMask[c]) <> 0 then
    begin
      passSq := Integer(BsrQWord(wPassed and FileMask[c]));
      if sq < passSq then
      begin
        Dec(ScoreMG, RookBehindEnemyPassedMG);
        Dec(ScoreEG, RookBehindEnemyPassedEG);
      end;
    end;
  end;

  // =========================================================================
  // PASS 5 (v0981): Mobility evaluation
  // For each non-pawn non-king piece of each side, count the number of
  // legal-destination squares (= attack set AND NOT own_occupancy, which
  // includes captures of enemy pieces and quiet squares but excludes
  // own-piece blockers). Multiply the count by a per-piece-type weight
  // and add to ScoreMG / ScoreEG with the appropriate sign.
  //
  // Pieces included: knight, bishop, rook, queen.
  // Pieces excluded:
  //   - Pawn: pawn structure terms already cover this (PST, passed /
  //     doubled / isolated / backward). Adding pawn "mobility" here
  //     would double-count and be very noisy.
  //   - King: counting king mobility rewards king activity, which is
  //     correct in EG (already handled by KingPST_EG + EG centre
  //     distance) but DANGEROUS in MG, where an active king is exposed.
  //     Cleaner to leave the king out of the mobility term entirely.
  //
  // v1.00-rc11: the fixed per-square weight multiply is replaced by a
  // per-piece-type table lookup indexed by the SAME mobility count:
  //   Knight: KnightMobMG/EG[0..8]    Bishop: BishopMobMG/EG[0..13]
  //   Rook:   RookMobMG/EG[0..14]     Queen:  QueenMobMG/EG[0..27]
  // The tables are seeded linearly from the v0981 weights (N 4/4, B 5/5,
  // R 2/4, Q 1/2 MG/EG; entry[m] = m * weight), so the seeded build is
  // bit-identical to the old multiply (bench-verified); the saturation
  // shape (0->3 moves huge, 20->23 nearly nil) is supplied by Texel
  // tuning, not hand-imposed. Historical v0981 note kept below.
  //
  // Weights before rc11 (centipawn per attacked-and-not-own square):
  //   Knight: 4 MG / 4 EG
  //   Bishop: 5 MG / 5 EG
  //   Rook:   2 MG / 4 EG  (rooks gain enormously in open EG positions)
  //   Queen:  1 MG / 2 EG  (kept low — queen value is already high)
  //
  // These are middle-of-the-road values from the Glaurung / early-
  // Stockfish era. They produce ~20-40cp swing total in a typical MG
  // position — meaningful but not overwhelming. No "safe mobility"
  // filter (excluding squares attacked by enemy pawns) yet; that would
  // change the table INDEX, so it stays a separate later change.
  //
  // SliderAttacks(sq, start, end) returns the full attack set from sq
  // across the given direction range. Bishops use (4, 7), rooks (0, 3),
  // queens (0, 7). Knight attacks come from the precomputed
  // KnightAttacks[sq] table.
  // =========================================================================

  // v1.00-rc12: bind the king zones and clear the attack-unit accumulators
  // before the mobility sweep. Zone = king ring + king square. BsfQWord on
  // the king bitboard is safe: a legal position always has both kings.
  // v1.00-rc13: king squares are now bound to wKsq/bKsq locals so the king
  // ring can also be folded into the side attack maps below.
  wKsq := Integer(BsfQWord(State.Pieces[wK]));
  bKsq := Integer(BsfQWord(State.Pieces[bK]));
  wKingZone := KingAttacks[wKsq] or State.Pieces[wK];
  bKingZone := KingAttacks[bKsq] or State.Pieces[bK];
  wAttackUnits := 0;  bAttackUnits := 0;
  wAttackers   := 0;  bAttackers   := 0;

  // v1.00-rc13: pawn attack maps. White pawns attack up-left (LERF +7,
  // a-file sources masked to prevent h-file wraparound) and up-right
  // (LERF +9, h-file sources masked). Black is the mirror (-7 / -9).
  // These feed both the threat terms (PASS 7) and the side attack maps.
  wPawnAtk := ((wPawns and not FileMask[0]) shl 7) or
              ((wPawns and not FileMask[7]) shl 9);
  bPawnAtk := ((bPawns and not FileMask[7]) shr 7) or
              ((bPawns and not FileMask[0]) shr 9);

  // v1.00-rc13: side attack maps start from pawns + king ring; the
  // PASS 5 loops OR in every knight/bishop/rook/queen attack set as it
  // is computed for mobility. Minor attack maps start empty.
  wAttackBB := wPawnAtk or KingAttacks[wKsq];
  bAttackBB := bPawnAtk or KingAttacks[bKsq];
  wMinorAtk := 0;
  bMinorAtk := 0;

  // -- White mobility --
  // v1.00-rc21 step 7: SAFE MOBILITY. The destination mask now also excludes
  // squares attacked by ENEMY pawns: a square a knight/bishop/rook/queen can
  // technically move to but where an enemy pawn would capture it for free is
  // not real mobility. NotOwn becomes (NOT own occupancy) AND (NOT enemy pawn
  // attacks). bPawnAtk is complete above, before this loop. This CHANGES the
  // mobility count (index) for every affected piece, so the old tuned
  // mobility tables become stale seeds — acceptable, the joint retune
  // re-fits them. Only NotOwn changes; every mobility loop body is untouched
  // because they all read NotOwn.
  NotOwn := (not State.Occupied[0]) and (not bPawnAtk);

  pieceBB := State.Pieces[wN];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    atk := KnightAttacks[sq];                                  // rc12: keep raw set
    wAttackBB := wAttackBB or atk;                             // rc13: side attack map
    wMinorAtk := wMinorAtk or atk;                             // rc13: minor threats
    mobCount := Integer(PopCnt(atk and NotOwn));
    Inc(ScoreMG, KnightMobMG[mobCount]);
    Inc(ScoreEG, KnightMobEG[mobCount]);
    // rc14/rc15: knight outpost. Three conditions, cheapest first:
    //   (a) relative ranks 4-6 (white LERF ranks 3..5),
    //   (b) defended by an own pawn (bit test against wPawnAtk, which
    //       is complete before this loop runs),
    //   (c) no black pawn can now or ever attack sq (outpost mask).
    // rc15 step 2: the flat bonus is now OutpostMG/EG[relRank]; for white
    // the relative rank is the LERF rank (sq shr 3), guaranteed 3..5 here.
    if ((sq shr 3) in [3, 4, 5]) then
    begin
      sqBB := QWord(1) shl sq;
      if ((wPawnAtk and sqBB) <> 0) and
         ((bPawns and WhiteOutpostMask[sq]) = 0) then
      begin
        Inc(ScoreMG, OutpostMG[sq shr 3]);
        Inc(ScoreEG, OutpostEG[sq shr 3]);
      end;
    end;
    zoneHits := Integer(PopCnt(atk and bKingZone));            // rc12: king pressure
    if zoneHits > 0 then
    begin
      Inc(bAttackUnits, 2 * zoneHits);
      Inc(bAttackers);
    end;
  end;

  pieceBB := State.Pieces[wB];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    atk := SliderAttacks(sq, 4, 7);                            // rc12: keep raw set
    wAttackBB := wAttackBB or atk;                             // rc13: side attack map
    wMinorAtk := wMinorAtk or atk;                             // rc13: minor threats
    mobCount := Integer(PopCnt(atk and NotOwn));
    Inc(ScoreMG, BishopMobMG[mobCount]);
    Inc(ScoreEG, BishopMobEG[mobCount]);
    // rc17 step 3: bad bishop — blocked central own pawns on the bishop's
    // colour complex. A white pawn is BLOCKED when the square in front
    // (sq+8) is occupied by any piece; as a bitboard that is
    // wPawns AND (AllOccupied shr 8) — shifting occupancy DOWN one rank
    // lines each front-square occupier up with the pawn behind it. Then
    // AND the bishop's colour complex and the central-file band, and
    // PopCnt. Single-shot for the whole side, no per-pawn loop.
    if ((QWord(1) shl sq) and LightSquaresBB) <> 0 then
      colorBB := LightSquaresBB
    else
      colorBB := DarkSquaresBB;
    badPawns := Integer(PopCnt(wPawns and colorBB and CentralFilesBB
                               and (State.AllOccupied shr 8)));
    Dec(ScoreMG, badPawns * BadBishopPawnMG);
    Dec(ScoreEG, badPawns * BadBishopPawnEG);
    // rc15 step 2: bishop outpost — same three conditions as the knight
    // outpost (relative rank 4-6 = white LERF 3..5, pawn-defended, on a
    // permanent hole via WhiteOutpostMask). Half-weight scalar pair. sqBB
    // is reused from the bad-bishop colour test above? No — that test used
    // (QWord(1) shl sq) inline, so bind sqBB here for the defended test.
    if ((sq shr 3) in [3, 4, 5]) then
    begin
      sqBB := QWord(1) shl sq;
      if ((wPawnAtk and sqBB) <> 0) and
         ((bPawns and WhiteOutpostMask[sq]) = 0) then
      begin
        Inc(ScoreMG, BishopOutpostMG);
        Inc(ScoreEG, BishopOutpostEG);
      end;
    end;
    zoneHits := Integer(PopCnt(atk and bKingZone));
    if zoneHits > 0 then
    begin
      Inc(bAttackUnits, 2 * zoneHits);
      Inc(bAttackers);
    end;
  end;

  pieceBB := State.Pieces[wR];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    atk := SliderAttacks(sq, 0, 3);                            // rc12: keep raw set
    wAttackBB := wAttackBB or atk;                             // rc13: side attack map
    mobCount := Integer(PopCnt(atk and NotOwn));
    Inc(ScoreMG, RookMobMG[mobCount]);
    Inc(ScoreEG, RookMobEG[mobCount]);
    zoneHits := Integer(PopCnt(atk and bKingZone));
    if zoneHits > 0 then
    begin
      Inc(bAttackUnits, 3 * zoneHits);
      Inc(bAttackers);
    end;
  end;

  pieceBB := State.Pieces[wQ];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    atk := SliderAttacks(sq, 0, 7);                            // rc12: keep raw set
    wAttackBB := wAttackBB or atk;                             // rc13: side attack map
    mobCount := Integer(PopCnt(atk and NotOwn));
    Inc(ScoreMG, QueenMobMG[mobCount]);
    Inc(ScoreEG, QueenMobEG[mobCount]);
    zoneHits := Integer(PopCnt(atk and bKingZone));
    if zoneHits > 0 then
    begin
      Inc(bAttackUnits, 5 * zoneHits);
      Inc(bAttackers);
    end;
  end;

  // -- Black mobility --
  // v1.00-rc21 step 7: safe mobility, black mirror — exclude squares
  // attacked by WHITE pawns (wPawnAtk).
  NotOwn := (not State.Occupied[1]) and (not wPawnAtk);

  pieceBB := State.Pieces[bN];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    atk := KnightAttacks[sq];                                  // rc12: keep raw set
    bAttackBB := bAttackBB or atk;                             // rc13: side attack map
    bMinorAtk := bMinorAtk or atk;                             // rc13: minor threats
    mobCount := Integer(PopCnt(atk and NotOwn));
    Dec(ScoreMG, KnightMobMG[mobCount]);
    Dec(ScoreEG, KnightMobEG[mobCount]);
    // rc14/rc15: knight outpost, black mirror. Relative ranks 4-6 for black
    // are LERF ranks 4..2; defended test against bPawnAtk; hole test
    // against white pawns via BlackOutpostMask.
    // rc15 step 2: index the OutpostMG/EG tables by the black relative
    // rank 7 - (sq shr 3), the mirror of the white indexing — one shared
    // table pair serves both sides, exactly as the passed-pawn tables do.
    if ((sq shr 3) in [2, 3, 4]) then
    begin
      sqBB := QWord(1) shl sq;
      if ((bPawnAtk and sqBB) <> 0) and
         ((wPawns and BlackOutpostMask[sq]) = 0) then
      begin
        Dec(ScoreMG, OutpostMG[7 - (sq shr 3)]);
        Dec(ScoreEG, OutpostEG[7 - (sq shr 3)]);
      end;
    end;
    zoneHits := Integer(PopCnt(atk and wKingZone));            // rc12: king pressure
    if zoneHits > 0 then
    begin
      Inc(wAttackUnits, 2 * zoneHits);
      Inc(wAttackers);
    end;
  end;

  pieceBB := State.Pieces[bB];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    atk := SliderAttacks(sq, 4, 7);                            // rc12: keep raw set
    bAttackBB := bAttackBB or atk;                             // rc13: side attack map
    bMinorAtk := bMinorAtk or atk;                             // rc13: minor threats
    mobCount := Integer(PopCnt(atk and NotOwn));
    Dec(ScoreMG, BishopMobMG[mobCount]);
    Dec(ScoreEG, BishopMobEG[mobCount]);
    // rc17 step 3: bad bishop, black mirror. A black pawn advances toward
    // LOWER ranks, so its front square is sq-8 and "blocked" is
    // bPawns AND (AllOccupied shl 8) — shifting occupancy UP one rank
    // aligns each front-square occupier with the black pawn above it.
    // Colour complexes are side-independent; central-file band identical.
    if ((QWord(1) shl sq) and LightSquaresBB) <> 0 then
      colorBB := LightSquaresBB
    else
      colorBB := DarkSquaresBB;
    badPawns := Integer(PopCnt(bPawns and colorBB and CentralFilesBB
                               and (State.AllOccupied shl 8)));
    Inc(ScoreMG, badPawns * BadBishopPawnMG);
    Inc(ScoreEG, badPawns * BadBishopPawnEG);
    // rc15 step 2: bishop outpost, black mirror. Same three conditions
    // (relative rank 4-6 = black LERF 4..2, pawn-defended via bPawnAtk,
    // permanent hole via BlackOutpostMask), index-free half-weight scalar.
    if ((sq shr 3) in [2, 3, 4]) then
    begin
      sqBB := QWord(1) shl sq;
      if ((bPawnAtk and sqBB) <> 0) and
         ((wPawns and BlackOutpostMask[sq]) = 0) then
      begin
        Dec(ScoreMG, BishopOutpostMG);
        Dec(ScoreEG, BishopOutpostEG);
      end;
    end;
    zoneHits := Integer(PopCnt(atk and wKingZone));
    if zoneHits > 0 then
    begin
      Inc(wAttackUnits, 2 * zoneHits);
      Inc(wAttackers);
    end;
  end;

  pieceBB := State.Pieces[bR];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    atk := SliderAttacks(sq, 0, 3);                            // rc12: keep raw set
    bAttackBB := bAttackBB or atk;                             // rc13: side attack map
    mobCount := Integer(PopCnt(atk and NotOwn));
    Dec(ScoreMG, RookMobMG[mobCount]);
    Dec(ScoreEG, RookMobEG[mobCount]);
    zoneHits := Integer(PopCnt(atk and wKingZone));
    if zoneHits > 0 then
    begin
      Inc(wAttackUnits, 3 * zoneHits);
      Inc(wAttackers);
    end;
  end;

  pieceBB := State.Pieces[bQ];
  while pieceBB <> 0 do
  begin
    sq := BsfQWord(pieceBB); pieceBB := pieceBB and (pieceBB - 1);
    atk := SliderAttacks(sq, 0, 7);                            // rc12: keep raw set
    bAttackBB := bAttackBB or atk;                             // rc13: side attack map
    mobCount := Integer(PopCnt(atk and NotOwn));
    Dec(ScoreMG, QueenMobMG[mobCount]);
    Dec(ScoreEG, QueenMobEG[mobCount]);
    zoneHits := Integer(PopCnt(atk and wKingZone));
    if zoneHits > 0 then
    begin
      Inc(wAttackUnits, 5 * zoneHits);
      Inc(wAttackers);
    end;
  end;

  // =========================================================================
  // PASS 6 (v1.00-rc12): King safety via attack units (MG-only).
  //
  // The accumulators above hold, per king, the weighted count of enemy
  // knight/bishop/rook/queen attacks landing in the king zone (ring +
  // king square) and the number of distinct attacking pieces. With
  // fewer than two attackers the term is silent — the classic gate
  // that stops the table firing on a single developed piece that
  // merely eyes the king from across the board. The SafetyTable is
  // convex, so a queen joining an existing attack costs the defender
  // far more than the same queen attacking alone, which is exactly
  // the non-additivity that the flat shield/back-rank terms cannot
  // represent. MG-only: the tapered blend fades it in the endgame,
  // where the EG king terms want the OPPOSITE behaviour (activity).
  //
  // Overlap note: the pawn shield, back-rank penalty, and castle bonus
  // below measure the DEFENDER's structure; this pass measures the
  // ATTACKER's piece pressure. They coexist without double-counting,
  // though the shield penalties may deserve a downward revisit once
  // this term is SPRT-confirmed, since an open shield now also tends
  // to raise zoneHits indirectly.
  // =========================================================================
  if wAttackers >= 2 then
    Dec(ScoreMG, SafetyTable[Min(wAttackUnits, 99)]);
  if bAttackers >= 2 then
    Inc(ScoreMG, SafetyTable[Min(bAttackUnits, 99)]);

  // =========================================================================
  // PASS 7 (v1.00-rc13): Threat terms.
  //
  // Evaluated from the attack maps completed in PASS 5. Must run after
  // BOTH sides' loops: the hanging test needs the defender's full map.
  //
  //   Family 1 — pawn attacks minor / rook / queen. Counted per
  //     attacked PIECE (a piece attacked by two pawns counts once:
  //     the intersection is on the piece bitboard, not the pawn map).
  //   Family 2 — minor attacks rook / queen. Same counting.
  //   Family 3 — hanging: enemy non-king unit attacked by us and
  //     defended by nobody. Pawns included as victims. Stacks with
  //     families 1-2 by design (see the const-block comment).
  //
  // Sign convention as everywhere in Evaluate: white's threats Inc,
  // black's threats Dec. Both phases: unlike king safety, a threat is
  // a threat in the endgame too — if anything the EG values are
  // larger because fewer defensive resources exist.
  // =========================================================================

  // -- White threatens black --
  threatBB := wPawnAtk and (State.Pieces[bN] or State.Pieces[bB]);
  if threatBB <> 0 then
  begin
    Inc(ScoreMG, Integer(PopCnt(threatBB)) * PawnThreatMinorMG);
    Inc(ScoreEG, Integer(PopCnt(threatBB)) * PawnThreatMinorEG);
  end;
  threatBB := wPawnAtk and State.Pieces[bR];
  if threatBB <> 0 then
  begin
    Inc(ScoreMG, Integer(PopCnt(threatBB)) * PawnThreatRookMG);
    Inc(ScoreEG, Integer(PopCnt(threatBB)) * PawnThreatRookEG);
  end;
  threatBB := wPawnAtk and State.Pieces[bQ];
  if threatBB <> 0 then
  begin
    Inc(ScoreMG, Integer(PopCnt(threatBB)) * PawnThreatQueenMG);
    Inc(ScoreEG, Integer(PopCnt(threatBB)) * PawnThreatQueenEG);
  end;
  threatBB := wMinorAtk and State.Pieces[bR];
  if threatBB <> 0 then
  begin
    Inc(ScoreMG, Integer(PopCnt(threatBB)) * MinorThreatRookMG);
    Inc(ScoreEG, Integer(PopCnt(threatBB)) * MinorThreatRookEG);
  end;
  threatBB := wMinorAtk and State.Pieces[bQ];
  if threatBB <> 0 then
  begin
    Inc(ScoreMG, Integer(PopCnt(threatBB)) * MinorThreatQueenMG);
    Inc(ScoreEG, Integer(PopCnt(threatBB)) * MinorThreatQueenEG);
  end;
  // Hanging: black non-king units attacked by white, defended by nobody.
  threatBB := (State.Occupied[1] and not State.Pieces[bK]) and
              wAttackBB and not bAttackBB;
  if threatBB <> 0 then
  begin
    Inc(ScoreMG, Integer(PopCnt(threatBB)) * HangingMG);
    Inc(ScoreEG, Integer(PopCnt(threatBB)) * HangingEG);
  end;

  // -- Black threatens white --
  threatBB := bPawnAtk and (State.Pieces[wN] or State.Pieces[wB]);
  if threatBB <> 0 then
  begin
    Dec(ScoreMG, Integer(PopCnt(threatBB)) * PawnThreatMinorMG);
    Dec(ScoreEG, Integer(PopCnt(threatBB)) * PawnThreatMinorEG);
  end;
  threatBB := bPawnAtk and State.Pieces[wR];
  if threatBB <> 0 then
  begin
    Dec(ScoreMG, Integer(PopCnt(threatBB)) * PawnThreatRookMG);
    Dec(ScoreEG, Integer(PopCnt(threatBB)) * PawnThreatRookEG);
  end;
  threatBB := bPawnAtk and State.Pieces[wQ];
  if threatBB <> 0 then
  begin
    Dec(ScoreMG, Integer(PopCnt(threatBB)) * PawnThreatQueenMG);
    Dec(ScoreEG, Integer(PopCnt(threatBB)) * PawnThreatQueenEG);
  end;
  threatBB := bMinorAtk and State.Pieces[wR];
  if threatBB <> 0 then
  begin
    Dec(ScoreMG, Integer(PopCnt(threatBB)) * MinorThreatRookMG);
    Dec(ScoreEG, Integer(PopCnt(threatBB)) * MinorThreatRookEG);
  end;
  threatBB := bMinorAtk and State.Pieces[wQ];
  if threatBB <> 0 then
  begin
    Dec(ScoreMG, Integer(PopCnt(threatBB)) * MinorThreatQueenMG);
    Dec(ScoreEG, Integer(PopCnt(threatBB)) * MinorThreatQueenEG);
  end;
  // Hanging: white non-king units attacked by black, defended by nobody.
  threatBB := (State.Occupied[0] and not State.Pieces[wK]) and
              bAttackBB and not wAttackBB;
  if threatBB <> 0 then
  begin
    Dec(ScoreMG, Integer(PopCnt(threatBB)) * HangingMG);
    Dec(ScoreEG, Integer(PopCnt(threatBB)) * HangingEG);
  end;

  // =========================================================================
  // King safety (MG-only) and king centralisation (EG-only)
  // [unchanged from v0975]
  // =========================================================================
  if State.WhiteKingR <= 5 then Dec(ScoreMG, (5 - State.WhiteKingR) * 25);
  if (State.WhiteKingR = 7) and ((State.WhiteKingC = 6) or (State.WhiteKingC = 2)) then Inc(ScoreMG, 30);
  if State.BlackKingR >= 2 then Inc(ScoreMG, (State.BlackKingR - 2) * 25);
  if (State.BlackKingR = 0) and ((State.BlackKingC = 6) or (State.BlackKingC = 2)) then Dec(ScoreMG, 30);

  // v1.00-rc20: PawnShieldPenalty now returns a SIGNED sum of ShieldMG
  // entries (<= 0 with penalty seeds). Add it for white, subtract for
  // black — same net effect as the old "subtract a positive penalty".
  ScoreMG := ScoreMG + PawnShieldPenalty(State.WhiteKingR, State.WhiteKingC, 0);
  ScoreMG := ScoreMG - PawnShieldPenalty(State.BlackKingR, State.BlackKingC, 1);

  ScoreEG := ScoreEG - CentreDistance(State.WhiteKingR, State.WhiteKingC) * 10;
  ScoreEG := ScoreEG + CentreDistance(State.BlackKingR, State.BlackKingC) * 10;

  // v1.00-rc19 step 5: king / passed-pawn distance (EG only). Reuses the
  // PASS 4 wPassed/bPassed sets and the king squares. For each WHITE
  // passer, the black king wants to be near its front square (reward its
  // distance) and the white king wants to be near it too (penalise white
  // king distance). Signs mirror for black passers. wKsq/bKsq were bound
  // in PASS 5 and are still in scope here. NOT cached in the pawn hash:
  // this whole block runs after the cached PASS 3 delta and depends on
  // king squares, so the pawn-key invariant is preserved.
  passFile := wPassed;
  while passFile <> 0 do
  begin
    passSq := Integer(BsfQWord(passFile)); passFile := passFile and (passFile - 1);
    Inc(passSq, 8);   // front (advance) square; white passers never on rank 7
    Inc(ScoreEG, KingPassedEnemyEG * ChebDist(bKsq, passSq));
    Dec(ScoreEG, KingPassedOwnEG   * ChebDist(wKsq, passSq));
  end;
  passFile := bPassed;
  while passFile <> 0 do
  begin
    passSq := Integer(BsfQWord(passFile)); passFile := passFile and (passFile - 1);
    Dec(passSq, 8);   // front (advance) square for black; never on rank 0
    Dec(ScoreEG, KingPassedEnemyEG * ChebDist(wKsq, passSq));
    Inc(ScoreEG, KingPassedOwnEG   * ChebDist(bKsq, passSq));
  end;

  // Tempo bonus (v0962a)
  if State.SideToMove = 0 then Inc(ScoreMG, 10) else Dec(ScoreMG, 10);

  {$IFDEF TUNER}
    TunerLastMG := ScoreMG;
    TunerLastEG := ScoreEG;
    TunerLastPhase := gamePhase;
  {$ENDIF}

  // Tapered blend
  Score := (ScoreMG * gamePhase + ScoreEG * (MaxPhase - gamePhase)) div MaxPhase;
  if State.SideToMove = 1 then Score := -Score;
  Result := Score;
end;


function SEE(Move: TMove): integer;
{**Static Exchange Evaluation.**
 Simulates the full sequence of captures on Move.ToR/ToC assuming each
 side always recaptures with its least valuable attacker, and returns
 the net material swing in centipawns from the side-to-move's view.
 Positive = winning capture, 0 = even, negative = losing capture.

 Used to fix MVV-LVA's blind spot: a queen taking a pawn defended by a
 pawn looks great to MVV-LVA (10*100 - 9 = 991) but actually loses 800
 centipawns. SEE replays the swap-off statically and gives -800, which
 the caller uses to demote the move below killers/quiets.

 Algorithm (the "swap stack" form, e.g. CPW):
   1. Gain[0] is the value of the initial victim.
   2. We iterate: at each step the side-to-move's LVA captures whatever
      is currently sitting on the target square. The piece value sitting
      on the target then becomes the next victim.
   3. After we run out of attackers (or hit a king-legality stop), we
      fold backward with negamax: each side may stop the exchange if
      continuing would lose material.

 Implementation notes:
   - A local Removed map marks squares whose pieces have already
     entered the exchange. State.Board is never modified.
   - X-ray attackers (sliders behind a removed slider/pawn) appear
     naturally because the ray scan in FindLVA skips Removed squares.
   - En passant returns 0 (the captured pawn is not on the target
     square, and EP captures are rare enough that the approximation
     costs essentially no Elo).
   - Initial-move promotions are handled exactly: Gain[0] absorbs the
     (Q - P) material injection and the mover becomes a queen for the
     swap. Recapture promotions are handled the same way inside the
     loop. Under-promotions are never modelled in the swap — a
     recapturing pawn is always assumed to promote to queen, which is
     correct for SEE since the recapturer would always pick max value.
   - The king is allowed as an attacker, but only if the opposite
     side has no remaining attacker on the target. Otherwise the king
     would be capturing into check, which is illegal — we abort the
     exchange at the previous step in that case.
   - King value is set to 10000 (not 20000) so a king on the swap
     stack cannot overflow the integer arithmetic in pathological
     positions with many sliders. The exact king value never matters
     for the SEE result; it only needs to be larger than every other
     piece so the king is selected last.
   - No early pruning of the forward loop. The textbook
     max(-gain[d-1], gain[d]) < 0 short-circuit is unsafe in
     combination with the promotion-bonus adjustment (the pruning
     check fires before the bonus is added), and the cost saved is
     1-2 LVA scans per call — too small to chase before SPRT.

 v0974: FindLVA migrated to bitboards. Removed is now a single QWord
 (RemovedBB) instead of a [0..7, 0..7] boolean array. Pawn/knight/king
 attacker checks are single precomputed-mask intersections; slider
 scans use an "effective occupancy" of AllOccupied AND NOT RemovedBB to
 model X-ray reveal through removed pieces. State.Board is still
 consulted to read the piece type at a slider blocker square (cheaper
 than testing each Pieces[] bitboard separately for the type).

 v1.00-rc6: the slider scan uses the plain-magic probes under the same
 effective occupancy (two probes replace the eight per-ray scans). The
 candidate set must additionally be masked with NOT RemovedBB: removed
 pieces are transparent in effectiveOcc, so they can never be the
 terminating blocker of a ray, but their squares can still appear as
 pass-through squares of the probed attack set while remaining set in
 the (unmodified) Pieces[] bitboards. Equal-value ties between slider
 attackers on different rays are broken by DirIndexTab in the original
 ray order 0..7, so the piece FindLVA selects - and therefore the
 X-ray reveal sequence and the SEE value - is bit-identical to rc5.}
const
  SeeVal: array[TPiece] of integer = (
       0,                                    // EMPTY
     100, 320, 330, 500, 900, 10000,         // wP wN wB wR wQ wK
     100, 320, 330, 500, 900, 10000);        // bP bN bB bR bQ bK
var
  RemovedBB: QWord;         // v0974: was Removed: array[0..7, 0..7] of boolean
  Gain: array[0..31] of integer;
  d: integer;
  TR, TC: integer;          // target square (where all the captures happen)
  Side: integer;            // side whose turn it is to recapture next
  CurAttackerVal: integer;  // value of the piece currently sitting on TR/TC
  CurAttackerPiece: TPiece;
  NextR, NextC: integer;
  NextAttackerPiece: TPiece;
  NextAttackerVal: integer;
  DummyR, DummyC: integer;
  DummyPiece: TPiece;

  // ----------------------------------------------------------------
  // FindLVA: returns the value of the least-valuable piece of curSide
  // that attacks the target square (TR/TC), ignoring any square
  // already in RemovedBB. Returns 0 if no attacker exists.
  // Order of checks: pawn -> knight -> sliders (B/R/Q) -> king.
  // For sliders we scan all 8 rays once and track the lowest-value
  // matching piece (a bishop on a diagonal ray beats a queen on an
  // orthogonal one only if it has the lower value, etc).
  //
  // v0974: bitboard implementation. Pawn/knight/king use single mask
  // intersections against PawnAttacks/KnightAttacks/KingAttacks.
  // v1.00-rc6: sliders via two magic probes under an effective
  // occupancy that excludes removed squares — this gives
  // X-ray-through-Removed semantics for free.
  // ----------------------------------------------------------------
  function FindLVA(curSide: integer; out fr, fc: integer; out apiece: TPiece): integer;
  var
    sq, j: integer;
    pawnsBB, knightsBB, kingPiecesBB,
    bishopsQueensBB, rooksQueensBB: QWord;
    attackerBB, effectiveOcc: QWord;
    attackerSq, blockerR, blockerC: integer;
    bestVal: integer;
    bestPiece: TPiece;
    bestSq, bestDir: integer;
    blockerPiece: TPiece;
  begin
    sq := SquareIndex(TR, TC);

    if curSide = 0 then
    begin
      pawnsBB         := State.Pieces[wP];
      knightsBB       := State.Pieces[wN];
      kingPiecesBB    := State.Pieces[wK];
      bishopsQueensBB := State.Pieces[wB] or State.Pieces[wQ];
      rooksQueensBB   := State.Pieces[wR] or State.Pieces[wQ];
    end
    else
    begin
      pawnsBB         := State.Pieces[bP];
      knightsBB       := State.Pieces[bN];
      kingPiecesBB    := State.Pieces[bK];
      bishopsQueensBB := State.Pieces[bB] or State.Pieces[bQ];
      rooksQueensBB   := State.Pieces[bR] or State.Pieces[bQ];
    end;

    // Effective occupancy for slider X-rays: removed pieces become
    // transparent to the ray scan.
    effectiveOcc := State.AllOccupied and not RemovedBB;

    // (1) Pawns — cheapest. PawnAttacks[s, sq] is the bitboard of
    // squares from which a pawn of side s attacks sq.
    attackerBB := PawnAttacks[curSide, sq] and pawnsBB and not RemovedBB;
    if attackerBB <> 0 then
    begin
      attackerSq := BsfQWord(attackerBB);
      SquareCoords(attackerSq, fr, fc);
      if curSide = 0 then apiece := wP else apiece := bP;
      Exit(SeeVal[apiece]);
    end;

    // (2) Knights.
    attackerBB := KnightAttacks[sq] and knightsBB and not RemovedBB;
    if attackerBB <> 0 then
    begin
      attackerSq := BsfQWord(attackerBB);
      SquareCoords(attackerSq, fr, fc);
      if curSide = 0 then apiece := wN else apiece := bN;
      Exit(SeeVal[apiece]);
    end;

    // (3) Sliders: bishops, rooks, queens (v1.00-rc6, magic probes).
    // Each probe under effectiveOcc yields exactly the first effective
    // blocker in every direction; ANDing with the matching piece class
    // AND NOT RemovedBB leaves precisely the slider attackers the old
    // eight-ray scan would have found (see the doc header for why the
    // RemovedBB mask is required here). We record the lowest-value
    // match; equal values tie-break on DirIndexTab so the winner is the
    // one the old ray-order-0..7 scan (strict '<', first ray wins)
    // would have selected — bit-identical SEE.
    bestVal := 0;
    bestPiece := EMPTY;
    bestSq := 0;
    bestDir := 255;
    attackerBB := ((RookAttacksBB(sq, effectiveOcc)   and rooksQueensBB) or
                   (BishopAttacksBB(sq, effectiveOcc) and bishopsQueensBB))
                  and not RemovedBB;
    while attackerBB <> 0 do
    begin
      attackerSq := BsfQWord(attackerBB);
      attackerBB := attackerBB and (attackerBB - 1);
      SquareCoords(attackerSq, blockerR, blockerC);
      blockerPiece := State.Board[blockerR, blockerC];
      j := DirIndexTab[sq, attackerSq];
      if (bestPiece = EMPTY) or (SeeVal[blockerPiece] < bestVal) or
         ((SeeVal[blockerPiece] = bestVal) and (j < bestDir)) then
      begin
        bestVal := SeeVal[blockerPiece];
        bestPiece := blockerPiece;
        bestSq := attackerSq;
        bestDir := j;
      end;
    end;
    if bestPiece <> EMPTY then
    begin
      SquareCoords(bestSq, fr, fc);
      apiece := bestPiece;
      Exit(bestVal);
    end;

    // (4) King — highest value, also potentially illegal; the caller
    // is responsible for verifying the king isn't capturing into a
    // remaining attacker before committing.
    attackerBB := KingAttacks[sq] and kingPiecesBB and not RemovedBB;
    if attackerBB <> 0 then
    begin
      attackerSq := BsfQWord(attackerBB);
      SquareCoords(attackerSq, fr, fc);
      if curSide = 0 then apiece := wK else apiece := bK;
      Exit(SeeVal[apiece]);
    end;

    fr := -1; fc := -1; apiece := EMPTY;
    Exit(0);
  end;

begin
  // ----------------------------------------------------------------
  // Edge cases.
  // ----------------------------------------------------------------
  // En passant: the captured pawn isn't on the to-square, so the swap
  // stack doesn't model it correctly. Treat as a neutral capture.
  if Move.MoveType = MT_EN_PASSANT then Exit(0);
  // Defensive: SEE is meaningless on quiet moves. Caller should already
  // gate on capture status, but guard here too.
  if State.Board[Move.ToR, Move.ToC] = EMPTY then Exit(0);

  TR := Move.ToR;
  TC := Move.ToC;

  // v0974: Removed is now a single QWord. The initial mover's source
  // square enters the exchange immediately.
  RemovedBB := QWord(1) shl SquareIndex(Move.FromR, Move.FromC);

  // Gain[0] = value of the initial victim sitting on the target.
  Gain[0] := SeeVal[State.Board[TR, TC]];

  CurAttackerPiece := State.Board[Move.FromR, Move.FromC];
  CurAttackerVal  := SeeVal[CurAttackerPiece];

  // Initial-move promotion: the pawn becomes the promotion piece on
  // arrival. Two adjustments:
  //   - The mover gained (promoted - pawn) extra material at step 1,
  //     which gets folded into Gain[0] (so the opponent's view of the
  //     deficit at step 2 is correct).
  //   - The piece sitting on the target after step 1 is now the
  //     promotion piece, not the pawn, so CurAttackerVal switches.
  if Move.Promotion <> EMPTY then
  begin
    Gain[0]        := Gain[0] + SeeVal[Move.Promotion] - SeeVal[CurAttackerPiece];
    CurAttackerVal := SeeVal[Move.Promotion];
  end;

  // After the initial capture the opposite side gets to choose whether
  // to recapture. Side tracks who is "up" in the loop.
  if IsWhite(CurAttackerPiece) then Side := 1 else Side := 0;

  // ----------------------------------------------------------------
  // Forward swap loop.
  // ----------------------------------------------------------------
  d := 0;
  while True do
  begin
    Inc(d);
    if d > 30 then Break; // safety cap; real swaps never reach this

    Gain[d] := CurAttackerVal - Gain[d-1];

    NextAttackerVal := FindLVA(Side, NextR, NextC, NextAttackerPiece);
    if NextAttackerVal = 0 then Break; // no more attackers for this side

    // King-legality guard: if the just-found attacker is a king and
    // the OTHER side still has any attacker on the target, the king
    // would be moving into check — illegal. End the exchange now
    // (this step doesn't happen, Gain[d] stands as the final value).
    if (NextAttackerPiece = wK) or (NextAttackerPiece = bK) then
    begin
      RemovedBB := RemovedBB or (QWord(1) shl SquareIndex(NextR, NextC));
      if FindLVA(1 - Side, DummyR, DummyC, DummyPiece) > 0 then Break;
    end
    else
      RemovedBB := RemovedBB or (QWord(1) shl SquareIndex(NextR, NextC));

    // Recapture promotion: a pawn reaching rank 8 (row 0) or rank 1
    // (row 7) promotes. Inject the (Q - P) bonus into THIS step's
    // gain (the side that just promoted), and set the piece-on-target
    // value to queen for the next iteration's accounting.
    if ((NextAttackerPiece = wP) and (TR = 0)) or
       ((NextAttackerPiece = bP) and (TR = 7)) then
    begin
      Gain[d]        := Gain[d] + SeeVal[wQ] - SeeVal[wP];
      CurAttackerVal := SeeVal[wQ];
    end
    else
      CurAttackerVal := NextAttackerVal;

    Side := 1 - Side;
  end;

  // ----------------------------------------------------------------
  // Backward fold (negamax minimax).
  // For each step from d down to 1, the side whose turn it would be
  // can either accept the position as-is or continue capturing. The
  // recurrence Gain[d-1] := -max(-Gain[d-1], Gain[d]) selects whichever
  // is better for the side moving. The fold runs while d > 1 because
  // the last Gain[d] is only used to update Gain[d-1] one level up.
  // ----------------------------------------------------------------
  while d > 1 do
  begin
    Dec(d);
    if Gain[d] > -Gain[d-1] then
      Gain[d-1] := -Gain[d];
  end;

  Result := Gain[0];
end;


function Quiescence(Alpha, Beta, Ply: integer): integer;
{**A specialized search that only examines captures to avoid the horizon effect.**
 After the main search reaches its depth limit, quiescence continues searching only capture moves (plus all moves when in check).
 This prevents the engine from stopping right before a losing capture (horizon effect).
 Key features:
- **Stand-pat**: If the current position's evaluation already exceeds beta, return immediately
- **Delta pruning**: Skips hopeless captures that cannot improve alpha (e.g., capturing a pawn when already down a queen)
- Uses MVV-LVA move ordering (Most Valuable Victim - Least Valuable Aggressor)
- Detects checkmate in quiescence search
- Ply: distance from root, used for ply-adjusted mate scores so closer mates are preferred}
var
  Moves: TMoveList;
  MoveCount, i, j, BestIdx, BestScore, Score, StandPat, LegalMovesSearched: integer;
  OldState: TGameState;
  Temp: TMove;
  InCheck: boolean;
  CapturedValue: integer;
begin
  Inc(SearchNodes);
  Inc(NodeCheckCount);
  // v1.00-rc3b: track selective depth in quiescence. Ply is the distance
  // from the root passed in; qsearch lines are what push seldepth well past
  // the nominal depth.
  if Ply > SelDepth then SelDepth := Ply;

  // Time management check
  // =========================================================================
  // Search abort checks.
  // Wall-clock time and 'stop' command are checked every 10000 nodes to
  // amortise the cost of the syscalls. The node-limit check is unconditional
  // because SearchNodes is incremented every Search call anyway, so testing
  // it costs nothing extra and ensures we stop immediately when the limit
  // is reached (important for accurate 'go nodes' compliance).
  // =========================================================================
  // v1.00-rc3: check every ~10000 nodes. The 'stop' command is checked
  // whenever the counter trips, regardless of time-management mode, so
  // 'go infinite' / unlimited analysis (ExceedCeilingAbortMs = 0) still stops on
  // command. The wall-clock (hard-limit) abort is checked only when a time
  // limit is active. This is the mid-search HARD ceiling; the soft limit is
  // handled between iterations in GetBestMove and never aborts mid-search.
  if NodeCheckCount > 10000 then
  begin
    NodeCheckCount := 0;
    if (ExceedCeilingAbortMs > 0) and
       (GetTickCount64 - SearchStartTime > QWord(ExceedCeilingAbortMs)) then AbortSearch := True;
    if InputReady then AbortSearch := True; // Check for 'stop' command
  end;
  if (NodeLimit > 0) and (SearchNodes >= NodeLimit) then AbortSearch := True;
  if AbortSearch then Exit(Alpha);

  InCheck := IsInCheck(State.SideToMove);

  // If in check, we cannot stand pat, and must search ALL moves.
  if InCheck then
  begin
    StandPat := -29000; // Pretend we are losing badly to force search of all moves
    GeneratePseudoLegalMoves(Moves, MoveCount, False);
    LegalMovesSearched := 0;
  end
  else
  begin
    StandPat := Evaluate();
    if StandPat >= Beta then Exit(Beta);
    if StandPat > Alpha then Alpha := StandPat;
    GeneratePseudoLegalMoves(Moves, MoveCount, True); // Captures only
    LegalMovesSearched := -1; // Not tracking checkmates in normal qsearch
  end;

  // Delta pruning: skip futile captures
  for i := 0 to MoveCount - 1 do
  begin
    // Sort moves by capture value (MVV-LVA)
    BestIdx := i;
    BestScore := -999999;
    for j := i to MoveCount - 1 do
    begin
      Score := 0;
      if State.Board[Moves[j].ToR, Moves[j].ToC] <> EMPTY then
        Score := (Abs(PieceValue[State.Board[Moves[j].ToR, Moves[j].ToC]]) * 10) -
                 (Abs(PieceValue[State.Board[Moves[j].FromR, Moves[j].FromC]]) div 100);
      if Moves[j].Promotion <> EMPTY then Score := Score + 9000;
      if Score > BestScore then begin BestScore := Score; BestIdx := j; end;
    end;

    if BestIdx <> i then
    begin
      Temp := Moves[i]; Moves[i] := Moves[BestIdx]; Moves[BestIdx] := Temp;
    end;

    // Delta pruning: skip if capturing a piece that can't improve alpha
    if not InCheck and (State.Board[Moves[i].ToR, Moves[i].ToC] <> EMPTY) then
    begin
      CapturedValue := Abs(PieceValue[State.Board[Moves[i].ToR, Moves[i].ToC]]);
      if StandPat + CapturedValue + DELTA_MARGIN < Alpha then
        Continue; // Skip this capture - it's hopeless
    end;

    // SEE pruning (v0965): skip captures that statically lose material.
    // In qsearch the only available moves are captures, and a losing
    // capture (a) cannot raise alpha (it just lost material) and (b)
    // spawns a fresh qsearch node on the opponent's turn with even more
    // captures available, so the subtree below it is almost pure noise
    // around the stand-pat value. Skipping these captures with Continue
    // both cuts the node and propagates the existing stand-pat upward.
    //
    // Conditions that must ALL hold to prune:
    //   - Not in check: when in check qsearch must search every legal
    //     move (we generated full pseudo-legals above), and a losing
    //     capture may be the only legal escape.
    //   - Not a promotion: promotion captures can be tactically critical
    //     (e.g. promote with check or to defend a piece), and our SEE
    //     handles initial-move promotions exactly so the SEE value would
    //     be reliable, but the asymmetry between promotion-captures and
    //     non-promotion-captures is not what we want to prune away here.
    //   - Not en passant: SEE returns 0 for EP, so it would never prune
    //     it anyway, but excluding it explicitly avoids any future
    //     surprises if SEE's EP handling changes.
    //   - SEE strictly less than zero: even trades (SEE = 0) are kept,
    //     since they let qsearch follow through a clean equal exchange.
    if not InCheck and
       (Moves[i].Promotion = EMPTY) and
       (Moves[i].MoveType <> MT_EN_PASSANT) and
       (SEE(Moves[i]) < 0) then
      Continue;

    OldState := State;
    DoMakeMove(Moves[i]);





    // Verify move doesn't leave king in check
    if IsInCheck(1 - State.SideToMove) then
    begin
      State := OldState;
      Continue;
    end;

    if InCheck then Inc(LegalMovesSearched);

    Score := -Quiescence(-Beta, -Alpha, Ply + 1);
    State := OldState;

    if AbortSearch then Exit(Alpha);
    if Score >= Beta then Exit(Beta);
    if Score > Alpha then Alpha := Score;
  end;

  // If in check and no legal moves were found, it's checkmate.
  // Use ply-adjusted score so closer mates are preferred over distant ones.
  if InCheck and (LegalMovesSearched = 0) then Exit(-29000 + Ply);

  Result := Alpha;
end;

function IsInsufficientMaterial: boolean;// Insufficient Material (Dead Position)
{The engine does not detect when neither side has enough material to checkmate (e.g., King vs King, King+Bishop vs King, King+Knight vs King).
 Without this, the engine will play on infinitely in those positions, searching to the maximum depth every turn.

 v0978: piece counts come from PopCnt of the piece bitboards; the early
 exit on any pawn/rook/queen is a single OR-test against the combined
 bitboard. Bishop square colour comes from the LERF bit index of the
 single bishop — parity of (file + rank) — which gives a different
 absolute encoding from the old (r+c) mod 2 but the same equality result
 for pairwise comparison, which is all the function uses.}
var
  WhiteBishops, BlackBishops, WhiteKnights, BlackKnights: integer;
  WhiteBishopColor, BlackBishopColor: integer; // 0/1, encoding doesn't matter, only equality
  sq: integer;
begin
  // Any pawn, rook, or queen on the board → not insufficient.
  if (State.Pieces[wP] or State.Pieces[bP] or
      State.Pieces[wR] or State.Pieces[bR] or
      State.Pieces[wQ] or State.Pieces[bQ]) <> 0 then Exit(False);

  WhiteBishops := PopCnt(State.Pieces[wB]);
  BlackBishops := PopCnt(State.Pieces[bB]);
  WhiteKnights := PopCnt(State.Pieces[wN]);
  BlackKnights := PopCnt(State.Pieces[bN]);

  // K vs K
  if (WhiteBishops + WhiteKnights + BlackBishops + BlackKnights) = 0 then Exit(True);

  // K+B vs K or K+N vs K
  if (WhiteBishops + WhiteKnights <= 1) and (BlackBishops = 0) and (BlackKnights = 0) then Exit(True);
  if (BlackBishops + BlackKnights <= 1) and (WhiteBishops = 0) and (WhiteKnights = 0) then Exit(True);

  // K+B vs K+B (Bishops on the same color square)
  if (WhiteKnights = 0) and (BlackKnights = 0) and (WhiteBishops = 1) and (BlackBishops = 1) then
  begin
    sq := BsfQWord(State.Pieces[wB]);
    WhiteBishopColor := ((sq and 7) + (sq shr 3)) and 1;
    sq := BsfQWord(State.Pieces[bB]);
    BlackBishopColor := ((sq and 7) + (sq shr 3)) and 1;
    if WhiteBishopColor = BlackBishopColor then Exit(True);
  end;

  Result := False;
end;


function IsThreefoldRepetition: boolean;
var
  i, Count: integer;
begin
  Count := 0;
  // We only need to check back to the last pawn move or capture,
  // but checking the whole history is safe and fast enough.
  // Start at GamePly - 4 because a position can't be repeated in less than 4 plies
  // (e.g., white moves, black moves, white returns, black returns).
  for i := State.GamePly - 4 downto 0 do
  begin
    if GameHistory[i] = State.Hash then
    begin
      Inc(Count);
      if Count >= 2 then Exit(True); // Count=2 means this is the 3rd occurrence
    end;
  end;
  Result := False;
end;


//forward only
     function Search(Depth, Alpha, Beta, RootDepth: integer; const PrevMove, Excluded: TMove; ParentStaticEval: integer): integer; forward; //function NullMovePruning() and function Search()  call each other.  v09992: Excluded sentinel (FromR<0) supports singular-extension probes.  v1.00-rc9: ParentStaticEval carries the parent node's static eval down for the Improving flag (IMPROVING_UNKNOWN = -30001 when the parent could not supply one).

function HasNonPawnMaterial(Side: integer): boolean;
{**Returns True if Side has at least one piece other than pawns and king.**
Used as a zugzwang guard for Null-Move Pruning. The NMP heuristic
("if I pass and the position is still good, my best real move is even
stronger") fails catastrophically in pure king-and-pawn endgames, where
*having* to move is exactly what loses. Without this guard the engine
can completely misjudge K+P endings — the verification search does not
catch it because both the primary null search and the verification
search agree on the wrong answer.

v0977: single bitboard OR-test replaces the up-to-64-square mailbox
scan. Result is mathematically identical.}
begin
  if Side = 0 then
    Result := (State.Pieces[wN] or State.Pieces[wB] or
               State.Pieces[wR] or State.Pieces[wQ]) <> 0
  else
    Result := (State.Pieces[bN] or State.Pieces[bB] or
               State.Pieces[bR] or State.Pieces[bQ]) <> 0;
end;


// Null Move Pruning - reduces search tree significantly
function NullMovePruning(Depth, Beta: integer): boolean;
{**Null-Move Pruning with verification search.**
 If we let the opponent move twice (a "null move") and they still can't
 hurt us by Beta, the position is so strong that we don't need to search
 every move ourselves. Skipping straight to a fail-high saves an entire
 subtree per node where it fires.

 Safeguards:
  - Disabled in check (a null move would let the side-to-move "escape"
    illegally, which would give absurd cutoffs).
  - Disabled in zugzwang-prone endings (no non-pawn material), where
    "passing" is genuinely worse than playing — the null-move heuristic
    is unsafe and the verification search agrees with it on the wrong
    answer.
  - Verification search: when the null move triggers a cutoff, a real
    reduced search confirms before pruning. Catches tactical threats
    (e.g. a queen attacking an undefended rook) that the null-move
    heuristic would otherwise miss.}
var
  OldState: TGameState;
  Score, VerifyScore: integer;
  // v1.00-rc5: depth-scaled null-move reduction.
  //   R        = plies removed by the reduction itself (2 at Depth 3..7,
  //              growing by 1 every 4 plies of remaining depth).
  //   NewDepth = child depth for BOTH the primary null search and the
  //              verification search: Depth - R - 1. The extra "- 1" is
  //              the tempo ply the null move itself consumes, matching
  //              the previous fixed "Depth - 2 - 1" convention exactly.
  R, NewDepth: integer;
  // v0998: PrevMove sentinel passed to both child Search calls. The
  // primary search is a true null-move continuation (no real move was
  // played), so cont-history has no parent move to index against. The
  // verification search restores OldState first but is conceptually a
  // peer of the parent's normal search; we still pass sentinel here
  // for the simpler "all NMP children see sentinel" rule, accepting a
  // small accuracy loss on the rare verification path.
  NullPrev: TMove;
  // v09992: NoExcluded sentinel passed to both child Search calls.
  // NMP children are never inside a singular probe (NMP itself is
  // disabled when the outer node has Excluded set; see top of Search).
  NoExcluded: TMove;
begin
  Result := False;
  NullPrev := Default(TMove);
  NullPrev.FromR := -1;  // Sentinel: cont-history skips on FromR < 0
  NoExcluded := Default(TMove);
  NoExcluded.FromR := -1;  // v09992: sentinel for "no singular exclusion"
  // Only use null move if not in check and depth is sufficient.
  // A verification search is used when null move causes a cutoff, to prevent
  // the engine from being blind to real threats (e.g. a queen attacking an
  // undefended rook) that the null move heuristic would otherwise prune away.
  //
  // v0956b: also require non-pawn material for the side to move. In K+P
  // endings the null-move heuristic is unsafe (the side that must move is
  // the one that loses); both the primary and verification searches would
  // agree on the wrong answer, so this is the only place we can catch it.
  if (Depth >= 3) and not IsInCheck(State.SideToMove) and
     HasNonPawnMaterial(State.SideToMove) then
  begin
    OldState := State;

    // Make null move (just change side to move)
    State.Hash := State.Hash xor ZobristSide;
    State.SideToMove := 1 - State.SideToMove;

    // v0965: clear en-passant on the null move. The hash MUST be updated
    // to match — if there was a legal EP file before the null, its Zobrist
    // contribution is still mixed into State.Hash, so the post-null hash
    // would not correspond to any real position with EP cleared, and the
    // TT could serve a cutoff from an unrelated sister position. Fires
    // only when EPC <> -1 at a node where NMP runs (rare), but it's a
    // genuine correctness bug — fix is unconditional.
    if OldState.EPC <> -1 then
      State.Hash := State.Hash xor ZobristEP[OldState.EPC];
    State.EPR := -1; State.EPC := -1; // Clear en passant on null move

    // =====================================================================
    // v1.00-rc5: depth-scaled reduction replaces the fixed R=2.
    //
    // Rationale: the deeper the node, the more reliable the null-move
    // signal (the reduced search behind it is itself deep enough to see
    // real threats), so a larger reduction is safe and saves a larger
    // subtree. The fixed R=2 was calibrated for safety at shallow depths;
    // scaling recovers the shallow-depth behaviour EXACTLY (Depth 3..7
    // still search at Depth - 3) and only reduces more from Depth 8 up:
    //   Depth  3.. 7  ->  R = 2  ->  NewDepth = Depth - 3   (unchanged)
    //   Depth  8..11  ->  R = 3  ->  NewDepth = Depth - 4
    //   Depth 12..15  ->  R = 4  ->  NewDepth = Depth - 5
    //   Depth 16..19  ->  R = 5  ->  NewDepth = Depth - 6
    //
    // NewDepth cannot go negative: at the Depth >= 3 gate minimum,
    // NewDepth = 0 (a quiescence hand-off), same as before.
    //
    // NOT included (yet): the Stockfish-style eval-margin term
    // min((StaticEval - Beta) div 200, 2).
    //   v1.00-rc9 UPDATE: the "StaticEval at all non-check nodes"
    //   refactor has now landed, so a static eval DOES exist at every
    //   non-check node where NMP fires — the input the term needs now
    //   exists. It is still not wired in here, deliberately, because
    //   NMP is invoked from the top of Search BEFORE that node computes
    //   its StaticEval (and NullMovePruning is a separate function
    //   without access to the Search local). Feeding the term requires
    //   reordering the node so InCheck + StaticEval are computed ahead
    //   of the NMP call and then passed in — a structural change that
    //   must be measured on its own SPRT rather than folded into the
    //   rc9 RFP change. That reorder + eval-margin term is the natural
    //   next candidate now that the enabler is in place.
    //
    // The verification search uses the SAME NewDepth, preserving the
    // existing convention that primary and verification searches share
    // one reduced depth. Lesson 8 applies: verification fires on a
    // different node population once R scales; if this SPRT passes, a
    // follow-up should test restricting or removing verification at
    // high depth (unstarted candidate 4).
    // =====================================================================
    R := 2 + (Depth div 4);
    NewDepth := Depth - R - 1;

    // Search with reduced depth and null window.
    // v1.00-rc9: NMP runs before this node's StaticEval is computed and the
    // null-move child is not a normal move continuation, so it receives the
    // IMPROVING_UNKNOWN sentinel (-30001) as ParentStaticEval — its own
    // children therefore start "not improving", which is the conservative
    // default for a synthetic null-move line.
    Score := -Search(NewDepth, -Beta, -Beta + 1, NewDepth, NullPrev, NoExcluded, -30001);

    // Restore state
    State := OldState;

    // Verification search: if null move caused a cutoff, verify with a
    // real reduced search before trusting it. This prevents the engine
    // from being blind to threats (e.g. a queen attacking an undefended
    // rook) that the null move heuristic would otherwise prune away.
    if Score >= Beta then
    begin
      VerifyScore := Search(NewDepth, Beta - 1, Beta, NewDepth, NullPrev, NoExcluded, -30001); // v1.00-rc9: IMPROVING_UNKNOWN, same rationale as the primary null search
      Result := VerifyScore >= Beta;  // Only prune if verified
    end;
  end;
end;


function Search(Depth, Alpha, Beta, RootDepth: integer; const PrevMove, Excluded: TMove; ParentStaticEval: integer): integer;
{**The heart of the engine - implements Alpha-Beta search with Negamax framework.**
This recursive function explores the game tree to find the best move. It uses the **negamax** variant where the evaluation is always from the current player's perspective, simplifying the code by negating scores when switching sides.

**Alpha-beta pruning** is applied here:
- `Alpha` represents the best score the current player can guarantee
- `Beta` represents the best score the opponent can force
- If a move's score >= Beta, the remaining moves are **pruned** (cut off) because the opponent will never allow this line
- If a move improves Alpha, we update it and continue searching

The function also includes:
- Transposition table lookup to reuse previous search results
- Null move pruning (trying a pass move to detect winning positions)
- Reverse futility pruning (prune nodes where static eval is far above beta)
- Futility pruning (skip quiet moves at depth 1-2 when static eval is far below alpha)
- Late Move Pruning (skip quiet non-checking non-killer late moves at shallow depths)
- Late Move Reductions (search late quiet moves at reduced depth, re-search if they beat alpha)
- Check extensions (search 1 ply deeper when giving check)
- Killer move heuristic for move ordering
- History heuristic for quiet-move ordering
- Draw detection (repetition, 50-move rule)
- Time management checks

 v0986: SEE re-introduced in main-search move ordering. Captures whose
 Static Exchange Evaluation is strictly negative (statically losing
 material) have their MVV-LVA score reduced by BAD_CAPTURE_PENALTY,
 pushing them below killers and history quiets. Promotions and
 en passant are excluded (matches qsearch SEE-pruning gating: SEE
 handles initial-move promotions exactly but the promotion-capture
 asymmetry is not what we want to reorder here; SEE returns 0 for EP
 so it would never trigger anyway).

 v0986 also restructures move ordering to precompute scores once per
 node into MoveScores[] instead of recomputing inside the selection
 sort. This both eliminates the O(n^2) scoring cost and ensures SEE
 is evaluated at most once per capture per node (rather than once per
 capture per selection-sort pass, which would be MoveCount times
 more expensive).

 v0988: Late Move Pruning (LMP) added at shallow depths (1..3) on
 non-PV nodes. After a depth-scaled number of legal moves has been
 searched, additional quiet non-checking non-killer moves are
 skipped outright (Continue) instead of being searched. Unlike
 LMR (which reduces depth) and futility (which compares static eval
 to alpha), LMP is a hard, eval-free, purely ordinal cutoff. The
 thresholds are intentionally generous (N=4/8/12 at d=1/2/3) — the
 cost of pruning a strong move is bounded by the very shallow depth
 at which LMP fires.

 v0988 also caches IsInCheck(State.SideToMove) into a single
 GivesCheck local that is shared by LMP, futility, and the check
 extension. Previously the same query was issued up to twice per
 loop iteration; with LMP it would have become three calls. The
 killer-match test is similarly hoisted out of the LMR block to be
 used by both LMP and LMR with a single computation.

 v0997: History-based LMR adjustment. Inside the LMR block, the
 history score of the candidate quiet move (indexed by the side that
 PLAYED the move, i.e. OldState.SideToMove because DoMakeMove has
 already flipped State.SideToMove) is read; if it is above
 HISTORY_LMR_HIGH the base reduction is decreased by 1. Re-test of a
 feature that previously regressed/proved neutral before the PeSTO
 PST migrations (v0993..v0995); see HISTORY_LMR_HIGH const for the
 rationale on why the prior shifted.}
const
  // =========================================================================
  // Per-depth futility tuning. Depth 2 needs to be substantially more
  // conservative than depth 1 because:
  //   - Between our quiet move and qsearch there is a full opponent ply,
  //     so any positional gain from a quiet move is more likely to be lost
  //     to pruning than at depth 1 where qsearch follows immediately.
  //   - Quiet moves after the killers are now ordered by the history
  //     heuristic, but history is still only a coarse signal, so a few
  //     plausible moves should be searched before pruning kicks in.
  //
  // Therefore at depth 2 we (a) demand a much larger static deficit and
  // (b) require several legal moves to have been searched first.
  // Depth 1 keeps the v0939 settings (200cp margin, search > 1 moves first)
  // because that configuration was already known to be Elo-positive.
  // =========================================================================
  FutilityMargin: array[1..2] of integer = (200, 500);   // d1: minor piece, d2: rook + pawn
  FutilityMinMoves: array[1..2] of integer = (1, 3);     // d1: > 1 searched, d2: > 3 searched
  // =========================================================================
  // Razoring margins (v09997).
  //
  // Node-level eval-driven prune at Depth 1-2. Fires when the static
  // evaluation is so far BELOW alpha that a single null-window qsearch
  // can be expected to confirm "no recovery possible". Symmetric mirror
  // of Reverse Futility Pruning, which prunes when StaticEval is so far
  // ABOVE beta that the opponent would never allow this. Complements
  // IIR by acting at Depth 1-2 where IIR (Depth >= 4) does not fire.
  //
  // Margins are wider than FutilityMargin[1..2] = (200, 500) at depth 1
  // because:
  //   - In-loop futility prunes individual quiet moves AFTER move
  //     generation and a few searched moves. Razoring prunes the WHOLE
  //     node BEFORE any search work. The wider margin avoids
  //     double-counting the same low-eval signal in a sharper cut and
  //     reserves razoring for cases where in-loop futility would also
  //     fire on essentially every quiet anyway.
  //   - Stockfish-family razoring margins at low depth historically
  //     cluster around 250..300cp for d1 and 400..550cp for d2 on
  //     PeSTO-calibrated evals. (300, 500) sits inside that band and
  //     matches PasKnight's cp scale (pawn = 100).
  //
  // Depth 1: 300cp deficit  (~minor piece)
  // Depth 2: 500cp deficit  (~rook)
  // =========================================================================
  RazorMargin: array[1..2] of integer = (300, 500);

  // =========================================================================
  // History heuristic tuning.
  //   HISTORY_MAX caps the stored value so it cannot overflow over many
  //     cutoffs in a long search; capping at 16384 fits comfortably in an
  //     integer and is well above any single-iteration accumulation.
  //   HISTORY_ORDERING_CAP is the maximum score the history value can
  //     contribute in the move-ordering selection sort. It is set strictly
  //     below the killer scores (7900 and 8000) so that killer moves are
  //     always searched before the best history-scored quiet move.
  // =========================================================================
  HISTORY_MAX          = 16384;
  // v0997b: symmetric floor for two-sided history. With Inc(...,Depth*Depth)
  // applied to cutoff moves and Dec(...,Depth*Depth) applied to quiet moves
  // that were searched without cutoff, scores can now go negative; this
  // floor caps how negative a single (side,from,to) entry can become so
  // accumulated malus over many siblings can't drive it into absurdly
  // negative territory that would dominate later ordering decisions.
  HISTORY_MIN          = -HISTORY_MAX;
  HISTORY_ORDERING_CAP = 7000;

  // =========================================================================
  // Late Move Reductions (LMR) tuning.
  //   LMR_MIN_DEPTH: minimum remaining depth at which LMR can fire. Below
  //     this, reducing leaves too little search behind to be reliable.
  //   LMR_MIN_MOVE: the first move number at which LMR is allowed. The
  //     first few moves in the ordering (TT move, captures, killers, top
  //     history scores) are searched at full depth.
  //   LMR_DEEP_MOVE: from this move number onward the reduction is 2.
  //   LMR_VERY_DEEP_MOVE: from this move number onward the reduction is 3.
  //     This third tier targets very late moves at higher depths, which
  //     are extremely unlikely to be best given current move ordering.
  // =========================================================================
  LMR_MIN_DEPTH      = 3;
  LMR_MIN_MOVE       = 3;
  LMR_DEEP_MOVE      = 6;
  LMR_VERY_DEEP_MOVE = 12;

  // =========================================================================
  // v0997: History-based LMR adjustment.
  //   HISTORY_LMR_HIGH: history-score threshold above which a quiet move's
  //     LMR reduction is decreased by 1 (i.e. searched one ply deeper than
  //     the base ladder would dictate). Set to HISTORY_MAX / 2 = 8192, so
  //     only moves in the upper half of the history saturation range get
  //     the exemption. Well above HISTORY_ORDERING_CAP (7000), so "ordinary
  //     good" quiets — the kind already used for tie-breaking inside the
  //     selection sort — still receive the full base reduction. Only the
  //     genuinely repeated-cutoff moves get the deeper search.
  //
  // Rationale for revisiting this in v0997:
  //   The pre-v0993 attempt regressed or proved neutral. The diagnosis
  //   recorded in roadmap notes was that the engine was eval-signal
  //   saturated, not search-saturated — so reducing late moves less when
  //   they look promising couldn't help because the evaluator wasn't
  //   distinguishing them clearly enough. With the PeSTO MG/EG PSTs
  //   (v0993/v0994) and the tapered material values (v0995) all landing
  //   positive, the eval signal is now substantially stronger, and the
  //   prior on history-LMR shifts back to neutral-or-positive.
  // =========================================================================
  // =========================================================================
    // v0998: Continuous history-based LMR adjustment.
    //
    // Replaces v0997's binary threshold (HISTORY_LMR_HIGH = 8192, decrement
    // by 1 above the threshold) with a smooth Stockfish-style formulation:
    // Reduction is decreased by (HistoryVal div HISTORY_LMR_DIVISOR), so
    // every increment in history score contributes a proportional reduction
    // in LMR depth.
    //
    // With HISTORY_LMR_DIVISOR = 4096 and HISTORY_MAX = 16384, the adjustment
    // takes integer values in the range 0..4:
    //   HistoryVal       0 ..  4095  ->  adjustment 0
    //   HistoryVal    4096 ..  8191  ->  adjustment 1
    //   HistoryVal    8192 .. 12287  ->  adjustment 2
    //   HistoryVal   12288 .. 16383  ->  adjustment 3
    //   HistoryVal           16384   ->  adjustment 4
    //
    // Why this is expected to beat the v0997 threshold version:
    //   - v0997 only differentiated moves above 8192. With base reductions
    //     of 1 or 2 ply at early LMR positions (moves 3..5 and 6..11),
    //     the threshold could only shave one ply off an already-shallow
    //     reduction. The continuous version is meaningful across the full
    //     range — including very late moves at high depths where base
    //     reduction is 3 ply and the technique has actual room to act.
    //   - Moves in the 4096..8191 history band — multiple cutoffs but not
    //     yet "saturated" — now also get a 1-ply exemption rather than
    //     none. These are a much larger population than the >8192 band.
    //
    // Lower clamp handles the worst case: base 1 (early tier) + IsPVNode
    // (-1) + max history (-4) = -4. The (Reduction < 0) clamp brings that
    // back to 0, which means the move gets searched at full depth — the
    // intended behaviour for a strongly-history-suggested move.
    // =========================================================================
    HISTORY_LMR_DIVISOR = 4096;

  // =========================================================================
  // SEE-based bad-capture demotion (v0986).
  // When a capture's static exchange evaluation is strictly negative
  // (i.e. the swap-off statically loses material), the move's ordering
  // score is reduced by BAD_CAPTURE_PENALTY. With MVV-LVA capture scores
  // in the 1000..9000 range, the resulting score is negative
  // (-9000..-1000), which is strictly below:
  //   - The two killer slots (7900 and 7800-equivalent / 8000)
  //   - HISTORY_ORDERING_CAP (7000), the maximum quiet-move history score
  //   - Quiet moves with zero history (0)
  // so bad captures sort after every plausible quiet move, but stay
  // above each other in MVV-LVA order (useful when several bad captures
  // exist on the same target). The captures are NOT pruned — main-search
  // does not prune captures here (LMR also gates on a quiet move) — only
  // re-ordered to the back of the list.
  //
  // Rationale: a queen taking a pawn defended by a pawn looks like
  // MVV-LVA score 991 (a "good" capture), but actually loses 800cp.
  // Searching it before quiet history moves wastes the early-cutoff
  // budget on a line that the opponent will refute trivially. Demoting
  // it below quiets uses the early-cutoff budget on moves that ordering
  // believes are more likely to cause a beta cutoff.
  // =========================================================================
  BAD_CAPTURE_PENALTY = 10000;

  // =========================================================================
  // Late Move Pruning (LMP) tuning — v0988.
  //
  // At shallow depths (1..LMP_MAX_DEPTH) and non-PV nodes, quiet
  // non-checking non-killer moves that come very late in the ordering
  // are skipped outright (Continue), without reduced search or any
  // static-eval comparison. This is the "hard cousin" of LMR: LMR
  // reduces depth, LMP eliminates the move entirely.
  //
  // Gating overlap with LMR is intentional. At depth 3, LMR can reduce
  // moves 3..12 and LMP skips moves 13+. At depths 1..2 LMR does not
  // fire (LMR_MIN_DEPTH = 3) so LMP is the only late-move filter
  // beyond futility.
  //
  // Threshold values: with LegalMovesSearched > LMP_Threshold[Depth]
  // as the trigger, the first N moves are always searched and pruning
  // begins on move N+1:
  //   Depth 1: prune from move  5+ (LMP_Threshold[1] = 4)
  //   Depth 2: prune from move  9+ (LMP_Threshold[2] = 8)
  //   Depth 3: prune from move 13+ (LMP_Threshold[3] = 12)
  //
  // Why these thresholds are safe even though LMP is unconditional:
  //   - The cost of incorrectly pruning a move is bounded by the depth
  //     of the subtree that would have been searched. At depth <= 3
  //     this is small.
  //   - Move ordering at this engine strength puts the TT move,
  //     captures, promotions, killers, and the best history-scored
  //     quiets in the first 4-12 slots. Anything beyond that is, by
  //     construction, a low-probability candidate for best move.
  //   - Captures, promotions, and en passant are excluded — they have
  //     intrinsic ordering signal independent of history.
  //   - Killer moves are excluded — they proved cutoff-worthy at this
  //     ply elsewhere.
  //   - Moves that give check are excluded — they can be tactical.
  //   - In-check positions at this node are excluded — escape moves
  //     are forced and all important.
  //   - PV nodes are excluded — a wrongly pruned move there can
  //     corrupt the principal variation that propagates to the root.
  //   - Near-mate alpha excluded — never prune when mate is in view.
  //
  // The thresholds are deliberately on the cautious side of typical
  // Stockfish-style values; we can tune them more aggressively in a
  // later SPRT once LMP itself is validated as Elo-positive in
  // isolation.
  // =========================================================================
  LMP_MAX_DEPTH  = 3;
  LMP_Threshold: array[1..3] of integer = (4, 8, 12);

  // =========================================================================
  // SEE capture pruning tuning — v1.00-rc4.
  //
  // At shallow depth, non-PV nodes, skip captures whose static exchange
  // evaluation loses more than SEE_PRUNE_MARGIN centipawns per remaining
  // ply. This is the pruning-class complement to the v0986 ordering-side
  // bad-capture demotion: demotion only pushes a losing capture LATE in
  // the list, it still gets searched if no earlier move produced a cutoff.
  // At depths 1..6 those tail searches are pure waste in the overwhelming
  // majority of cases — a capture that sheds >= 100 cp * Depth of material
  // cannot realistically recover it within the remaining horizon.
  //
  //   SEE_PRUNE_MAX_DEPTH:  only prune close to the horizon, where the
  //                         remaining search cannot exploit deep
  //                         compensation (sacrifices). Depth-scaled margin
  //                         means depth 6 already requires SEE < -600
  //                         (a full rook + pawn) to fire.
  //   SEE_PRUNE_MARGIN:     centipawns of SEE loss tolerated per remaining
  //                         ply before pruning. 100 (a pawn per ply) is the
  //                         conventional starting value (Stockfish-family
  //                         engines use comparable depth-scaled cuts).
  //
  // Cost note: this block adds ZERO SEE() calls. The lazy-SEE machinery
  // (v1.00-pr1) already resolves SEE at point-of-selection for every plain
  // capture before it can be searched; v1.00-rc4 merely RETAINS that value
  // in the SeeValue[] array (previously discarded after the demotion
  // decision) and reads it at the pruning site.
  // =========================================================================
  SEE_PRUNE_MAX_DEPTH = 6;
  SEE_PRUNE_MARGIN    = 100;

  // =========================================================================
  // Singular Extension tuning — v09992.
  //
  // At sufficient depth, when the TT move is the only move that holds the
  // node above a threshold derived from the TT score, we extend the search
  // for that move by one ply. The probe runs a reduced-depth, null-window
  // search of the SAME position with the TT move excluded; if it fails low
  // against (TTScore - margin*Depth), the TT move is "singular" — extend.
  //
  //   SINGULAR_MIN_DEPTH:       depth threshold for considering the probe.
  //                             Below this, the probe's reduced search is
  //                             too shallow to be reliable and the per-probe
  //                             cost is not amortised by the extension.
  //   SINGULAR_TT_DEPTH_MARGIN: TT entry depth must be >= (Depth - margin).
  //                             A stale or shallow TT score is not a
  //                             trustworthy basis for a singular threshold.
  //   SINGULAR_MARGIN_PER_PLY:  centipawns subtracted from TTScore per
  //                             remaining ply to form SingularBeta. Larger
  //                             values fire less often but with more
  //                             confidence; smaller values fire more often
  //                             but with more noise. Standard SF-style cut
  //                             is 1-2 cp/ply. Starting at 2.
  // =========================================================================
  SINGULAR_MIN_DEPTH       = 7;
  SINGULAR_TT_DEPTH_MARGIN = 3;
  SINGULAR_MARGIN_PER_PLY  = 2;

  // =========================================================================
  // v1.00-rc9: Improving-flag sentinel and RFP margins.
  //
  // IMPROVING_UNKNOWN is a distinct sentinel from the StaticEval "-30000
  // not computed" value. It is passed as ParentStaticEval when the parent
  // node could not supply a real static eval — the root (no grandparent to
  // compare against) and any in-check parent (StaticEval was never computed
  // there). A node whose ParentStaticEval is IMPROVING_UNKNOWN, or whose own
  // StaticEval is the in-check sentinel, is treated as NOT improving. Chosen
  // as -30001 so it is separable from and more negative than every real
  // StaticEval and from the -30000 "not computed" marker.
  //
  // RFP_MARGIN_IMPROVING / RFP_MARGIN_NOT_IMPROVING are the per-ply reverse
  // futility margins. The pre-rc9 code used a single 120*Depth. rc9 keeps
  // 120 when improving and tightens to 100 when not improving, so a node
  // whose eval has deteriorated over the last full move is pruned on a
  // smaller cushion above beta. Standard improving-conditioned RFP.
  // =========================================================================
  RFP_MARGIN_IMPROVING     = 120;
  RFP_MARGIN_NOT_IMPROVING = 100;

var
  Moves: TMoveList;
  MoveCount, i, BestScore, Score, BestIdx, j, LegalMovesSearched, Extension: integer;
  OldState: TGameState;
  Temp, BestMoveFound: TMove;
  TTIdx: integer;
  TTE: ^TTTEntry;
  OrigAlpha: integer;
  CurrentHash: QWord;  // Store hash before move for TT
  StaticEval: integer; // For futility pruning and reverse futility pruning
  Improving: boolean;  // v1.00-rc9: StaticEval > ParentStaticEval (this side's eval rose over the last full move); false whenever either value is a sentinel
  IsPVNode: boolean;   // True when the search window is wider than zero (Beta - Alpha > 1)
  HistoryVal: integer; // Local history score used during move ordering AND v0997 LMR adjustment
  InCheck: boolean;    // True if the side-to-move at THIS node is in check (cached)
  IsKiller: boolean;   // True if current move matches a killer at this depth
  GivesCheck: boolean; // True if the current move puts the opponent in check (v0988 cache)
  Reduction: integer;  // LMR reduction in plies for the current move (0 = no reduction)
  SortScore: integer;
  // v0986: cached per-move ordering scores. Computed once per node before
  // the selection sort, so SEE is called at most once per capture rather
  // than O(MoveCount) times per capture (which the previous in-sort
  // scoring would have caused).
  MoveScores: array[0..255] of integer;
  SeeScore:   integer;
  TmpScore:   integer;
  // v1.00-pr1: lazy-SEE precompute. In v0986..v09998d1 the precompute loop
  // called SEE() on every capture up front to apply the bad-capture demotion.
  // Most nodes fail high on the first one or two moves, so the majority of
  // those SEE() calls scored captures that were never searched. v1.00-pr1
  // defers the SEE() call to the point of selection: the precompute assigns a
  // capture its provisional MVV-LVA score and sets SeePending[i]; the actual
  // SEE() + demotion happens inside the selection sort only when a capture
  // reaches the front-runner slot, with a single re-selection of that slot so
  // the resulting move order is bit-identical to the eager-SEE baseline.
  //   SeePending[i]  True  => Moves[i] is a capture (not promotion, not EP)
  //                          whose SEE demotion has not yet been resolved;
  //                          MoveScores[i] currently holds the provisional
  //                          (un-demoted) MVV-LVA score.
  //                  False => Moves[i] needs no SEE resolution (TT move,
  //                          quiet, killer, promotion, EP, or a capture whose
  //                          SEE has already been resolved).
  // SeePending is index-parallel to Moves/MoveScores and is swapped alongside
  // them in the selection sort so the flag always tracks its move.
  SeePending: array[0..255] of boolean;
  SeeResolved: boolean; // v1.00-pr1: set when a slot's SEE resolution demotes
                        // the front-runner, forcing one re-selection of the slot.
  // v1.00-rc4: SEE value captured at lazy-SEE resolution time, index-parallel
  // to Moves/MoveScores/SeePending and swapped alongside them in the selection
  // sort. Read by the SEE capture-pruning block in the iteration loop.
  // Invariant: by the time a plain capture (non-promotion, non-EP) is the
  // settled winner of a selection slot, its SEE has been resolved — either in
  // this slot's repeat-scan or in an earlier slot that demoted it — so
  // SeeValue[i] is always valid where the pruning block reads it. Entries for
  // quiets / promotions / EP are initialised to 0 and never read (the pruning
  // gate excludes those move classes).
  SeeValue: array[0..255] of integer;
  // v0997b: track quiet moves searched at this node without producing a
  // cutoff. On a beta cutoff, every move in this list receives a history
  // malus of Depth*Depth. The cutoff move itself never enters the list —
  // the append happens only in the no-cutoff branch — so the malus loop
  // needs no exclusion. 256 matches the move-list size used elsewhere.
  SearchedQuiets:    array[0..255] of TMove;
  NumSearchedQuiets: integer;
  k:                 integer; // loop index for the v0997b malus pass
  IsQuietMove:       boolean; // cached per-iteration: Moves[i] is non-capture, non-EP
  // v09992: singular extension locals.
  //   NoExcluded:    sentinel TMove (FromR=-1) passed to non-singular
  //                  recursive Search calls. Built once at function entry.
  //   IsTTMove:      cached per-iteration test "is Moves[i] the TT move?".
  //                  Recomputing this from BestMoveFound inside the
  //                  singular gate is harmless but it reads more cleanly
  //                  as a named flag.
  //   SingularBeta:  null-window centre for the singular probe, computed
  //                  from the TT score and the per-ply margin.
  //   SingularDepth: reduced depth for the singular probe ((Depth-1) div 2,
  //                  the standard Stockfish formula).
  //   SingularScore: result of the singular probe call.
  //   TTScoreLocal:  TT score adjusted from ply-relative to search-relative
  //                  (via ScoreFromTT); read once at the singular gate.
  NoExcluded:        TMove;
  IsTTMove:          boolean;
  SingularBeta:      integer;
  SingularDepth:     integer;
  SingularScore:     integer;
  TTScoreLocal:      integer;


            // E.g. This will allow the king to protect a rook from being taken by a queen.
            // Adjust mate scores before storing in TT.
            // Mate scores are stored as distance-from-ROOT, but computed as distance-from-node.
            // We add the current ply depth so the score is position-relative, not search-relative.
            function ScoreToTT(Score, Ply: integer): integer;
            begin
              if Score > 28000 then Result := Score + Ply       // White mates: push further away
              else if Score < -28000 then Result := Score - Ply // Black mates: push further away
              else Result := Score;
            end;

            // Adjust mate scores after retrieving from TT.
            // Convert position-relative mate score back to search-relative.
            function ScoreFromTT(Score, Ply: integer): integer;
            begin
              if Score > 28000 then Result := Score - Ply
              else if Score < -28000 then Result := Score + Ply
              else Result := Score;
            end;

begin
  Inc(SearchNodes);
  Inc(NodeCheckCount);
  // v1.00-rc3b: track selective depth. Ply at this node is RootDepth - Depth
  // (the same expression used for ply-adjusted mate scores below).
  if (RootDepth - Depth) > SelDepth then SelDepth := RootDepth - Depth;

  if IsThreefoldRepetition or (State.HalfMoveClock >= 100) or IsInsufficientMaterial then
  begin
    Exit(0); // Return a draw score
  end;

  // Time management check
  // =========================================================================
  // Search abort checks.
  // Wall-clock time and 'stop' command are checked every 10000 nodes to
  // amortise the cost of the syscalls. The node-limit check is unconditional
  // because SearchNodes is incremented every Search call anyway, so testing
  // it costs nothing extra and ensures we stop immediately when the limit
  // is reached (important for accurate 'go nodes' compliance).
  // =========================================================================
  // v1.00-rc3: check every ~10000 nodes. The 'stop' command is checked
  // whenever the counter trips, regardless of time-management mode, so
  // 'go infinite' / unlimited analysis (ExceedCeilingAbortMs = 0) still stops on
  // command. The wall-clock (hard-limit) abort is checked only when a time
  // limit is active. This is the mid-search HARD ceiling; the soft limit is
  // handled between iterations in GetBestMove and never aborts mid-search.
  if NodeCheckCount > 10000 then
  begin
    NodeCheckCount := 0;
    if (ExceedCeilingAbortMs > 0) and
       (GetTickCount64 - SearchStartTime > QWord(ExceedCeilingAbortMs)) then AbortSearch := True;
    if InputReady then AbortSearch := True; // Check for 'stop' command
  end;
  if (NodeLimit > 0) and (SearchNodes >= NodeLimit) then AbortSearch := True;
  if AbortSearch then Exit(Alpha);


  // PV node detection: a node is a PV node when the search window is wider
  // than zero. Zero-window (null-window) searches have Beta = Alpha + 1 and
  // are used by PVS to confirm/refute candidate moves cheaply. Futility
  // pruning is unsafe at PV nodes because a wrongly pruned move can affect
  // the principal variation and the root best-move choice.
  IsPVNode := (Beta - Alpha > 1);

  // v09992: build the "no exclusion" sentinel once. Passed to every
  // recursive Search call EXCEPT the singular probe itself, which passes
  // the TT move as the excluded move to suppress its consideration in
  // the probe's move loop.
  NoExcluded := Default(TMove);
  NoExcluded.FromR := -1;

  // Null Move Pruning
  // v09992: skip NMP when inside a singular probe. The probe is already a
  // constrained, reduced-window search; pruning it further with NMP makes
  // the singular determination unreliable. Standard Stockfish gate.
  if (Excluded.FromR < 0) and NullMovePruning(Depth, Beta) then Exit(Beta);
  if Depth <= 0 then Exit(Quiescence(Alpha, Beta, RootDepth));

  // Transposition Table Lookup
  TTIdx := Integer(State.Hash and TTMask);
  TTE := @TT[TTIdx];
  BestMoveFound := Default(TMove);
  BestMoveFound.FromR := -1; // Sentinel: -1 means no TT move available yet
  if TTE^.HashKey = State.Hash then
  begin
    BestMoveFound := UnpackMove(TTE^.MoveData); // v1.00-rc5: packed entry
    // v09992: skip TT cutoff exit when inside a singular probe. The
    // singular probe re-enters Search at the SAME position whose TT
    // entry we just used to derive SingularBeta — returning the cached
    // score here would be circular and would always claim the move is
    // singular (or never), depending on the bound. The TT move is still
    // captured into BestMoveFound above for move-ordering purposes; only
    // the early-exit cutoff is suppressed.
    if (Excluded.FromR < 0) and (TTE^.Depth >= Depth) then
    begin
      if TTE^.Flag = ttExact then Exit(ScoreFromTT(TTE^.Score, RootDepth - Depth));
      if (TTE^.Flag = ttAlpha) and (ScoreFromTT(TTE^.Score, RootDepth - Depth) <= Alpha) then Exit(Alpha);
      if (TTE^.Flag = ttBeta) and (ScoreFromTT(TTE^.Score, RootDepth - Depth) >= Beta) then Exit(Beta);
    end;
  end;

  // Cache the in-check status of the side to move at this node. Used by
  // both the StaticEval guard below and the LMR check inside the move
  // loop, so computing it once avoids a redundant IsInCheck call.
  InCheck := IsInCheck(State.SideToMove);

  // =========================================================================
  // Static Evaluation - computed once and reused by every static heuristic.
  //
  // v1.00-rc9: computed at ALL non-check nodes (previously only Depth <= 3,
  // because RFP and futility — the only historical consumers — fire only at
  // Depth <= 3). Eval is now also needed at deeper nodes to derive the
  // Improving flag, which conditions RFP here and is the enabler for later
  // improving-gated LMR/NMP/futility work.
  //
  // The -30000 sentinel still means "in check / not computed"; every reader
  // that must exclude in-check nodes tests StaticEval > -30000 exactly as
  // before. Placing this AFTER the TT lookup means positions resolved by the
  // TT still never pay the Evaluate() cost.
  // =========================================================================
  StaticEval := -30000; // Sentinel: means "not computed" (in check)
  if not InCheck then
    StaticEval := Evaluate();

  // v1.00-rc9: Improving = this side's static eval is higher than it was two
  // plies ago (ParentStaticEval is the parent node's StaticEval, which is the
  // same side to move as this node). False whenever either value is a
  // sentinel: an in-check node (StaticEval = -30000) never improves, and a
  // node whose parent supplied no eval — the root, or an in-check parent
  // (ParentStaticEval = IMPROVING_UNKNOWN) — is conservatively not improving.
  Improving := (StaticEval > -30000) and
               (ParentStaticEval > -30000) and
               (StaticEval > ParentStaticEval);

  // =========================================================================
  // Reverse Futility Pruning (Static Null Move Pruning)
  // If the static evaluation is so far ABOVE beta that even if we "give back"
  // a margin the position is still better than beta, we can safely prune this
  // node without searching any moves. The logic is the mirror image of
  // futility pruning: instead of asking "can we reach alpha from below?", we
  // ask "are we so far above beta that the opponent would never allow this?".
  //
  // Conditions:
  //   - Depth 1..3 only: deeper nodes are too complex for static judgement
  //   - Not in check: guaranteed by StaticEval sentinel check below
  //   - Not a mate score: avoid pruning near-mate positions incorrectly
  //
  // Margin scales with depth. v1.00-rc9: the per-ply margin is now gated on
  // the Improving flag — 120cp/ply when improving, 100cp/ply when not — so a
  // node whose eval has fallen over the last full move is pruned on a smaller
  // cushion above beta:
  //   improving:      d1 >= beta+120,  d2 >= beta+240,  d3 >= beta+360
  //   not improving:  d1 >= beta+100,  d2 >= beta+200,  d3 >= beta+300
  // The improving branch reproduces the pre-rc9 120*Depth behaviour exactly.
  // =========================================================================
  if ((Depth <=3) and (Depth >= 1)) and
     (StaticEval > -30000) and  // Was computed: guarantees not in check
     (Abs(Beta) < 28000) then   // Not a mate score
  begin
    if Improving then
    begin
      if StaticEval >= Beta + RFP_MARGIN_IMPROVING * Depth then
        Exit(Beta);
    end
    else
    begin
      if StaticEval >= Beta + RFP_MARGIN_NOT_IMPROVING * Depth then
        Exit(Beta);
    end;
  end;

  // =========================================================================
  // v09997: Razoring (verified, Depth 1-2, non-PV).
  //
  // The structural mirror of Reverse Futility Pruning. RFP asks "is the
  // static eval so far above beta that the opponent would never allow
  // this?" and prunes upward. Razoring asks "is the static eval so far
  // below alpha that no quiet move can plausibly rescue the position?"
  // and prunes downward.
  //
  // Verified form: rather than returning alpha unconditionally on the
  // static signal (the "unverified" or "drop-to-qsearch" form, which can
  // discard hidden tactics), we run a single null-window qsearch
  // anchored at alpha. The qsearch is the engine's existing strong
  // qsearch (delta pruning + SEE + check evasions + mate detection). If
  // qsearch confirms the static verdict (Score <= Alpha), we return that
  // qsearch score — it is a tighter, mate-aware upper bound than alpha
  // itself. If qsearch disagrees (Score > Alpha) we fall through to the
  // normal move loop, paying only the qsearch cost as overhead on a
  // node where the static eval was already pessimistic.
  //
  // Trigger conditions (all required):
  //   - Depth in [1..2]: razoring is a sharp depth-collapsing cut. At
  //     Depth 3 it overlaps with RFP (same depth band, mirror gate) and
  //     with IIR (which reduces Depth-4 cold-TT nodes into Depth-3
  //     territory), so adding razoring at Depth 3 lands in a crowded
  //     calibration region. Depths 1-2 are a clean, uncovered slice:
  //     in-loop futility prunes individual quiet moves there but pays
  //     the move-generation and per-move setup cost first; razoring
  //     skips the whole node when qsearch confirms it cannot recover.
  //   - not IsPVNode: razoring returns a qsearch verdict that can
  //     replace a real search result at this node. At a PV node a
  //     wrong return propagates further (corrupts the principal
  //     variation and the root best-move choice). The Stockfish-family
  //     convention is to gate razoring on non-PV; we follow it. RFP
  //     above omits this gate because it returns Beta (a known-safe
  //     upper bound that's already established by the caller); the
  //     qsearch verdict razoring returns is sharper and demands the
  //     stricter gate.
  //   - StaticEval > -30000: was computed (sentinel guarantees not in
  //     check). In-check nodes have forced/limited move sets where a
  //     static-eval-driven prune is unsafe; this guard inherits RFP's.
  //   - Abs(Alpha) < 28000: not a mate score. Near-mate alphas need
  //     every plausible move searched; razoring there could miss the
  //     defense.
  //   - Excluded.FromR < 0: not inside a singular-extension probe.
  //     The probe is already a constrained, reduced-window search
  //     with the TT move excluded; pruning it further with razoring
  //     would make the singular determination unreliable. Matches
  //     the NMP gate above.
  //   - StaticEval + RazorMargin[Depth] <= Alpha: the static fire
  //     test. RazorMargin = (300, 500) — see const block above for
  //     calibration rationale.
  //
  // Cost analysis:
  //   - Per-node overhead when the static test fails: one addition,
  //     one comparison.
  //   - Per-node overhead when the static test passes: one qsearch
  //     call. These are the nodes where the move loop was about to
  //     start with a sunk eval; in-loop futility would have pruned
  //     most quiet moves there anyway, so the qsearch cost is roughly
  //     bounded by what the truncated move loop would have done.
  //   - Per-node gain when qsearch confirms: skip move generation,
  //     ordering, and the full move loop entirely.
  // =========================================================================
  if ((Depth <= 2) and (Depth >= 1)) and
     (not IsPVNode) and
     (StaticEval > -30000) and  // Was computed: guarantees not in check
     (Abs(Alpha) < 28000) and   // Not a mate score
     (Excluded.FromR < 0) then  // Not inside a singular probe
  begin
    if StaticEval + RazorMargin[Depth] <= Alpha then
    begin
      Score := Quiescence(Alpha, Alpha + 1, RootDepth);
      if Score <= Alpha then
        Exit(Score);
    end;
  end;

  // =========================================================================
  // v09996: Internal Iterative Reductions (IIR).
  //
  // When the TT probe above produced no best-move hint for this position
  // (BestMoveFound.FromR still at the -1 sentinel), the upcoming move loop
  // will be searched with degraded move ordering: the first move tried is
  // unlikely to be the actual best, the next several are searched at
  // near-full window before LMR/PVS can prune them, and the whole node
  // pays a wider effective search than a TT-warm node would. Rather than
  // pay that full cost at the original depth, reduce by 1 ply. The
  // shallower search still produces a useful best-move suggestion which
  // is written into the TT; the NEXT visit to this position - which
  // happens often via repetition, transposition, or descendant
  // re-searches - finds a TT move and runs at full depth with good
  // ordering. Net effect across the tree: less wasted node-work at cold
  // positions, more budget available for the positions that matter.
  //
  // Trigger conditions (all required):
  //   - Depth >= 4: at lower depths the search is cheap enough that the
  //     reduction does not earn its keep, and the depth window
  //     overlaps with RFP/futility (which already act at Depth<=3).
  //     Threshold 4 is the standard Stockfish-family choice.
  //   - BestMoveFound.FromR < 0: no TT move was found. The whole
  //     point of IIR is to handle exactly this case; with a TT move
  //     the search is already ordering-warm and a reduction would
  //     just lose depth for no benefit.
  //   - Excluded.FromR < 0: not inside a singular-extension probe.
  //     A singular probe has the TT move excluded, so by construction
  //     a singular re-search at this node will look like "no TT move"
  //     even though the position is normally TT-warm. Reducing depth
  //     during a singular probe would produce a misleading singular
  //     verdict. (BestMoveFound check would catch this case too in
  //     practice, but Excluded check is explicit and safer.)
  //   - Not in check: in-check nodes have limited and largely forced
  //     move sets where ordering matters less, but depth-reduction
  //     could miss the right defense in critical tactical positions.
  //     Stockfish-family convention is to exclude in-check from IIR.
  //
  // NMP, RFP, and futility above all ran at the ORIGINAL Depth, which
  // is the correct ordering: those heuristics are calibrated against
  // the actual search budget of this node, not the post-IIR budget.
  //
  // After Dec(Depth) here, the rest of the function - move generation,
  // ordering, the move loop with its LMR formula and recursive Search
  // calls, and the TT store on cutoff - all use the reduced depth
  // naturally. The TT entry written at the end of this Search will
  // record the reduced depth, which is exactly what later TT-depth
  // freshness checks should see.
  // =========================================================================
  if (Depth >= 4) and
     (BestMoveFound.FromR < 0) and
     (Excluded.FromR < 0) and
     (not InCheck) then
    Dec(Depth);

  GeneratePseudoLegalMoves(Moves, MoveCount, False);
  LegalMovesSearched := 0;
  NumSearchedQuiets  := 0;  // v0997b: per-node list of quiets searched without cutoff
  BestScore := -30000;

  OrigAlpha := Alpha;
  CurrentHash := State.Hash; // Save hash for TT storage

  // Sort Best Move from TT to front
  if BestMoveFound.FromR >= 0 then // Check if TT move is valid (sentinel -1 means none)
  begin
    for i := 0 to MoveCount - 1 do
    begin
      if (Moves[i].FromR = BestMoveFound.FromR) and (Moves[i].FromC = BestMoveFound.FromC) and
         (Moves[i].ToR = BestMoveFound.ToR) and (Moves[i].ToC = BestMoveFound.ToC) and
         (Moves[i].Promotion = BestMoveFound.Promotion) then
      begin
        Temp := Moves[0]; Moves[0] := Moves[i]; Moves[i] := Temp;
        Break;
      end;
    end;
  end;

  // =========================================================================
  // v0986: Precompute move-ordering scores once per node.
  //
  // Previously the selection sort recomputed each move's score on every
  // pass (O(MoveCount^2) scoring evaluations per node). With SEE added
  // to capture scoring, this would call SEE up to MoveCount times per
  // capture. Precomputing into MoveScores[] makes it exactly once per
  // capture, which is the only structurally affordable shape for SEE in
  // main-search ordering.
  //
  // The scoring rules below match v0985 verbatim except for the SEE
  // demotion of bad captures. Ordering bands (high to low):
  //   100000                        TT move match (locked at index 0)
  //    9000..9991                   Promotion (incl. promotion-captures)
  //    1000..9000                   Capture, MVV-LVA, SEE >= 0
  //    8000                         Killer slot 0
  //    7900                         Killer slot 1
  //       0..HISTORY_ORDERING_CAP   Quiet move (history)
  //   -9000..-1000                  Capture, MVV-LVA, SEE < 0 (v0986)
  //
  // Notes:
  //   - The TT move was swapped to index 0 above. Giving it score 100000
  //     here locks it at index 0 through the selection sort (a queen
  //     capture would otherwise have a higher MVV-LVA score and steal
  //     position 0).
  //   - En passant: Board[To] is empty for EP, so the MVV-LVA branch is
  //     not entered. EP keeps its v0985 behaviour (Score=0 fallthrough
  //     into history scoring), which is a pre-existing oddity but is
  //     not what v0986 is testing — left untouched.
  //   - SEE is only called when (capture) AND (not promotion) AND (not
  //     en passant), matching the qsearch SEE-pruning gate verbatim.
  //   - The score = 0 history fallback only triggers when MVV-LVA didn't
  //     fire and the move isn't a killer/promotion. A bad capture
  //     (Score = MVV-LVA - 10000, typically negative) does NOT trigger
  //     it, so bad captures do not get a spurious history score on top.
  // =========================================================================
  for i := 0 to MoveCount - 1 do
  begin
    Score := 0;
    SeePending[i] := False; // v1.00-pr1: default; set True only for un-SEE'd captures
    SeeValue[i]   := 0;     // v1.00-rc4: default; overwritten at lazy-SEE resolution

    // ---------------------------------------------------------------------
    // TT move detection. The TT move was swapped to index 0 above, but the
    // selection sort scoring below (MVV-LVA, killers, history) is blind to
    // that fact: a quiet TT move would score 0 or <= HISTORY_ORDERING_CAP,
    // while any later capture scores >= 9000, so the sort would happily
    // swap a capture into position 0 and lose the TT signal entirely.
    // Giving the TT move a score above every other possible score locks
    // it at index 0 regardless of what else is in the list.
    // ---------------------------------------------------------------------
    if (BestMoveFound.FromR >= 0) and
       (Moves[i].FromR     = BestMoveFound.FromR    ) and
       (Moves[i].FromC     = BestMoveFound.FromC    ) and
       (Moves[i].ToR       = BestMoveFound.ToR      ) and
       (Moves[i].ToC       = BestMoveFound.ToC      ) and
       (Moves[i].Promotion = BestMoveFound.Promotion) then
      Score := 100000
    else
    begin


      // MVV-LVA: Most Valuable Victim - Least Valuable Aggressor

      if State.Board[Moves[i].ToR, Moves[i].ToC] <> EMPTY then
      begin
        Score := (Abs(PieceValue[State.Board[Moves[i].ToR, Moves[i].ToC]]) * 10) -
                 (Abs(PieceValue[State.Board[Moves[i].FromR, Moves[i].FromC]]) div 100);

        // v0986: SEE-based demotion. Same gating as qsearch SEE-pruning.
        // v1.00-pr1: deferred. Instead of calling SEE() here for every
        // capture, we mark the move SEE-pending and leave MoveScores[i] at
        // its provisional MVV-LVA value. The SEE() call and the
        // -BAD_CAPTURE_PENALTY demotion are performed later, inside the
        // selection sort, only if and when this capture reaches the
        // front-runner slot. Same gate as before (capture AND not promotion
        // AND not en passant); promotion-captures and EP are never SEE-pending
        // and keep their eager scoring, matching the original gating exactly.
        if (Moves[i].Promotion = EMPTY) and (Moves[i].MoveType <> MT_EN_PASSANT) then
          SeePending[i] := True;
      end
      else if Moves[i].MoveType = MT_EN_PASSANT then
      begin
        // EP edge-case fix: the To square is EMPTY (the captured pawn sits
        // on an adjacent square), so the Board[To] <> EMPTY gate above
        // missed the move and Score fell through to the history-score
        // path — treating EP as a quiet move. EP is always pawn x pawn,
        // so the MVV-LVA score is 100*10 - 100/100 = 999, identical to
        // any other P x P capture. SEE returns 0 for EP (explicit
        // early-exit in SEE) so the demotion would never trigger; we
        // skip the SEE call to avoid the per-EP cost.
        Score := (Abs(PieceValue[wP]) * 10) - (Abs(PieceValue[wP]) div 100);
      end;
      // Promotions are always good
      if Moves[i].Promotion <> EMPTY then Score := Score + 9000;




      // =========================================================================
      // Killer Move Heuristic (v0997c: restored to the precompute loop)
      //
      // For quiet moves (those that fell through to Score = 0 after the
      // TT-match, MVV-LVA, EP, and promotion-bonus passes above), assign a
      // privileged ordering score if the move matches one of the two killers
      // stored at this ply:
      //   Killer 0  ->  Score = 8000   (most-recent cutoff move at this ply)
      //   Killer 1  ->  Score = 7900   (prior cutoff move, displaced by 0)
      //
      // Both slot scores sit strictly above the +HISTORY_ORDERING_CAP = 7000
      // ceiling for history-scored quiets and strictly below the 9000+ band
      // for captures and promotions, so killers are guaranteed to be tried
      // before any other quiet move at this ply but after every plausible
      // capture/promotion. The complete quiet-ordering band is now:
      //   8000                          Killer 0
      //   7900                          Killer 1
      //   -HISTORY_ORDERING_CAP..       Quiet by history (signed, v0997b)
      //     +HISTORY_ORDERING_CAP
      //
      // Why this was missing in v0997b: the v0986 precompute restructure
      // (which moved scoring from inside the selection sort into a one-pass
      // MoveScores[] array) inadvertently dropped the killer scoring lines.
      // The Killers[Depth, 0..1] table was still being maintained on beta
      // cutoff (see the cutoff handler below) and IsKiller was still being
      // computed inside the iteration loop (used to gate LMP and LMR), but
      // killers had no privileged ordering slot — they sorted by whatever
      // history score they had accumulated. v0997b's symmetric history clamp
      // gave them a strong de-facto ordering position (a killer move had
      // almost always been bonused on its prior cutoff and so scored close
      // to +HISTORY_ORDERING_CAP), which is part of why the v0997b SPRT
      // landed so strongly — history was the only working ordering signal
      // for quiets and sharpening it had outsized effect. The restored slot
      // mostly hoists "young" killers that have not yet accumulated history.
      //
      // Comparison uses FromR/FromC/ToR/ToC only, matching the existing
      // IsKiller check inside the iteration loop so the slot hit and the
      // IsKiller flag stay in 1:1 agreement. Promotion field is intentionally
      // not compared: it's omitted from the IsKiller check too, and matching
      // the existing convention is more important than the marginal precision
      // a Promotion comparison would add.
      //
      // Initial Killers[d, x] is all-zero after FillChar; this represents a
      // "no killer yet" state. The all-zero entry has FromR=ToR=FromC=ToC=0
      // (a1->a1), which cannot match any pseudo-legally generated move, so
      // no sentinel guard is needed — the comparison just naturally fails
      // against every real move.
      //
      // History fallback (v0997b, unchanged) runs only when no killer slot
      // matched. Score is signed in [-HISTORY_ORDERING_CAP..+HISTORY_ORDERING_CAP]
      // so quiet moves with negative history sort behind zero-history quiets
      // and can interleave with bad captures (-9000..-1000 band). This is
      // the ordering-side complement to the LMR-side adjustment that
      // v0997a/v0998 introduced: moves that have repeatedly failed to cut
      // off get pushed late in the list, not just searched at smaller
      // reductions.
      // =========================================================================
      if Score = 0 then
      begin
        if (Moves[i].FromR = Killers[Depth, 0].FromR) and
           (Moves[i].FromC = Killers[Depth, 0].FromC) and
           (Moves[i].ToR   = Killers[Depth, 0].ToR)   and
           (Moves[i].ToC   = Killers[Depth, 0].ToC) then
          Score := 8000
        else if (Moves[i].FromR = Killers[Depth, 1].FromR) and
                (Moves[i].FromC = Killers[Depth, 1].FromC) and
                (Moves[i].ToR   = Killers[Depth, 1].ToR)   and
                (Moves[i].ToC   = Killers[Depth, 1].ToC) then
          Score := 7900
        else
        begin
          HistoryVal := History[State.SideToMove, Moves[i].FromR, Moves[i].FromC, Moves[i].ToR, Moves[i].ToC];
          if HistoryVal >  HISTORY_ORDERING_CAP then HistoryVal :=  HISTORY_ORDERING_CAP;
          if HistoryVal < -HISTORY_ORDERING_CAP then HistoryVal := -HISTORY_ORDERING_CAP;
          Score := HistoryVal;
        end;
      end;
    end;
    MoveScores[i] := Score;
  end;

  // Iterate through all moves
  for i := 0 to MoveCount - 1 do
  begin
    // =====================================================================
    // Move ordering: selection sort on the precomputed MoveScores[] array.
    // SortScore is initialised to MoveScores[i] (the current candidate at
    // position i) and then we scan j = i+1 .. end for a higher-scoring
    // move. This is strictly cheaper than the v0985 in-sort scoring path,
    // and it handles negative scores (bad captures, v0986) correctly —
    // v0985 initialised SortScore to -1 which would have left negatively
    // scored moves in arbitrary (generation) order at the tail.
    //
    // BestScore is reserved for the actual search result tracking (see
    // the outer-loop init above) and is never touched by ordering.
    // =====================================================================
    // v1.00-pr1: lazy-SEE resolution wraps the selection scan. The scan below
    // is identical to the v0986..v09998d1 selection sort, except that when its
    // winning slot is a SEE-pending capture we resolve the SEE() and apply the
    // -BAD_CAPTURE_PENALTY demotion at that moment, then repeat the scan for
    // this slot. Because a demotion can only ever LOWER a move's score, a move
    // that loses its front-runner status after demotion can never re-win this
    // slot from a lower position, so the loop terminates in at most (number of
    // pending captures that reach the front here + 1) scans — and in the common
    // fail-high case it runs a single scan. The resulting Moves[i] chosen for
    // this slot is exactly the move the eager-SEE baseline would have selected,
    // so move order is bit-identical; only the number of SEE() calls differs.
    repeat
      SeeResolved := False;

      BestIdx := i;
      SortScore := MoveScores[i];
      for j := i + 1 to MoveCount - 1 do
      begin
        if MoveScores[j] > SortScore then
        begin
          SortScore := MoveScores[j];
          BestIdx := j;
        end;
      end;

      // v1.00-pr1: if the front-runner is a capture whose SEE demotion has
      // not yet been resolved, resolve it now. SEE() is called at most once
      // per capture across the whole node because SeePending[BestIdx] is
      // cleared here regardless of the demotion outcome. If the capture is
      // losing (SEE < 0) it is demoted by BAD_CAPTURE_PENALTY, which may drop
      // it below another move; SeeResolved forces one more scan of this slot
      // so the true winner is re-selected. If the capture is not losing, its
      // score is unchanged and it stays the winner — no re-scan needed.
      if SeePending[BestIdx] then
      begin
        SeePending[BestIdx] := False;
        SeeScore := SEE(Moves[BestIdx]);
        SeeValue[BestIdx] := SeeScore; // v1.00-rc4: retain for the SEE capture-pruning block below
        if SeeScore < 0 then
        begin
          MoveScores[BestIdx] := MoveScores[BestIdx] - BAD_CAPTURE_PENALTY;
          SeeResolved := True; // demotion changed the field; re-select this slot
        end;
      end;
    until not SeeResolved;

    // Swap best move (and its cached score and SEE-pending flag) to current
    // position. v1.00-pr1: SeePending is index-parallel to Moves/MoveScores
    // and must be swapped alongside them so a still-pending capture that is
    // moved down the list retains its pending flag for a later slot.
    if BestIdx <> i then
    begin
      Temp := Moves[i]; Moves[i] := Moves[BestIdx]; Moves[BestIdx] := Temp;
      TmpScore := MoveScores[i]; MoveScores[i] := MoveScores[BestIdx]; MoveScores[BestIdx] := TmpScore;
      SeeResolved := SeePending[i]; SeePending[i] := SeePending[BestIdx]; SeePending[BestIdx] := SeeResolved;
      // v1.00-rc4: SeeValue is index-parallel and must travel with its move.
      TmpScore := SeeValue[i]; SeeValue[i] := SeeValue[BestIdx]; SeeValue[BestIdx] := TmpScore;
    end;

    // =========================================================================
    // v09992: Singular-probe exclusion skip.
    //
    // When this Search invocation IS the singular probe (Excluded.FromR >= 0),
    // the move whose singularity is being tested must be skipped here so the
    // probe answers "what is the best score among the OTHER moves at this
    // position?". The match test is on all five identifying fields, matching
    // the convention used by the v0995 TT-move match elsewhere.
    //
    // This skip happens BEFORE DoMakeMove so no state is touched.
    // =========================================================================
    if (Excluded.FromR >= 0) and
       (Moves[i].FromR     = Excluded.FromR)     and
       (Moves[i].FromC     = Excluded.FromC)     and
       (Moves[i].ToR       = Excluded.ToR)       and
       (Moves[i].ToC       = Excluded.ToC)       and
       (Moves[i].Promotion = Excluded.Promotion) then
      Continue;

    // =========================================================================
    // v09992: Singular-extension probe.
    //
    // If the candidate move is the TT move AND the TT entry is deep and
    // strong enough to define a credible threshold, run a reduced-depth
    // null-window probe of the SAME position with this move excluded. If
    // the probe fails low against SingularBeta, no other move beats the
    // threshold — the TT move is singular and is searched one ply deeper.
    //
    // Gating (all must hold):
    //   1. Depth >= SINGULAR_MIN_DEPTH       — probe shallowness vs cost.
    //   2. Excluded.FromR < 0                — not already inside a probe.
    //   3. RootDepth - Depth > 0             — not at the root ply. The
    //      root has its own ordering/aspiration logic and the cost of a
    //      wrong extension there is disproportionate.
    //   4. TTE^.HashKey = State.Hash         — TT entry is for THIS pos.
    //   5. TTE^.Depth >= Depth - SINGULAR_TT_DEPTH_MARGIN — entry is
    //      not too shallow to derive a credible threshold from.
    //   6. TTE^.Flag <> ttAlpha              — only ttBeta/ttExact give
    //      a usable lower bound on the TT move's score. An upper-bound
    //      entry (ttAlpha) tells us nothing about whether THIS move
    //      could beat the threshold.
    //   7. Abs(TTE^.Score) < 28000           — not a mate score; singular
    //      probes near mate are unreliable.
    //   8. BestMoveFound.FromR >= 0          — we actually have a TT move.
    //   9. Moves[i] matches BestMoveFound    — this is THE TT move.
    //
    // The probe call passes Moves[i] as Excluded so the inner Search skips
    // it (clause above). The inner Search also skips its TT cutoff and
    // its NMP (gated on Excluded.FromR < 0 at the top of the function), so
    // the probe truly searches the remaining moves rather than returning
    // a cached score.
    //
    // Extension := 1 only when the probe fails low; check-extension below
    // gates on (Extension = 0) so the two do not double-extend.
    // =========================================================================
    Extension := 0;

    IsTTMove := (BestMoveFound.FromR >= 0) and
                (Moves[i].FromR     = BestMoveFound.FromR)     and
                (Moves[i].FromC     = BestMoveFound.FromC)     and
                (Moves[i].ToR       = BestMoveFound.ToR)       and
                (Moves[i].ToC       = BestMoveFound.ToC)       and
                (Moves[i].Promotion = BestMoveFound.Promotion);

    // =========================================================================
    // SEE capture pruning — v1.00-rc4.
    //
    // Skip captures whose static exchange evaluation loses more than
    // SEE_PRUNE_MARGIN * Depth centipawns. The ordering-side demotion
    // (v0986/v1.00-pr1) has already pushed these moves behind every quiet;
    // reaching one here means no earlier move cut off, and at Depth <= 6
    // the remaining horizon is too short to recover a loss of this size
    // (depth 1 requires SEE < -100; depth 6 requires SEE < -600).
    //
    // Placed BEFORE DoMakeMove: a pruned capture also skips the make/unmake
    // and the legality test, so the prune is cheaper than the LMP/futility
    // prunes below (which must run after DoMakeMove because they gate on
    // GivesCheck). No GivesCheck exemption is applied here — a checking
    // capture that sheds >= a pawn per remaining ply is overwhelmingly a
    // spite check; exempting them would re-add the make/unmake cost for
    // every pruning candidate and is left as a separate SPRT question.
    //
    // Conditions that must ALL be true to prune:
    //   1. Depth <= SEE_PRUNE_MAX_DEPTH (= 6): only near the horizon,
    //      where deep sacrificial compensation cannot be exploited.
    //   2. Not a PV node: a wrongly pruned move there can corrupt the
    //      principal variation (same rationale as LMP/futility).
    //   3. Not in check at this node: evasions are forced; a losing
    //      capture may be the only viable escape.
    //   4. Not the TT move: it has proven value in a prior search, and
    //      the singular-extension gate below assumes it is searched.
    //   5. At least one legal move already searched: preserves the
    //      checkmate/stalemate detection at the bottom of the function
    //      (LegalMovesSearched = 0 must remain reachable only when the
    //      side to move truly has no legal moves).
    //   6. Alpha not near mate: never prune when mate is in view
    //      (matches the LMP/futility convention).
    //   7. Plain capture: destination occupied, not a promotion, not
    //      en passant — exactly the population whose SEE the lazy-SEE
    //      machinery resolves, so SeeValue[i] is valid (see invariant
    //      at the SeeValue declaration). Promotions and EP are never
    //      pruned here, matching the SEE gating convention everywhere
    //      else in the engine.
    //   8. SeeValue[i] < -(SEE_PRUNE_MARGIN * Depth): the depth-scaled
    //      cut itself. Even trades and mild losses are kept.
    //
    // Uses State.Board (not OldState) for the capture test because the
    // move has NOT been made yet at this point in the loop.
    // =========================================================================
    if (Depth <= SEE_PRUNE_MAX_DEPTH) and
       (not IsPVNode) and
       (not InCheck) and
       (not IsTTMove) and
       (LegalMovesSearched >= 1) and
       (Abs(Alpha) < 28000) and                                     // not near a mate score
       (State.Board[Moves[i].ToR, Moves[i].ToC] <> EMPTY) and       // plain capture (move not yet made)
       (Moves[i].Promotion = EMPTY) and                             // not a promotion
       (Moves[i].MoveType <> MT_EN_PASSANT) and                     // not en passant
       (SeeValue[i] < -(SEE_PRUNE_MARGIN * Depth)) then
      Continue; // Skip this capture — statically loses too much material to recover in the remaining depth

    if (Depth >= SINGULAR_MIN_DEPTH) and
       (Excluded.FromR < 0) and
       (RootDepth - Depth > 0) and
       (TTE^.HashKey = State.Hash) and
       (TTE^.Depth >= Depth - SINGULAR_TT_DEPTH_MARGIN) and
       (TTE^.Flag <> ttAlpha) and
       (Abs(TTE^.Score) < 28000) and
       IsTTMove then
    begin
      TTScoreLocal  := ScoreFromTT(TTE^.Score, RootDepth - Depth);
      SingularBeta  := TTScoreLocal - SINGULAR_MARGIN_PER_PLY * Depth;
      SingularDepth := (Depth - 1) div 2;

      // Probe: search THIS position with Moves[i] excluded, at reduced
      // depth, with a null window around SingularBeta. PrevMove is
      // forwarded unchanged (we are still at the same position, so the
      // parent move context is the same).
      SingularScore := Search(SingularDepth, SingularBeta - 1, SingularBeta,
                              RootDepth, PrevMove, Moves[i], ParentStaticEval);
      // v1.00-rc9: the singular probe re-searches THIS SAME position (same
      // side to move) with one move excluded, so its parent-eval context is
      // identical to this node's — forward ParentStaticEval unchanged rather
      // than this node's StaticEval (which would be the eval of the position
      // the probe is itself evaluating, i.e. one ply off).

      if AbortSearch then Exit(Alpha);

      if SingularScore < SingularBeta then
        Extension := 1;
    end;

    // Make the move
    OldState := State;
    DoMakeMove(Moves[i]);

    // Verify move legality (king not in check after move)
    if IsInCheck(1 - State.SideToMove) then
    begin
      State := OldState;
      Continue;
    end;

    Inc(LegalMovesSearched);

    // =========================================================================
    // v0988: Cache "does this move give check?" once per loop iteration.
    // Used by LMP, futility pruning, and the check-extension below; computing
    // it once is strictly cheaper than the three independent IsInCheck calls
    // the naive layout would issue. After DoMakeMove the side to move has
    // flipped, so IsInCheck(State.SideToMove) tests whether the opponent
    // (the side now to move) is in check — which is exactly "did we give
    // check with this move?".
    // =========================================================================
    GivesCheck := IsInCheck(State.SideToMove);

    // =========================================================================
    // v0988: Cache killer-match flag once per loop iteration.
    // Used by both LMP and LMR. Previously this was computed only inside
    // the LMR block, but LMP also gates on it — hoisting avoids computing
    // it twice when both blocks are reached, and avoids a more invasive
    // restructuring.
    // =========================================================================
    IsKiller := False;
    if (Moves[i].FromR = Killers[Depth, 0].FromR) and (Moves[i].FromC = Killers[Depth, 0].FromC) and
       (Moves[i].ToR = Killers[Depth, 0].ToR) and (Moves[i].ToC = Killers[Depth, 0].ToC) then
      IsKiller := True
    else if (Moves[i].FromR = Killers[Depth, 1].FromR) and (Moves[i].FromC = Killers[Depth, 1].FromC) and
            (Moves[i].ToR = Killers[Depth, 1].ToR) and (Moves[i].ToC = Killers[Depth, 1].ToC) then
      IsKiller := True;

    // =========================================================================
    // Late Move Pruning (LMP) — v0988
    //
    // After LMP_Threshold[Depth] legal moves have been searched at this
    // node, additional quiet non-checking non-killer moves are skipped
    // outright instead of being searched (even at reduced depth). LMP
    // does NOT compare static eval to alpha — it relies entirely on the
    // ordinal position of the move within the ordering.
    //
    // Placed BEFORE futility because the LMP predicate is strictly
    // cheaper (no static-eval comparison) and at shallow depths both
    // can apply to the same move. Whichever fires first triggers
    // Continue and skips the rest of the loop body, including LMR.
    //
    // Conditions that must ALL be true to prune:
    //   1. Depth <= LMP_MAX_DEPTH (= 3): only close to the horizon,
    //      where the cost of a wrong cutoff is bounded.
    //   2. Not a PV node: a wrongly pruned move can corrupt the PV.
    //   3. Not in check at this node: escape moves are forced.
    //   4. Quiet move: captures, promotions, and en passant have
    //      intrinsic ordering signal; never prune them by ordinal
    //      position alone.
    //   5. Not a killer: killers proved cutoff-worthy at this ply
    //      elsewhere — searching them is cheap relative to their hit
    //      rate.
    //   6. Not giving check: a checking move can be tactically critical
    //      regardless of where it sits in the ordering.
    //   7. Alpha not near mate: never prune when mate is in view.
    //   8. LegalMovesSearched > LMP_Threshold[Depth]: the first N
    //      legal moves are always searched in full (subject to the
    //      LMR ladder if Depth >= 3).
    // =========================================================================
    if (Depth <= LMP_MAX_DEPTH) and
       (not IsPVNode) and
       (not InCheck) and
       (OldState.Board[Moves[i].ToR, Moves[i].ToC] = EMPTY) and     // quiet move
       (Moves[i].Promotion = EMPTY) and                             // not a promotion
       (Moves[i].MoveType <> MT_EN_PASSANT) and                     // not en passant
       (not IsKiller) and                                           // not a killer
       (not GivesCheck) and                                         // not giving check
       (Abs(Alpha) < 28000) and                                     // not near a mate score
       (LegalMovesSearched > LMP_Threshold[Depth]) then
    begin
      State := OldState;
      Continue; // Skip this move — late, quiet, and below the depth-scaled threshold
    end;

    // =========================================================================
    // Futility Pruning
    // At depth 1-2 (close to the search horizon), if the static evaluation is
    // so far below alpha that even a significant material gain cannot raise it
    // above alpha, there is no point searching this move — it is very unlikely
    // to be useful and we skip it to save nodes.
    //
    // The margin and the minimum-moves-searched threshold are BOTH per-depth
    // (see the FutilityMargin / FutilityMinMoves arrays at the top of the
    // function) so that depth 2 is far more conservative than depth 1:
    //   Depth 1: prune if StaticEval + 200 < Alpha, after >= 2 legal moves
    //   Depth 2: prune if StaticEval + 500 < Alpha, after >= 4 legal moves
    //
    // Rationale for the depth-2 caution:
    //   - At depth 2 there is a full opponent ply between this quiet move and
    //     quiescence, so positional gains from quiet moves can be lost.
    //   - Quiet moves are now ordered by the history heuristic, which helps,
    //     but it is still only a coarse signal — searching a few moves first
    //     before pruning kicks in is the safer policy.
    //
    // Conditions that must ALL be true before pruning:
    //   1. Depth <= 2: only close to the search horizon
    //   2. Not a PV node: at PV nodes a wrong pruning decision can corrupt
    //      the principal variation and the root best-move choice
    //   3. StaticEval was computed (sentinel check confirms not in check before move)
    //   4. Quiet move: not a capture, not a promotion, not en passant
    //      (captures and promotions can swing the score dramatically)
    //   5. Not giving check (GivesCheck cache, v0988): if the move gives
    //      check it could be very strong
    //   6. Alpha is not a mate score: never prune when a mate is in view
    //   7. Enough legal moves already searched: see FutilityMinMoves above
    //
    // StaticEval is reused from the pre-computation above — Evaluate() is
    // NOT called again here. The sentinel check (> -30000) is always true
    // when not in check at depth <= 2, which is guaranteed by the
    // pre-computation condition (depth <= 3 and not in check).
    // =========================================================================
    if (Depth <= 1) and  //depth 2 (extended Futility Pruning)  is regressive with elo -10.1 +/- 11.3  and therefore avoided
       (not IsPVNode) and                                           // safe only at non-PV nodes
       (StaticEval > -30000) and                                    // was computed (not in check before move)
       (OldState.Board[Moves[i].ToR, Moves[i].ToC] = EMPTY) and     // quiet move: use OldState since DoMakeMove already executed
       (Moves[i].Promotion = EMPTY) and                             // not a promotion
       (Moves[i].MoveType <> MT_EN_PASSANT) and                     // not en passant
       (not GivesCheck) and                                         // not giving check (v0988 cache)
       (Abs(Alpha) < 28000) and                                     // not near a mate score
       (LegalMovesSearched > FutilityMinMoves[Depth]) then           // enough plausible moves already searched
    begin
      if StaticEval + FutilityMargin[Depth] < Alpha then
      begin
        State := OldState;
        Continue; // Skip this move — static eval too far below alpha to recover
      end;
    end;

    // Check Extension: Extend search by 1 ply if we give check
    // (uses GivesCheck cache, v0988)
    // v09992: gated on (Extension = 0) so a singular extension already
    // set above is not stacked with a check extension. The cap of 1 ply
    // per move keeps total search horizon controlled.
    if (Extension = 0) and GivesCheck then Extension := 1;

    // =========================================================================
    // Late Move Reductions (LMR)
    // For moves that come late in the ordering (after the TT move, captures,
    // promotions, killers, and the best history-scored quiets), the move is
    // very unlikely to be the best one — move ordering put it there for a
    // reason. Instead of searching it at full depth and almost always finding
    // that it failed low, search it at REDUCED depth first. If the reduced
    // search returns a score that beats alpha, only then re-search at full
    // depth to verify.
    //
    // Net effect: the engine spends more time on the moves likely to matter
    // (early in the ordering) and skims over the rest. Typical Elo gain at
    // this engine strength: 50-100. The technique only pays once move
    // ordering is good, which is why we added it AFTER the history heuristic.
    //
    // Conditions that must ALL be true to reduce:
    //   1. Depth >= LMR_MIN_DEPTH (= 3): below this the search behind the
    //      reduction is too short to be reliable
    //   2. LegalMovesSearched >= LMR_MIN_MOVE (= 3): the first two moves
    //      get full-depth search
    //   3. Not a check extension (Extension = 0): if the move gives check,
    //      it can be tactically critical
    //   4. Not in check at this node: when in check we have very few legal
    //      moves and they tend to be all important
    //   5. Not a killer move: killers have already proven cutoff-worthy at
    //      this ply elsewhere (IsKiller cache, computed earlier in v0988)
    //   6. Quiet move: captures, promotions, and en passant can swing
    //      the score and should not be reduced
    //
    // Reduction depth:
    //   LegalMovesSearched 3..5  -> Reduction = 1
    //   LegalMovesSearched >= 6  -> Reduction = 2
    //   LegalMovesSearched >= 12 -> Reduction = 3
    //   Clamped so the reduced new depth is at least 1 (no further LMR if
    //   the clamp would push reduction to zero anyway).
    //
    // v0997: history-based LMR adjustment. After the base reduction and PV
    // adjustment, the history score of the candidate quiet move is read; if
    // it exceeds HISTORY_LMR_HIGH the reduction is decreased by 1 ply, so
    // moves that have produced cutoffs elsewhere in the tree are searched
    // closer to full depth.
    // =========================================================================
    Reduction := 0;
    if (Depth >= LMR_MIN_DEPTH) and
       (LegalMovesSearched >= LMR_MIN_MOVE) and
       (Extension = 0) and                                          // not extending for check
       (not InCheck) and                                            // not escaping check
       (not IsKiller) and                                           // killer moves searched at full depth
       (OldState.Board[Moves[i].ToR, Moves[i].ToC] = EMPTY) and     // quiet move (no capture)
       (Moves[i].Promotion = EMPTY) and                             // not a promotion
       (Moves[i].MoveType <> MT_EN_PASSANT) then                    // not en passant
    begin
      // Base reduction by move number: deeper into the move list = larger
      // reduction. Move ordering has put the most promising moves first,
      // so by move 6 or 12 we are searching moves that are very unlikely
      // to be best — the cost of getting one of those wrong (and triggering
      // a re-search) is more than paid for by the nodes saved on the rest.
      Reduction := 1;
      if LegalMovesSearched >= LMR_DEEP_MOVE      then Reduction := 2;
      if LegalMovesSearched >= LMR_VERY_DEEP_MOVE then Reduction := 3;

      // PV nodes are sensitive to depth: a wrongly reduced move here can
      // corrupt the principal variation that propagates back to the root.
      // Reduce by one less ply at PV nodes. With this adjustment:
      //   PV node, moves 3-5  : R = 0 (no reduction)
      //   PV node, moves 6-11 : R = 1
      //   PV node, moves 12+  : R = 2
      //   Non-PV, moves 3-5   : R = 1
      //   Non-PV, moves 6-11  : R = 2
      //   Non-PV, moves 12+   : R = 3
      if IsPVNode then Dec(Reduction);

      // =====================================================================
      // v0998: Continuous history-based LMR adjustment.
      //
      // Read the history score of the quiet move just played. Use
      // OldState.SideToMove because DoMakeMove (executed earlier in this
      // loop iteration) has flipped State.SideToMove — we want the side
      // that PLAYED the move, not the side now to respond.
      //
      // Subtract (HistoryVal div HISTORY_LMR_DIVISOR) from the reduction.
      // With HistoryVal capped at HISTORY_MAX = 16384 and the divisor at
      // 4096, the subtraction is in 0..4. Captures, promotions, and en
      // passant are already excluded by the outer LMR guard, so no extra
      // gating is needed here. The lower clamp on Reduction below handles
      // the case where this drives Reduction negative — high-history
      // moves can have LMR fully cancelled, which is the intended
      // behaviour: history says this move has been cutting off in
      // siblings, so search it at full depth.
      // =====================================================================
      HistoryVal := History[OldState.SideToMove,
                            Moves[i].FromR, Moves[i].FromC,
                            Moves[i].ToR,   Moves[i].ToC];
      Reduction := Reduction - (HistoryVal div HISTORY_LMR_DIVISOR);

      // Clamp: reduced new depth must be at least 1 (i.e. Reduction <=
      // Depth - 2 since Extension is 0 in this branch). The combined PV
      // and history adjustments can take Reduction to -2 for the first
      // late tier at a PV node with a high-history move; the lower clamp
      // brings that back to 0.
      if Reduction > Depth - 2 then Reduction := Depth - 2;
      if Reduction < 0 then Reduction := 0;
    end;

    // =========================================================================
    // Recursive search: Principal Variation Search (PVS) + LMR ladder.
    //
    // First move (LegalMovesSearched = 1):
    //   Full window, full depth. Establishes alpha for this node.
    //
    // Subsequent moves:
    //   Step 1: Null-window search at reduced depth (if Reduction > 0,
    //           otherwise just null-window at full depth — i.e. plain PVS).
    //   Step 2: If LMR was applied AND it beat alpha, re-search at full
    //           depth (still null window) to verify the reduced search
    //           was not over-optimistic.
    //   Step 3: If the move beat alpha AND is within the (alpha, beta)
    //           window, re-search with full window for an exact score
    //           (standard PVS re-search).
    //
    // In the vast majority of nodes only step 1 executes — both re-search
    // branches require the move to look unexpectedly strong, which is rare
    // for late moves by construction.
    // =========================================================================
    // v1.00-rc9: all four child searches below pass THIS node's StaticEval as
    // the child's ParentStaticEval. The child is one ply deeper (opponent to
    // move); ITS child (our grandchild, our side again) is what compares
    // against this value to set Improving. StaticEval is the -30000 sentinel
    // when this node is in check, which correctly makes the grandchild "not
    // improving" off an in-check ancestor.
    if LegalMovesSearched = 1 then
      // First legal move: full window search to establish alpha
      Score := -Search(Depth - 1 + Extension, -Beta, -Alpha, RootDepth, Moves[i], NoExcluded, StaticEval)
    else
    begin
      // Step 1: null window search, possibly at reduced depth (LMR)
      Score := -Search(Depth - 1 + Extension - Reduction, -Alpha - 1, -Alpha, RootDepth, Moves[i], NoExcluded, StaticEval);

      // Step 2: LMR verification — if a reduced search beat alpha, re-search
      // at full depth (still null window) before trusting it.
      if (Reduction > 0) and (Score > Alpha) and not AbortSearch then
        Score := -Search(Depth - 1 + Extension, -Alpha - 1, -Alpha, RootDepth, Moves[i], NoExcluded, StaticEval);

      // Step 3: PVS re-search — if the move is a PV candidate, re-search
      // with the full window to get an exact score.
      if (Score > Alpha) and (Score < Beta) and not AbortSearch then
        Score := -Search(Depth - 1 + Extension, -Beta, -Alpha, RootDepth, Moves[i], NoExcluded, StaticEval);
    end;
    State := OldState;

    if AbortSearch then Exit(Alpha);




    // v0997b: classify the just-searched move as quiet or not. Used by both
    // the cutoff bookkeeping (which gates killer-update + history-bonus on
    // IsQuietMove, matching v0997a) and the no-cutoff append further down.
    // OldState.Board is the correct read here because DoMakeMove has already
    // executed and updated State.Board; we want the from-position contents
    // of the destination square.
    IsQuietMove := (OldState.Board[Moves[i].ToR, Moves[i].ToC] = EMPTY) and
                   (Moves[i].MoveType <> MT_EN_PASSANT);

    // Beta cutoff
    if Score >= Beta then
    begin
      // =====================================================================
      // Quiet-move bookkeeping on beta cutoff (v0997a behaviour preserved).
      // For quiet (non-capture, non-en-passant) moves that produce a cutoff
      // we update two ordering heuristics:
      //   - Killer moves: this move is recorded as the most recent killer
      //     for this ply, so it is searched very early at sibling nodes
      //     at the same ply.
      //   - History BONUS: the move's history counter is incremented by
      //     Depth*Depth. The quadratic weight means cutoffs found deeper
      //     in the tree (where each subtree is more expensive to search)
      //     carry more weight than shallow ones, but the value is capped
      //     at HISTORY_MAX so a single hot move cannot saturate ordering.
      // Captures and en-passant are excluded from killer/bonus because
      // MVV-LVA already supplies their ordering signal.
      // =====================================================================
      if IsQuietMove then
      begin
        Killers[Depth, 1] := Killers[Depth, 0];
        Killers[Depth, 0] := Moves[i];

        Inc(History[State.SideToMove, Moves[i].FromR, Moves[i].FromC, Moves[i].ToR, Moves[i].ToC],
            Depth * Depth);
        if History[State.SideToMove, Moves[i].FromR, Moves[i].FromC, Moves[i].ToR, Moves[i].ToC] > HISTORY_MAX then
          History[State.SideToMove, Moves[i].FromR, Moves[i].FromC, Moves[i].ToR, Moves[i].ToC] := HISTORY_MAX;
      end;

      // =====================================================================
      // v0997b: History MALUS on every quiet move searched at this node
      // without producing a cutoff.
      //
      // SearchedQuiets[] was populated by the no-cutoff append below on
      // each previous iteration of the move loop. Captures, EP, illegal
      // moves, LMP/futility-pruned moves, and the current (cutoff) move
      // are all absent from the list — only quiet moves that completed
      // the recursive search call without producing a cutoff are
      // penalised.
      //
      // Magnitude: -Depth*Depth, matching the bonus on the cutoff move
      // above. This is the cleanest baseline formulation — Stockfish uses
      // asymmetric bonus/malus magnitudes (typically malus smaller than
      // bonus) tuned over millions of self-play games, but equal magnitude
      // is the natural first cut for SPRT validation. If v0997b lands
      // positive, asymmetric magnitudes can be tested as v0997c.
      //
      // Floor: HISTORY_MIN. Without this, repeated malus on a move that
      // never cuts off would drive its history score arbitrarily negative
      // and dominate later ordering decisions.
      //
      // Applied REGARDLESS of whether the cutoff move itself is quiet or
      // a capture — the signal that matters is "these quiets were tried
      // and didn't cut off", not who eventually did. This matches the
      // Stockfish formulation.
      // =====================================================================
      for k := 0 to NumSearchedQuiets - 1 do
      begin
        Dec(History[State.SideToMove,
                    SearchedQuiets[k].FromR, SearchedQuiets[k].FromC,
                    SearchedQuiets[k].ToR,   SearchedQuiets[k].ToC],
            Depth * Depth);
        if History[State.SideToMove,
                   SearchedQuiets[k].FromR, SearchedQuiets[k].FromC,
                   SearchedQuiets[k].ToR,   SearchedQuiets[k].ToC] < HISTORY_MIN then
          History[State.SideToMove,
                  SearchedQuiets[k].FromR, SearchedQuiets[k].FromC,
                  SearchedQuiets[k].ToR,   SearchedQuiets[k].ToC] := HISTORY_MIN;
      end;

      // Store in Transposition Table (using parent position hash)
      TTE^.HashKey := CurrentHash;
      // v1.00-rc5: packed entry. Depth (0..~100) and the ScoreToTT result
      // (bounded by the +/-30000 window / +/-29100 mate range) fit their
      // narrowed fields exactly; the casts document that contract.
      TTE^.Depth := ShortInt(Depth);
      TTE^.Score := SmallInt(ScoreToTT(Beta, RootDepth - Depth));
      TTE^.Flag := ttBeta;
      TTE^.MoveData := PackMove(Moves[i]);
      Exit(Beta);
    end;

    // =========================================================================
    // v0997b: No cutoff — record this move (if quiet) as "searched without
    // cutoff" so a later sibling cutoff at this node can apply malus to it.
    //
    // Captures and en-passant are excluded for two reasons:
    //   1. They have no history-table entry to penalise (history is indexed
    //      only by from/to squares, with no piece-type granularity — and
    //      capture ordering uses MVV-LVA + SEE instead).
    //   2. MVV-LVA already differentiates captures by victim/aggressor,
    //      so the malus signal would be redundant noise.
    // =========================================================================
    if IsQuietMove then
    begin
      SearchedQuiets[NumSearchedQuiets] := Moves[i];
      Inc(NumSearchedQuiets);
    end;

    // Update best score and alpha
    if Score > BestScore then
    begin
      BestScore := Score;
      BestMoveFound := Moves[i];
    end;
    if Score > Alpha then Alpha := Score;
  end;

  // Check for checkmate or stalemate
  if LegalMovesSearched = 0 then
  begin
    if IsInCheck(State.SideToMove) then
      Exit(-29000 + (RootDepth - Depth)) // Checkmate: closer mate = more negative
    else
      Exit(0); // Stalemate
  end;

  // Store in Transposition Table (using parent position hash)
  TTE^.HashKey := CurrentHash;
  // v1.00-rc5: packed entry — same field-range contract as the beta-cutoff
  // store above. BestMoveFound may still be the FromR = -1 sentinel here
  // (fail-low node with no TT move); PackMove encodes that as
  // High(Cardinal) and UnpackMove restores it exactly.
  TTE^.Depth := ShortInt(Depth);
  TTE^.Score := SmallInt(ScoreToTT(Alpha, RootDepth - Depth));
  if Alpha <= OrigAlpha then
    TTE^.Flag := ttAlpha
  else
    TTE^.Flag := ttExact;
  TTE^.MoveData := PackMove(BestMoveFound);

  Result := Alpha;
end;


procedure ShuffleMoves(var Moves: TMoveList; MoveCount: integer);//**Randomizes move order (used at root to avoid deterministic bias).**
var
  i, j: integer;
  Temp: TMove;
begin
  for i := MoveCount - 1 downto 1 do
  begin
    j := Random(i + 1);
    Temp := Moves[i]; Moves[i] := Moves[j]; Moves[j] := Temp;
  end;
end;

function GetPVLine(BestRootMove: TMove; MaxPly: integer): string;
// Reconstructs the principal variation by following TT best moves from
// the position AFTER the root move has already been applied.
// BestRootMove: the best move found at the root by GetBestMove.
// MaxPly: maximum number of moves to trace (= CurrentDepth).
var
  TTIdx: integer;
  TTE: ^TTTEntry;
  SavedState: TGameState;
  Move: TMove;
  Ply: integer;
begin
  SavedState := State;
  Result := MoveToStr(BestRootMove);  // Always start with the root move
  DoMakeMove(BestRootMove);           // Apply root move so TT walk starts from ply 1

  for Ply := 1 to MaxPly - 1 do
  begin
    TTIdx := Integer(State.Hash and TTMask);
    TTE := @TT[TTIdx];
    // Stop if no TT entry for this position, or stored move is sentinel/uninitialised
    if (TTE^.HashKey <> State.Hash) then Break;
    Move := UnpackMove(TTE^.MoveData); // v1.00-rc5: packed entry
    if Move.FromR < 0 then Break;       // Sentinel: no best move stored
    if (Move.FromR = Move.ToR) and (Move.FromC = Move.ToC) then Break; // Null move guard
    Result := Result + ' ' + MoveToStr(Move);
    DoMakeMove(Move);
  end;

  State := SavedState;  // Restore board to root position
end;


function HashFull: integer;
{**v1.00-rc3b: transposition-table fill level as a permille (0..1000), for
 the UCI 'hashfull' info field. Samples the first min(1000, Length(TT))
 entries and reports the fraction whose HashKey is non-zero. An empty slot
 has HashKey = 0 (ClearTT zeros the whole array); a real position hash of
 exactly 0 is astronomically rare and, at worst, undercounts one slot in
 the sample, which is within the noise of a permille estimate. Sampling
 (rather than scanning the whole table) keeps the cost O(1) regardless of
 hash size, matching standard engine practice.}
var
  n, i, used: integer;
begin
  n := Length(TT);
  if n = 0 then Exit(0);
  if n > 1000 then n := 1000;
  used := 0;
  for i := 0 to n - 1 do
    if TT[i].HashKey <> 0 then Inc(used);
  // permille of the sample
  Result := (used * 1000) div n;
end;

function ScoreToUci(Score: integer): string;
{**v1.00-rc3b: format a search score as a UCI 'score' token. Mate scores
 (|score| > 28000, the near-mate threshold used throughout the engine) are
 reported as 'score mate N' where N is the number of MOVES to mate, signed
 (+ = we mate, - = we are mated); everything else is 'score cp N'.

 Mate encoding: a checkmate returns -(29000 - ply) from the mated side's
 view, so |score| = 29000 - plies_to_mate, giving plies = 29000 - |score|.
 Moves-to-mate = ceil(plies / 2) = (plies + 1) div 2. The sign of N follows
 the sign of the score. This is pure output formatting; it does not change
 any score used in search.}
var
  plies, movesToMate: integer;
begin
  if Abs(Score) > 28000 then
  begin
    plies := 29000 - Abs(Score);
    if plies < 0 then plies := 0;
    movesToMate := (plies + 1) div 2;
    if Score > 0 then
      Result := 'score mate ' + IntToStr(movesToMate)
    else
      Result := 'score mate -' + IntToStr(movesToMate);
  end
  else
    Result := 'score cp ' + IntToStr(Score);
end;

                       // =========================================================================
// ALSO ADD to the GLOBAL const block (next to STABLE_ITERS_FOR_EASE etc.):
//
//  // v1.00-rc3g: fixed score margins, NOT tuning knobs. Values sit on a
//  // wide plateau (20-35 / 30-60 test the same); do not sweep them.
//  //   SCORE_STABLE_MARGIN  a repeated best move only counts toward
//  //                        StableIters if its score did not fall more
//  //                        than this (cp) vs the previous completed depth.
//  //   SCORE_PANIC_DROP     a score fall larger than this (cp) vs the
//  //                        previous completed depth extends the budget to
//  //                        the existing 150% ceiling. Adds NO new clock
//  //                        headroom: the go-handler CeilingCapAlloc clamp
//  //                        already guarantees alloc*150% fits the clock.
//  SCORE_STABLE_MARGIN = 25;
//  SCORE_PANIC_DROP    = 40;
// =========================================================================

function GetBestMove(AllocatedTimeMs: integer; MaxDepth: integer): string;
{**Manages iterative deepening and time allocation for the entire search.**
 This top-level function orchestrates the search process:
 - Generates all legal moves for the current position
 - Implements **iterative deepening** (searching depth 1, then 2, then 3, etc.)
 - Uses previous depth's best move to order the first move of next depth
 - Monitors time usage and decides when to stop searching
 - Partial search recovery: if a depth is aborted mid-search, the best move
   found so far is used if at least one root move was fully evaluated AND
   the partial score is not drastically worse than the last completed depth
   score (controlled by PARTIAL_FALLBACK_MARGIN below). Otherwise the
   previous depth's result is retained.
 - Returns the best move in UCI format (e.g., "e2e4")
 - Handles special cases (no moves, one move only)

 v0996: aspiration windows added. At depth >= ASP_MIN_DEPTH and when
 LastCompletedScore is not a mate score, the root window is centred on
 the previous depth's score with half-width ASP_INIT_DELTA. On fail-high
 (PartialBestScore >= WindowBeta) Beta widens; on fail-low
 (PartialBestScore <= OriginalAlpha) Alpha widens. Widening is
 asymmetric and AspDelta doubles per retry, falling through to a full
 window once AspDelta exceeds ASP_MAX_DELTA. OriginalAlpha is captured
 at the top of each retry attempt so the loop's necessary Alpha
 mutation (PVS at root) does not break fail-low detection — this is the
 specific failure mode that sank the earlier attempt.}
const
  // Partial-depth recovery margin (centipawns). When a depth aborts
  // after evaluating at least one root move, the partial best score is
  // compared against the previous completed depth's best score. If the
  // partial is worse by more than this margin, the partial is REJECTED
  // and the previous depth's result is kept. See v0995 comments above.
  PARTIAL_FALLBACK_MARGIN = 30;
const
  // Fixed values, not tuning knobs. SCORE_STABLE_MARGIN: a repeated best
  // move only counts as stable if its score did not fall more than this
  // (centipawns) versus the previous completed depth. SCORE_PANIC_DROP:
  // a fall larger than this extends the budget to the existing 150%
  // ceiling (no new headroom - the go-handler clamps already bound it).
  SCORE_STABLE_MARGIN = 25;
  SCORE_PANIC_DROP    = 40;

var
  Moves: TMoveList;
  MoveCount, i, Score, BestScore, BestIdx, CurrentDepth, Alpha, Beta: integer;
  OldState: TGameState;
  BestMoveAtDepth, templog: string;
  StartTime, CurrentTime, DepthStartTime, TimeForThisDepth: QWord;
  TimeElapsed: QWord;
  Temp: TMove;
  RootPrev: TMove;  // v0998: sentinel PrevMove passed to root Search calls.
  RootExcluded: TMove;  // v09992: sentinel Excluded passed to root Search calls
                        // (root is never inside a singular probe; FromR := -1).
  LastBestIdx: integer;
  BookMove: string;
  PartialBestIdx: integer;
  PartialBestScore: integer;
  PartialMoveCount: integer;
  LastCompletedScore: integer;
  InfoLine: string;
  // --- v0996 aspiration window locals ---
  AspDelta: integer;          // current aspiration half-width
  OriginalAlpha: integer;     // Alpha at top of current root-loop attempt
  WindowBeta: integer;        // Beta at top of current root-loop attempt
  AspirationDone: boolean;    // exit flag for the inner retry loop
  AspirationRetries: integer; // per-depth diagnostic counter
  // --- v1.00-rc3g stability time-management locals ---
  PrevBestMoveStr: string;    // best move from the previous completed depth,
                              // for the stability comparison. '' = no
                              // completed depth yet; guards every use of
                              // PrevScore below.
  PrevScore: integer;         // score of the previous completed depth.
                              // Only meaningful when PrevBestMoveStr <> ''.
  StableIters: integer;       // consecutive completed depths whose best move
                              // equals the previous depth's AND whose score
                              // did not fall by more than SCORE_STABLE_MARGIN.
  PanicMode: boolean;         // score fell by more than SCORE_PANIC_DROP vs
                              // the previous completed depth: extend budget.
  EffBudget: QWord;           // per-move budget after easy shrink / panic extend.
begin
  // === OPENING BOOK CHECK ===
  BookMove := GetBookMove;
  if BookMove <> '' then
  begin
    InfoLine := 'info Found something in the opening book';
    WriteLn(InfoLine);
    Flush(Output);
    Log(InfoLine);
    Result := BookMove;
    Exit;
  end;
  // === END BOOK CHECK ===

  GenerateLegalMoves(Moves, MoveCount);
  if MoveCount = 0 then Exit('0000');
  if MoveCount = 1 then Exit(MoveToStr(Moves[0]));
  ShuffleMoves(Moves, MoveCount);

  StartTime := GetTickCount64;
  SearchStartTime := StartTime;

  // =========================================================================
  // v1.00-rc3f: derive the mid-search abort ceiling from the allocation.
  //   ExceedCeilingAbortMs = AllocatedTimeMs * EXCEED_CEILING_FACTOR_PCT/100
  // This is the emergency brake polled inside Search()/Quiescence(); the
  // normal stop is the between-iterations stability check further below.
  // AllocatedTimeMs <= 0 or >= TM_UNLIMITED_MS means no time management
  // (fixed depth / nodes / 'go infinite'): the abort is disabled (0) and
  // the depth/node limit is the real bound. QWord intermediate avoids int32
  // overflow for large allocations.
  // =========================================================================
  if (AllocatedTimeMs > 0) and (AllocatedTimeMs < TM_UNLIMITED_MS) then
    ExceedCeilingAbortMs := integer((QWord(AllocatedTimeMs) * EXCEED_CEILING_FACTOR_PCT) div 100)
  else
    ExceedCeilingAbortMs := 0;  // no time management: mid-search abort disabled

  Result             := MoveToStr(Moves[0]);
  BestMoveAtDepth    := Result;
  BestScore          := -30000;
  BestIdx            := 0;
  LastBestIdx        := 0;
  LastCompletedScore := -30000;
  templog            := '';
  // v1.00-rc3g: time-management tracking state. PrevScore's value is
  // irrelevant until PrevBestMoveStr is non-empty (every comparison below
  // is guarded on that); 0 just keeps it formally initialized.
  PrevBestMoveStr    := '';
  PrevScore          := 0;
  StableIters        := 0;
  PanicMode          := False;
  //CompletedDepth     := 0;   // instrumentation

  // v0998: initialise root PrevMove sentinel once. Passed unchanged to all
  // three root Search calls below. Other fields default to FillChar zero.
  RootPrev := Default(TMove);
  RootPrev.FromR := -1;

  // v09992: initialise root Excluded sentinel once. Passed unchanged to all
  // three root Search calls below. The root is never inside a singular probe,
  // so this is always the sentinel; the parameter exists so the root calls
  // typecheck against the new Search signature.
  RootExcluded := Default(TMove);
  RootExcluded.FromR := -1;



  for CurrentDepth := 1 to MaxDepth do
  begin
    SearchNodes    := 0;
    NodeCheckCount := 0;
    AbortSearch    := False;
    SelDepth       := CurrentDepth;  // v1.00-rc3b: seldepth is at least the
                                     // nominal depth; nodes push it higher.

    // =====================================================================
    // Move ordering: bring the previous depth's best move to index 0.
    // Match on all five fields (including Promotion) — see v0995 comment.
    // Done ONCE per depth, BEFORE the aspiration retry loop, so retries
    // reuse the same move order.
    // =====================================================================
    if (CurrentDepth > 1) and (LastBestIdx >= 0) and (LastBestIdx < MoveCount) then
    begin
      for i := 0 to MoveCount - 1 do
      begin
        if (Moves[i].FromR     = Moves[LastBestIdx].FromR    ) and
           (Moves[i].FromC     = Moves[LastBestIdx].FromC    ) and
           (Moves[i].ToR       = Moves[LastBestIdx].ToR      ) and
           (Moves[i].ToC       = Moves[LastBestIdx].ToC      ) and
           (Moves[i].Promotion = Moves[LastBestIdx].Promotion) then
        begin
          if i <> 0 then
          begin
            Temp     := Moves[0];
            Moves[0] := Moves[i];
            Moves[i] := Temp;
          end;
          BestIdx     := 0;
          LastBestIdx := 0;
          Break;
        end;
      end;
    end;

    DepthStartTime := GetTickCount64;

    // =====================================================================
    // v0996 aspiration window setup. At shallow depths or when
    // LastCompletedScore is a mate score, fall through to a full
    // (-30000, +30000) window — narrow windows around mate scores are
    // unstable and shallow depths have no reliable centre.
    // =====================================================================
    if (CurrentDepth >= ASP_MIN_DEPTH) and
       (Abs(LastCompletedScore) < ASP_MATE_BOUND) then
    begin
      AspDelta := ASP_INIT_DELTA;
      Alpha    := LastCompletedScore - AspDelta;
      Beta     := LastCompletedScore + AspDelta;
    end
    else
    begin
      AspDelta := ASP_MAX_DELTA + 1;   // sentinel: any retry falls through to full
      Alpha    := -30000;
      Beta     :=  30000;
    end;
    AspirationRetries := 0;
    AspirationDone    := False;

    while not AspirationDone do
    begin
      // OriginalAlpha and WindowBeta are the bounds at the START of this
      // attempt. The root PVS loop below mutates Alpha when a move
      // raises it (necessary for PVS); fail-low detection must compare
      // against the PRE-mutation Alpha to be correct. WindowBeta is
      // captured for symmetry / clarity; Beta itself is not mutated by
      // the loop but we still read WindowBeta for the fail-high test.
      OriginalAlpha    := Alpha;
      WindowBeta       := Beta;
      PartialBestIdx   := BestIdx;
      PartialBestScore := -30000;
      PartialMoveCount := 0;

      for i := 0 to MoveCount - 1 do
      begin
        OldState := State;
        DoMakeMove(Moves[i]);

        // =================================================================
        // Root PVS: first move full window, rest null-window then
        // re-search if they beat Alpha unexpectedly. Unchanged from v0995.
        // =================================================================
        if IsInCheck(1 - State.SideToMove) then
        begin
          State := OldState;
          Continue;
        end;

        // v1.00-rc9: the root has no grandparent static eval to compare
        // against, so its child searches receive the IMPROVING_UNKNOWN
        // sentinel (-30001) as ParentStaticEval. The root's children (ply 1)
        // are therefore "not improving"; the first nodes that can be
        // improving are at ply 2, which correctly need a real eval two plies
        // up (i.e. at ply 0, the root) — but since the root loop here does
        // not compute a root StaticEval, we start the improving chain one
        // ply later. This is the conservative, standard root treatment.
        if i = 0 then
            Score := -Search(CurrentDepth - 1, -Beta, -Alpha, CurrentDepth - 1, RootPrev, RootExcluded, -30001)
        else
        begin
          Score := -Search(CurrentDepth - 1, -Alpha - 1, -Alpha, CurrentDepth - 1, RootPrev, RootExcluded, -30001);
          if (Score > Alpha) and (Score < Beta) and not AbortSearch then
            Score := -Search(CurrentDepth - 1, -Beta, -Alpha, CurrentDepth - 1, RootPrev, RootExcluded, -30001);
        end;
        State := OldState;

        if AbortSearch then
        begin
          // =============================================================
          // Search aborted mid-depth. Same three-case partial recovery as
          // v0995, with `asp_retries N` annotated into log lines so the
          // diagnostic record makes it clear whether the abort fell in
          // an aspiration retry or the first attempt.
          // =============================================================
          CurrentTime := GetTickCount64;
          TimeElapsed := CurrentTime - StartTime;

          if (PartialMoveCount > 0) and
             (PartialBestScore >= LastCompletedScore - PARTIAL_FALLBACK_MARGIN) then
          begin
            // Case (a): partial is trustworthy, accept it.
            BestIdx         := PartialBestIdx;
            BestScore       := PartialBestScore;
            BestMoveAtDepth := MoveToStr(Moves[BestIdx]);
            Result          := BestMoveAtDepth;

            InfoLine := 'info depth ' + IntToStr(CurrentDepth) +
                        ' seldepth ' + IntToStr(SelDepth) +
                        ' ' + ScoreToUci(BestScore) +
                        ' time '      + IntToStr(TimeElapsed) +
                        ' nodes '     + IntToStr(SearchNodes) +
                        ' hashfull ' + IntToStr(HashFull) +
                        ' pv '        + GetPVLine(Moves[BestIdx], CurrentDepth) +
                        ' best_move ' + BestMoveAtDepth;
            WriteLn(InfoLine);
            Flush(Output);
            BufferedLog(InfoLine + ' [partial: ' + IntToStr(PartialMoveCount) +
                '/' + IntToStr(MoveCount) + ' root moves; asp_retries ' +
                IntToStr(AspirationRetries) + ']');

            templog := templog + ('Depth ' + IntToStr(CurrentDepth) +
              ' aborted after ' + IntToStr(PartialMoveCount) +
              ' moves (asp_retries ' + IntToStr(AspirationRetries) +
              '). Using partial best: ' + BestMoveAtDepth +
              ' score ' + IntToStr(BestScore)) + #10;
          end
          else if PartialMoveCount > 0 then
          begin
            // Case (b): partial best dropped too far below last completed.
            InfoLine := 'info depth ' + IntToStr(CurrentDepth) +
                        ' time '  + IntToStr(TimeElapsed) +
                        ' nodes ' + IntToStr(SearchNodes) +
                        ' string partial result ' +
                        MoveToStr(Moves[PartialBestIdx]) + ' cp ' +
                        IntToStr(PartialBestScore) +
                        ' rejected (below depth ' + IntToStr(CurrentDepth - 1) +
                        ' score ' + IntToStr(LastCompletedScore) +
                        ' by more than ' + IntToStr(PARTIAL_FALLBACK_MARGIN) +
                        '); keeping depth ' + IntToStr(CurrentDepth - 1) +
                        ' result ' + BestMoveAtDepth;
            WriteLn(InfoLine);
            Flush(Output);
            BufferedLog(InfoLine);

            templog := templog + ('Depth ' + IntToStr(CurrentDepth) +
              ' aborted (asp_retries ' + IntToStr(AspirationRetries) +
              '); partial best ' + MoveToStr(Moves[PartialBestIdx]) +
              ' score ' + IntToStr(PartialBestScore) +
              ' rejected vs last completed score ' +
              IntToStr(LastCompletedScore) + '. Keeping ' +
              BestMoveAtDepth) + #10;
          end
          else
          begin
            // Case (c): no root move completed at this depth.
            InfoLine := 'info depth ' + IntToStr(CurrentDepth) +
                        ' time '  + IntToStr(TimeElapsed) +
                        ' nodes ' + IntToStr(SearchNodes) +
                        ' string aborted before any root move completed; ' +
                        'keeping depth ' + IntToStr(CurrentDepth - 1) +
                        ' result ' + BestMoveAtDepth;
            WriteLn(InfoLine);
            Flush(Output);
            BufferedLog(InfoLine);

            templog := templog + ('Depth ' + IntToStr(CurrentDepth) +
              ' aborted before any move completed (asp_retries ' +
              IntToStr(AspirationRetries) + '). Keeping depth ' +
              IntToStr(CurrentDepth - 1) + ' result: ' + BestMoveAtDepth) + #10;
          end;
          Break;  // out of for-i
        end;

        // Move fully evaluated
        Inc(PartialMoveCount);
        if Score > PartialBestScore then
        begin
          PartialBestScore := Score;
          PartialBestIdx   := i;
        end;
        if Score > Alpha then Alpha := Score;
        if Alpha >= Beta  then Break;  // fail-high at root; aspiration handles it
      end;

      if AbortSearch then Break;  // out of while-aspiration; outer Break handles for-CurrentDepth

      // =================================================================
      // v0996 aspiration verdict. Compare PartialBestScore to the
      // PRE-mutation bounds (OriginalAlpha, WindowBeta) captured at the
      // top of this attempt. Widen asymmetrically and retry, or fall
      // through to a full window once AspDelta exceeds ASP_MAX_DELTA.
      // =================================================================
      if PartialBestScore >= WindowBeta then
      begin
        // Fail-high. The true score is at least WindowBeta but possibly
        // much larger. Widen the upper bound only — leave Alpha at
        // OriginalAlpha so the re-search does not have to redo the
        // already-confirmed lower half of the window.
        Inc(AspirationRetries);
        AspDelta := AspDelta * 2;
        if AspDelta > ASP_MAX_DELTA then
        begin
          Alpha := -30000;
          Beta  :=  30000;
        end
        else
        begin
          Alpha := OriginalAlpha;                    // restore pre-mutation Alpha
          Beta  := LastCompletedScore + AspDelta;    // widen Beta
        end;
        Continue;
      end;

      if PartialBestScore <= OriginalAlpha then
      begin
        // Fail-low. No root move improved OriginalAlpha. Widen the
        // lower bound only; preserve the upper bound.
        Inc(AspirationRetries);
        AspDelta := AspDelta * 2;
        if AspDelta > ASP_MAX_DELTA then
        begin
          Alpha := -30000;
          Beta  :=  30000;
        end
        else
        begin
          Alpha := LastCompletedScore - AspDelta;    // widen Alpha
          Beta  := WindowBeta;                       // preserve upper bound
        end;
        Continue;
      end;

      // In-window: accept this attempt's result.
      AspirationDone := True;
    end;  // while not AspirationDone

    if AbortSearch then Break;

    // Depth completed cleanly — commit partial accumulators
    BestIdx            := PartialBestIdx;
    BestScore          := PartialBestScore;
    LastBestIdx        := BestIdx;
    LastCompletedScore := BestScore;
    BestMoveAtDepth    := MoveToStr(Moves[BestIdx]);
    Result             := BestMoveAtDepth;

    CurrentTime      := GetTickCount64;
    TimeForThisDepth := CurrentTime - DepthStartTime;
    TimeElapsed      := CurrentTime - StartTime;

    InfoLine := 'info depth ' + IntToStr(CurrentDepth) +
                ' seldepth ' + IntToStr(SelDepth) +
                ' ' + ScoreToUci(BestScore) +
                ' time '      + IntToStr(TimeElapsed) +
                ' nodes '     + IntToStr(SearchNodes) +
                ' hashfull ' + IntToStr(HashFull) +
                ' pv '        + GetPVLine(Moves[BestIdx], CurrentDepth) +
                ' best_move ' + BestMoveAtDepth;
    WriteLn(InfoLine);
    Flush(Output);
    if AspirationRetries > 0 then
      BufferedLog(InfoLine + ' [asp_retries ' + IntToStr(AspirationRetries) + ']')
    else
      BufferedLog(InfoLine);

    templog := templog + ('Depth ' + IntToStr(CurrentDepth) +
      ' completed in ' + IntToStr(TimeForThisDepth) + 'ms. Score: ' +
      IntToStr(BestScore) + ' Nodes: ' + IntToStr(SearchNodes) +
      ' asp_retries ' + IntToStr(AspirationRetries) +
      ' best_move ' + BestMoveAtDepth) + #10;

    if CurrentDepth >= MaxDepth then Break;

    // =====================================================================
    // v1.00-rc3g: score-gated stability stop + panic extension.
    // Still TWO tuning knobs (STABLE_ITERS_FOR_EASE, STABLE_EASE_PCT);
    // the two score margins are fixed constants, and the panic factor
    // reuses EXCEED_CEILING_FACTOR_PCT so it needs no new clock headroom.
    //
    // After each completed depth, decide whether to start the next one:
    //   1. StableIters counts consecutive completed depths that returned
    //      the SAME best move AND whose score did not fall by more than
    //      SCORE_STABLE_MARGIN cp. A repeated move with a collapsing
    //      score is NOT easy (the refutation is coming into view).
    //   2. If the score fell by more than SCORE_PANIC_DROP cp vs the
    //      previous completed depth, PanicMode extends the budget to
    //      allocation * EXCEED_CEILING_FACTOR_PCT / 100 (= the existing
    //      mid-search abort ceiling, so the ceiling becomes the stop for
    //      panicked moves; the go-handler CeilingCapAlloc clamp already
    //      guarantees this fits the remaining clock).
    //   3. Otherwise: effective budget = full allocation, shrunk to
    //      STABLE_EASE_PCT percent once StableIters reaches
    //      STABLE_ITERS_FOR_EASE (stop sooner on genuinely easy moves).
    //   4. If TimeElapsed has reached the effective budget, stop and
    //      play; otherwise search one more depth.
    //
    // No predictor, no soft/hard split, no phase. If a started depth runs
    // long, the mid-search abort (ExceedCeilingAbortMs) stops it and the
    // partial-depth recovery above keeps the last completed depth, so
    // starting an over-long depth is safe.
    //
    // Active only under real time management. Fixed-depth / 'go infinite'
    // searches (AllocatedTimeMs <= 0 or >= TM_UNLIMITED_MS) fall through to
    // the next depth, bounded by MaxDepth and the mid-search abort.
    // =====================================================================
    if (AllocatedTimeMs > 0) and (AllocatedTimeMs < TM_UNLIMITED_MS) then
    begin
      if PrevBestMoveStr = '' then
      begin
        StableIters := 0;                      // first scored depth: seed only
        PanicMode   := False;
      end
      else
      begin
        // Stability: same move AND score not falling beyond the margin.
        if (BestMoveAtDepth = PrevBestMoveStr) and
           (BestScore >= PrevScore - SCORE_STABLE_MARGIN) then
          Inc(StableIters)
        else
          StableIters := 0;

        // Panic: score fell hard vs the previous completed depth.
        // Latched for the rest of this move once it fires — a partial
        // recovery at the next depth must not silently un-panic.
        if BestScore < PrevScore - SCORE_PANIC_DROP then
          PanicMode := True;
      end;
      PrevBestMoveStr := BestMoveAtDepth;
      PrevScore       := BestScore;

      // v1.01rc3: graded ease. Budget scales continuously with the length
      // of the stability streak: 0 stable -> 100%, 67%, 50%, 40%, 33%.
      EffBudget := (QWord(AllocatedTimeMs) * 2) div (2 + StableIters);


      if TimeElapsed >= EffBudget then
      begin
        templog := templog + ('v1.00-rc3g TM stop at depth ' +
          IntToStr(CurrentDepth) + ': elapsed ' + IntToStr(TimeElapsed) +
          'ms >= budget ' + IntToStr(EffBudget) + 'ms (alloc ' +
          IntToStr(AllocatedTimeMs) + ', stable ' + IntToStr(StableIters) +
          ', ease_div ' + IntToStr(1 + StableIters) +
          ', panic ' + BoolToStr(PanicMode, True) + ').') + #10;
        Break;
      end;
    end;
  end;

  BufferedLog(templog);
  Flushlog;

  if (AllocatedTimeMs > 0) and (AllocatedTimeMs < TM_UNLIMITED_MS) then //for calculate average time move
    begin
      Inc(TMSumAllocMs, QWord(AllocatedTimeMs));
      Inc(TMSumUsedMs, GetTickCount64 - StartTime);
    end;

  Result := BestMoveAtDepth;
end;



// Parse and apply a move from UCI format (e.g., "e2e4", "e7e8q")
procedure ApplyUCIMove(MoveStr: string);
var
  FR, FC, TR, TC: integer;
  M: TMove;
  Promo: TPiece;
begin
  if Length(MoveStr) < 4 then Exit;
  FC := Ord(MoveStr[1]) - Ord('a');
  FR := Ord('8') - Ord(MoveStr[2]);
  TC := Ord(MoveStr[3]) - Ord('a');
  TR := Ord('8') - Ord(MoveStr[4]);

  Promo := EMPTY;
  if Length(MoveStr) >= 5 then
  begin
    case MoveStr[5] of
      'q', 'Q': Promo := wQ;
      'r', 'R': Promo := wR;
      'b', 'B': Promo := wB;
      'n', 'N': Promo := wN;
    end;
    if State.SideToMove = 1 then Promo := TPiece(Ord(Promo) + 6); // Convert to black piece enum
  end;

  M.FromR := FR; M.FromC := FC; M.ToR := TR; M.ToC := TC; M.Promotion := Promo;
  M.MoveType := MT_NORMAL;

  // Detect special moves to correctly set MoveType
  if (State.Board[FR, FC] = wK) and (Abs(FC - TC) = 2) then
  begin
    if TC = 6 then M.MoveType := MT_CASTLE_WK
    else if TC = 2 then M.MoveType := MT_CASTLE_WQ;
  end
  else if (State.Board[FR, FC] = bK) and (Abs(FC - TC) = 2) then
  begin
    if TC = 6 then M.MoveType := MT_CASTLE_BK
    else if TC = 2 then M.MoveType := MT_CASTLE_BQ;
  end
  else if ((State.Board[FR, FC] = wP) or (State.Board[FR, FC] = bP)) and (FC <> TC) and (State.Board[TR, TC] = EMPTY) then
  begin
    M.MoveType := MT_EN_PASSANT; // Pawn diagonal move to empty square
  end;

  DoMakeMove(M);
  // Note: GamePly and GameHistory are updated inside DoMakeMove
end;


function GetParamValue(SL: TStringList; Key: string; Default: integer): integer;
var
  Idx: integer;
begin
  Idx := SL.IndexOf(Key);
  if (Idx <> -1) and (Idx + 1 < SL.Count) then
  begin
    try Result := StrToInt(SL[Idx + 1]); except Result := Default; end;
  end
  else Result := Default;
end;


procedure ParseFEN(const FEN: string);
{**Sets up the board state from a FEN string.**
FEN strings describe a specific chess position (piece placement, side to move,
castling rights, en passant square, etc.). This is essential for the GUI to
set up custom positions or resume saved games.}      //Test:  8/2P5/8/8/3r4/8/2K5/k7 w - - 9 6    Saavedra_position, white to play and promote to rook
var
  Parts: array[0..5] of string;
  PartCount, i, r, c, val: integer;
  Ch: char;
  TempStr: string;
begin
  // Split FEN string by spaces into parts
  PartCount := 0;
  TempStr := Trim(FEN);
  for i := 0 to 5 do Parts[i] := '';
  while (TempStr <> '') and (PartCount <= 5) do
  begin
    if Pos(' ', TempStr) > 0 then
    begin
      Parts[PartCount] := Copy(TempStr, 1, Pos(' ', TempStr) - 1);
      Delete(TempStr, 1, Pos(' ', TempStr));
      TempStr := TrimLeft(TempStr);
      Inc(PartCount);
    end
    else
    begin
      Parts[PartCount] := TempStr;
      TempStr := '';
    end;
  end;

  // 1. Piece placement (Part 0)
  for r := 0 to 7 do for c := 0 to 7 do State.Board[r, c] := EMPTY;
  r := 0; c := 0;
  for i := 1 to Length(Parts[0]) do
  begin
    Ch := Parts[0,i];
    if Ch = '/' then begin r := r + 1; c := 0; end //prepare for new command next line
    else if Ch in ['1'..'8'] then c := c + (Ord(Ch) - Ord('0'))
    else begin
      // FenPieces = 'PNBRQKpnbrqk' maps directly to TPiece enum + 1
      val:=Pos(Ch, FenPieces);
      if val>0 then
      begin
        State.Board[r, c] := TPiece(val);
        if State.Board[r, c] = wK then begin State.WhiteKingR := r; State.WhiteKingC := c; end; //log where kings are
        if State.Board[r, c] = bK then begin State.BlackKingR := r; State.BlackKingC := c; end;
        Inc(c);
      end;
    end;
  end;

  // 2. Side to move (Part 1)
  if PartCount >= 1 then
  begin
    if Parts[1] = 'w' then State.SideToMove := 0
    else State.SideToMove := 1;
  end else State.SideToMove := 0;

  // 3. Castling rights (Part 2)
  State.CastleMask := 0;
  if PartCount >= 2 then
  begin
    if Pos('K', Parts[2]) > 0 then State.CastleMask := State.CastleMask or CM_WK;
    if Pos('Q', Parts[2]) > 0 then State.CastleMask := State.CastleMask or CM_WQ;
    if Pos('k', Parts[2]) > 0 then State.CastleMask := State.CastleMask or CM_BK;
    if Pos('q', Parts[2]) > 0 then State.CastleMask := State.CastleMask or CM_BQ;
  end;

  // 4. En passant square (Part 3)
  State.EPR := -1; State.EPC := -1;
  if (PartCount >= 3) and (Length(Parts[3]) >= 2) and (Parts[3][1] in ['a'..'h']) then
  begin
    State.EPC := Ord(Parts[3][1]) - Ord('a');
    State.EPR := Ord('8') - Ord(Parts[3][2]);
  end;

  // 5. Half-move clock & Full-move number (Parts 4 & 5)
  if PartCount >= 4 then State.HalfMoveClock := StrToIntDef(Parts[4], 0)
  else State.HalfMoveClock := 0;
  // v1.00-rc3: full-move number from FEN field 6 (Parts[5]). Standard FEN
  // numbers moves from 1; default to 1 when the field is absent (e.g. a
  // truncated FEN or 'position startpos').
  if PartCount >= 5 then State.FullMoveNumber := StrToIntDef(Parts[5], 1)
  else State.FullMoveNumber := 1;
  if State.FullMoveNumber < 1 then State.FullMoveNumber := 1;

  // Recompute hash and reset history for repetition detection
  State.Hash := ComputeHash;
  State.GamePly := 0;
  GameHistory[0] := State.Hash;
  FillChar(Killers, SizeOf(Killers), 0);
  FillChar(History, SizeOf(History), 0);

  RebuildBitboardsFromBoard; // v0967: derive bitboards from the FEN-parsed mailbox
  // v1.00-rc8: pawn key from scratch, AFTER the bitboards are rebuilt
  // (ComputePawnHash reads State.Pieces[wP]/[bP]).
  State.PawnHash := ComputePawnHash;
end;


procedure DisplayBoardSimple;
{**Simple ASCII board - guaranteed to work everywhere.**}
var
  r, c: integer;
  Piece: TPiece;
  PieceChar: char;
begin
  WriteLn;
  WriteLn('  +---+---+---+---+---+---+---+---+');

  for r := 0 to 7 do
  begin
    Write(8 - r, ' ');

    for c := 0 to 7 do
    begin
      Piece := State.Board[r, c];

      case Piece of
            wK: PieceChar := 'K';
            wQ: PieceChar := 'Q';
            wR: PieceChar := 'R';
            wB: PieceChar := 'B';
            wN: PieceChar := 'N';
            wP: PieceChar := 'P';
            bK: PieceChar := 'k';
            bQ: PieceChar := 'q';
            bR: PieceChar := 'r';
            bB: PieceChar := 'b';
            bN: PieceChar := 'n';
            bP: PieceChar := 'p';
         EMPTY: PieceChar := '.';
         else   PieceChar := '?';
       end;
      Write('| ', PieceChar, ' ');
    end;
    WriteLn('|');
    WriteLn('  +---+---+---+---+---+---+---+---+');
  end;

  Write('    ');
  for c := 0 to 7 do
    Write(Chr(Ord('a') + c), '   ');

  // Position info
  if State.SideToMove = 0 then
    WriteLn('White to move')
  else
    WriteLn('Black to move');

  //WriteLn('FEN: ', GetFEN);  // You'll need to implement GetFEN
  WriteLn;
end;


procedure RunBench(BenchDepth: integer);
{**Runs the engine through a fixed set of positions at a fixed depth and
reports the total node count and nodes-per-second. Used to verify that a
code change did not unintentionally alter search behaviour: identical
source + identical bench parameters must produce an identical total node
count. The bench total node count is therefore a "fingerprint" of the
build's search behaviour and is the standard regression check between
revisions for engines that use SPRT-style testing.

Bench is deterministic: TT, killers, and history are cleared before each
position; ShuffleMoves is made repeatable by resetting RandSeed; and the
opening book is disabled so book hits do not skip the search.

The set of positions below is deliberately diverse — opening, middlegame
(quiet and tactical), endgame (pawn, rook, queen) — so the bench total
reflects search behaviour across the whole game rather than only one
phase.}
const
  BENCH_FENS: array[0..15] of string = (
    // Standard test positions covering opening, middlegame, endgame
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',           // 1. Starting position
    'r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1', // 2. Kiwipete (tactical middlegame)
    '8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1',                            // 3. Sharp R+P endgame (Roycroft)
    'r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1',     // 4. Tactical with castling
    'rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8',            // 5. Promotion tension
    'r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10', // 6. Quiet symmetric middlegame
    'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3',    // 7. Italian opening
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2',        // 8. Sicilian with en passant
    '8/8/8/8/4k3/8/4P3/4K3 w - - 0 1',                                      // 9. K+P vs K endgame
    '1K6/1P6/8/8/8/8/r7/2k4R w - - 0 1',                                    // 10. Lucena position
    '6k1/5ppp/8/8/8/8/5PPP/6K1 w - - 0 1',                                  // 11. Pawn endgame symmetric
    '2r3k1/p4ppp/1p2p3/8/2P1Q3/1P4P1/P4P1P/4R1K1 w - - 0 1',                // 12. Q+R middlegame
    'r1bq1rk1/ppp2ppp/2np1n2/2b1p3/2B1P3/2PP1N2/PP1N1PPP/R1BQ1RK1 w - - 0 8', // 13. Closed quiet
    'r1bqk2r/pp1nbppp/2p1pn2/3p4/2PP4/2N1PN2/PP3PPP/R1BQKB1R w KQkq - 0 7', // 14. Queens gambit declined
    '8/8/8/4k3/8/4K3/4P3/8 w - - 0 1',                                      // 15. K+P opposition endgame
    'r2q1rk1/pp2ppbp/2n2np1/2pp4/3P1B2/2PBPN2/PP1N1PPP/R2Q1RK1 b - - 0 9'   // 16. King's Indian Attack
  );
var
  i: integer;
  TotalNodes: int64;
  StartTime: QWord;
  ElapsedMs: int64;
  NodesPerSec: int64;
  BestMove: string;
  SavedSeed: cardinal;
  SavedState: TGameState;
begin
  // Snapshot global state we will modify, so the engine can resume the
  // previous game/position normally after bench completes.
  SavedSeed  := RandSeed;
  SavedState := State;

  WriteLn('Running bench: depth ', BenchDepth, ', ',
          Length(BENCH_FENS), ' positions');
  Flush(Output);

  TotalNodes := 0;
  StartTime  := GetTickCount64;

  for i := 0 to High(BENCH_FENS) do
  begin
    // Per-position isolation: clear TT, killers, and history so node counts
    // depend only on the position being searched, not on residue from
    // previous searches.
    InitState;
    ParseFEN(BENCH_FENS[i]);
    ClearTT;
    ClearPawnTT;  // v1.00-rc8: per-position isolation for the pawn cache too,
                  // so bench node counts stay deterministic across positions.
    FillChar(Killers, SizeOf(Killers), 0);
    FillChar(History, SizeOf(History), 0);

    // Reset RandSeed before each position so ShuffleMoves at the root
    // produces the same root-move order on every run. Without this,
    // bench would be non-deterministic and useless as a regression check.
    RandSeed := 12345;

    // Disable opening book for bench: a book hit would bypass the search
    // entirely, so the position would contribute 0 to the node total.
    BookCount  := 0;
    BookLoaded := True;  // prevent any (re)load attempt

    // Disable the node limit and the abort flag from any previous search;
    // bench uses pure depth-limited search with no time pressure.
    NodeLimit       := 0;
    SearchNodes     := 0;
    NodeCheckCount  := 0;
    AbortSearch     := False;
    ExceedCeilingAbortMs := 0;
    SearchStartTime := GetTickCount64;

    // Generous AllocatedTimeMs (well within int32 even after *85). The
    // depth limit is the real stopping condition; time is effectively
    // disabled.
    BestMove := GetBestMove(MaxInt div 100, BenchDepth);

    TotalNodes := TotalNodes + SearchNodes;

    WriteLn('Position ', i+1:3, '/', Length(BENCH_FENS),
            '  bestmove ', BestMove,
            '  nodes ', SearchNodes);
    Flush(Output);
  end;

  ElapsedMs := Int64(GetTickCount64 - StartTime);
  if ElapsedMs > 0 then
    NodesPerSec := (TotalNodes * 1000) div ElapsedMs
  else
    NodesPerSec := 0;

  WriteLn('===========================');
  WriteLn('Time (ms)    : ', ElapsedMs);
  WriteLn('Nodes total  : ', TotalNodes);
  WriteLn('Nodes/second : ', NodesPerSec);
  WriteLn('===========================');
  Flush(Output);

  // Restore previous state and RNG seed so the engine can continue
  // serving its UCI session normally.
  State    := SavedState;
  RandSeed := SavedSeed;
end;



// Helper to apply a string of space-separated UCI moves
 procedure ApplyUCIMoves(const MoveString: string);
 var
   P: integer;
   MStr: string;
 begin
   P := 1;
   while P <= Length(MoveString) do
   begin
     while (P <= Length(MoveString)) and (MoveString[P] = ' ') do Inc(P);
     MStr := '';
     while (P <= Length(MoveString)) and (MoveString[P] <> ' ') do
     begin
       MStr := MStr + MoveString[P];
       Inc(P);
     end;
     if MStr <> '' then ApplyUCIMove(MStr);
   end;
 end;

{Writing a chess move generator is notoriously error-prone due to the complex rules of chess (castling rights, en passant, pins, check/double check, and stalemates).
Because the exact number of legal paths for various chess positions is known with absolute mathematical certainty, you can use perft to isolate exactly where your code is failing.
Here is the step-by-step debugging process:
1. Compare Totals Against Known Results
You run your engine on a specific position (like the starting position or a complex custom setup) to a certain depth and compare your total node count against established benchmarks.
    If your engine says Depth 5 has 4,865,620 nodes, but the correct answer is 4,865,609, you know you have a bug (you are either generating 11 illegal moves, or missing 11 legal ones).
2. Use the "Divide" Command to Isolate the Branch
Finding a needle in a haystack of 4 million moves is impossible. This is where the divide feature comes in. You run perft with the divide flag at the failing depth.
Your engine will output something like this:

e2e3: 17859
e2e4: 196291
g1f3: 178627
...
b1c3: 178522 (Expected: 178511) <-- BUG ISOLATED  }


function Perft(Depth: integer): Int64;
var
  Moves: TMoveList;
  MoveCount, i: integer;
  Saved: TGameState;
begin
  if Depth = 0 then Exit(1);
  GenerateLegalMoves(Moves, MoveCount);
  Result := 0;
  if Depth = 1 then Exit(MoveCount);  // small optimisation
  for i := 0 to MoveCount - 1 do
  begin
    Saved := State;
    DoMakeMove(Moves[i]);
    Result := Result + Perft(Depth - 1);
    State := Saved;
  end;
end;


function PerftDivide(Depth: integer): int64;
var
  Moves: TMoveList;
  MoveCount, i: integer;
  Saved: TGameState;
  Sub, Total: Int64;
begin
  GenerateLegalMoves(Moves, MoveCount);
  Total := 0;
  for i := 0 to MoveCount - 1 do
  begin
    Saved := State;
    DoMakeMove(Moves[i]);
    if Depth = 1 then Sub := 1
    else Sub := Perft(Depth - 1);
    State := Saved;
    WriteLn(MoveToStr(Moves[i]), ': ', Sub);
    Total := Total + Sub;
  end;
  WriteLn('Total: ', Total);
  result:=total;
end;


procedure PlayMode;
{**Simple interactive human-vs-engine loop, activated by the non-UCI command
"play". Reuses the existing engine primitives (InitState, GenerateLegalMoves,
DoMakeMove, MoveToStr, IsInCheck, GetBestMove, DisplayBoardSimple). In
human-vs-engine play the engine uses a fixed search depth chosen by the user;
in self-play (engine vs engine, for debugging) it uses a time budget per 40
moves instead. State is left in a clean starting position on exit so the
normal UCI protocol can resume afterwards.**}
var
  PlayDepth, HumanSide: integer;   // HumanSide: 0 = white, 1 = black; -1 = self-play (computer vs computer)
  MoveTimeMs: integer;             // per-move time budget in self-play (time per 40 moves / 40)
  UseBook: boolean;
  Line: string;
  HM: TMove;
  MoveNo: integer;

  function ReadLineTrimmed: string;
  begin
    ReadLn(Result);
    Result := Trim(Result);
    if Result <> '' then Log('>> PLAY RECV: ' + Result);
  end;

  // Find the legal move matching a UCI string (e.g. "e2e4", "e7e8q").
  // Returns True and fills M if found; the caller only ever plays legal moves.
  function FindLegalMove(const S: string; out M: TMove): boolean;
  var
    Moves: TMoveList;
    MoveCount, i: integer;
  begin
    Result := False;
    GenerateLegalMoves(Moves, MoveCount);
    for i := 0 to MoveCount - 1 do
      if LowerCase(MoveToStr(Moves[i])) = LowerCase(S) then
      begin
        M := Moves[i];
        Exit(True);
      end;
  end;

  // Report game state after a move: checkmate / stalemate / ongoing.
  // Returns True if the game has ended.
  function GameEnded: boolean;
  var
    Moves: TMoveList;
    MoveCount: integer;
  begin
    GenerateLegalMoves(Moves, MoveCount);
    Result := (MoveCount = 0);
    if Result then
    begin
      if IsInCheck(State.SideToMove) then
      begin
        if State.SideToMove = 0 then
          WriteLn('Checkmate - Black (engine/you) wins.')
        else
          WriteLn('Checkmate - White (engine/you) wins.');
      end
      else
        WriteLn('Stalemate - draw.');
    end;
  end;

  // Run the engine for one move and play it. Returns False if no move.
  // In self-play (HumanSide = -1) the time budget governs; otherwise the
  // depth limit governs and time is effectively unlimited.
  function EngineMove: boolean;
  var
    BestStr: string;
    M: TMove;
  begin
    Result := False;
    AbortSearch := False;
    if HumanSide = -1 then
      // Self-play: time budget per move governs; depth is left wide open.
      BestStr := GetBestMove(MoveTimeMs, 100)
    else
      // Human play: high allocated time is irrelevant; the depth limit governs.
      BestStr := GetBestMove(24 * 60 * 60 * 1000, PlayDepth);
    if (BestStr = '') or (BestStr = '0000') or (BestStr = '(none)') then Exit;
    if FindLegalMove(BestStr, M) then
    begin
      DoMakeMove(M);
      DisplayBoardSimple;
      WriteLn('Engine: ', BestStr);
      Result := True;
    end;
  end;

begin
  PlayDepth  := 6;   // sensible default, overridden below for human play
  MoveTimeMs := 250; // sensible default, overridden below for self-play

  // --- Ask which colour the human plays (or 's' for engine self-play) ---
  Write('You play black or white [b/w], s for self-play? or q to quit: ');
  Flush(Output);
  Line := LowerCase(ReadLineTrimmed);
  if Line = 'q' then Exit;
  if Line = 's' then HumanSide := -1
  else if Line = 'b' then HumanSide := 1
  else HumanSide := 0;

  if HumanSide = -1 then
  begin
    // --- Self-play: ask for the maximum time per 40 moves ---
    Write('Max time per 40 moves in seconds? or q to quit: ');
    Flush(Output);
    Line := ReadLineTrimmed;
    if LowerCase(Line) = 'q' then Exit;
    MoveTimeMs := StrToIntDef(Line, 0);
    if MoveTimeMs < 1 then MoveTimeMs := 1;
    // Convert total seconds for 40 moves into a per-move budget in ms.
    MoveTimeMs := (MoveTimeMs * 1000) div 40;
    if MoveTimeMs < 1 then MoveTimeMs := 1;
  end
  else
  begin
    // --- Human play: ask for search depth ---
    Write('Depth[1..20]? or q to quit: ');
    Flush(Output);
    Line := ReadLineTrimmed;
    if LowerCase(Line) = 'q' then Exit;
    PlayDepth := StrToIntDef(Line, 0);
    if PlayDepth < 1 then PlayDepth := 1;
    if PlayDepth > 20 then PlayDepth := 20;
  end;

  // --- Ask about the opening book ---
  Write('Openingbook [y/n]? default n, q to quit: ');
  Flush(Output);
  Line := LowerCase(ReadLineTrimmed);
  if Line = 'q' then Exit;
  UseBook := (Line = 'y');

  // --- Set up a fresh game ---
  InitState;
  ClearTT;
  ClearPawnTT;  // v1.00-rc8: keep the pawn cache in sync with the TT reset
  FillChar(Killers, SizeOf(Killers), 0);
  FillChar(History, SizeOf(History), 0);

  // Load / disable the opening book for this game.
  if UseBook then
  begin
    if not BookInitialized then
    begin
      WriteLn('info loading open book ......');
      LoadAllOpeningBooks;
      BookInitialized := True;
    end;
  end
  else
    BookCount := 0;   // engine search only

  DisplayBoardSimple;

  // --- Self-play mode: engine plays both sides (debugging) ---
  if HumanSide = -1 then
  begin
    WriteLn('Self-play mode. Engine vs engine. Press q<Enter> at any time... (move cap 500).');
    MoveNo := 0;
    while True do
    begin
      if GameEnded then Break;
      if MoveNo >= 500 then
      begin
        WriteLn('Move cap (500) reached - stopping self-play.');
        Break;
      end;
      if not EngineMove then begin WriteLn('No legal engine move.'); Break; end;
      Inc(MoveNo);
    end;
    InitState;
    WriteLn('Leaving play mode.');
    Flush(Output);
    Exit;
  end;

  // --- If the engine is White (human is Black), it moves first ---
  if HumanSide = 1 then
    if not EngineMove then begin WriteLn('No legal engine move.'); Exit; end;

  // --- Main play loop ---
  while True do
  begin
    if GameEnded then Break;

    // Human's turn
    Write('Your move or q to quit? ');
    Flush(Output);
    Line := ReadLineTrimmed;
    if LowerCase(Line) = 'q' then Break;

    // Parse and validate the human move.
    if not FindLegalMove(Line, HM) then
    begin
      WriteLn('Illegal or unrecognised move: ', Line,
              '  (use UCI form, e.g. e2e4, e7e8q). Try again.');
      Continue;
    end;

    DoMakeMove(HM);
    DisplayBoardSimple;

    if GameEnded then Break;

    // Engine's reply
    if not EngineMove then begin WriteLn('No legal engine move.'); Break; end;
  end;

  // Leave the engine in a clean state for subsequent UCI commands.
  InitState;
  WriteLn('Leaving play mode.');
  Flush(Output);
end;


procedure Help;
begin
  Writeln('None uci commands: display, help, play');
  writeln;
  Writeln('=== PakKnight UCI Commands Help ===');
  Writeln('uci           - Start UCI mode. Example: uci');
  Writeln('isready       - Check if engine is ready. Example: isready');
  Writeln('setoption     - Change engine settings. Example: setoption name ownbook value false');
  Writeln('ucinewgame    - Start a new game. Example: ucinewgame');
  Writeln('position      - Set board position. Example: position startpos moves e2e4 e7e5');
  Writeln('position (FEN)- Set board from FEN. Example: position fen rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1');
  Writeln('go            - Start search. Example: go depth 10');
  Writeln('go            - Search for fixed time. Example: go movetime 5000');
  Writeln('go            - Search fixed nodes. Example: go nodes 100000');
  Writeln('go perft 5    - Node count from this position for depth 5');
  Writeln('go perftauto  - Node count for several programmed positions at fixed depth 5. Reports any error');
  Writeln('stop          - Stop search and return best move. Example: stop');
  Writeln('quit          - Exit engine. Example: quit');
end;

//=========================================================


//texel tuning
{$IFDEF TUNER}
{$I pasknight_texel_tuner.pas}
{$ENDIF}

begin
  writeln('PasKnight UCI compatible chess engine ' + version +
    '. Log text file will be written at same location as executable. Waiting for uci commands. Type display for chess board. Type help for help. Type play for basic interface.');

  Randomize;// Initialize random with deterministic seed for Zobrist
  InitZobrist;
  InitAttackTables;  // v0967: build precomputed pawn/knight/king attack tables
  InitMagicTables;   // v1.00-rc6: build + verify the plain-magic slider tables
  InitPawnMasks;     // v0984: build precomputed pawn-structure file masks
  InitPawnHash;      // v1.00-rc8: allocate + clear the pawn hash table
  InitState;
  BookInitialized:=false;
  // v1.00-rc3 instrumentation: start the per-game phase accumulators clean.
//  StatsGameIndex := 1;
//  FillChar(PhaseTimeSum,  SizeOf(PhaseTimeSum),  0);
//  FillChar(PhaseMoveCnt,  SizeOf(PhaseMoveCnt),  0);
//  FillChar(PhaseDepthSum, SizeOf(PhaseDepthSum), 0);


  // v0997: allocate and clear the transposition table at default size.
  // The GUI may issue 'setoption name Hash value N' later, which calls
  // ResizeHash again with the requested size. Allocating at startup means
  // even a GUI that never sends setoption Hash gets a working TT.
  ResizeHash(HASH_DEFAULT_MB);
  AllocatedTimems := 20000; // Default 20 seconds if GUI sends no time
  SearchDepth := 10;
  display:=false;

  //texel tuning
  {$IFDEF TUNER}
  RunTexelTuner;
  Halt(0);
  {$ENDIF}

  try
    while True do
    begin
      ReadLn(InputLine);
      InputLine := Trim(InputLine);
      if InputLine <> '' then Log('>> RECV: ' + InputLine);

      if InputLine = 'uci' then
      begin
        WriteLn('id name PasKnight '+version);
        WriteLn('id author Han Kleijn (Country: NL)');
        WriteLn('option name Hash type spin default ' + IntToStr(HASH_DEFAULT_MB) +
                ' min ' + IntToStr(HASH_MIN_MB) + ' max ' + IntToStr(HASH_MAX_MB));
        WriteLn('option name depth type spin default 50 min 1 max 99');
        WriteLn('option name OwnBook type check default true');
        WriteLn('option name LogFile type check default false');
        // Advertise the custom opening book path option to the GUI
        WriteLn('option name BookFile type string default *.pgn');

        // Advertise non-default capabilities. UCI has no formal way to do
        // this, but most GUIs display info string lines, so curious users
        // (and developers debugging engine-GUI interactions) can see them.
        WriteLn('info string Supported go parameters: depth movetime nodes infinite wtime btime winc binc movestogo');
        WriteLn('info string Non-UCI commands: bench [depth]');

        WriteLn('uciok');
      end


      else if InputLine = 'isready' then
      begin
        // Load the opening book on the first isready call.
        // Arena waits for readyok, so it won't timeout here.
        if BookInitialized=false then
        begin
          writeln('info loading open book ......');
          LoadAllOpeningBooks;
          BookInitialized := True;
        end;
        WriteLn('readyok');
        Flush(Output);
      end

      else if Pos('setoption', InputLine) = 1 then
      begin
        ParamName := LowerCase(InputLine);
        if Pos('name ', ParamName) > 0 then
          Delete(ParamName, 1, Pos('name ', ParamName) + 4)
        else
          ParamName := '';
        ValPos := Pos(' value ', ParamName);

        if ValPos > 0 then
        begin
          ParamValue := Trim(Copy(ParamName, ValPos + 7, Length(ParamName)));
          ParamName := Trim(Copy(ParamName, 1, ValPos - 1));
        end
        else
        begin
          ParamValue := '';
          ParamName := lowercase(Trim(ParamName));
        end;
        if lowercase(ParamName) = 'ownbook' then
        begin
          if ParamValue = 'false' then
          begin
            BookLoaded := true;//set bookloaded:=true, book will not be loaded after this
            bookcount:=0;//if already loaded stop using it.
          end;
        end;
        if lowercase(ParamName) = 'logfile' then
        begin
          logfile:=(ParamValue = 'true');
          if logfile then
          begin
            logname := ChangeFileExt(ParamStr(0),
                           '_' + version +
                           '_pid' + IntToStr(GetProcessID) +
                           '_log.txt');
            if FileExists(logname) then DeleteFile(logname);
            Log('Engine Started '+version);
          end;
        end;
        if lowercase(ParamName) = 'bookfile' then
        begin
          if ParamValue <> '' then
          begin
            BookFileName := ParamValue;   // Store the custom path sent by Arena
            BookInitialized := false;     // Force re-loading with the new file path on next isready/go
          end;
        end;
        if lowercase(ParamName) = 'depth' then
        begin
          SearchDepth := max(1,min(20,StrToInt(ParamValue)));
        end;
        // v0997: runtime hash resize.
        // The GUI typically sends this once, between 'uci' and 'ucinewgame'.
        // ResizeHash silently clamps out-of-range values; StrToIntDef returns
        // HASH_DEFAULT_MB if ParamValue isn't parseable, so a malformed value
        // is benign rather than fatal.
        if lowercase(ParamName) = 'hash' then
        begin
          ResizeHash(StrToIntDef(ParamValue, HASH_DEFAULT_MB));
        end;
      end

      else if InputLine = 'ucinewgame' then
      begin
        InitState;
        TMSumAllocMs:=0;   // sum of AllocatedTimeMs over past moves this game
        TMSumUsedMs:= 0;   // sum of actually elapsed search time
        ClearTT; // Clear Transposition Table on new game
        ClearPawnTT; // v1.00-rc8: clear pawn hash table on new game too
        FillChar(Killers, SizeOf(Killers), 0); // Clear killer moves
        FillChar(History, SizeOf(History), 0);
        if display then DisplayBoardSimple;//display board in ascii for debugging
      end

      else if Pos('fen', Inputline) > 0 then
      begin
        bookcount:=0; //switch off opening book
        FenStartPos := Pos('fen', LowerCase(InputLine)) + 3;
        FENStr := Trim(Copy(InputLine, FenStartPos, Length(InputLine)));//example: position fen 6nr/5Ppk/8/7K/8/8/8/8 w - - 0 1

        MovesStr := '';
        MovePos := Pos('moves', LowerCase(FENStr));
        if MovePos > 0 then //example combined command:  fen rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1 moves e7e5 e2e3
        begin
          MovesStr := Copy(FENStr, MovePos + 5, Length(FENStr));
          FENStr := Trim(Copy(FENStr, 1, MovePos - 1));
        end;

        ParseFEN(FENStr);        // First: set up board from FEN

        if MovesStr <> '' then
          ApplyUCIMoves(MovesStr);  // Then: apply moves on that position  Example: position startpos moves a2a3 e7e5 b2b3

        if display then
           DisplayBoardSimple;//display board in ascii for debugging

      end
      else if Pos('position', Inputline) = 1 then
      begin
        if Pos('startpos', Inputline) > 0 then  //example: position startpos moves a2a3 e7e5 b2b3
        begin
          InitState;
          MovePos := Pos('moves', Inputline);
          if MovePos > 0 then
            ApplyUCIMoves(Copy(InputLine, MovePos + 5, Length(InputLine)));
        end
        else if Pos('fen', Inputline) > 0 then //example: position fen 6nr/5Ppk/8/7K/8/8/8/8 w - - 0 1
        begin
          FenStartPos := Pos('fen', LowerCase(InputLine)) + 3;
          FENStr := Trim(Copy(InputLine, FenStartPos, Length(InputLine)));

          MovePos := Pos('moves', LowerCase(FENStr));
          if MovePos > 0 then
          begin
            ApplyUCIMoves(Copy(FENStr, MovePos + 5, Length(FENStr)));
            FENStr := Trim(Copy(FENStr, 1, MovePos - 1));
          end;

          ParseFEN(FENStr);
        end;
        if display then DisplayBoardSimple;//display board in ascii for debugging
      end

      else if InputLine = 'stop' then
      begin
        AbortSearch := True;
        Log('Received stop command.');
      end

      else if Copy(InputLine, 1, 2) = 'go' then
      begin
        if BookInitialized=false then //should already be loaded after uci command
        begin
          LoadAllOpeningBooks;
          BookInitialized := True;
        end;
        SL := TStringList.Create;
        try
          SL.StrictDelimiter := True;
          SL.Delimiter := ' ';
          SL.DelimitedText := InputLine;
          AllocatedTimeMs := 0;
          // Default depth ceiling for time-controlled play. Time abort decides
          // when to stop, so the depth cap only matters as a safety bound.
          // Setting this to a high value means the 'depth' UCI option no
          // longer artificially caps normal play; that option now only takes
          // effect via an explicit 'go depth N' command from the GUI.
          // Without this, a GUI that sends 'setoption name depth value 6'
          // (which is the default value the engine advertises) would limit
          // the engine to depth 6 in every time-controlled game, costing
          // ~200 Elo of playing strength.
          HardDepthLimit := 50;
          NodeLimit        := 0;  // Reset; only the 'nodes' branch sets a non-zero limit
          if SL.IndexOf('infinite') <> -1 then
          begin
            HardDepthLimit := 50;

            // v1.00-rc3: no time management. TM_UNLIMITED_MS takes the no-TM
            // path in GetBestMove (both limits 0); the search runs to the
            // depth 50 ceiling or until a 'stop' command, which is checked
            // every ~10000 nodes regardless of time-management mode.
            AllocatedTimeMs := TM_UNLIMITED_MS;
            Log('Received go infinite. Searching until stop command or depth 50.');
          end
          else if SL.IndexOf('depth') <> -1 then
          begin
            HardDepthLimit := GetParamValue(SL, 'depth', 5);
            SearchDepth := HardDepthLimit;
            if HardDepthLimit < 1 then HardDepthLimit := 1;
            Log('Received go depth ' + IntToStr(HardDepthLimit));
          end
          else if SL.IndexOf('movetime') <> -1 then
          begin
            AllocatedTimeMs := GetParamValue(SL, 'movetime', 0);
            AllocatedTimeMs := AllocatedTimeMs - 50; // Safety margin
            if AllocatedTimeMs < 50 then AllocatedTimeMs := 50;
            HardDepthLimit := SearchDepth;
            Log('Received go movetime ' + IntToStr(AllocatedTimeMs));
          end

          // =====================================================================
          // go nodes N : search until at least N nodes have been visited, then
          // return bestmove. No wall-clock time limit applies. This is the
          // standard UCI mechanism for deterministic, machine-independent
          // testing — used by Cute Chess and others for noise-reduced SPRT.
          // The depth limit is set high so it does not gate the search before
          // the node target is reached.
          // =====================================================================
          else if SL.IndexOf('nodes') <> -1 then
          begin
            NodeLimit       := GetParamValue(SL, 'nodes', 0);
            AllocatedTimeMs := 2147483647;  // Effectively unlimited time
            HardDepthLimit  := 50;          // High depth ceiling; node limit decides
            Log('Received go nodes ' + IntToStr(NodeLimit));
          end
          else
          begin
            // Time control (e.g., go wtime 60000)
            WTime := GetParamValue(SL, 'wtime', 0);
            BTime := GetParamValue(SL, 'btime', 0);
            WInc  := GetParamValue(SL, 'winc', 0);
            BInc  := GetParamValue(SL, 'binc', 0);
            // v1.01: default 0 = 'movestogo NOT sent'. The presence of
            // movestogo is the GUI's signal of the time-control TYPE, so it
            // must not be faked with a default: present means a repeating
            // control (e.g. 40/15) where the value is the EXACT number of
            // moves the remaining time must last; absent means sudden death
            // (e.g. 12+8 or 5+0) where moves left must be estimated.
            // (Replaces the old default of 30, which made 12+8 games
            // permanently budget as if 30 moves always remained, leaving
            // large amounts of clock unspent at game end.)
            Movestogo := GetParamValue(SL, 'movestogo', 0);

            if State.SideToMove = 0 then begin MyTime := WTime; MyInc := WInc; end
            else begin MyTime := BTime; MyInc := BInc; end;

            if MyTime > 0 then
            begin
              // =============================================================
              // v1.01: base per-move allocation, branched on control type.
              //
              // Repeating control (movestogo sent):
              //   Divide the remaining time by movestogo plus a small buffer.
              //   The buffer guards the moves just before the control: a
              //   search that overshoots into the abort ceiling near
              //   movestogo 1..3 would otherwise eat the following moves'
              //   entire share. At movestogo <= 2 the buffer shrinks to +1
              //   so the last move before the refill still uses most of
              //   what remains (the clock refills right after it anyway).
              //
              // Sudden death (movestogo absent):
              //   Estimate moves remaining from the move number: start
              //   around 50-45, taper as the game progresses, floor at 16.
              //     move  1: divisor 50   move 30: divisor 32
              //     move 40: divisor 26   move 57+: divisor 16
              //   The taper is what lets the engine actually spend its
              //   banked time late in the game; a fixed divisor perpetually
              //   assumes the same number of moves remain and finishes the
              //   game with unspent clock. Values are fixed shape choices
              //   on wide plateaus, not tuning knobs.
              //
              // Both branches add 3/4 of the increment: spending less than
              // the full increment per move on average means the increment
              // portion of the clock can never be exhausted.
              //
              // The stability logic in GetBestMove sits on top of whatever
              // base figure this produces; this block only sets the nominal
              // AllocatedTimeMs. Safety clamps below are unchanged from
              // v1.00-rc3f and are phase- and type-independent.
              // =============================================================
              if Movestogo > 0 then
              begin
                // Repeating control (e.g. 40/15). movestogo is exact.
                if Movestogo <= 2 then
                  TimeDivisor := Movestogo + 1
                else
                  TimeDivisor := Movestogo + 2;
              end
              else
              begin  //time is increased like 12 min + 8 sec per move
                // Sudden death (e.g. 12+8, 5+0). Estimate moves left.
                // v1.01d: 40 - move/2, floor 12 (was 50 - move*3/5, floor
                // 16). Targets the typical ~40-55 move game instead of a
                // long one: unspent clock in a game that ends early is
                // worth zero, while long games are protected by the floor
                // and by the (now full) increment term.
                EstMovesLeft := 40 - (State.FullMoveNumber div 2);
                if EstMovesLeft < 12 then EstMovesLeft := 12;
                TimeDivisor := EstMovesLeft;
              end;
              // v1.01d: full increment (was 3/4). The base term drains the
              // initial bank; the increment is refunded every move, so
              // spending it fully is sustainable by construction, and the
              // max-clamp/reserve below still prevent flagging.
              AllocatedTimeMs := (MyTime div TimeDivisor) + MyInc;


              // v1.01b: utilization correction. The ease logic in
              // GetBestMove refunds most of the budget on stable moves, so
              // realized spend runs well below allocation. Scale the
              // allocation by the inverse of the measured utilization so
              // the INTENDED average spend is actually achieved. Bounds
              // 100..200% are safety rails, not knobs: never shrink below
              // the nominal slice, never more than double it (the clamps
              // below bound the absolute value regardless). Needs a few
              // moves of history before it activates; until then the
              // nominal allocation is used unchanged.
              if TMSumUsedMs > 1000 then   // >=1s of accumulated search time
                AllocatedTimeMs :=round(AllocatedTimeMs * min(max(TMSumAllocMs/TMSumUsedMs,1.0),4.0));//adapt to average usage with limits


              // ---- Limit 1: SAFETY CLAMP on the allocation (type-independent) --
              // Clamp the allocation between a minimum and a maximum. These are
              // safety bounds, NOT tuning knobs.
              //   MIN = ~10% of the nominal per-move slice (control-relative, so
              //         it does not over-clamp at fast controls like 40/10s),
              //         with a 5ms absolute floor for bullet speeds.
              //   MAX = remaining clock minus a reserve of max(100ms, 10% of
              //         the clock), so a move can never allocate more time than
              //         is safely available. At very low clocks (<=500ms) fall
              //         back to half the remaining time.
              MinAlloc := (MyTime div TimeDivisor) div 10;
              if MinAlloc < 5 then MinAlloc := 5;
              if AllocatedTimeMs < MinAlloc then AllocatedTimeMs := MinAlloc;

              if MyTime <= 500 then
                AllocatedTimeMs := MyTime div 2
              else if AllocatedTimeMs > MyTime - Max(100, MyTime div 10) then
                AllocatedTimeMs := MyTime - Max(100, MyTime div 10);

              // Cap the allocation so the downstream abort ceiling
              // (ExceedCeilingAbortMs = AllocatedTimeMs * EXCEED_CEILING_FACTOR_PCT/100)
              // can never exceed the remaining clock minus the reserve. MyTime is
              // valid here (freshly set from the 'go' command); GetBestMove sees
              // only AllocatedTimeMs, so the clamp must happen here.
              CeilingCapAlloc := ((MyTime - Max(100, MyTime div 10)) * 100)
                                 div EXCEED_CEILING_FACTOR_PCT;
              if AllocatedTimeMs > CeilingCapAlloc then
                AllocatedTimeMs := CeilingCapAlloc;

              Log('Time control detected. Allocated ' + IntToStr(AllocatedTimeMs) +
                'ms for this move (move ' + IntToStr(State.FullMoveNumber) +
                ', divisor ' + IntToStr(TimeDivisor) +
                ', movestogo ' + IntToStr(Movestogo) + ')');
            end
            else
            begin
              perftdepth := GetParamValue(SL, 'perft', 0);
              if perftdepth<>0 then
              begin
                //ParseFEN('r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1');
                writeln('For new ucinewgame');
                writeln('For go perft 5: 4865609');
                writeln('For "Kiwipete: : position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -');
                writeln('For go perft 4: 4085603, for go perft 5: 193690690');
                writeln('For "Position 3": position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1');
                writeln('For go perft 5: 674624, for go perft 6: 11030083');
                PerftDivide(perftdepth);
                continue;
              end
              else
              begin
               if pos('perftauto',inputLine)>0 then
               begin
                 perror:=0;
                 writeln('position fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1');//https://www.chessprogramming.org/Perft_Results
                 ParseFEN('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1');
                 if PerftDivide(5)<>4865609 then begin writeln('Error!'); perror:=1;end;

                 if not AttackSelfTest then begin writeln('Error verifiy bitboards !'); perror:=7; end;


                 writeln('position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -     (position 2/Kiwipete)');
                 ParseFEN('r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -');
                 if PerftDivide(5)<>193690690 then begin writeln('Error!'); perror:=2;end;

                 if not AttackSelfTest then begin writeln('Error verifiy bitboards !'); perror:=8; end;


                 writeln('position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1      (position 3/Kiwipete)');
                 ParseFEN('8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1 ');
                 if PerftDivide(5)<>674624 then begin writeln('Error!'); perror:=3;end;

                 writeln('position fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1     (position 4)');
                 ParseFEN('r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1');
                 if PerftDivide(5)<>15833292 then begin writeln('Error!'); perror:=4;end;

                 writeln('position fen rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8     (position 5)');
                 ParseFEN('rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8');
                 if PerftDivide(5)<>89941194 then begin writeln('Error!'); perror:=5;end;



                 //writeln('position fen r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10     (position 6)');
                 //ParseFEN('r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10');
                 //if PerftDivide(5)<>164075551 then begin writeln('Error!'); perror:=6;end;

                 if perror>0 then writeln('Error at ',perror) else writeln('All test successful, no problem detected.');

                 continue;
               end;
              end;
            end;
          end;
        finally
          SL.Free;
        end;

        AbortSearch := False;
        BestMoveStr := GetBestMove(AllocatedTimeMs, HardDepthLimit);

        WriteLn('bestmove ', BestMoveStr);
        Log('<< SEND: bestmove ' + BestMoveStr);

        if display then
           DisplayBoardSimple;//display board in ascii for debugging
      end
      else if InputLine = 'display' then
      begin
        Display:=true;
        DisplayBoardSimple;//display board in ascii for debugging
      end
      else if Pos('bench', InputLine) = 1 then
      begin
        // bench           -> run at default depth 8
        // bench 10        -> run at depth 10
        try
          if Trim(Copy(InputLine, 6, MaxInt)) <> '' then
            RunBench(StrToInt(Trim(Copy(InputLine, 6, MaxInt))))
          else
            RunBench(8);
        except
          RunBench(8);  // fall back to default if argument unparseable
        end;
      end

      else if InputLine = 'quit' then
      begin
        Break;
      end
      else if InputLine = 'help' then
        help
      else if InputLine = 'play' then
              PlayMode
      else
      begin
        writeln('info Unknown command: ',InputLine);
        log('Unknown command: '+InputLine);
      end;

      Flush(Output);
    end;
  except
    on E: Exception do
    begin
      Log('FATAL EXCEPTION: ' + E.ClassName + ' - ' + E.Message);
      WriteLn('bestmove 0000'); // Try to send something to avoid GUI hang
    end;
  end;
end.
