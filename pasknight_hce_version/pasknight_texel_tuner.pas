{Copyright (C) 2026 by Han Kleijn, www.hnsky.org
 email: han.k.. at...hnsky.org

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.   }


{ Suitable for this training set: https://github.com/codemaniac/lichess-big3
 5r2/p4pk1/2pb4/8/1p2rN2/4p3/PPPB4/3K4 w - - 0 3 [0.0]
 1r4k1/6p1/7p/4p3/R7/3rPNP1/1b3P1P/5RK1 b - - 1 1 [1.0]
 Full 6-field FEN, then the white-POV result in square brackets ([1.0]/[0.5]/[0.0]) instead of the quoted c9 "1-0"; tag.
 Usage: pasknight lichess-big3-resolved.book

 Or the much smaller Zurichess set
 https://github.com/KierenP/ChessTrainingSets

================================================================================
PASKNIGHT TEXEL TUNER - DATA FORMAT AND METHOD (see texel_tuner.inc)
================================================================================

1. TRAINING DATA
----------------
One labelled position per line. Two formats are auto-detected per line:

  a) zurichess quiet-labeled.epd (725k positions, from CCRL engine games):
     <fen 4 fields> c9 "1/2-1/2";
     rnb1kbnr/pp1pppp1/7p/2q5/5P2/N1P1P3/P2P2PP/R1BQKBNR w KQkq - c9 "1/2-1/2";

  b) lichess-big3-resolved.book (7.15M positions, from lichess human games):
     <fen 6 fields> [0.5]
     5r2/p4pk1/2pb4/8/1p2rN2/4p3/PPPB4/3K4 w - - 0 3 [0.0]

The result tag is the FINAL GAME OUTCOME from White's point of view,
mapped to 1.0 (White won), 0.5 (draw), 0.0 (Black won). The positions are
quiet (no pending tactics), so the static evaluation alone is meaningful
and no quiescence search is needed during tuning.

2. THE MODEL: EXACT LINEAR RECONSTRUCTION OF Evaluate
-----------------------------------------------------
The tunable weights are the 12 PSTs (6 piece types x MG/EG). Material is
loaded as parameters but FROZEN: search consumers (SEE, MVV-LVA, futility
and delta margins) assume the stock piece-value scale, and material and
PST means are gauge-redundant anyway (a constant added to a whole PST is
a material change in disguise).

At load time each position is stored as:
  - a sparse coefficient list: net count (white minus black, black rows
    mirrored) of each PST cell, exactly as PASS 1 of Evaluate reads them;
  - MG and EG residuals: everything Evaluate adds that is NOT tunable
    (mobility, pawn structure, passed pawns, king shield, rook files,
    bishop pair, tempo), obtained as TunerLastMG/EG minus the tunable
    part. Because the eval is linear in the tunable weights, these
    residuals are weight-independent and thus captured exactly once;
  - the game phase (0..24) captured at the same point.

The model prediction rebuilds the engine's white-POV score:
  E = Trunc((MG * phase + EG * (24 - phase)) / 24)
where MG/EG = residual + sum(weight * count). Trunc matches Pascal's
integer 'div' bit-for-bit. Every position is verified at load: if the
model does not reproduce Evaluate exactly, the run aborts (a mismatch
means an integration hook is wrong, usually the TunerLast capture point).

3. LOSS: FROM CENTIPAWNS TO WIN PROBABILITY
-------------------------------------------
The score E is mapped to an expected game result with a sigmoid:
  P = 1 / (1 + 10 ^ (-K * E / 400))
K is NOT a universal constant. It is fitted per engine and per dataset
by a golden-section search minimizing the training MSE with the weights
still at their stock values, then FROZEN for the whole run. Fitting K
first removes the degree of freedom by which the tuner could otherwise
lower the loss by inflating all evaluations instead of ranking positions
better. (PasKnight: K = 1.51 on zurichess, about 1.47 on big3.)

The loss is the mean squared error against the game results:
  Loss = mean( (P - Result)^2 )

4. OPTIMIZATION
---------------
Full-batch gradient descent with Adam (lr default 0.25). Refinements:

  - VALIDATION SPLIT: every 10th position is held out and never touches
    the gradient. The best-validation weight snapshot is what ships.
    The learning rate is halved after 15 stagnant epochs; the run stops
    after 40. Training loss falling while validation stalls is fitted
    noise, and this setup discards it automatically.

  - L2 ANCHOR (lambda, default 2e-7): the gradient gets an extra pull
    lambda * (w - PeSTO_anchor). Rare-occupancy cells (rank-7/8 pawns,
    advanced-king MG cells) have noise-dominated gradients, yet Adam's
    per-coordinate RMS normalization gives them full-size steps; without
    the anchor they random-walk tens of centipawns. Dense cells are
    unaffected because their data gradient dwarfs the pull.

  - GRADIENT PROJECTION: the per-table mean of the gradient (over live
    cells) is subtracted before Adam, deleting the material/PST gauge
    direction at the source so PST means stay put and Adam's moment
    statistics stay clean. A once-per-epoch re-center mops up sub-cp
    leakage from Adam's per-coordinate scaling.

The result is written as a drop-in Pascal const section (tuned_pst.pas),
to be pasted into the engine, rebuilt WITHOUT -dTUNER, and verified by
SPRT against the stock build.
================================================================================
}

//
//
// ===========================================================================
// texel_tuner.inc — self-contained Texel tuner for PasKnight
//                   (PST shape + v1.00-rc10 passed-pawn rank tables
//                    + v1.00-rc11 mobility tables by move count)
//
// This is an INCLUDE file, not a unit. A true Pascal unit cannot see the
// program's globals (State, Evaluate, ParseFEN, the PST tables) without
// restructuring the whole engine into units, so for a single-file .lpr the
// idiomatic separation is {$I texel_tuner.inc}. The engine source needs only
// the four small hooks listed below; everything else lives in this file.
//
// ---------------------------------------------------------------------------
// INTEGRATION (4 hooks in the engine .lpr)
// ---------------------------------------------------------------------------
// 1. Near the top of the file:
//        {$DEFINE TUNER}        // comment out for a normal build
//    and make sure the uses clause contains SysUtils and Math.
//
// 2. The 12 PST tables, PieceValueMG/EG, the two passed-pawn tables
//    (v1.00-rc10) and the eight mobility tables (v1.00-rc11) must be VARs
//    in a tuner build:
//        {$IFDEF TUNER}var{$ELSE}const{$ENDIF}
//          PieceValueMG: array[TPiece] of integer = ( ... );
//          ...
//          KingPST_EG: array[0..7, 0..7] of integer = ( ... );
//          PassedPawnMG: array[0..7] of integer = ( ... );
//          PassedPawnEG: array[0..7] of integer = ( ... );
//          KnightMobMG/EG: array[0..8] of integer = ( ... );
//          BishopMobMG/EG: array[0..13] of integer = ( ... );
//          RookMobMG/EG: array[0..14] of integer = ( ... );
//          QueenMobMG/EG: array[0..27] of integer = ( ... );
//          PawnThreatMinorMG/EG, PawnThreatRookMG/EG, PawnThreatQueenMG/EG,
//          MinorThreatRookMG/EG, MinorThreatQueenMG/EG, HangingMG/EG:
//            integer = ...;   // v1.00-rc13 threat scalars, TYPED constants
//          ConnectedMG: array[0..7] of integer = ( ... );  // v1.00-rc15
//          ConnectedEG: array[0..7] of integer = ( ... );  // v1.00-rc15
//          OutpostMG: array[0..7] of integer = ( ... );     // v1.00-rc15 step 2
//          OutpostEG: array[0..7] of integer = ( ... );     // v1.00-rc15 step 2
//          BishopOutpostMG, BishopOutpostEG: integer = ...; // v1.00-rc15 step 2
//          BadBishopPawnMG, BadBishopPawnEG: integer = ...; // v1.00-rc17 step 3
//          RookOn7thMG/EG, RookBehindOwnPassedMG/EG,
//          RookBehindEnemyPassedMG/EG: integer = ...;       // v1.00-rc18 step 4
//          KingPassedEnemyEG, KingPassedOwnEG: integer = ...;// v1.00-rc19 step 5 (EG-only)
//          ShieldMG: array[0..3] of integer = ( ... );       // v1.00-rc20 step 6 (MG-only)
//          DoubledPawnMG/EG, IsolatedPawnMG/EG,
//          BackwardPawnMG/EG: integer = ...;                 // v1.00-rc21 sweep
//        {$IFDEF TUNER}const{$ENDIF}
//
// 3. Just above Evaluate, and inside Evaluate immediately BEFORE the blend
//        Score := (ScoreMG*gamePhase + ScoreEG*(MaxPhase-gamePhase)) div MaxPhase;
//    add:
//        {$IFDEF TUNER}
//        var TunerLastMG, TunerLastEG, TunerLastPhase: integer;
//        {$ENDIF}
//        ...
//        {$IFDEF TUNER}
//        TunerLastMG := ScoreMG; TunerLastEG := ScoreEG;
//        TunerLastPhase := gamePhase;
//        {$ENDIF}
//
// 4. Include this file after Evaluate/ParseFEN are defined (e.g. just before
//    the main "begin"), and call the tuner at the top of the main block:
//        {$IFDEF TUNER}{$I texel_tuner.inc}{$ENDIF}
//        ...
//        begin
//          ... engine init (InitZobrist, InitAttackTables, InitMagicTables,
//              InitPawnMasks, InitPawnHash, InitState, ResizeHash) ...
//        {$IFDEF TUNER}
//          RunTexelTuner;   // never enters the UCI loop
//          Halt(0);
//        {$ENDIF}
//
// ---------------------------------------------------------------------------
// USAGE
// ---------------------------------------------------------------------------
//   Build:  fpc -dTUNER -O3 pasknight.lpr
//   Run:    pasknight <dataset> [maxEpochs=1000] [lambda=2e-7] [lr=0.25]
//           e.g.  pasknight quiet-labeled.epd 1000 2e-7 0.25
//           e.g.  pasknight lichess-big3-resolved.book 1000 2e-7 0.25
//   Data:   both common labelled formats are auto-detected per line:
//             <fen 4 fields> c9 "1/2-1/2";   (zurichess quiet-labeled, 725k)
//             <fen 6 fields> [0.5]           (lichess-big3-resolved, 7.15M)
//           Result tags are white-POV in both.
//   Output: tuned_pst.pas (drop-in const tables, BEST validation snapshot)
//
// ---------------------------------------------------------------------------
// WHAT CHANGED vs the rc8a..rc8d in-file tuner
// ---------------------------------------------------------------------------
// (a) VALIDATION SPLIT + EARLY STOPPING (convergence control).
//     Every 10th position (i mod 10 = 0) is held out; the gradient never
//     sees it. Training loss must fall monotonically; validation loss is
//     the honest signal. The run keeps a snapshot of the best-validation
//     parameters, halves the learning rate after TUNE_LR_PATIENCE stagnant
//     epochs, and stops after TUNE_STOP_PATIENCE stagnant epochs. The
//     OUTPUT is always the best snapshot, never the final wandering state,
//     so "too many epochs" can no longer hurt — only waste time.
//
// (b) L2 REGULARIZATION TOWARD THE PeSTO ANCHOR.
//     grad += lambda * (w - anchor), anchor snapshotted at startup.
//     Rare-occupancy cells (rank-7/8 pawns, advanced-king MG cells) have
//     near-zero, noise-dominated data gradients, yet Adam's per-coordinate
//     RMS normalisation hands them full-size steps — over hundreds of
//     epochs they random-walk tens of centipawns (observed: -60..-80 cp on
//     rank-7 pawn cells in the unregularized 280-epoch run). The anchor
//     pull is negligible where data is dense and dominant where it is not.
//     Sweep lambda over {3e-8, 2e-7, 1e-6}: pick the largest value that
//     still lets well-observed central cells move 10-30 cp.
//
// (c) GRADIENT PROJECTION replaces post-step parameter re-centering.
//     Material and PST are gauge-redundant (a constant added to a PST is a
//     material change). The old fix re-centered the PARAMETERS after each
//     Adam step, but Adam's m/v then keep accumulating the mean-direction
//     gradient that the projection keeps deleting — inflating vhat and
//     shrinking the effective step for the shape signal. Now the per-table
//     mean (over live cells) is subtracted from the GRADIENT before Adam
//     ever sees it: Adam's statistics stay clean and the PST means never
//     receive an update in the first place. TuneRecenterPSTs is kept as a
//     cheap once-per-epoch safety net; with projected gradients it corrects
//     only the sub-cp leakage caused by Adam's per-coordinate scaling.
//
// (d) LOCALE-SAFE FLOAT PARSING for the lambda/lr CLI arguments (a Dutch
//     Windows locale uses ',' as decimal separator; StrToFloat on '2e-7'
//     would otherwise fail or misparse).
//
// (e) v1.00-rc10: PASSED-PAWN RANK TABLES are now tunable. Sixteen extra
//     parameters (PassedPawnMG[0..7] then PassedPawnEG[0..7]) are appended
//     to the vector after material. The coefficient of PassedPawn??[rr] is
//     the NET COUNT (white minus black) of files whose most-advanced pawn
//     is an unblocked passer at relative rank rr — extracted by replicating
//     PASS 3's per-file front-pawn logic bit-for-bit (same masks, same
//     BsrQWord/BsfQWord front-pawn selection), so the exact-residual
//     verification still holds: the index (relative rank) is weight-
//     independent, hence the term is linear in the table entries.
//     Entries 0 and 7 of each table are unreachable and FROZEN (like pawn
//     PST ranks 1/8). The gradient projection and re-centering deliberately
//     do NOT touch these parameters: unlike PST-vs-material there is no
//     gauge redundancy (the bonus applies only to passers, not to every
//     pawn), so their means are genuine signal. The L2 anchor pull applies
//     as to any other live parameter, which also matters here: the high
//     relative ranks are sparse-occupancy cells of exactly the kind the
//     anchor was introduced for. The output file gains the two tuned
//     tables as drop-in const declarations.
//
// (f) v1.00-rc11: MOBILITY TABLES are now tunable. 132 extra parameters
//     (66 MG then 66 EG; within a phase: KnightMob[0..8], BishopMob[0..13],
//     RookMob[0..14], QueenMob[0..27]) are appended after the passed-pawn
//     block. The coefficient of a cell is the NET COUNT (white minus black)
//     of pieces of that type whose mobility count (popcount of attacks AND
//     NOT own occupancy) equals the index — extracted by replicating PASS 5
//     bit-for-bit (same KnightAttacks / SliderAttacks / State.Occupied
//     masks), so the exact-residual verification covers it: the index is
//     weight-independent, hence the term is linear in the table entries.
//     GAUGE: unlike the passed-pawn tables, EVERY piece of a type lands in
//     exactly ONE cell of its mobility table, so a constant added to a
//     whole table is a per-piece material change in disguise — the same
//     redundancy as material-vs-PST. The eight mobility sub-tables are
//     therefore gradient-projected and re-centered per sub-table exactly
//     like the PSTs. Cells with ZERO occurrences in the training set
//     (e.g. QueenMob[27]) are frozen at their anchor after dataset load
//     (TuneFreezeUnseenMobility), so the projection cannot drift cells the
//     data never constrains. The engine tables ship seeded linearly from
//     the v0981 weights, so the anchor IS the old linear mobility and the
//     L2 pull reads as "stay linear unless the data says otherwise".
//
// (g) v1.00-rc13: THREAT SCALARS are now tunable. 12 extra parameters
//     (6 MG then 6 EG: PawnThreatMinor, PawnThreatRook, PawnThreatQueen,
//     MinorThreatRook, MinorThreatQueen, Hanging) are appended after the
//     mobility block. The coefficient of a scalar is the NET COUNT (white
//     minus black) of enemy pieces threatened in that family — extracted
//     by replicating PASS 5's attack-map accumulation and PASS 7's
//     intersections bit-for-bit (same pawn-attack shifts, same
//     KnightAttacks / SliderAttacks / KingAttacks sets), so the exact-
//     residual verification covers it: the counts are weight-independent,
//     hence the terms are linear in the scalars. Like the passed-pawn
//     tables (and unlike PSTs/mobility) the threat scalars are NOT
//     gauge-redundant with material — they reach only threatened pieces,
//     not every piece — so they are NOT gradient-projected and NOT
//     re-centered; their means are genuine signal. No static freezes:
//     every family occurs abundantly in any realistic dataset, and the
//     L2 anchor covers residual sparsity. The rc12 king-safety term
//     (SafetyTable) stays NON-tunable: it is a nonlinear table lookup on
//     summed attack units and does not fit the linear model; it remains
//     in the frozen residual.
//
// (h) v1.00-rc15 step 1: CONNECTED-PAWN RANK TABLES are now tunable. 16
//     extra parameters (ConnectedMG[0..7] then ConnectedEG[0..7], indexed
//     by relative rank) are appended after the threat block. The engine
//     term is  (2 + phalanx - opposed) * Connected??[relRank]  per pawn
//     that is supported or phalanx (PASS 3, inside the pawn hash). The
//     multiplier m in {1,2,3} is a weight-independent integer, so the
//     coefficient of cell rr is the NET SUM of m over connected pawns at
//     relative rank rr (white +m, black -m) — extracted by replicating
//     the PASS 3 flags bit-for-bit (same PawnAttacks defender test, same
//     AdjacentFileMask/RankMask phalanx test, same RanksAtOrAbove/Below
//     opposed test), so the exact-residual verification covers it.
//     Entries 0 and 7 are unreachable and statically FROZEN (policy of
//     the passed-pawn tables). Like the passed-pawn tables and threat
//     scalars — and unlike PSTs/mobility — the connected tables are NOT
//     gauge-redundant with material (the bonus reaches only connected
//     pawns, not every pawn), so they are NOT gradient-projected and NOT
//     re-centered; their means are genuine signal. Sparse high-rank
//     cells (relRank 5-6) lean on the L2 anchor, and the freeze-unseen
//     mechanism (generalised from the rc11 mobility version into
//     TuneFreezeUnseenRange) additionally freezes any cell with zero
//     training coverage at its seed.
//
// (i) v1.00-rc15 step 2: KNIGHT-OUTPOST RANK TABLE + BISHOP-OUTPOST
//     SCALAR are now tunable. 18 extra parameters: OutpostMG[0..7] then
//     OutpostEG[0..7] (knight outpost by relative rank, TUNE_OUT_BASE),
//     then BishopOutpostMG, BishopOutpostEG (TUNE_BOUT_BASE). The engine
//     term is a 0/1 flag times the table entry (knight) or scalar
//     (bishop) under the SAME three PASS 5 conditions — relative rank
//     4-6, own-pawn-defended (wPawnAtk/bPawnAtk bit test), permanent
//     hole (WhiteOutpostMask/BlackOutpostMask AND enemy pawns = 0).
//     Coefficients are extracted by replaying those conditions bit-for-
//     bit on the SAME pawn-attack maps the threat extraction already
//     builds, so the exact-residual verification covers them. The
//     knight-outpost coefficient of cell rr is the net (white minus
//     black) count of outpost knights at relative rank rr; the bishop
//     coefficient is the net count of outpost bishops. Only relative
//     ranks 3,4,5 can fire (condition (a)), so knight cells 0,1,2,6,7
//     are statically FROZEN — same policy as the connected/passed
//     ranks 0/7 — and the freeze-unseen range mops up any of 3,4,5 the
//     data happens not to exercise. Like the passed/connected/threat
//     terms and unlike PSTs/mobility, outposts are NOT gauge-redundant
//     with material (they reach only outpost minors, not every minor),
//     so they are NOT gradient-projected and NOT re-centered.
//
// (j) v1.00-rc17 step 3: BAD-BISHOP SCALARS are now tunable. 2 extra
//     parameters BadBishopPawnMG, BadBishopPawnEG (TUNE_BADB_BASE). The
//     engine term is  -badPawns * BadBishopPawn??  per bishop, where
//     badPawns counts own pawns that are simultaneously on the bishop's
//     colour complex, on a central file (c..f), and BLOCKED (a piece
//     occupies the square directly ahead). The coefficient is therefore
//     the NEGATED net count of such pawns summed over the side's bishops
//     (white subtracts, so its coefficient is negative; black adds).
//     Extraction replays the exact single-shot bitboard the engine uses
//     -- colour AND CentralFilesBB AND shifted-occupancy -- so the
//     exact-residual verification covers it. It is a per-pawn count times
//     a scalar, hence linear; not gauge-redundant with material (it
//     reaches only blocked central complex pawns, a small subset), so
//     NOT projected and NOT re-centered. The pair is always potentially
//     live and needs no static freeze; the freeze-unseen range catches
//     the (unlikely) case of a dataset with zero qualifying pawns.
//
// (k) v1.00-rc18 step 4: ROOK-TERM SCALARS are now tunable. 6 extra
//     parameters at TUNE_ROOK_BASE, three MG/EG pairs: rook on relative
//     rank 7, rook behind own passed pawn, rook behind enemy passed
//     pawn. Each is a per-rook flag times a scalar, so linear; the
//     coefficient is the net (white minus black) count of rooks meeting
//     each condition. Extraction reuses the SAME passed-pawn bitboards
//     (rebuilt identically here from the pawn placement) and the SAME
//     rank/king/file tests as PASS 4, so the exact-residual verification
//     covers them. Not gauge-redundant with material (each reaches only
//     rooks in a specific relation), so NOT projected and NOT
//     re-centered; freeze-unseen range catches any pair the dataset
//     leaves at zero coverage.
//
// (l) v1.00-rc19 step 5: KING / PASSED-PAWN DISTANCE, EG-ONLY. 2 extra
//     parameters at TUNE_KPD_BASE: KingPassedEnemyEG, KingPassedOwnEG.
//     Both are EG-only (TuneParamIsEG returns true for both), so they
//     contribute ONLY to the endgame side of the tapered model and have
//     no MG coefficient. The engine term, per passer, is
//       +enemy * dist(enemyKing, front) - own * dist(ownKing, front)
//     with signs mirrored for the other colour; dist is Chebyshev
//     (king-move) 0..7 and front is the passer's advance square. The
//     coefficient is therefore DISTANCE-WEIGHTED, not a plain 0/1 count:
//     coeff(KingPassedEnemyEG) = sum over white passers of
//     dist(bK,front) minus sum over black passers of dist(wK,front);
//     coeff(KingPassedOwnEG) = -(sum over white passers of dist(wK,front))
//     + sum over black passers of dist(bK,front). Extraction rebuilds
//     the SAME wPassed/bPassed sets and the SAME Chebyshev/front-square
//     arithmetic as the engine, so the exact-residual check covers it.
//     Not gauge-redundant with anything (reaches only kings-vs-passers),
//     so NOT projected and NOT re-centered; freeze-unseen catches the
//     no-passer-in-dataset degenerate case. NB: because these are
//     EG-only, their coefficient is placed on the EG accumulator inside
//     the extractor exactly as the engine places it on ScoreEG.
//
// (m) v1.00-rc20 step 6: PAWN-SHIELD RAMP, MG-ONLY. 4 extra parameters
//     at TUNE_SHIELD_BASE: ShieldMG[0..3] indexed by the nearest shield
//     pawn's advancement on each king-front file (0 best .. 3 missing).
//     ALL MG-only (TuneParamIsEG returns false for the block), matching
//     the engine adding the shield sum to ScoreMG only. Per king-front
//     file the nearest shield pawn falls in exactly one bucket, so the
//     coefficient of ShieldMG[k] is the net (white minus black) number
//     of shield files in bucket k. Extraction replays the SAME scope
//     gate (king on its own first two ranks), the SAME three-file window
//     with off-board files skipped, and the SAME nearest-first bucketing
//     via State.Board, so the exact-residual check covers it. It is a
//     king-dependent term, computed OUTSIDE the pawn hash (end-of-eval
//     block), so nothing about the pawn-hash cache changes. Not gauge-
//     redundant with anything (reaches only shield files of a king on
//     its home ranks), so NOT projected and NOT re-centered; freeze-
//     unseen range covers any bucket the dataset never exercises (e.g.
//     bucket 2 is rare).
//
// (n) v1.00-rc21 step 7: SAFE MOBILITY. Not a new parameter block — the
//     mobility TABLES are unchanged in shape and location — but the
//     mobility COUNT (the table index) now excludes squares attacked by
//     enemy pawns: mobNotOwn = (NOT own occ) AND (NOT enemy pawn atk),
//     mirroring the engine's PASS 5. This shifts which cell each piece
//     lands in; the extractor applies the identical mask (using
//     thWPawnAtk/thBPawnAtk, built before the mobility loops), so the
//     exact-residual check still holds. Old tuned mobility values are now
//     stale seeds — expected, the joint retune re-fits them. Because safe
//     mobility caps the reachable counts lower, more high-index mobility
//     cells become zero-coverage and are frozen by the freeze-unseen
//     range (observed 8 -> 18 on a random set); this is correct.
//
// (o) v1.00-rc21 registration sweep: DOUBLED / ISOLATED / BACKWARD pawn
//     penalties are now tunable. 6 parameters at TUNE_DIB_BASE (doubled
//     MG/EG, isolated MG/EG, backward MG/EG), stored as POSITIVE penalty
//     magnitudes exactly as the former PASS 3 literals. These are PASS 3
//     pawn-hash terms, so extraction lives in the pawn-structure file loop
//     alongside the passed-pawn extraction, replaying the SAME per-file
//     tests: doubled coefficient = -(wCount-1) + (bCount-1) net per file
//     (penalty, so white subtracts), isolated = -1/+1 per isolated front
//     set, backward = -1/+1 per backward rear pawn. Since these are
//     penalties SUBTRACTED for white, the white coefficient is NEGATIVE.
//     Exact-residual covers them. Pawn-structure terms are not gauge-
//     redundant with material (they reach only defective pawns), so NOT
//     projected/re-centered; freeze-unseen covers any that a dataset
//     never exercises.
// measured against the real Evaluate, Trunc reproduces Pascal div, per-
// position verification aborts on mismatch), material is frozen, pawn PST
// ranks 1/8 are frozen, K is fitted once on the stock weights.
// ===========================================================================

type
  TCoeff = record
    idx:  integer;   // flat index into the parameter vector
    cnt:  double;    // RAW net count (white minus black), NOT phase-scaled
    isEG: boolean;   // true => feeds ScoreEG; false => ScoreMG
  end;
  TTunePos = record
    nc:         integer;            // number of non-zero coefficients
    coeffs:     array of TCoeff;    // sparse coefficient list
    mgResidual: double;             // frozen non-tunable ScoreMG part (white POV, pre-blend)
    egResidual: double;             // frozen non-tunable ScoreEG part (white POV, pre-blend)
    phase:      integer;            // gamePhase in 0..MaxPhase
    result:     double;             // game result, white POV: 1.0 / 0.5 / 0.0
  end;

const
  // Parameter-vector layout: 12 blocks of 64 PST cells, then 10 material,
  // then (v1.00-rc10) 16 passed-pawn entries: PassedPawnMG[0..7] followed
  // by PassedPawnEG[0..7], indexed by relative rank of the passer, then
  // (v1.00-rc11) 132 mobility entries: 66 MG followed by 66 EG; within a
  // phase block: KnightMob[0..8], BishopMob[0..13], RookMob[0..14],
  // QueenMob[0..27], indexed by mobility count, then (v1.00-rc13) 12
  // threat scalars: 6 MG followed by 6 EG; within a phase block:
  // PawnThreatMinor, PawnThreatRook, PawnThreatQueen, MinorThreatRook,
  // MinorThreatQueen, Hanging, then (v1.00-rc15) 16 connected-pawn
  // entries: ConnectedMG[0..7] followed by ConnectedEG[0..7], indexed by
  // relative rank of the connected pawn.
  TUNE_PST_COUNT    = 12;
  TUNE_PST_CELLS    = 64;
  TUNE_MAT_COUNT    = 10;                                // 5 pieces x (MG,EG)
  TUNE_PASSED_COUNT = 16;                                // 8 MG + 8 EG by relative rank
  TUNE_MOB_PHASE    = 66;                                // 9 + 14 + 15 + 28 per phase
  TUNE_MOB_COUNT    = 2 * TUNE_MOB_PHASE;                // 132 (MG block then EG block)
  TUNE_THREAT_PHASE = 6;                                 // v1.00-rc13: scalars per phase
  TUNE_THREAT_COUNT = 2 * TUNE_THREAT_PHASE;             // 12 (6 MG then 6 EG)
  TUNE_CONN_COUNT   = 16;                                // v1.00-rc15: 8 MG + 8 EG by relative rank
  TUNE_OUT_COUNT    = 16;                                // v1.00-rc15 step 2: 8 MG + 8 EG knight outpost by rel rank
  TUNE_BOUT_COUNT   = 2;                                 // v1.00-rc15 step 2: bishop outpost MG + EG scalar
  TUNE_BADB_COUNT   = 2;                                 // v1.00-rc17 step 3: bad-bishop MG + EG scalar
  TUNE_ROOK_COUNT   = 6;                                 // v1.00-rc18 step 4: 3 rook MG/EG pairs
  TUNE_KPD_COUNT    = 2;                                 // v1.00-rc19 step 5: king/passer dist, EG-only (enemy, own)
  TUNE_SHIELD_COUNT = 4;                                 // v1.00-rc20 step 6: pawn-shield ramp, MG-only
  TUNE_DIB_COUNT    = 6;                                 // v1.00-rc21 sweep: doubled/isolated/backward MG+EG
  TUNE_NPARAMS      = TUNE_PST_COUNT * TUNE_PST_CELLS
                      + TUNE_MAT_COUNT + TUNE_PASSED_COUNT
                      + TUNE_MOB_COUNT + TUNE_THREAT_COUNT
                      + TUNE_CONN_COUNT
                      + TUNE_OUT_COUNT + TUNE_BOUT_COUNT
                      + TUNE_BADB_COUNT
                      + TUNE_ROOK_COUNT
                      + TUNE_KPD_COUNT
                      + TUNE_SHIELD_COUNT
                      + TUNE_DIB_COUNT; // 992
  TUNE_MAT_BASE     = TUNE_PST_COUNT * TUNE_PST_CELLS;   // 768
  TUNE_PASSED_BASE  = TUNE_MAT_BASE + TUNE_MAT_COUNT;    // 778
  TUNE_MOB_BASE     = TUNE_PASSED_BASE + TUNE_PASSED_COUNT; // 794
  TUNE_THREAT_BASE  = TUNE_MOB_BASE + TUNE_MOB_COUNT;    // 926 (v1.00-rc13)
  TUNE_CONN_BASE    = TUNE_THREAT_BASE + TUNE_THREAT_COUNT; // 938 (v1.00-rc15)
  TUNE_OUT_BASE     = TUNE_CONN_BASE + TUNE_CONN_COUNT;  // 954 (v1.00-rc15 step 2, knight outpost)
  TUNE_BOUT_BASE    = TUNE_OUT_BASE + TUNE_OUT_COUNT;    // 970 (v1.00-rc15 step 2, bishop outpost)
  TUNE_BADB_BASE    = TUNE_BOUT_BASE + TUNE_BOUT_COUNT;  // 972 (v1.00-rc17 step 3, bad bishop)
  // v1.00-rc18 step 4: 6 rook scalars, ordered
  //   +0 RookOn7thMG            +1 RookOn7thEG
  //   +2 RookBehindOwnPassedMG  +3 RookBehindOwnPassedEG
  //   +4 RookBehindEnemyPassedMG+5 RookBehindEnemyPassedEG
  TUNE_ROOK_BASE    = TUNE_BADB_BASE + TUNE_BADB_COUNT;  // 974 (v1.00-rc18 step 4, rook terms)
  // v1.00-rc19 step 5: 2 king/passer-distance scalars, BOTH EG-only:
  //   +0 KingPassedEnemyEG   +1 KingPassedOwnEG
  TUNE_KPD_BASE     = TUNE_ROOK_BASE + TUNE_ROOK_COUNT;  // 980 (v1.00-rc19 step 5)
  // v1.00-rc20 step 6: 4 pawn-shield entries, ALL MG-only, indexed by
  // shield-pawn advancement (0 best .. 3 missing).
  TUNE_SHIELD_BASE  = TUNE_KPD_BASE + TUNE_KPD_COUNT;    // 982 (v1.00-rc20 step 6)
  // v1.00-rc21 sweep: 6 pawn-structure penalty scalars, ordered
  //   +0 DoubledMG  +1 DoubledEG  +2 IsolatedMG  +3 IsolatedEG
  //   +4 BackwardMG +5 BackwardEG   (all POSITIVE penalty magnitudes)
  TUNE_DIB_BASE     = TUNE_SHIELD_BASE + TUNE_SHIELD_COUNT; // 986 (v1.00-rc21 sweep)
  // Order of the 6 scalars WITHIN a threat phase block (EG = MG + 6):
  //   0 PawnThreatMinor  1 PawnThreatRook  2 PawnThreatQueen
  //   3 MinorThreatRook  4 MinorThreatQueen  5 Hanging
  // Per-piece offsets WITHIN a phase block (EG cell = MG cell + TUNE_MOB_PHASE)
  TUNE_MOB_N_OFF    = 0;                                 // knight [0..8]
  TUNE_MOB_B_OFF    = 9;                                 // bishop [0..13]
  TUNE_MOB_R_OFF    = 23;                                // rook   [0..14]
  TUNE_MOB_Q_OFF    = 38;                                // queen  [0..27]
  // The 8 mobility sub-tables (N/B/R/Q MG, then N/B/R/Q EG) as offsets
  // relative to TUNE_MOB_BASE — used by the gradient projection and the
  // re-centering, which treat each sub-table like a PST (see note (f)).
  TUNE_MOB_SEGS     = 8;
  TuneMobSegOff: array[0..TUNE_MOB_SEGS-1] of integer =
    (0, 9, 23, 38, 66, 75, 89, 104);
  TuneMobSegLen: array[0..TUNE_MOB_SEGS-1] of integer =
    (9, 14, 15, 28, 9, 14, 15, 28);

  // --- Convergence control -------------------------------------------------
  TUNE_VAL_EVERY     = 1;    // evaluate validation loss every N epochs
  TUNE_LR_PATIENCE   = 15;   // stagnant epochs before halving the lr
  TUNE_STOP_PATIENCE = 40;   // stagnant epochs before stopping
  TUNE_MIN_IMPROVE   = 1e-8; // validation-loss delta that counts as progress
  TUNE_MIN_LR        = 0.02; // lr floor after repeated halvings

var
  TuneParam:  array[0..TUNE_NPARAMS-1] of double;  // live weights (float mirror)
  TuneAnchor: array[0..TUNE_NPARAMS-1] of double;  // PeSTO prior (L2 target)
  TuneBest:   array[0..TUNE_NPARAMS-1] of double;  // best-validation snapshot
  TuneFrozen: array[0..TUNE_NPARAMS-1] of boolean; // true => never updated
  TuneM, TuneV: array[0..TUNE_NPARAMS-1] of double; // Adam moment estimates
  TunePositions: array of TTunePos;
  TuneNPos:  integer;
  TuneK:     double;                               // sigmoid scaling constant

// Validation membership: deterministic, storage-free. Every 10th position
// is held out (~10%). The dataset has no meaningful ordering correlation at
// stride 10, so this is as good as a random split and fully reproducible.
function TuneIsVal(i: integer): boolean; inline;
begin
  Result := (i mod 10) = 0;
end;

// Pointers to the 12 PST tables in the SAME order as the parameter vector.
// Index p in 0..767: table = p div 64, cell = p mod 64 = r*8 + c (white
// orientation, row 0 = rank 8).
type
  TPSTPtr = ^TPSTTable;
  TPSTTable = array[0..7, 0..7] of integer;
var
  PSTList: array[0..TUNE_PST_COUNT-1] of TPSTPtr;

procedure TuneInitTableList;
begin
  PSTList[0]  := @PawnPST_MG;   PSTList[1]  := @KnightPST_MG;
  PSTList[2]  := @BishopPST_MG; PSTList[3]  := @RookPST_MG;
  PSTList[4]  := @QueenPST_MG;  PSTList[5]  := @KingPST_MG;
  PSTList[6]  := @PawnPST_EG;   PSTList[7]  := @KnightPST_EG;
  PSTList[8]  := @BishopPST_EG; PSTList[9]  := @RookPST_EG;
  PSTList[10] := @QueenPST_EG;  PSTList[11] := @KingPST_EG;
end;

// Copy the live float parameter vector back into the integer engine tables
// (rounding to nearest). Used only when writing the output file.
procedure TuneParamsToTables;
var t, cell, r, c, i: integer;
begin
  for t := 0 to TUNE_PST_COUNT-1 do
    for cell := 0 to 63 do
    begin
      r := cell div 8; c := cell mod 8;
      PSTList[t]^[r, c] := Round(TuneParam[t*64 + cell]);
    end;
  for i := 0 to 4 do
  begin
    PieceValueMG[TPiece(1+i)] := Round(TuneParam[TUNE_MAT_BASE + i]);
    PieceValueMG[TPiece(7+i)] := -Round(TuneParam[TUNE_MAT_BASE + i]);
    PieceValueEG[TPiece(1+i)] := Round(TuneParam[TUNE_MAT_BASE + 5 + i]);
    PieceValueEG[TPiece(7+i)] := -Round(TuneParam[TUNE_MAT_BASE + 5 + i]);
  end;
  // v1.00-rc10: passed-pawn rank tables (8 MG, then 8 EG).
  for i := 0 to 7 do
  begin
    PassedPawnMG[i] := Round(TuneParam[TUNE_PASSED_BASE + i]);
    PassedPawnEG[i] := Round(TuneParam[TUNE_PASSED_BASE + 8 + i]);
  end;
  // v1.00-rc11: mobility tables (per-phase offsets N/B/R/Q; EG = MG + 66).
  for i := 0 to 8 do
  begin
    KnightMobMG[i] := Round(TuneParam[TUNE_MOB_BASE + TUNE_MOB_N_OFF + i]);
    KnightMobEG[i] := Round(TuneParam[TUNE_MOB_BASE + TUNE_MOB_PHASE + TUNE_MOB_N_OFF + i]);
  end;
  for i := 0 to 13 do
  begin
    BishopMobMG[i] := Round(TuneParam[TUNE_MOB_BASE + TUNE_MOB_B_OFF + i]);
    BishopMobEG[i] := Round(TuneParam[TUNE_MOB_BASE + TUNE_MOB_PHASE + TUNE_MOB_B_OFF + i]);
  end;
  for i := 0 to 14 do
  begin
    RookMobMG[i] := Round(TuneParam[TUNE_MOB_BASE + TUNE_MOB_R_OFF + i]);
    RookMobEG[i] := Round(TuneParam[TUNE_MOB_BASE + TUNE_MOB_PHASE + TUNE_MOB_R_OFF + i]);
  end;
  for i := 0 to 27 do
  begin
    QueenMobMG[i] := Round(TuneParam[TUNE_MOB_BASE + TUNE_MOB_Q_OFF + i]);
    QueenMobEG[i] := Round(TuneParam[TUNE_MOB_BASE + TUNE_MOB_PHASE + TUNE_MOB_Q_OFF + i]);
  end;
  // v1.00-rc13: threat scalars (6 MG, then 6 EG; order per layout comment).
  PawnThreatMinorMG  := Round(TuneParam[TUNE_THREAT_BASE + 0]);
  PawnThreatRookMG   := Round(TuneParam[TUNE_THREAT_BASE + 1]);
  PawnThreatQueenMG  := Round(TuneParam[TUNE_THREAT_BASE + 2]);
  MinorThreatRookMG  := Round(TuneParam[TUNE_THREAT_BASE + 3]);
  MinorThreatQueenMG := Round(TuneParam[TUNE_THREAT_BASE + 4]);
  HangingMG          := Round(TuneParam[TUNE_THREAT_BASE + 5]);
  PawnThreatMinorEG  := Round(TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 0]);
  PawnThreatRookEG   := Round(TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 1]);
  PawnThreatQueenEG  := Round(TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 2]);
  MinorThreatRookEG  := Round(TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 3]);
  MinorThreatQueenEG := Round(TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 4]);
  HangingEG          := Round(TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 5]);
  // v1.00-rc15: connected-pawn rank tables (8 MG, then 8 EG).
  for i := 0 to 7 do
  begin
    ConnectedMG[i] := Round(TuneParam[TUNE_CONN_BASE + i]);
    ConnectedEG[i] := Round(TuneParam[TUNE_CONN_BASE + 8 + i]);
  end;
  // v1.00-rc15 step 2: knight-outpost rank tables (8 MG, then 8 EG) and
  // the bishop-outpost scalar pair.
  for i := 0 to 7 do
  begin
    OutpostMG[i] := Round(TuneParam[TUNE_OUT_BASE + i]);
    OutpostEG[i] := Round(TuneParam[TUNE_OUT_BASE + 8 + i]);
  end;
  BishopOutpostMG := Round(TuneParam[TUNE_BOUT_BASE + 0]);
  BishopOutpostEG := Round(TuneParam[TUNE_BOUT_BASE + 1]);
  // v1.00-rc17 step 3: bad-bishop scalar pair.
  BadBishopPawnMG := Round(TuneParam[TUNE_BADB_BASE + 0]);
  BadBishopPawnEG := Round(TuneParam[TUNE_BADB_BASE + 1]);
  // v1.00-rc18 step 4: rook scalars.
  RookOn7thMG             := Round(TuneParam[TUNE_ROOK_BASE + 0]);
  RookOn7thEG             := Round(TuneParam[TUNE_ROOK_BASE + 1]);
  RookBehindOwnPassedMG   := Round(TuneParam[TUNE_ROOK_BASE + 2]);
  RookBehindOwnPassedEG   := Round(TuneParam[TUNE_ROOK_BASE + 3]);
  RookBehindEnemyPassedMG := Round(TuneParam[TUNE_ROOK_BASE + 4]);
  RookBehindEnemyPassedEG := Round(TuneParam[TUNE_ROOK_BASE + 5]);
  // v1.00-rc19 step 5: king/passer distance (EG-only scalars).
  KingPassedEnemyEG := Round(TuneParam[TUNE_KPD_BASE + 0]);
  KingPassedOwnEG   := Round(TuneParam[TUNE_KPD_BASE + 1]);
  // v1.00-rc20 step 6: pawn-shield ramp (MG-only).
  for i := 0 to 3 do
    ShieldMG[i] := Round(TuneParam[TUNE_SHIELD_BASE + i]);
  // v1.00-rc21 sweep: doubled/isolated/backward pawn penalties.
  DoubledPawnMG  := Round(TuneParam[TUNE_DIB_BASE + 0]);
  DoubledPawnEG  := Round(TuneParam[TUNE_DIB_BASE + 1]);
  IsolatedPawnMG := Round(TuneParam[TUNE_DIB_BASE + 2]);
  IsolatedPawnEG := Round(TuneParam[TUNE_DIB_BASE + 3]);
  BackwardPawnMG := Round(TuneParam[TUNE_DIB_BASE + 4]);
  BackwardPawnEG := Round(TuneParam[TUNE_DIB_BASE + 5]);
end;

// Load current engine tables into the float parameter vector; mark frozen
// cells (all material, pawn PST ranks 1 & 8); snapshot the anchor.
procedure TuneTablesToParams;
var t, cell, r, c, i: integer;
begin
  for i := 0 to TUNE_NPARAMS-1 do TuneFrozen[i] := False;
  for t := 0 to TUNE_PST_COUNT-1 do
    for cell := 0 to 63 do
    begin
      r := cell div 8; c := cell mod 8;
      TuneParam[t*64 + cell] := PSTList[t]^[r, c];
    end;
  for i := 0 to 4 do
  begin
    TuneParam[TUNE_MAT_BASE + i]     := PieceValueMG[TPiece(1+i)];
    TuneParam[TUNE_MAT_BASE + 5 + i] := PieceValueEG[TPiece(1+i)];
  end;

  // v1.00-rc10: passed-pawn rank tables into the vector (8 MG, then 8 EG).
  for i := 0 to 7 do
  begin
    TuneParam[TUNE_PASSED_BASE + i]     := PassedPawnMG[i];
    TuneParam[TUNE_PASSED_BASE + 8 + i] := PassedPawnEG[i];
  end;

  // v1.00-rc11: mobility tables into the vector (66 MG, then 66 EG). No
  // static freezes here: every index is geometrically reachable; cells the
  // TRAINING DATA never exercises are frozen after loading, data-driven,
  // by TuneFreezeUnseenMobility.
  for i := 0 to 8 do
  begin
    TuneParam[TUNE_MOB_BASE + TUNE_MOB_N_OFF + i]                  := KnightMobMG[i];
    TuneParam[TUNE_MOB_BASE + TUNE_MOB_PHASE + TUNE_MOB_N_OFF + i] := KnightMobEG[i];
  end;
  for i := 0 to 13 do
  begin
    TuneParam[TUNE_MOB_BASE + TUNE_MOB_B_OFF + i]                  := BishopMobMG[i];
    TuneParam[TUNE_MOB_BASE + TUNE_MOB_PHASE + TUNE_MOB_B_OFF + i] := BishopMobEG[i];
  end;
  for i := 0 to 14 do
  begin
    TuneParam[TUNE_MOB_BASE + TUNE_MOB_R_OFF + i]                  := RookMobMG[i];
    TuneParam[TUNE_MOB_BASE + TUNE_MOB_PHASE + TUNE_MOB_R_OFF + i] := RookMobEG[i];
  end;
  for i := 0 to 27 do
  begin
    TuneParam[TUNE_MOB_BASE + TUNE_MOB_Q_OFF + i]                  := QueenMobMG[i];
    TuneParam[TUNE_MOB_BASE + TUNE_MOB_PHASE + TUNE_MOB_Q_OFF + i] := QueenMobEG[i];
  end;

  // v1.00-rc13: threat scalars into the vector (6 MG, then 6 EG). No
  // freezes: every family occurs abundantly in any realistic dataset,
  // and the scalars are neither projected nor re-centered (their means
  // are genuine signal — see note (g) and TuneProjectGradient).
  TuneParam[TUNE_THREAT_BASE + 0] := PawnThreatMinorMG;
  TuneParam[TUNE_THREAT_BASE + 1] := PawnThreatRookMG;
  TuneParam[TUNE_THREAT_BASE + 2] := PawnThreatQueenMG;
  TuneParam[TUNE_THREAT_BASE + 3] := MinorThreatRookMG;
  TuneParam[TUNE_THREAT_BASE + 4] := MinorThreatQueenMG;
  TuneParam[TUNE_THREAT_BASE + 5] := HangingMG;
  TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 0] := PawnThreatMinorEG;
  TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 1] := PawnThreatRookEG;
  TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 2] := PawnThreatQueenEG;
  TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 3] := MinorThreatRookEG;
  TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 4] := MinorThreatQueenEG;
  TuneParam[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 5] := HangingEG;

  // v1.00-rc15: connected-pawn rank tables into the vector (8 MG, then
  // 8 EG). Like the passed-pawn tables: not projected, not re-centered
  // (means are genuine signal — the bonus reaches only connected pawns).
  for i := 0 to 7 do
  begin
    TuneParam[TUNE_CONN_BASE + i]     := ConnectedMG[i];
    TuneParam[TUNE_CONN_BASE + 8 + i] := ConnectedEG[i];
  end;

  // v1.00-rc15 step 2: knight-outpost tables + bishop-outpost scalar into
  // the vector. Not projected, not re-centered (means are signal).
  for i := 0 to 7 do
  begin
    TuneParam[TUNE_OUT_BASE + i]     := OutpostMG[i];
    TuneParam[TUNE_OUT_BASE + 8 + i] := OutpostEG[i];
  end;
  TuneParam[TUNE_BOUT_BASE + 0] := BishopOutpostMG;
  TuneParam[TUNE_BOUT_BASE + 1] := BishopOutpostEG;
  // v1.00-rc17 step 3: bad-bishop scalar pair. Not projected/re-centered.
  TuneParam[TUNE_BADB_BASE + 0] := BadBishopPawnMG;
  TuneParam[TUNE_BADB_BASE + 1] := BadBishopPawnEG;
  // v1.00-rc18 step 4: rook scalars. Not projected/re-centered.
  TuneParam[TUNE_ROOK_BASE + 0] := RookOn7thMG;
  TuneParam[TUNE_ROOK_BASE + 1] := RookOn7thEG;
  TuneParam[TUNE_ROOK_BASE + 2] := RookBehindOwnPassedMG;
  TuneParam[TUNE_ROOK_BASE + 3] := RookBehindOwnPassedEG;
  TuneParam[TUNE_ROOK_BASE + 4] := RookBehindEnemyPassedMG;
  TuneParam[TUNE_ROOK_BASE + 5] := RookBehindEnemyPassedEG;
  // v1.00-rc19 step 5: king/passer distance (EG-only). Not projected.
  TuneParam[TUNE_KPD_BASE + 0] := KingPassedEnemyEG;
  TuneParam[TUNE_KPD_BASE + 1] := KingPassedOwnEG;
  // v1.00-rc20 step 6: pawn-shield ramp (MG-only). Not projected.
  for i := 0 to 3 do
    TuneParam[TUNE_SHIELD_BASE + i] := ShieldMG[i];
  // v1.00-rc21 sweep: doubled/isolated/backward pawn penalties.
  TuneParam[TUNE_DIB_BASE + 0] := DoubledPawnMG;
  TuneParam[TUNE_DIB_BASE + 1] := DoubledPawnEG;
  TuneParam[TUNE_DIB_BASE + 2] := IsolatedPawnMG;
  TuneParam[TUNE_DIB_BASE + 3] := IsolatedPawnEG;
  TuneParam[TUNE_DIB_BASE + 4] := BackwardPawnMG;
  TuneParam[TUNE_DIB_BASE + 5] := BackwardPawnEG;

  // Freeze pawn PST rank 8 (row 0) and rank 1 (row 7): tables 0 and 6.
  for c := 0 to 7 do
  begin
    TuneFrozen[0*64 + 0*8 + c] := True;  TuneFrozen[0*64 + 7*8 + c] := True;
    TuneFrozen[6*64 + 0*8 + c] := True;  TuneFrozen[6*64 + 7*8 + c] := True;
  end;

  // v1.00-rc10: freeze the unreachable passed-pawn entries. Relative rank 0
  // (a pawn on its own back rank) and 7 (a pawn on the promotion rank) can
  // never occur, so those cells receive no data gradient — freeze them
  // outright, same policy as pawn PST ranks 1/8.
  TuneFrozen[TUNE_PASSED_BASE + 0]     := True;
  TuneFrozen[TUNE_PASSED_BASE + 7]     := True;
  TuneFrozen[TUNE_PASSED_BASE + 8]     := True;
  TuneFrozen[TUNE_PASSED_BASE + 15]    := True;

  // v1.00-rc15: freeze the unreachable connected-pawn entries. Relative
  // rank 0 (own back rank) and 7 (promotion rank) cannot hold a pawn —
  // same policy and same reasoning as the passed-pawn freezes above.
  TuneFrozen[TUNE_CONN_BASE + 0]       := True;
  TuneFrozen[TUNE_CONN_BASE + 7]       := True;
  TuneFrozen[TUNE_CONN_BASE + 8]       := True;
  TuneFrozen[TUNE_CONN_BASE + 15]      := True;

  // v1.00-rc15 step 2: freeze the unreachable knight-outpost ranks. The
  // gating condition restricts firing to relative ranks 3,4,5, so cells
  // 0,1,2,6,7 (both MG and EG) can never receive a coefficient — freeze
  // them at their zero seed. Cells 3,4,5 stay live; the freeze-unseen
  // range handles any the data does not exercise. The bishop-outpost
  // scalar pair is always live (it occurs whenever any outpost bishop
  // does) and needs no static freeze.
  for i := 0 to 7 do
    if (i < 3) or (i > 5) then
    begin
      TuneFrozen[TUNE_OUT_BASE + i]     := True;
      TuneFrozen[TUNE_OUT_BASE + 8 + i] := True;
    end;

  // Material/PST gauge freedom: total piece value on a square is
  //   PieceValue[p] + PST[sq], so material and PST are redundant by a
  //   per-piece constant. We freeze material at its anchor values (the scale
  //   the search's SEE / MVV-LVA / futility margins expect) and remove the
  //   remaining gauge direction from the GRADIENT (TuneProjectGradient), so
  //   only PST SHAPE — the part that carries new signal — is tuned.
  for i := 0 to TUNE_MAT_COUNT - 1 do
    TuneFrozen[TUNE_MAT_BASE + i] := True;

  // Anchor snapshot for the L2 prior (and the max-deviation report).
  for i := 0 to TUNE_NPARAMS-1 do TuneAnchor[i] := TuneParam[i];
end;

// Safety-net re-centering: restore each PST's mean (over live cells) to the
// anchor mean. With projected gradients the means should never move; Adam's
// per-coordinate scaling leaks sub-cp amounts back in, which this mops up
// once per epoch. If the printed drift is ever more than a fraction of a cp,
// something is wrong upstream. (The v1.00-rc10 passed-pawn parameters are
// deliberately outside — see TuneProjectGradient. The v1.00-rc11 mobility
// sub-tables ARE covered: every piece of a type lands in exactly one cell
// of its table, so their means carry the same material gauge as the PSTs.)
procedure TuneRecenterPSTs;
var t, cell, base, nlive: integer; s, anchorMean, delta: double;
begin
  for t := 0 to TUNE_PST_COUNT-1 do
  begin
    s := 0; anchorMean := 0; nlive := 0;
    for cell := 0 to 63 do
      if not TuneFrozen[t*64 + cell] then
      begin
        s := s + TuneParam[t*64 + cell];
        anchorMean := anchorMean + TuneAnchor[t*64 + cell];
        Inc(nlive);
      end;
    if nlive = 0 then Continue;
    delta := (s - anchorMean) / nlive;      // current mean minus anchor mean
    if delta = 0 then Continue;
    for cell := 0 to 63 do
      if not TuneFrozen[t*64 + cell] then
        TuneParam[t*64 + cell] := TuneParam[t*64 + cell] - delta;
  end;

  // v1.00-rc11: same treatment for the 8 mobility sub-tables.
  for t := 0 to TUNE_MOB_SEGS-1 do
  begin
    base := TUNE_MOB_BASE + TuneMobSegOff[t];
    s := 0; anchorMean := 0; nlive := 0;
    for cell := 0 to TuneMobSegLen[t]-1 do
      if not TuneFrozen[base + cell] then
      begin
        s := s + TuneParam[base + cell];
        anchorMean := anchorMean + TuneAnchor[base + cell];
        Inc(nlive);
      end;
    if nlive = 0 then Continue;
    delta := (s - anchorMean) / nlive;
    if delta = 0 then Continue;
    for cell := 0 to TuneMobSegLen[t]-1 do
      if not TuneFrozen[base + cell] then
        TuneParam[base + cell] := TuneParam[base + cell] - delta;
  end;
end;

// Remove the per-table mean (over live cells) from the gradient BEFORE Adam.
// This deletes the material/PST gauge direction at the source, so Adam's
// m/v statistics never accumulate a component that would only be projected
// away afterwards (which inflated vhat and slowed shape learning in the
// re-center-after-step design).
// v1.00-rc10: the passed-pawn parameters (TUNE_PASSED_BASE..) are NOT
// projected. The PST/material gauge argument does not apply to them: the
// bonus reaches only files with an unblocked front-pawn passer, not every
// pawn, so a constant added to a passed table is real signal, not a
// material shift in disguise. Their mean must stay free to move.
// v1.00-rc11: the mobility sub-tables ARE projected, per sub-table. Here
// the gauge argument DOES apply: every knight/bishop/rook/queen on the
// board contributes to exactly one cell of its table, so a constant added
// to a whole sub-table is a per-piece material shift — with material
// frozen, an unprojected mobility mean would hand that degree of freedom
// straight back to the optimizer and re-inflate Adam's moments with the
// mean direction (the exact failure mode note (c) removed for PSTs).
procedure TuneProjectGradient(var grad: array of double);
var t, cell, base, nlive: integer; s: double;
begin
  for t := 0 to TUNE_PST_COUNT-1 do
  begin
    s := 0; nlive := 0;
    for cell := 0 to 63 do
      if not TuneFrozen[t*64 + cell] then
      begin s := s + grad[t*64 + cell]; Inc(nlive); end;
    if nlive = 0 then Continue;
    s := s / nlive;
    for cell := 0 to 63 do
      if not TuneFrozen[t*64 + cell] then
        grad[t*64 + cell] := grad[t*64 + cell] - s;
  end;

  // v1.00-rc11: per-sub-table mean removal for the mobility blocks.
  for t := 0 to TUNE_MOB_SEGS-1 do
  begin
    base := TUNE_MOB_BASE + TuneMobSegOff[t];
    s := 0; nlive := 0;
    for cell := 0 to TuneMobSegLen[t]-1 do
      if not TuneFrozen[base + cell] then
      begin s := s + grad[base + cell]; Inc(nlive); end;
    if nlive = 0 then Continue;
    s := s / nlive;
    for cell := 0 to TuneMobSegLen[t]-1 do
      if not TuneFrozen[base + cell] then
        grad[base + cell] := grad[base + cell] - s;
  end;
end;

// Extract the sparse tunable coefficient vector for the CURRENT global State
// (white POV), as RAW net counts (not phase-scaled). Mirrors PASS 1 of
// Evaluate exactly: white reads [r,c], black reads [7-r,c] and is subtracted.
// v1.00-rc10: additionally mirrors the PASS 3 passed-pawn term: per file,
// the most-advanced pawn only, single-AND passed test, same masks and
// BsrQWord/BsfQWord selection as the engine — bit-for-bit, so the exact-
// residual verification in TuneLoadDataset still covers it.
// v1.00-rc11: additionally mirrors the PASS 5 mobility term: per piece,
// mobility count = PopCnt(attacks AND NOT own occupancy) with the SAME
// KnightAttacks / SliderAttacks / State.Occupied the engine uses —
// bit-for-bit, so the exact-residual verification covers it too. Net
// count: white +1, black -1, into the MG and EG cell of the piece's
// sub-table at index = mobility count.
// v1.00-rc13: additionally mirrors the PASS 7 threat terms: the pawn
// attack maps, minor attack maps, and full side attack maps are rebuilt
// with the SAME shifts / attack tables the engine's PASS 5 accumulates,
// then the six family counts are extracted from the SAME intersections
// PASS 7 evaluates — bit-for-bit, so the exact-residual verification
// covers these too. Net count: white family count minus black family
// count, into the MG scalar (base + family) and EG scalar (+6 further).
// NOTE: the mobility loops below double as the attack-map accumulation,
// exactly as PASS 5 does in the engine — the atk set is bound per piece
// and OR-ed into the side (and minor) maps before the mobility popcount.
procedure TuneExtractCoeffs(var coeffAcc: array of double);
var
  r, c, i, pc, t, matIdx: integer;
  pieceType: integer;   // 1..6 for P,N,B,R,Q,K
  isWhite: boolean;
  sgn: double;
  pr: integer;          // PST row after black mirror
  // v1.00-rc10: passed-pawn extraction scratch (mirrors PASS 3 locals)
  wPawns, bPawns, wFile, bFile: QWord;
  wFrontSq, bFrontSq, relRank: integer;
  // v1.00-rc11: mobility extraction scratch (mirrors PASS 5 locals)
  mobBB, mobNotOwn: QWord;
  mobSq, mobCount, mobIdx: integer;
  // v1.00-rc13: threat extraction scratch (mirrors the rc12/rc13 PASS 5
  // attack-map locals and the PASS 7 intersections)
  thAtk: QWord;                        // raw attack set of the current piece
  thWPawnAtk, thBPawnAtk: QWord;       // pawn attack maps
  thWMinorAtk, thBMinorAtk: QWord;     // knight+bishop attack maps
  thWAttackBB, thBAttackBB: QWord;     // full side attack maps
  thCnt: double;                       // net family count scratch
  // v1.00-rc15: connected-pawn extraction scratch (mirrors PASS 3 locals)
  connBB, connAdj: QWord;              // per-file pawn iterator / adjacent-file pawns
  connSq: integer;                     // LERF square of the pawn under test
  connSup, connPha, connOpp: boolean;  // supported / phalanx / opposed flags
  connM: integer;                      // SF-classical multiplier 2+phalanx-opposed
  // v1.00-rc15 step 2: outpost extraction scratch (mirrors PASS 5 locals).
  // outSqBB is the single-bit board of the minor under test; outRank its
  // LERF rank. The pawn-attack maps thWPawnAtk/thBPawnAtk built for the
  // threat block double as the outpost defender maps (same as PASS 5,
  // where wPawnAtk/bPawnAtk feed both outpost and threats).
  outSqBB: QWord;
  outRank: integer;
  // v1.00-rc17 step 3: bad-bishop extraction scratch. badColorBB is the
  // bishop's colour complex; badCnt is the single-shot blocked-central-
  // complex pawn count, replayed exactly from the engine's PASS 5 form.
  badColorBB: QWord;
  badCnt: integer;
  // v1.00-rc18 step 4: passed-pawn bitboards + rook extraction scratch,
  // built identically to the engine's PASS 4 (same front-pawn / passed
  // test, same rank/king/file conditions).
  wPassed, bPassed: QWord;
  rookBB: QWord;
  rookSq, rookR, rookC: integer;
  // v1.00-rc19 step 5: king/passer-distance extraction scratch.
  kpdWK, kpdBK, kpdF: integer;
  // v1.00-rc20 step 6: pawn-shield extraction scratch.
  shKR, shKC, shBest, shAdv, shVery, shFile, shBucket: integer;
  // v1.00-rc21 sweep: doubled/isolated/backward extraction scratch (PASS 3).
  dibWCount, dibBCount, dibRearSq, dibStopSq: integer;
  dibWAdj, dibBAdj: QWord;
begin
  for i := 0 to High(coeffAcc) do coeffAcc[i] := 0;

  for r := 0 to 7 do
    for c := 0 to 7 do
    begin
      pc := Ord(State.Board[r, c]);
      if pc = Ord(EMPTY) then Continue;
      isWhite := pc <= Ord(wK);                 // wP..wK = 1..6
      if isWhite then pieceType := pc           // 1..6
                 else pieceType := pc - 6;      // bP..bK -> 1..6
      if isWhite then sgn := 1 else sgn := -1;
      if isWhite then pr := r else pr := 7 - r;
      t := pieceType - 1;                       // 0..5 (MG table index)

      // PST: MG table t, EG table t+6. Raw count = +/-1 at this cell.
      coeffAcc[t*64 + pr*8 + c]     := coeffAcc[t*64 + pr*8 + c]     + sgn;
      coeffAcc[(t+6)*64 + pr*8 + c] := coeffAcc[(t+6)*64 + pr*8 + c] + sgn;

      // Material (skip king; king material cancels in every legal position).
      if pieceType <= 5 then
      begin
        matIdx := pieceType - 1;
        coeffAcc[TUNE_MAT_BASE + matIdx]     := coeffAcc[TUNE_MAT_BASE + matIdx]     + sgn;
        coeffAcc[TUNE_MAT_BASE + 5 + matIdx] := coeffAcc[TUNE_MAT_BASE + 5 + matIdx] + sgn;
      end;
    end;

  // v1.00-rc10: passed-pawn rank coefficients. EXACT replica of the PASS 3
  // logic in Evaluate: per file, only the MOST ADVANCED pawn is a candidate
  // (white: MSB of the file's pawn set; black: LSB), and it scores iff the
  // single-AND passed test against WhitePassedMask/BlackPassedMask is
  // clear. White relative rank = LERF rank of the front pawn; black is the
  // mirror (7 - LERF rank). Net count: white +1, black -1, into the MG
  // entry (base + relRank) and the EG entry (base + 8 + relRank).
  wPawns := State.Pieces[wP];
  bPawns := State.Pieces[bP];

  // v1.00-rc13: threat attack maps — pawn maps and side-map seeds, built
  // exactly as the engine does at the top of PASS 5 (same shifts, same
  // source-file masks, king ring from KingAttacks at the BsfQWord king
  // square). The piece attack sets are OR-ed in inside the mobility
  // loops below.
  thWPawnAtk := ((wPawns and not FileMask[0]) shl 7) or
                ((wPawns and not FileMask[7]) shl 9);
  thBPawnAtk := ((bPawns and not FileMask[7]) shr 7) or
                ((bPawns and not FileMask[0]) shr 9);
  thWAttackBB := thWPawnAtk or KingAttacks[Integer(BsfQWord(State.Pieces[wK]))];
  thBAttackBB := thBPawnAtk or KingAttacks[Integer(BsfQWord(State.Pieces[bK]))];
  thWMinorAtk := 0;
  thBMinorAtk := 0;

  // v1.00-rc18 step 4: accumulate the passed-pawn bitboards as we detect
  // passers below (same test the engine's PASS 4 builder uses).
  wPassed := 0;
  bPassed := 0;

  for c := 0 to 7 do
  begin
    wFile := wPawns and FileMask[c];
    if wFile <> 0 then
    begin
      wFrontSq := Integer(BsrQWord(wFile));
      if (WhitePassedMask[wFrontSq] and bPawns) = 0 then
      begin
        wPassed := wPassed or (QWord(1) shl wFrontSq);  // rc18 step 4
        relRank := wFrontSq shr 3;
        coeffAcc[TUNE_PASSED_BASE + relRank]     := coeffAcc[TUNE_PASSED_BASE + relRank]     + 1;
        coeffAcc[TUNE_PASSED_BASE + 8 + relRank] := coeffAcc[TUNE_PASSED_BASE + 8 + relRank] + 1;
      end;
    end;
    bFile := bPawns and FileMask[c];
    if bFile <> 0 then
    begin
      bFrontSq := Integer(BsfQWord(bFile));
      if (BlackPassedMask[bFrontSq] and wPawns) = 0 then
      begin
        bPassed := bPassed or (QWord(1) shl bFrontSq);  // rc18 step 4
        relRank := 7 - (bFrontSq shr 3);
        coeffAcc[TUNE_PASSED_BASE + relRank]     := coeffAcc[TUNE_PASSED_BASE + relRank]     - 1;
        coeffAcc[TUNE_PASSED_BASE + 8 + relRank] := coeffAcc[TUNE_PASSED_BASE + 8 + relRank] - 1;
      end;
    end;

    // v1.00-rc15: connected-pawn coefficients. EXACT replica of the PASS 3
    // logic: per pawn on this file, supported = own defender via
    // PawnAttacks[side, sq], phalanx = own pawn on adjacent file at the
    // same rank, opposed = enemy pawn strictly ahead on the same file.
    // A qualifying (supported-or-phalanx) pawn contributes the integer
    // multiplier m = 2 + phalanx - opposed to the MG cell (base + rr)
    // and the EG cell (base + 8 + rr); white adds, black subtracts.
    // -- white --
    connAdj := wPawns and AdjacentFileMask[c];
    connBB  := wPawns and FileMask[c];
    while connBB <> 0 do
    begin
      connSq := Integer(BsfQWord(connBB)); connBB := connBB and (connBB - 1);
      relRank := connSq shr 3;                       // white relRank = LERF rank
      connSup := (PawnAttacks[0, connSq] and wPawns) <> 0;
      connPha := (connAdj and RankMask[relRank]) <> 0;
      if connSup or connPha then
      begin
        connOpp := (bFile and RanksAtOrAbove[relRank + 1]) <> 0;
        connM   := 2 + Ord(connPha) - Ord(connOpp);
        coeffAcc[TUNE_CONN_BASE + relRank]     := coeffAcc[TUNE_CONN_BASE + relRank]     + connM;
        coeffAcc[TUNE_CONN_BASE + 8 + relRank] := coeffAcc[TUNE_CONN_BASE + 8 + relRank] + connM;
      end;
    end;
    // -- black mirror --
    connAdj := bPawns and AdjacentFileMask[c];
    connBB  := bPawns and FileMask[c];
    while connBB <> 0 do
    begin
      connSq := Integer(BsfQWord(connBB)); connBB := connBB and (connBB - 1);
      connSup := (PawnAttacks[1, connSq] and bPawns) <> 0;
      connPha := (connAdj and RankMask[connSq shr 3]) <> 0;
      if connSup or connPha then
      begin
        connOpp := (wFile and RanksAtOrBelow[(connSq shr 3) - 1]) <> 0;
        connM   := 2 + Ord(connPha) - Ord(connOpp);
        relRank := 7 - (connSq shr 3);               // mirrored relative rank
        coeffAcc[TUNE_CONN_BASE + relRank]     := coeffAcc[TUNE_CONN_BASE + relRank]     - connM;
        coeffAcc[TUNE_CONN_BASE + 8 + relRank] := coeffAcc[TUNE_CONN_BASE + 8 + relRank] - connM;
      end;
    end;

    // v1.00-rc21 sweep: doubled / isolated / backward coefficients. EXACT
    // replica of the PASS 3 per-file tests. Penalties are SUBTRACTED for
    // white in the engine, so the white coefficient is NEGATIVE (and black
    // POSITIVE). wFile/bFile bound above; recompute adj/counts here.
    dibWAdj := wPawns and AdjacentFileMask[c];
    dibBAdj := bPawns and AdjacentFileMask[c];
    dibWCount := Integer(PopCnt(wFile));
    dibBCount := Integer(PopCnt(bFile));

    // doubled: per extra pawn on the file (count-1). base+0 MG, base+1 EG.
    if dibWCount > 1 then
    begin
      coeffAcc[TUNE_DIB_BASE + 0] := coeffAcc[TUNE_DIB_BASE + 0] - (dibWCount - 1);
      coeffAcc[TUNE_DIB_BASE + 1] := coeffAcc[TUNE_DIB_BASE + 1] - (dibWCount - 1);
    end;
    if dibBCount > 1 then
    begin
      coeffAcc[TUNE_DIB_BASE + 0] := coeffAcc[TUNE_DIB_BASE + 0] + (dibBCount - 1);
      coeffAcc[TUNE_DIB_BASE + 1] := coeffAcc[TUNE_DIB_BASE + 1] + (dibBCount - 1);
    end;

    // isolated: front-set present with no adjacent-file own pawn. base+2/+3.
    if (wFile <> 0) and (dibWAdj = 0) then
    begin
      coeffAcc[TUNE_DIB_BASE + 2] := coeffAcc[TUNE_DIB_BASE + 2] - 1;
      coeffAcc[TUNE_DIB_BASE + 3] := coeffAcc[TUNE_DIB_BASE + 3] - 1;
    end;
    if (bFile <> 0) and (dibBAdj = 0) then
    begin
      coeffAcc[TUNE_DIB_BASE + 2] := coeffAcc[TUNE_DIB_BASE + 2] + 1;
      coeffAcc[TUNE_DIB_BASE + 3] := coeffAcc[TUNE_DIB_BASE + 3] + 1;
    end;

    // backward: rear pawn unsupported by adjacent files AND its stop square
    // attacked by an enemy pawn. Exact rear/stop arithmetic from PASS 3.
    // base+4 MG, base+5 EG.
    if wFile <> 0 then
    begin
      dibRearSq := Integer(BsfQWord(wFile));
      if (dibWAdj and RanksAtOrBelow[dibRearSq shr 3]) = 0 then
      begin
        dibStopSq := dibRearSq + 8;
        if (PawnAttacks[1, dibStopSq] and bPawns) <> 0 then
        begin
          coeffAcc[TUNE_DIB_BASE + 4] := coeffAcc[TUNE_DIB_BASE + 4] - 1;
          coeffAcc[TUNE_DIB_BASE + 5] := coeffAcc[TUNE_DIB_BASE + 5] - 1;
        end;
      end;
    end;
    if bFile <> 0 then
    begin
      dibRearSq := Integer(BsrQWord(bFile));
      if (dibBAdj and RanksAtOrAbove[dibRearSq shr 3]) = 0 then
      begin
        dibStopSq := dibRearSq - 8;
        if (PawnAttacks[0, dibStopSq] and wPawns) <> 0 then
        begin
          coeffAcc[TUNE_DIB_BASE + 4] := coeffAcc[TUNE_DIB_BASE + 4] + 1;
          coeffAcc[TUNE_DIB_BASE + 5] := coeffAcc[TUNE_DIB_BASE + 5] + 1;
        end;
      end;
    end;
  end;

  // v1.00-rc18 step 4: rook-term coefficients. EXACT replica of PASS 4's
  // rook conditions, using the wPassed/bPassed sets just built. Each is a
  // per-rook flag; white +1, black -1, into the paired MG/EG cells.
  //   pair 0 (base+0/+1): rook on relative rank 7
  //   pair 1 (base+2/+3): rook behind own passed pawn
  //   pair 2 (base+4/+5): rook behind enemy passed pawn
  rookBB := State.Pieces[wR];
  while rookBB <> 0 do
  begin
    rookSq := Integer(BsfQWord(rookBB)); rookBB := rookBB and (rookBB - 1);
    rookR := rookSq shr 3; rookC := rookSq and 7;
    if rookR = 6 then
      if ((State.Pieces[bK] and RankMask[7]) <> 0) or
         ((bPawns and RankMask[6]) <> 0) then
      begin
        coeffAcc[TUNE_ROOK_BASE + 0] := coeffAcc[TUNE_ROOK_BASE + 0] + 1;
        coeffAcc[TUNE_ROOK_BASE + 1] := coeffAcc[TUNE_ROOK_BASE + 1] + 1;
      end;
    if (wPassed and FileMask[rookC]) <> 0 then
      if rookSq < Integer(BsrQWord(wPassed and FileMask[rookC])) then
      begin
        coeffAcc[TUNE_ROOK_BASE + 2] := coeffAcc[TUNE_ROOK_BASE + 2] + 1;
        coeffAcc[TUNE_ROOK_BASE + 3] := coeffAcc[TUNE_ROOK_BASE + 3] + 1;
      end;
    if (bPassed and FileMask[rookC]) <> 0 then
      if rookSq > Integer(BsfQWord(bPassed and FileMask[rookC])) then
      begin
        coeffAcc[TUNE_ROOK_BASE + 4] := coeffAcc[TUNE_ROOK_BASE + 4] + 1;
        coeffAcc[TUNE_ROOK_BASE + 5] := coeffAcc[TUNE_ROOK_BASE + 5] + 1;
      end;
  end;
  rookBB := State.Pieces[bR];
  while rookBB <> 0 do
  begin
    rookSq := Integer(BsfQWord(rookBB)); rookBB := rookBB and (rookBB - 1);
    rookR := rookSq shr 3; rookC := rookSq and 7;
    if rookR = 1 then
      if ((State.Pieces[wK] and RankMask[0]) <> 0) or
         ((wPawns and RankMask[1]) <> 0) then
      begin
        coeffAcc[TUNE_ROOK_BASE + 0] := coeffAcc[TUNE_ROOK_BASE + 0] - 1;
        coeffAcc[TUNE_ROOK_BASE + 1] := coeffAcc[TUNE_ROOK_BASE + 1] - 1;
      end;
    if (bPassed and FileMask[rookC]) <> 0 then
      if rookSq > Integer(BsfQWord(bPassed and FileMask[rookC])) then
      begin
        coeffAcc[TUNE_ROOK_BASE + 2] := coeffAcc[TUNE_ROOK_BASE + 2] - 1;
        coeffAcc[TUNE_ROOK_BASE + 3] := coeffAcc[TUNE_ROOK_BASE + 3] - 1;
      end;
    if (wPassed and FileMask[rookC]) <> 0 then
      if rookSq < Integer(BsrQWord(wPassed and FileMask[rookC])) then
      begin
        coeffAcc[TUNE_ROOK_BASE + 4] := coeffAcc[TUNE_ROOK_BASE + 4] - 1;
        coeffAcc[TUNE_ROOK_BASE + 5] := coeffAcc[TUNE_ROOK_BASE + 5] - 1;
      end;
  end;

  // v1.00-rc19 step 5: king / passed-pawn distance coefficients (EG-only).
  // Rebuild the SAME arithmetic as the engine's end-of-Evaluate block:
  // front square = passer +/- 8, Chebyshev king distance, distance-weighted
  // into the two KPD scalars. wPassed/bPassed are the sets just built.
  // kpdWK/kpdBK are the king LERF squares; kpdF a passer's front square.
  kpdWK := Integer(BsfQWord(State.Pieces[wK]));
  kpdBK := Integer(BsfQWord(State.Pieces[bK]));
  rookBB := wPassed;
  while rookBB <> 0 do
  begin
    kpdF := Integer(BsfQWord(rookBB)) + 8; rookBB := rookBB and (rookBB - 1);
    coeffAcc[TUNE_KPD_BASE + 0] := coeffAcc[TUNE_KPD_BASE + 0]
        + Max(Abs((kpdBK and 7) - (kpdF and 7)), Abs((kpdBK shr 3) - (kpdF shr 3)));
    coeffAcc[TUNE_KPD_BASE + 1] := coeffAcc[TUNE_KPD_BASE + 1]
        - Max(Abs((kpdWK and 7) - (kpdF and 7)), Abs((kpdWK shr 3) - (kpdF shr 3)));
  end;
  rookBB := bPassed;
  while rookBB <> 0 do
  begin
    kpdF := Integer(BsfQWord(rookBB)) - 8; rookBB := rookBB and (rookBB - 1);
    coeffAcc[TUNE_KPD_BASE + 0] := coeffAcc[TUNE_KPD_BASE + 0]
        - Max(Abs((kpdWK and 7) - (kpdF and 7)), Abs((kpdWK shr 3) - (kpdF shr 3)));
    coeffAcc[TUNE_KPD_BASE + 1] := coeffAcc[TUNE_KPD_BASE + 1]
        + Max(Abs((kpdBK and 7) - (kpdF and 7)), Abs((kpdBK shr 3) - (kpdF shr 3)));
  end;

  // v1.00-rc20 step 6: pawn-shield coefficients (MG-only). EXACT replica of
  // PawnShieldPenalty: scope gate (king on its own first two ranks), three
  // king-front files with off-board skipped, nearest-first bucket
  // {best, adv, veryAdv, missing} -> ShieldMG[0..3]. White adds +1 to its
  // bucket, black subtracts. Uses State.Board and the king row/col exactly
  // as the engine's nested function does.
  // -- white (only if king on row 6 or 7) --
  shKR := State.WhiteKingR; shKC := State.WhiteKingC;
  if shKR >= 6 then
  begin
    shBest := shKR - 1; shAdv := shKR - 2; shVery := shKR - 3;
    for shFile := shKC - 1 to shKC + 1 do
      if (shFile >= 0) and (shFile <= 7) then
      begin
        if State.Board[shBest, shFile] = wP then shBucket := 0
        else if (shAdv >= 0) and (shAdv <= 7) and (State.Board[shAdv, shFile] = wP) then shBucket := 1
        else if (shVery >= 0) and (shVery <= 7) and (State.Board[shVery, shFile] = wP) then shBucket := 2
        else shBucket := 3;
        coeffAcc[TUNE_SHIELD_BASE + shBucket] := coeffAcc[TUNE_SHIELD_BASE + shBucket] + 1;
      end;
  end;
  // -- black (only if king on row 0 or 1) --
  shKR := State.BlackKingR; shKC := State.BlackKingC;
  if shKR <= 1 then
  begin
    shBest := shKR + 1; shAdv := shKR + 2; shVery := shKR + 3;
    for shFile := shKC - 1 to shKC + 1 do
      if (shFile >= 0) and (shFile <= 7) then
      begin
        if State.Board[shBest, shFile] = bP then shBucket := 0
        else if (shAdv >= 0) and (shAdv <= 7) and (State.Board[shAdv, shFile] = bP) then shBucket := 1
        else if (shVery >= 0) and (shVery <= 7) and (State.Board[shVery, shFile] = bP) then shBucket := 2
        else shBucket := 3;
        coeffAcc[TUNE_SHIELD_BASE + shBucket] := coeffAcc[TUNE_SHIELD_BASE + shBucket] - 1;
      end;
  end;

  // v1.00-rc11: mobility coefficients. EXACT replica of PASS 5 in Evaluate:
  // per N/B/R/Q piece, mobility count = PopCnt(attack set AND NOT own
  // occupancy); knight attacks from KnightAttacks[], sliders from
  // SliderAttacks(sq, 4,7 / 0,3 / 0,7). White +1, black -1, into the MG
  // cell (TUNE_MOB_BASE + pieceOff + count) and the EG cell (+66 further).

  // -- White --
  // v1.00-rc21 step 7: safe mobility — exclude squares attacked by black
  // pawns, exactly as the engine's PASS 5 now does. thBPawnAtk is built
  // above with the engine's shift pattern, so this is bit-for-bit.
  mobNotOwn := (not State.Occupied[0]) and (not thBPawnAtk);
  mobBB := State.Pieces[wN];
  while mobBB <> 0 do
  begin
    mobSq := Integer(BsfQWord(mobBB)); mobBB := mobBB and (mobBB - 1);
    thAtk := KnightAttacks[mobSq];                        // rc13: raw set
    thWAttackBB := thWAttackBB or thAtk;
    thWMinorAtk := thWMinorAtk or thAtk;
    mobCount := Integer(PopCnt(thAtk and mobNotOwn));
    mobIdx := TUNE_MOB_BASE + TUNE_MOB_N_OFF + mobCount;
    coeffAcc[mobIdx]                  := coeffAcc[mobIdx]                  + 1;
    coeffAcc[mobIdx + TUNE_MOB_PHASE] := coeffAcc[mobIdx + TUNE_MOB_PHASE] + 1;
    // rc15 step 2: white knight outpost. EXACT replica of PASS 5:
    // relative rank 3..5, pawn-defended (thWPawnAtk), permanent hole
    // (WhiteOutpostMask AND black pawns = 0). +1 into OutpostMG[relRank]
    // and OutpostEG[relRank]; relRank = LERF rank.
    outRank := mobSq shr 3;
    if (outRank >= 3) and (outRank <= 5) then
    begin
      outSqBB := QWord(1) shl mobSq;
      if ((thWPawnAtk and outSqBB) <> 0) and
         ((State.Pieces[bP] and WhiteOutpostMask[mobSq]) = 0) then
      begin
        coeffAcc[TUNE_OUT_BASE + outRank]     := coeffAcc[TUNE_OUT_BASE + outRank]     + 1;
        coeffAcc[TUNE_OUT_BASE + 8 + outRank] := coeffAcc[TUNE_OUT_BASE + 8 + outRank] + 1;
      end;
    end;
  end;
  mobBB := State.Pieces[wB];
  while mobBB <> 0 do
  begin
    mobSq := Integer(BsfQWord(mobBB)); mobBB := mobBB and (mobBB - 1);
    thAtk := SliderAttacks(mobSq, 4, 7);                  // rc13: raw set
    thWAttackBB := thWAttackBB or thAtk;
    thWMinorAtk := thWMinorAtk or thAtk;
    mobCount := Integer(PopCnt(thAtk and mobNotOwn));
    mobIdx := TUNE_MOB_BASE + TUNE_MOB_B_OFF + mobCount;
    coeffAcc[mobIdx]                  := coeffAcc[mobIdx]                  + 1;
    coeffAcc[mobIdx + TUNE_MOB_PHASE] := coeffAcc[mobIdx + TUNE_MOB_PHASE] + 1;
    // rc15 step 2: white bishop outpost. Same three conditions; +1 into
    // the single bishop-outpost scalar pair (MG, EG).
    outRank := mobSq shr 3;
    if (outRank >= 3) and (outRank <= 5) then
    begin
      outSqBB := QWord(1) shl mobSq;
      if ((thWPawnAtk and outSqBB) <> 0) and
         ((State.Pieces[bP] and WhiteOutpostMask[mobSq]) = 0) then
      begin
        coeffAcc[TUNE_BOUT_BASE + 0] := coeffAcc[TUNE_BOUT_BASE + 0] + 1;
        coeffAcc[TUNE_BOUT_BASE + 1] := coeffAcc[TUNE_BOUT_BASE + 1] + 1;
      end;
    end;
    // rc17 step 3: white bad bishop. Replay the engine's single-shot count
    // exactly: own pawns on this bishop's colour complex, central files,
    // blocked (front square sq+8 occupied => AllOccupied shr 8). White
    // penalty SUBTRACTS, so the coefficient is -badCnt. NB: recompute the
    // square bit here (outSqBB is only set inside the outpost rank band).
    if ((QWord(1) shl mobSq) and LightSquaresBB) <> 0 then
      badColorBB := LightSquaresBB
    else
      badColorBB := DarkSquaresBB;
    badCnt := Integer(PopCnt(wPawns and badColorBB and CentralFilesBB
                             and (State.AllOccupied shr 8)));
    coeffAcc[TUNE_BADB_BASE + 0] := coeffAcc[TUNE_BADB_BASE + 0] - badCnt;
    coeffAcc[TUNE_BADB_BASE + 1] := coeffAcc[TUNE_BADB_BASE + 1] - badCnt;
  end;
  mobBB := State.Pieces[wR];
  while mobBB <> 0 do
  begin
    mobSq := Integer(BsfQWord(mobBB)); mobBB := mobBB and (mobBB - 1);
    thAtk := SliderAttacks(mobSq, 0, 3);                  // rc13: raw set
    thWAttackBB := thWAttackBB or thAtk;
    mobCount := Integer(PopCnt(thAtk and mobNotOwn));
    mobIdx := TUNE_MOB_BASE + TUNE_MOB_R_OFF + mobCount;
    coeffAcc[mobIdx]                  := coeffAcc[mobIdx]                  + 1;
    coeffAcc[mobIdx + TUNE_MOB_PHASE] := coeffAcc[mobIdx + TUNE_MOB_PHASE] + 1;
  end;
  mobBB := State.Pieces[wQ];
  while mobBB <> 0 do
  begin
    mobSq := Integer(BsfQWord(mobBB)); mobBB := mobBB and (mobBB - 1);
    thAtk := SliderAttacks(mobSq, 0, 7);                  // rc13: raw set
    thWAttackBB := thWAttackBB or thAtk;
    mobCount := Integer(PopCnt(thAtk and mobNotOwn));
    mobIdx := TUNE_MOB_BASE + TUNE_MOB_Q_OFF + mobCount;
    coeffAcc[mobIdx]                  := coeffAcc[mobIdx]                  + 1;
    coeffAcc[mobIdx + TUNE_MOB_PHASE] := coeffAcc[mobIdx + TUNE_MOB_PHASE] + 1;
  end;

  // -- Black --
  // v1.00-rc21 step 7: safe mobility mirror — exclude white pawn attacks.
  mobNotOwn := (not State.Occupied[1]) and (not thWPawnAtk);
  mobBB := State.Pieces[bN];
  while mobBB <> 0 do
  begin
    mobSq := Integer(BsfQWord(mobBB)); mobBB := mobBB and (mobBB - 1);
    thAtk := KnightAttacks[mobSq];                        // rc13: raw set
    thBAttackBB := thBAttackBB or thAtk;
    thBMinorAtk := thBMinorAtk or thAtk;
    mobCount := Integer(PopCnt(thAtk and mobNotOwn));
    mobIdx := TUNE_MOB_BASE + TUNE_MOB_N_OFF + mobCount;
    coeffAcc[mobIdx]                  := coeffAcc[mobIdx]                  - 1;
    coeffAcc[mobIdx + TUNE_MOB_PHASE] := coeffAcc[mobIdx + TUNE_MOB_PHASE] - 1;
    // rc15 step 2: black knight outpost. Mirror of white: relative rank
    // 4..2 in LERF = LERF rank 2,3,4; defended via thBPawnAtk; hole via
    // BlackOutpostMask AND white pawns = 0. -1 into OutpostMG/EG at the
    // mirrored relative rank 7 - LERF rank.
    outRank := mobSq shr 3;
    if (outRank >= 2) and (outRank <= 4) then
    begin
      outSqBB := QWord(1) shl mobSq;
      if ((thBPawnAtk and outSqBB) <> 0) and
         ((State.Pieces[wP] and BlackOutpostMask[mobSq]) = 0) then
      begin
        coeffAcc[TUNE_OUT_BASE + (7 - outRank)]     := coeffAcc[TUNE_OUT_BASE + (7 - outRank)]     - 1;
        coeffAcc[TUNE_OUT_BASE + 8 + (7 - outRank)] := coeffAcc[TUNE_OUT_BASE + 8 + (7 - outRank)] - 1;
      end;
    end;
  end;
  mobBB := State.Pieces[bB];
  while mobBB <> 0 do
  begin
    mobSq := Integer(BsfQWord(mobBB)); mobBB := mobBB and (mobBB - 1);
    thAtk := SliderAttacks(mobSq, 4, 7);                  // rc13: raw set
    thBAttackBB := thBAttackBB or thAtk;
    thBMinorAtk := thBMinorAtk or thAtk;
    mobCount := Integer(PopCnt(thAtk and mobNotOwn));
    mobIdx := TUNE_MOB_BASE + TUNE_MOB_B_OFF + mobCount;
    coeffAcc[mobIdx]                  := coeffAcc[mobIdx]                  - 1;
    coeffAcc[mobIdx + TUNE_MOB_PHASE] := coeffAcc[mobIdx + TUNE_MOB_PHASE] - 1;
    // rc15 step 2: black bishop outpost. Same three conditions; -1 into
    // the bishop-outpost scalar pair.
    outRank := mobSq shr 3;
    if (outRank >= 2) and (outRank <= 4) then
    begin
      outSqBB := QWord(1) shl mobSq;
      if ((thBPawnAtk and outSqBB) <> 0) and
         ((State.Pieces[wP] and BlackOutpostMask[mobSq]) = 0) then
      begin
        coeffAcc[TUNE_BOUT_BASE + 0] := coeffAcc[TUNE_BOUT_BASE + 0] - 1;
        coeffAcc[TUNE_BOUT_BASE + 1] := coeffAcc[TUNE_BOUT_BASE + 1] - 1;
      end;
    end;
    // rc17 step 3: black bad bishop. Black pawn front is sq-8 => blocked
    // set is bPawns AND (AllOccupied shl 8). Black penalty ADDS to white
    // POV, so the coefficient is +badCnt (mirror of the white -badCnt).
    if ((QWord(1) shl mobSq) and LightSquaresBB) <> 0 then
      badColorBB := LightSquaresBB
    else
      badColorBB := DarkSquaresBB;
    badCnt := Integer(PopCnt(bPawns and badColorBB and CentralFilesBB
                             and (State.AllOccupied shl 8)));
    coeffAcc[TUNE_BADB_BASE + 0] := coeffAcc[TUNE_BADB_BASE + 0] + badCnt;
    coeffAcc[TUNE_BADB_BASE + 1] := coeffAcc[TUNE_BADB_BASE + 1] + badCnt;
  end;
  mobBB := State.Pieces[bR];
  while mobBB <> 0 do
  begin
    mobSq := Integer(BsfQWord(mobBB)); mobBB := mobBB and (mobBB - 1);
    thAtk := SliderAttacks(mobSq, 0, 3);                  // rc13: raw set
    thBAttackBB := thBAttackBB or thAtk;
    mobCount := Integer(PopCnt(thAtk and mobNotOwn));
    mobIdx := TUNE_MOB_BASE + TUNE_MOB_R_OFF + mobCount;
    coeffAcc[mobIdx]                  := coeffAcc[mobIdx]                  - 1;
    coeffAcc[mobIdx + TUNE_MOB_PHASE] := coeffAcc[mobIdx + TUNE_MOB_PHASE] - 1;
  end;
  mobBB := State.Pieces[bQ];
  while mobBB <> 0 do
  begin
    mobSq := Integer(BsfQWord(mobBB)); mobBB := mobBB and (mobBB - 1);
    thAtk := SliderAttacks(mobSq, 0, 7);                  // rc13: raw set
    thBAttackBB := thBAttackBB or thAtk;
    mobCount := Integer(PopCnt(thAtk and mobNotOwn));
    mobIdx := TUNE_MOB_BASE + TUNE_MOB_Q_OFF + mobCount;
    coeffAcc[mobIdx]                  := coeffAcc[mobIdx]                  - 1;
    coeffAcc[mobIdx + TUNE_MOB_PHASE] := coeffAcc[mobIdx + TUNE_MOB_PHASE] - 1;
  end;

  // v1.00-rc13: threat coefficients. EXACT replica of PASS 7 in Evaluate,
  // evaluated on the attack maps completed above. Each family's
  // coefficient is the NET count (white family count minus black family
  // count), stored once into the MG scalar and once into the EG scalar
  // (+TUNE_THREAT_PHASE). Family order matches the layout comment:
  //   0 PawnThreatMinor  1 PawnThreatRook  2 PawnThreatQueen
  //   3 MinorThreatRook  4 MinorThreatQueen  5 Hanging

  // 0: pawn attacks minor
  thCnt := Integer(PopCnt(thWPawnAtk and (State.Pieces[bN] or State.Pieces[bB])))
         - Integer(PopCnt(thBPawnAtk and (State.Pieces[wN] or State.Pieces[wB])));
  coeffAcc[TUNE_THREAT_BASE + 0] := thCnt;
  coeffAcc[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 0] := thCnt;

  // 1: pawn attacks rook
  thCnt := Integer(PopCnt(thWPawnAtk and State.Pieces[bR]))
         - Integer(PopCnt(thBPawnAtk and State.Pieces[wR]));
  coeffAcc[TUNE_THREAT_BASE + 1] := thCnt;
  coeffAcc[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 1] := thCnt;

  // 2: pawn attacks queen
  thCnt := Integer(PopCnt(thWPawnAtk and State.Pieces[bQ]))
         - Integer(PopCnt(thBPawnAtk and State.Pieces[wQ]));
  coeffAcc[TUNE_THREAT_BASE + 2] := thCnt;
  coeffAcc[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 2] := thCnt;

  // 3: minor attacks rook
  thCnt := Integer(PopCnt(thWMinorAtk and State.Pieces[bR]))
         - Integer(PopCnt(thBMinorAtk and State.Pieces[wR]));
  coeffAcc[TUNE_THREAT_BASE + 3] := thCnt;
  coeffAcc[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 3] := thCnt;

  // 4: minor attacks queen
  thCnt := Integer(PopCnt(thWMinorAtk and State.Pieces[bQ]))
         - Integer(PopCnt(thBMinorAtk and State.Pieces[wQ]));
  coeffAcc[TUNE_THREAT_BASE + 4] := thCnt;
  coeffAcc[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 4] := thCnt;

  // 5: hanging — non-king units attacked by the enemy, defended by nobody
  thCnt := Integer(PopCnt((State.Occupied[1] and not State.Pieces[bK])
                          and thWAttackBB and not thBAttackBB))
         - Integer(PopCnt((State.Occupied[0] and not State.Pieces[wK])
                          and thBAttackBB and not thWAttackBB));
  coeffAcc[TUNE_THREAT_BASE + 5] := thCnt;
  coeffAcc[TUNE_THREAT_BASE + TUNE_THREAT_PHASE + 5] := thCnt;
end;

// v1.00-rc11: freeze cells with ZERO occurrences in the loaded training
// set. Every mobility index is geometrically reachable, so unlike pawn PST
// ranks 1/8 there is nothing to freeze statically — but cells the data
// never exercises (e.g. QueenMob[27]) would still receive the negated
// per-sub-table mean via the gradient projection and drift away from the
// linear seed for no data reason. Freezing them at the anchor (= the seed)
// keeps unconstrained cells sane if they ever occur in play. Call AFTER
// TuneLoadDataset, BEFORE the first epoch.
// v1.00-rc15: generalised from the mobility-only version into a
// range-based procedure so any table block can reuse the policy —
// applied to the mobility block (as before) and the connected-pawn
// block (statically-frozen cells are skipped by the report count).
procedure TuneFreezeUnseenRange(base, count: integer; const blockName: string);
var
  i, j, idx, nFrozen: integer;
  seen: array of boolean;
begin
  SetLength(seen, count);
  for i := 0 to count-1 do seen[i] := False;
  for i := 0 to TuneNPos - 1 do
    for j := 0 to TunePositions[i].nc - 1 do
    begin
      idx := TunePositions[i].coeffs[j].idx;
      // Range-bounded on both sides: blocks above and below this one in
      // the vector must not alias into seen[] (the rc13 lesson).
      if (idx >= base) and (idx < base + count) then
        seen[idx - base] := True;
    end;
  nFrozen := 0;
  for i := 0 to count-1 do
    if (not seen[i]) and (not TuneFrozen[base + i]) then
    begin
      TuneFrozen[base + i] := True;
      Inc(nFrozen);
    end;
  Writeln(blockName, ' cells with zero training coverage (frozen at seed anchor): ',
          nFrozen, ' of ', count, '.');
end;

// Is parameter index p an EG-phase weight? PST tables 6..11 are EG; material
// indices TUNE_MAT_BASE+5 .. +9 are EG; passed-pawn indices
// TUNE_PASSED_BASE+8 .. +15 are EG (v1.00-rc10); mobility indices
// TUNE_MOB_BASE+66 .. +131 are EG (v1.00-rc11); threat indices
// TUNE_THREAT_BASE+6 .. +11 are EG (v1.00-rc13).
// v1.00-rc15: connected indices TUNE_CONN_BASE+8 .. +15 are EG.
// v1.00-rc15 step 2: knight-outpost TUNE_OUT_BASE+8 .. +15 are EG;
// bishop-outpost TUNE_BOUT_BASE+1 is EG (the pair is MG then EG).
function TuneParamIsEG(p: integer): boolean;
begin
  if p >= TUNE_DIB_BASE then
    // v1.00-rc21 sweep: three MG/EG pairs -> odd offset = EG.
    Result := ((p - TUNE_DIB_BASE) and 1) = 1
  else if p >= TUNE_SHIELD_BASE then
    // v1.00-rc20 step 6: pawn shield is MG-only -> never EG.
    Result := False
  else if p >= TUNE_KPD_BASE then
    // v1.00-rc19 step 5: king/passer distance is EG-only -> both EG.
    Result := True
  else if p >= TUNE_ROOK_BASE then
    // v1.00-rc18: three consecutive MG/EG pairs -> odd offset = EG.
    Result := ((p - TUNE_ROOK_BASE) and 1) = 1
  else if p >= TUNE_BADB_BASE then
    Result := (p - TUNE_BADB_BASE) >= 1
  else if p >= TUNE_BOUT_BASE then
    Result := (p - TUNE_BOUT_BASE) >= 1
  else if p >= TUNE_OUT_BASE then
    Result := (p - TUNE_OUT_BASE) >= 8
  else if p >= TUNE_CONN_BASE then
    Result := (p - TUNE_CONN_BASE) >= 8
  else if p >= TUNE_THREAT_BASE then
    Result := (p - TUNE_THREAT_BASE) >= TUNE_THREAT_PHASE
  else if p >= TUNE_MOB_BASE then
    Result := (p - TUNE_MOB_BASE) >= TUNE_MOB_PHASE
  else if p >= TUNE_PASSED_BASE then
    Result := (p - TUNE_PASSED_BASE) >= 8
  else if p >= TUNE_MAT_BASE then
    Result := (p - TUNE_MAT_BASE) >= 5
  else
    Result := (p div 64) >= 6;
end;

// Predicted white-POV eval for one position, reproducing the engine's blend
// EXACTLY: ScoreMG/ScoreEG from tunable weights + frozen residuals, then the
// SAME single truncating division the engine uses. Pascal integer `div`
// truncates TOWARD ZERO; Trunc matches it bit-for-bit for both signs (Floor
// would disagree by 1 cp on negative non-multiples of 24).
function TunePredict(const P: TTunePos): double;
var
  i: integer;
  mg, eg: double;
begin
  mg := P.mgResidual;
  eg := P.egResidual;
  for i := 0 to P.nc - 1 do
    if P.coeffs[i].isEG then
      eg := eg + TuneParam[P.coeffs[i].idx] * P.coeffs[i].cnt
    else
      mg := mg + TuneParam[P.coeffs[i].idx] * P.coeffs[i].cnt;
  Result := {Trunc}((mg * P.phase + eg * (MaxPhase - P.phase)) / MaxPhase);  //mod 26/07/2026
end;

function TuneSigmoid(E, K: double): double;
begin
  Result := 1.0 / (1.0 + Exp(-K * E / 400.0 * Ln(10)));  // 10^(-K*E/400)
end;

// Mean squared error at the current parameters over one subset:
// wantVal=False => training positions, wantVal=True => held-out validation.
function TuneLossSubset(K: double; wantVal: boolean): double;
var i, n: integer; e, p, diff, total: double;
begin
  total := 0; n := 0;
  for i := 0 to TuneNPos - 1 do
    if TuneIsVal(i) = wantVal then
    begin
      e := TunePredict(TunePositions[i]);
      p := TuneSigmoid(e, K);
      diff := TunePositions[i].result - p;
      total := total + diff * diff;
      Inc(n);
    end;
  if n > 0 then Result := total / n else Result := 0;
end;

// Golden-section search for the K that minimises TRAINING loss at the stock
// weights (standard Texel practice; K then stays fixed for the whole run).
procedure TuneFitK;
var a, b, c1, c2, f1, f2, gr: double; iter: integer;
begin
  a := 0.2; b := 3.0;
  gr := (Sqrt(5.0) - 1.0) / 2.0;
  c1 := b - gr * (b - a);
  c2 := a + gr * (b - a);
  f1 := TuneLossSubset(c1, False);
  f2 := TuneLossSubset(c2, False);
  for iter := 1 to 30 do
  begin
    if f1 < f2 then
    begin
      b := c2; c2 := c1; f2 := f1;
      c1 := b - gr * (b - a); f1 := TuneLossSubset(c1, False);
    end
    else
    begin
      a := c1; c1 := c2; f1 := f2;
      c2 := a + gr * (b - a); f2 := TuneLossSubset(c2, False);
    end;
  end;
  TuneK := (a + b) / 2.0;
end;

// Map a result tag to {0, 0.5, 1} (white POV). Accepts both spellings:
// '1-0' / '0-1' / '1/2-1/2' (zurichess) and '1.0' / '0.0' / '0.5'
// (lichess-big3-resolved). False if the tag is not a valid result.
function TuneTagToResult(const tag: string; out res: double): boolean;
begin
  Result := True;
  if (tag = '1-0') or (tag = '1.0') or (tag = '1') then res := 1.0
  else if (tag = '0-1') or (tag = '0.0') or (tag = '0') then res := 0.0
  else if (tag = '1/2-1/2') or (tag = '0.5') then res := 0.5
  else Result := False;
end;

// Parse one EPD/book line into its FEN part and white-POV result.
// Auto-detects, per line, the two common labelled-dataset formats:
//
//   zurichess / quiet-labeled:   <fen 4 fields> c9 "1/2-1/2";
//   lichess-big3-resolved:       <fen 6 fields> [0.5]
//
// Returns False (caller counts the line as skipped) if no valid label is
// found. ParseFEN tolerates both 4- and 6-field FENs.
function TuneParseLine(const Line: string; out fenPart: string;
                       out res: double): boolean;
var p1, p2: integer; tag: string;
begin
  Result := False;
  fenPart := '';

  // --- Format A: quoted tag,  ... c9 "1-0"; ---
  p1 := Pos('"', Line);
  if p1 > 1 then
  begin
    p2 := Pos('"', Copy(Line, p1 + 1, Length(Line)));
    if p2 = 0 then Exit;
    tag := Copy(Line, p1 + 1, p2 - 1);
    if not TuneTagToResult(tag, res) then Exit;
    fenPart := Copy(Line, 1, p1 - 1);
    // strip a trailing EPD opcode marker (' c9' etc.) if present
    p2 := Pos(' c9', fenPart);
    if p2 > 0 then fenPart := Copy(fenPart, 1, p2 - 1);
    fenPart := Trim(fenPart);
    Result := fenPart <> '';
    Exit;
  end;

  // --- Format B: bracket tag,  ... [0.5] ---
  p1 := Pos('[', Line);
  if p1 > 1 then
  begin
    p2 := Pos(']', Copy(Line, p1 + 1, Length(Line)));
    if p2 = 0 then Exit;
    tag := Trim(Copy(Line, p1 + 1, p2 - 1));
    if not TuneTagToResult(tag, res) then Exit;
    fenPart := Trim(Copy(Line, 1, p1 - 1));
    Result := fenPart <> '';
    Exit;
  end;
end;

// Load the dataset: parse FEN, extract coefficients + residual, store a
// compact sparse position. Verifies the linear model reproduces Evaluate.
procedure TuneLoadDataset(const FileName: string);
var
  F: TextFile;
  Line, fenPart: string;
  res: double;
  scratch: array of double;
  i, nz, cIdx: integer;
  evalWhite, modelWhite, tunMG, tunEG: double;
  mismatches, loaded, skipped: integer;
  cap: integer;
  ioErr: integer;
begin
  SetLength(scratch, TUNE_NPARAMS);
  SetLength(TunePositions, 0);
  TuneNPos := 0;
  mismatches := 0; loaded := 0; skipped := 0;
  cap := 0;

  if not FileExists(FileName) then
  begin
    Writeln('ERROR: dataset file not found: "', FileName, '"');
    Writeln('       (looked in current directory: ', GetCurrentDir, ')');
    Halt(2);
  end;

  AssignFile(F, FileName);
  {$I-}
  Reset(F);
  ioErr := IOResult;
  {$I+}
  if ioErr <> 0 then
  begin
    Writeln('ERROR: could not open dataset "', FileName,
            '" (I/O error ', ioErr, ').');
    Halt(2);
  end;

  Writeln('Loading dataset ', FileName, ' ...');
  Flush(Output);

  while not Eof(F) do
  begin
    {$I-} ReadLn(F, Line); ioErr := IOResult; {$I+}
    if ioErr <> 0 then
    begin
      Writeln('  WARN: read error ', ioErr, ' after ', loaded,
              ' positions; stopping load early.');
      Break;
    end;

    Line := Trim(Line);
    if Line = '' then Continue;
    if not TuneParseLine(Line, fenPart, res) then
    begin Inc(skipped); Continue; end;

    ParseFEN(fenPart);

    // Real engine eval (STM POV), flipped to white POV for the check below.
    evalWhite := Evaluate;
    if State.SideToMove = 1 then evalWhite := -evalWhite;

    TuneExtractCoeffs(scratch);

    nz := 0;
    for i := 0 to TUNE_NPARAMS - 1 do
      if scratch[i] <> 0 then Inc(nz);

    if TuneNPos >= cap then
    begin
      if cap = 0 then cap := 65536 else cap := cap * 2;
      SetLength(TunePositions, cap);
    end;

    with TunePositions[TuneNPos] do
    begin
      SetLength(coeffs, nz);
      cIdx := 0;
      tunMG := 0; tunEG := 0;   // tunable sums under CURRENT weights
      for i := 0 to TUNE_NPARAMS - 1 do
        if scratch[i] <> 0 then
        begin
          coeffs[cIdx].idx  := i;
          coeffs[cIdx].cnt  := scratch[i];
          coeffs[cIdx].isEG := TuneParamIsEG(i);
          if coeffs[cIdx].isEG then tunEG := tunEG + TuneParam[i] * scratch[i]
                               else tunMG := tunMG + TuneParam[i] * scratch[i];
          Inc(cIdx);
        end;
      nc := nz;
      // Residual = engine's pre-blend sum minus the tunable part. Captures
      // every non-tunable term (mobility, pawn structure, king safety, rook
      // files, bishop pair, tempo) exactly, split by phase. Because the eval
      // is linear in the tunable weights, the residual is weight-independent.
      mgResidual := TunerLastMG - tunMG;
      egResidual := TunerLastEG - tunEG;
      phase      := TunerLastPhase;
      result     := res;
    end;

    // Verify the model reproduces Evaluate EXACTLY (integer-faithful).
    modelWhite := TunePredict(TunePositions[TuneNPos]);
    if Abs(trunc(modelWhite) - evalWhite) > 0.5 then  // mod 26/07/2026 add trunc
    begin
      Inc(mismatches);
      if mismatches <= 5 then
        Writeln('  WARN model/eval mismatch: model=', modelWhite:0:4,
                ' eval=', evalWhite:0:2, '  FEN=', fenPart);
    end;

    Inc(TuneNPos);
    Inc(loaded);
    if (loaded mod 50000) = 0 then
    begin
      Writeln('  loaded ', loaded, ' positions');
      Flush(Output);
    end;
  end;
  CloseFile(F);

  SetLength(TunePositions, TuneNPos);

  Writeln('Loaded ', TuneNPos, ' positions (', skipped, ' lines skipped, ',
          mismatches, ' model mismatches).');
  if TuneNPos = 0 then
  begin
    Writeln('ERROR: the file opened but yielded 0 usable positions.');
    Writeln('       Expected EPD lines in one of these formats:');
    Writeln('         <fen fields> c9 "1/2-1/2";     (zurichess quiet-labeled)');
    Writeln('         <fen fields> [0.5]             (lichess-big3-resolved)');
    Halt(2);
  end;
  if mismatches > 0 then
  begin
    Writeln('ERROR: ', mismatches, ' model/eval mismatches — the linear ',
            'coefficient model does not');
    Writeln('       reproduce Evaluate. Check the four integration hooks ',
            '(esp. the TunerLast');
    Writeln('       capture point) before trusting any result.');
    Halt(2);
  end;
  Flush(Output);
end;

// One Adam epoch: full-batch gradient over the TRAINING subset only.
// lambda: L2 pull toward the PeSTO anchor, added to the per-position-
// normalised data gradient as lambda * (w - anchor).
procedure TuneAdamEpoch(lr, b1, b2, eps, lambda: double; var step: integer);
var
  grad: array of double;
  i, j, nTrain: integer;
  e, p, s, common: double;
  pfMG, pfEG: double;
  mhat, vhat: double;
begin
  SetLength(grad, TUNE_NPARAMS);
  for i := 0 to TUNE_NPARAMS - 1 do grad[i] := 0;

  // dL/dw = sum 2*(p - R) * p*(1-p) * (K*ln10/400) * dE/dw, with
  //   MG weight: dE/dw = cnt * gp/24,   EG weight: dE/dw = cnt * (24-gp)/24.
  // The Trunc in TunePredict contributes derivative 1 a.e. — it shapes the
  // prediction (exact match with Evaluate) but not the gradient direction.
  s := TuneK * Ln(10) / 400.0;
  nTrain := 0;
  for i := 0 to TuneNPos - 1 do
  begin
    if TuneIsVal(i) then Continue;          // validation never touches grad
    Inc(nTrain);
    e := TunePredict(TunePositions[i]);
    p := TuneSigmoid(e, TuneK);
    common := 2.0 * (p - TunePositions[i].result) * p * (1.0 - p) * s;
    pfMG := TunePositions[i].phase / MaxPhase;
    pfEG := (MaxPhase - TunePositions[i].phase) / MaxPhase;
    for j := 0 to TunePositions[i].nc - 1 do
      if TunePositions[i].coeffs[j].isEG then
        grad[TunePositions[i].coeffs[j].idx] :=
          grad[TunePositions[i].coeffs[j].idx]
          + common * TunePositions[i].coeffs[j].cnt * pfEG
      else
        grad[TunePositions[i].coeffs[j].idx] :=
          grad[TunePositions[i].coeffs[j].idx]
          + common * TunePositions[i].coeffs[j].cnt * pfMG;
  end;

  // Normalise, add the L2 anchor pull, then delete the gauge direction.
  for i := 0 to TUNE_NPARAMS - 1 do
    if not TuneFrozen[i] then
      grad[i] := grad[i] / nTrain
                 + lambda * (TuneParam[i] - TuneAnchor[i]);
  TuneProjectGradient(grad);

  Inc(step);
  for i := 0 to TUNE_NPARAMS - 1 do
  begin
    if TuneFrozen[i] then Continue;
    TuneM[i] := b1 * TuneM[i] + (1 - b1) * grad[i];
    TuneV[i] := b2 * TuneV[i] + (1 - b2) * grad[i] * grad[i];
    mhat := TuneM[i] / (1 - Power(b1, step));
    vhat := TuneV[i] / (1 - Power(b2, step));
    TuneParam[i] := TuneParam[i] - lr * mhat / (Sqrt(vhat) + eps);
  end;

  // Safety net; near no-op with projected gradients (see TuneRecenterPSTs).
  TuneRecenterPSTs;
end;

// Report the largest |param - anchor| and where it lives — a one-glance
// check on the regularizer, and (after the SPRT) a pointer to the cells the
// data fought hardest for.
procedure TuneReportMaxDeviation;
var
  i, bestIdx: integer;
  d, bestD: double;
  t, cell, r, c: integer;
  names: array[0..TUNE_PST_COUNT-1] of string;
begin
  names[0]  := 'PawnPST_MG';   names[1]  := 'KnightPST_MG';
  names[2]  := 'BishopPST_MG'; names[3]  := 'RookPST_MG';
  names[4]  := 'QueenPST_MG';  names[5]  := 'KingPST_MG';
  names[6]  := 'PawnPST_EG';   names[7]  := 'KnightPST_EG';
  names[8]  := 'BishopPST_EG'; names[9]  := 'RookPST_EG';
  names[10] := 'QueenPST_EG';  names[11] := 'KingPST_EG';

  bestD := -1; bestIdx := 0;
  for i := 0 to TUNE_NPARAMS - 1 do
    if not TuneFrozen[i] then
    begin
      d := Abs(TuneParam[i] - TuneAnchor[i]);
      if d > bestD then begin bestD := d; bestIdx := i; end;
    end;
  if bestIdx < TUNE_MAT_BASE then
  begin
    t := bestIdx div 64; cell := bestIdx mod 64;
    r := cell div 8; c := cell mod 8;
    Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at ',
            names[t], '[', r, ',', c, ']  (row 0 = rank 8, white view)');
  end
  else if bestIdx >= TUNE_DIB_BASE then
  begin
    // v1.00-rc21 sweep: doubled/isolated/backward pawn penalties.
    case bestIdx - TUNE_DIB_BASE of
      0: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at DoubledPawnMG');
      1: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at DoubledPawnEG');
      2: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at IsolatedPawnMG');
      3: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at IsolatedPawnEG');
      4: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at BackwardPawnMG');
      5: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at BackwardPawnEG');
    end;
  end
  else if bestIdx >= TUNE_SHIELD_BASE then
  begin
    // v1.00-rc20 step 6: pawn-shield ramp (MG-only), index = advancement.
    Writeln('Max deviation from anchor: ', bestD:0:1,
            ' cp at ShieldMG[', bestIdx - TUNE_SHIELD_BASE,
            ']  (0 best .. 3 missing)');
  end
  else if bestIdx >= TUNE_KPD_BASE then
  begin
    // v1.00-rc19 step 5: king/passer distance (EG-only pair).
    if (bestIdx - TUNE_KPD_BASE) = 0 then
      Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at KingPassedEnemyEG')
    else
      Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at KingPassedOwnEG');
  end
  else if bestIdx >= TUNE_ROOK_BASE then
  begin
    // v1.00-rc18 step 4: rook block, three MG/EG pairs.
    case bestIdx - TUNE_ROOK_BASE of
      0: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at RookOn7thMG');
      1: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at RookOn7thEG');
      2: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at RookBehindOwnPassedMG');
      3: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at RookBehindOwnPassedEG');
      4: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at RookBehindEnemyPassedMG');
      5: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at RookBehindEnemyPassedEG');
    end;
  end
  else if bestIdx >= TUNE_BADB_BASE then
  begin
    // v1.00-rc17 step 3: bad-bishop scalar pair (MG, EG).
    if (bestIdx - TUNE_BADB_BASE) = 0 then
      Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at BadBishopPawnMG')
    else
      Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at BadBishopPawnEG');
  end
  else if bestIdx >= TUNE_BOUT_BASE then
  begin
    // v1.00-rc15 step 2: bishop-outpost scalar pair (MG, EG).
    if (bestIdx - TUNE_BOUT_BASE) = 0 then
      Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at BishopOutpostMG')
    else
      Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at BishopOutpostEG');
  end
  else if bestIdx >= TUNE_OUT_BASE then
  begin
    // v1.00-rc15 step 2: knight-outpost block, 8 MG then 8 EG by rel rank.
    i := bestIdx - TUNE_OUT_BASE;
    if i < 8 then
      Writeln('Max deviation from anchor: ', bestD:0:1,
              ' cp at OutpostMG[', i, ']  (relative rank)')
    else
      Writeln('Max deviation from anchor: ', bestD:0:1,
              ' cp at OutpostEG[', i - 8, ']  (relative rank)');
  end
  else if bestIdx >= TUNE_CONN_BASE then
  begin
    // v1.00-rc15: connected block, 8 MG then 8 EG by relative rank.
    i := bestIdx - TUNE_CONN_BASE;
    if i < 8 then
      Writeln('Max deviation from anchor: ', bestD:0:1,
              ' cp at ConnectedMG[', i, ']  (relative rank)')
    else
      Writeln('Max deviation from anchor: ', bestD:0:1,
              ' cp at ConnectedEG[', i - 8, ']  (relative rank)');
  end
  else if bestIdx >= TUNE_THREAT_BASE then
  begin
    // v1.00-rc13: threat block, 6 MG then 6 EG scalars.
    i := bestIdx - TUNE_THREAT_BASE;
    case i of
      0:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at PawnThreatMinorMG');
      1:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at PawnThreatRookMG');
      2:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at PawnThreatQueenMG');
      3:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at MinorThreatRookMG');
      4:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at MinorThreatQueenMG');
      5:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at HangingMG');
      6:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at PawnThreatMinorEG');
      7:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at PawnThreatRookEG');
      8:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at PawnThreatQueenEG');
      9:  Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at MinorThreatRookEG');
      10: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at MinorThreatQueenEG');
      11: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at HangingEG');
    end;
  end
  else if bestIdx >= TUNE_MOB_BASE then
  begin
    // v1.00-rc11: mobility block, 66 MG then 66 EG; N/B/R/Q per phase.
    i := bestIdx - TUNE_MOB_BASE;
    for t := TUNE_MOB_SEGS-1 downto 0 do
      if i >= TuneMobSegOff[t] then
      begin
        cell := i - TuneMobSegOff[t];
        case t of
          0: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at KnightMobMG[', cell, ']');
          1: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at BishopMobMG[', cell, ']');
          2: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at RookMobMG[', cell, ']');
          3: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at QueenMobMG[', cell, ']');
          4: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at KnightMobEG[', cell, ']');
          5: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at BishopMobEG[', cell, ']');
          6: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at RookMobEG[', cell, ']');
          7: Writeln('Max deviation from anchor: ', bestD:0:1, ' cp at QueenMobEG[', cell, ']');
        end;
        Break;
      end;
  end
  else if bestIdx >= TUNE_PASSED_BASE then
  begin
    // v1.00-rc10: passed-pawn block, 8 MG then 8 EG by relative rank.
    i := bestIdx - TUNE_PASSED_BASE;
    if i < 8 then
      Writeln('Max deviation from anchor: ', bestD:0:1,
              ' cp at PassedPawnMG[', i, ']  (relative rank)')
    else
      Writeln('Max deviation from anchor: ', bestD:0:1,
              ' cp at PassedPawnEG[', i - 8, ']  (relative rank)');
  end
  else
    Writeln('Max deviation from anchor: ', bestD:0:1,
            ' cp at material index ', bestIdx - TUNE_MAT_BASE);
end;

// v1.00-rc11: write one mobility table as a drop-in const declaration,
// wrapped at 14 entries per line (matches the engine's QueenMob layout).
procedure TuneWriteMobArray(var F: TextFile; const AName: string;
                            const A: array of integer);
var i: integer;
begin
  Writeln(F, '  ', AName, ': array[0..', High(A), '] of integer =');
  Write  (F, '    (');
  for i := 0 to High(A) do
  begin
    Write(F, A[i]:4);
    if i < High(A) then Write(F, ',');
    if (i mod 14 = 13) and (i < High(A)) then
    begin
      Writeln(F);
      Write(F, '     ');
    end;
  end;
  Writeln(F, ');');
end;

// Write the tuned tables as a drop-in Pascal const section (from TuneParam,
// which the caller has set to the best-validation snapshot).
procedure TuneWriteOutput(const FileName: string);
var
  F: TextFile;
  t, r, c, i: integer;
  names: array[0..TUNE_PST_COUNT-1] of string;
begin
  names[0]  := 'PawnPST_MG';   names[1]  := 'KnightPST_MG';
  names[2]  := 'BishopPST_MG'; names[3]  := 'RookPST_MG';
  names[4]  := 'QueenPST_MG';  names[5]  := 'KingPST_MG';
  names[6]  := 'PawnPST_EG';   names[7]  := 'KnightPST_EG';
  names[8]  := 'BishopPST_EG'; names[9]  := 'RookPST_EG';
  names[10] := 'QueenPST_EG';  names[11] := 'KingPST_EG';

  TuneParamsToTables;
  AssignFile(F, FileName);
  Rewrite(F);
  Writeln(F, '  // Texel-tuned PST + piece values (best-validation snapshot).');
  Writeln(F, '  // Drop-in replacement for the corresponding const declarations.');
  Writeln(F, '  PieceValueMG: array[TPiece] of integer =');
  Write  (F, '    (0');
  for i := 1 to 5 do Write(F, ', ', PieceValueMG[TPiece(i)]:4);
  Write  (F, ', 20000');
  for i := 1 to 5 do Write(F, ', ', PieceValueMG[TPiece(i)] * (-1):4);
  Writeln(F, ', -20000);');
  Writeln(F, '  PieceValueEG: array[TPiece] of integer =');
  Write  (F, '    (0');
  for i := 1 to 5 do Write(F, ', ', PieceValueEG[TPiece(i)]:4);
  Write  (F, ', 20000');
  for i := 1 to 5 do Write(F, ', ', PieceValueEG[TPiece(i)] * (-1):4);
  Writeln(F, ', -20000);');
  Writeln(F);
  for t := 0 to TUNE_PST_COUNT-1 do
  begin
    Writeln(F, '  ', names[t], ': array[0..7, 0..7] of integer = (');
    for r := 0 to 7 do
    begin
      Write(F, '    (');
      for c := 0 to 7 do
      begin
        Write(F, PSTList[t]^[r, c]:4);
        if c < 7 then Write(F, ',');
      end;
      if r < 7 then Writeln(F, '),') else Writeln(F, '));');
    end;
    Writeln(F);
  end;

  // v1.00-rc10: tuned passed-pawn rank tables (drop-in, same layout as the
  // engine's declarations; index = relative rank, entries 0 and 7 frozen).
  Writeln(F, '  PassedPawnMG: array[0..7] of integer =');
  Write  (F, '    (');
  for i := 0 to 7 do
  begin
    Write(F, PassedPawnMG[i]:4);
    if i < 7 then Write(F, ',');
  end;
  Writeln(F, ');');
  Writeln(F, '  PassedPawnEG: array[0..7] of integer =');
  Write  (F, '    (');
  for i := 0 to 7 do
  begin
    Write(F, PassedPawnEG[i]:4);
    if i < 7 then Write(F, ',');
  end;
  Writeln(F, ');');
  Writeln(F);

  // v1.00-rc11: tuned mobility tables (drop-in, same layout as the engine's
  // declarations; index = mobility count, zero-coverage cells frozen at the
  // linear seed).
  TuneWriteMobArray(F, 'KnightMobMG', KnightMobMG);
  TuneWriteMobArray(F, 'KnightMobEG', KnightMobEG);
  TuneWriteMobArray(F, 'BishopMobMG', BishopMobMG);
  TuneWriteMobArray(F, 'BishopMobEG', BishopMobEG);
  TuneWriteMobArray(F, 'RookMobMG',   RookMobMG);
  TuneWriteMobArray(F, 'RookMobEG',   RookMobEG);
  TuneWriteMobArray(F, 'QueenMobMG',  QueenMobMG);
  TuneWriteMobArray(F, 'QueenMobEG',  QueenMobEG);
  Writeln(F);

  // v1.00-rc13: tuned threat scalars (drop-in TYPED constants for the
  // tunable {$IFDEF TUNER}var{$ELSE}const{$ENDIF} block).
  Writeln(F, '  PawnThreatMinorMG:  integer = ', PawnThreatMinorMG, ';');
  Writeln(F, '  PawnThreatMinorEG:  integer = ', PawnThreatMinorEG, ';');
  Writeln(F, '  PawnThreatRookMG:   integer = ', PawnThreatRookMG, ';');
  Writeln(F, '  PawnThreatRookEG:   integer = ', PawnThreatRookEG, ';');
  Writeln(F, '  PawnThreatQueenMG:  integer = ', PawnThreatQueenMG, ';');
  Writeln(F, '  PawnThreatQueenEG:  integer = ', PawnThreatQueenEG, ';');
  Writeln(F, '  MinorThreatRookMG:  integer = ', MinorThreatRookMG, ';');
  Writeln(F, '  MinorThreatRookEG:  integer = ', MinorThreatRookEG, ';');
  Writeln(F, '  MinorThreatQueenMG: integer = ', MinorThreatQueenMG, ';');
  Writeln(F, '  MinorThreatQueenEG: integer = ', MinorThreatQueenEG, ';');
  Writeln(F, '  HangingMG:          integer = ', HangingMG, ';');
  Writeln(F, '  HangingEG:          integer = ', HangingEG, ';');
  Writeln(F);

  // v1.00-rc15: tuned connected-pawn rank tables (drop-in, same layout as
  // the engine's declarations; index = relative rank, entries 0 and 7
  // frozen, zero-coverage cells frozen at the seed).
  TuneWriteMobArray(F, 'ConnectedMG', ConnectedMG);
  TuneWriteMobArray(F, 'ConnectedEG', ConnectedEG);
  Writeln(F);

  // v1.00-rc15 step 2: tuned knight-outpost rank tables (index = relative
  // rank; only 3,4,5 live, 0/1/2/6/7 frozen) and the bishop-outpost
  // scalar pair (TYPED constants for the tunable var/const block).
  TuneWriteMobArray(F, 'OutpostMG', OutpostMG);
  TuneWriteMobArray(F, 'OutpostEG', OutpostEG);
  Writeln(F, '  BishopOutpostMG:    integer = ', BishopOutpostMG, ';');
  Writeln(F, '  BishopOutpostEG:    integer = ', BishopOutpostEG, ';');
  // v1.00-rc17 step 3: tuned bad-bishop scalar pair (per BLOCKED central
  // own pawn on the bishop's colour complex).
  Writeln(F, '  BadBishopPawnMG:    integer = ', BadBishopPawnMG, ';');
  Writeln(F, '  BadBishopPawnEG:    integer = ', BadBishopPawnEG, ';');
  // v1.00-rc18 step 4: tuned rook scalars (drop-in typed constants).
  Writeln(F, '  RookOn7thMG:            integer = ', RookOn7thMG, ';');
  Writeln(F, '  RookOn7thEG:            integer = ', RookOn7thEG, ';');
  Writeln(F, '  RookBehindOwnPassedMG:  integer = ', RookBehindOwnPassedMG, ';');
  Writeln(F, '  RookBehindOwnPassedEG:  integer = ', RookBehindOwnPassedEG, ';');
  Writeln(F, '  RookBehindEnemyPassedMG:integer = ', RookBehindEnemyPassedMG, ';');
  Writeln(F, '  RookBehindEnemyPassedEG:integer = ', RookBehindEnemyPassedEG, ';');
  // v1.00-rc19 step 5: tuned king/passer-distance scalars (EG-only).
  Writeln(F, '  KingPassedEnemyEG:      integer = ', KingPassedEnemyEG, ';');
  Writeln(F, '  KingPassedOwnEG:        integer = ', KingPassedOwnEG, ';');
  // v1.00-rc20 step 6: tuned pawn-shield ramp (MG-only, index = advancement).
  TuneWriteMobArray(F, 'ShieldMG', ShieldMG);
  // v1.00-rc21 sweep: tuned doubled/isolated/backward pawn penalties.
  Writeln(F, '  DoubledPawnMG:  integer = ', DoubledPawnMG, ';');
  Writeln(F, '  DoubledPawnEG:  integer = ', DoubledPawnEG, ';');
  Writeln(F, '  IsolatedPawnMG: integer = ', IsolatedPawnMG, ';');
  Writeln(F, '  IsolatedPawnEG: integer = ', IsolatedPawnEG, ';');
  Writeln(F, '  BackwardPawnMG: integer = ', BackwardPawnMG, ';');
  Writeln(F, '  BackwardPawnEG: integer = ', BackwardPawnEG, ';');

  CloseFile(F);
  Writeln('Wrote tuned tables to ', FileName);
end;

// Locale-safe float parsing: a Dutch Windows locale uses ',' as decimal
// separator, which would break '2e-7' under the default StrToFloat.
function TuneStrToFloatDef(const S: string; Def: double): double;
var fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  Result := StrToFloatDef(S, Def, fs);
end;

procedure RunTexelTuner;
var
  dataset, outFile: string;
  maxEpochs, ep, step, i: integer;
  lambda, lr: double;
  trainLoss, valLoss, bestVal, lossBefore: double;
  kBefore, valAtNewK: double;        // post-convergence K refit diagnostic
  stagnant: integer;
  bestEpoch: integer;
begin
  dataset   := ParamStr(1);
  if dataset='' then
  begin
    writeln;
    writeln('Texel training using quit moves');
    Writeln('Usage: ', ExtractFileName(ParamStr(0)),
            ' <dataset.epd> [maxEpochs=1000] [lambda=2e-7] [lr=0.25]');
//    dataset:='C:\PasKnight.fpc\training\ChessTrainingSets-master\quiet-labeled.epd';
    dataset:='C:\PasKnight.fpc\training\lichess-big3-resolved.book';
    writeln('Will try using the default '+ dataset);
    writeln('Hit enter to continue');
    readln;
  end;
  maxEpochs := 1000;
  lambda    := 2e-7;
  lr        := 0.25;
  if ParamCount >= 2 then maxEpochs := StrToIntDef(ParamStr(2), 1000);
  if ParamCount >= 3 then lambda    := TuneStrToFloatDef(ParamStr(3), 2e-7);
  if ParamCount >= 4 then lr        := TuneStrToFloatDef(ParamStr(4), 0.25);
  outFile := 'tuned_pst.pas';

  Writeln('Texel tuner: maxEpochs=', maxEpochs, '  lambda=', lambda:0:10,
          '  lr=', lr:0:3);

  TuneInitTableList;
  TuneTablesToParams;               // params + frozen flags + anchor snapshot
  for i := 0 to TUNE_NPARAMS - 1 do
  begin
    TuneM[i] := 0; TuneV[i] := 0;
    TuneBest[i] := TuneParam[i];
  end;

  TuneLoadDataset(dataset);
  // v1.00-rc11/rc15: data-driven freezes — mobility (as before) and the
  // connected-pawn block (sparse high ranks; see note (h)).
  TuneFreezeUnseenRange(TUNE_MOB_BASE,  TUNE_MOB_COUNT,  'Mobility');
  TuneFreezeUnseenRange(TUNE_CONN_BASE, TUNE_CONN_COUNT, 'Connected');
  TuneFreezeUnseenRange(TUNE_OUT_BASE,  TUNE_OUT_COUNT,  'KnightOutpost');
  TuneFreezeUnseenRange(TUNE_BOUT_BASE, TUNE_BOUT_COUNT, 'BishopOutpost');
  TuneFreezeUnseenRange(TUNE_BADB_BASE, TUNE_BADB_COUNT, 'BadBishop');
  TuneFreezeUnseenRange(TUNE_ROOK_BASE, TUNE_ROOK_COUNT, 'RookTerms');
  TuneFreezeUnseenRange(TUNE_KPD_BASE,  TUNE_KPD_COUNT,  'KingPasserDist');
  TuneFreezeUnseenRange(TUNE_SHIELD_BASE, TUNE_SHIELD_COUNT, 'PawnShield');
  TuneFreezeUnseenRange(TUNE_DIB_BASE, TUNE_DIB_COUNT, 'DoubIsoBack');

  Writeln('Split: ', TuneNPos - (TuneNPos + 9) div 10, ' training / ',
          (TuneNPos + 9) div 10, ' validation (every 10th position held out).');

  Writeln('Fitting sigmoid K (on training subset) ...');
  TuneFitK;
  Writeln('  K = ', TuneK:0:4);

  lossBefore := TuneLossSubset(TuneK, False);
  bestVal    := TuneLossSubset(TuneK, True);
  Writeln('Loss before:  train ', lossBefore:0:6, '   val ', bestVal:0:6);

  step := 0;
  stagnant := 0;
  bestEpoch := 0;
  for ep := 1 to maxEpochs do
  begin
    TuneAdamEpoch(lr, 0.9, 0.999, 1e-8, lambda, step);

    if (ep mod TUNE_VAL_EVERY) = 0 then
    begin
      valLoss := TuneLossSubset(TuneK, True);

      if valLoss < bestVal - TUNE_MIN_IMPROVE then
      begin
        bestVal := valLoss;
        bestEpoch := ep;
        stagnant := 0;
        for i := 0 to TUNE_NPARAMS - 1 do TuneBest[i] := TuneParam[i];
      end
      else
        Inc(stagnant);

      if (ep mod 5 = 0) or (stagnant = 0) then
      begin
        trainLoss := TuneLossSubset(TuneK, False);
        Writeln('  epoch ', ep:4, '  train ', trainLoss:0:6,
                '  val ', valLoss:0:6,
                '  best ', bestVal:0:6, ' @', bestEpoch,
                '  lr ', lr:0:4);
        Flush(Output);
      end;

      // Plateau handling: halve the lr once progress stalls; give the
      // smaller step a fresh patience window. Stop when even that stalls.
      if (stagnant > 0) and (stagnant mod TUNE_LR_PATIENCE = 0)
         and (lr > TUNE_MIN_LR) then
      begin
        lr := lr / 2;
        if lr < TUNE_MIN_LR then lr := TUNE_MIN_LR;
        Writeln('  [plateau: lr halved to ', lr:0:4, ']');
      end;
      if stagnant >= TUNE_STOP_PATIENCE then
      begin
        Writeln('  [early stop: no validation improvement for ',
                TUNE_STOP_PATIENCE, ' epochs]');
        Break;
      end;
    end;
  end;

  // Restore and report the best-validation snapshot; that is what ships.
  for i := 0 to TUNE_NPARAMS - 1 do TuneParam[i] := TuneBest[i];
  Writeln('Best validation loss ', bestVal:0:6, ' at epoch ', bestEpoch,
          '  (train there: ', TuneLossSubset(TuneK, False):0:6, ')');
  TuneReportMaxDeviation;

  // Post-convergence K refit. K was fitted once at the SEED weights
  // (standard Texel practice) and held fixed for the whole run, but the
  // converged weights map centipawns to win probability slightly
  // differently than the seeds did — especially after a semantic change
  // like the rc21 safe-mobility index shift, where the seeds are stale by
  // design. Refitting K on the FINAL weights answers one question: does
  // the loss landscape still have room, or was the original K adequate?
  //   * If the refit barely moves K (< ~2-3%) and the validation loss is
  //     essentially unchanged, the run is converged in both K and weights:
  //     ship the output as-is.
  //   * If K moves noticeably and validation improves, a SECOND (usually
  //     short) tuning run at the new K can squeeze out a little more —
  //     rerun the tuner with the tuned tables pasted in as the new seeds;
  //     TuneFitK at the top of that run then starts from this refitted
  //     neighbourhood automatically.
  // The refit itself changes NOTHING that ships: K is not written to the
  // output file, and the weights are already frozen at the best-validation
  // snapshot. It is a diagnostic. (Refitting K on the training subset,
  // same as the initial fit — the validation loss printed after is the
  // honest generalisation readout at the new K.)
  Writeln;
  Writeln('Refitting sigmoid K on the converged weights ...');
  kBefore := TuneK;
  TuneFitK;                          // golden-section on TRAINING loss, as before
  valAtNewK := TuneLossSubset(TuneK, True);
  Writeln('  K: ', kBefore:0:4, ' -> ', TuneK:0:4,
          '  (', (100.0 * (TuneK - kBefore) / kBefore):0:2, '% change)');
  Writeln('  val loss at refitted K: ', valAtNewK:0:6,
          '   (was ', bestVal:0:6, ' at the original K)');
  if (Abs(TuneK - kBefore) / kBefore < 0.03) and
     (bestVal - valAtNewK < 10 * TUNE_MIN_IMPROVE) then
    Writeln('  -> K stable and val flat: run is converged; ship the output as-is.')
  else
    Writeln('  -> K moved and/or val improved: consider a second run seeded ',
            'from this output.');

  TuneWriteOutput(outFile);
  Writeln('Done. Paste ', outFile, ' over the corresponding declarations,');
  Writeln('rebuild WITHOUT -dTUNER, and SPRT against the stock build.');
  writeln('Hit return to exit');
  readln;
end;
