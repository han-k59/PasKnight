================================================================================
PasKnight — a UCI chess engine
Version 2.0.0
================================================================================

--------------------------------------------------------------------------------
1. What it is
--------------------------------------------------------------------------------
PasKnight is a UCI (Universal Chess Interface) chess engine. It has no graphical
interface of its own; it runs as a console application and communicates through
text commands with a GUI such as Arena, Cute Chess, BanksiaGUI, or WinBoard/
XBoard (via a UCI-to-XBoard adapter).

Since v2.0 PasKnight evaluates positions with a neural network (NNUE) only; the
hand-crafted evaluation (HCE) of v1.0 has been removed. The network is built
into the executable, so no separate .nnue file is needed to play. The engine
runs on a single thread and is built for Windows on CPUs with AVX2.

Strength: the v1.0 HCE engine was estimated at roughly 2510-2540 Elo. An early
NNUE net (NNUE5s) played at roughly 3000 in matches against other engines (a
rough estimate, not a rating-list figure). The current net has not yet been
measured against other engines.

The hand-crafted v1.0 line is kept separately (v1.0.1).

--------------------------------------------------------------------------------
2. Source code and building
--------------------------------------------------------------------------------
PasKnight is written in Object Pascal for the Free Pascal Compiler (FPC 3.2.2)
and the Lazarus IDE. All files must be in the same folder:

  - pasknight.lpr                main program (search, UCI, time management)
  - pasknight_unit_nnue.pas      the NNUE: loader, accumulator, forward pass
  - pasknight_net.inc            the embedded network, generated (see below)
  - pasknight_nnue_cmds.inc      the "nnue" validation commands
  - pasknight_nnue_gendata.inc   the training-data generator (GenData build)

The Lazarus project has two build modes, both with target processor COREAVX2:

  - Release   the UCI engine, used for play, bench and matches
  - GenData   adds the "gendata" command (define NNUE_GENDATA); for generating
              training data only, never for matches

From the command line:

    fpc -O3 -CpCOREAVX2 pasknight.lpr                    (Release)
    fpc -O3 -CpCOREAVX2 -dNNUE_GENDATA pasknight.lpr     (GenData)

The embedded network. pasknight_net.inc holds the .nnue file byte for byte as a
Pascal constant array (about 1.7 MB of source; the executable grows by about
411 KB). It is written by the engine itself and must not be edited by hand. To
build a different network into the executable:

    nnue embed C:\path\nnue10.nnue C:\path\pasknight_net.inc

then rebuild both build modes. The startup line names the embedded net.

--------------------------------------------------------------------------------
3. Core loop
--------------------------------------------------------------------------------
PasKnight follows the standard UCI cycle:

  - Listens for UCI commands (uci, isready, ucinewgame, position, go, stop,
    setoption, quit, plus the extra commands listed in section 13).
  - Maintains its internal board state from position commands, supporting both
    "startpos" and full FEN strings, each optionally followed by a move list.
  - Searches for the best move on "go", honouring the time control or an
    explicit depth / movetime / nodes limit, or "infinite" until "stop".
  - Streams search statistics ("info depth ... seldepth ... score ... nodes ...
    nps ... hashfull ... pv ...") and finally reports the chosen move with
    "bestmove".

--------------------------------------------------------------------------------
4. Board representation
--------------------------------------------------------------------------------
  - Bitboards (LERF layout): the board is a set of 64-bit integers, one per
    piece type per colour, with bit 0 = a1 (Little-Endian Rank-File mapping).
    A parallel 8x8 mailbox array is kept alongside for fast piece-type lookup
    on a square.
  - Magic bitboards: sliding-piece attacks (bishop, rook, queen) are generated
    by plain magic bitboard lookups — no ray-walking at runtime. Portable plain
    magics (no PEXT/BMI2) are used. The magic tables are re-verified
    constructively at startup.
  - Incremental state: king positions, castling rights, en-passant square, and
    the half-move (fifty-move) clock are tracked incrementally rather than
    recomputed. Search uses copy/restore of the game state (no separate
    make/unmake path), so all incremental fields roll back for free.
  - NNUE accumulator: updated incrementally at the single place where pieces
    are placed on or removed from the bitboards, so en passant, castling and
    promotions are handled by construction. The accumulator stack index is part
    of the game state, so copy/restore unwinds it as well.

--------------------------------------------------------------------------------
5. Move generation
--------------------------------------------------------------------------------
  - Pseudo-legal generation: all moves valid by piece-movement rules are
    generated, temporarily ignoring whether the mover's king is left in check.
  - Legality filtering: a pseudo-legal move is played, the mover's king is
    tested for check, and the move is retracted if it is illegal.
  - Attack detection uses the same magic-bitboard machinery as move generation,
    so "is square attacked" queries are fast.

--------------------------------------------------------------------------------
6. Search algorithm
--------------------------------------------------------------------------------
The search is a Negamax alpha-beta with a modern selective-search feature set.

  - Iterative deepening: depth 1, 2, 3, ... The best move and principal
    variation from the previous iteration guide move ordering at the next, and
    the engine always has a move ready if time runs out (partial-depth recovery
    keeps the last completed depth on an abort).
  - Negamax + alpha-beta pruning: the single-perspective Minimax variant with
    alpha-beta cut-offs.
  - Principal Variation Search (PVS): the first move is searched with a full
    window, the rest with null windows and re-searched only on a fail-high.
  - Aspiration windows: deeper iterations start with a narrow window around the
    previous score, widening on fail-high/low. The initial window was re-tuned
    for the NNUE evaluation scale in v2.0.
  - Transposition-table cut-offs and move ordering (see sections 7 and 8).
  - Quiescence search: at the search horizon the engine keeps searching only
    captures, promotions, and check evasions (with delta pruning and SEE
    pruning) to avoid the horizon effect. Includes stand-pat and mate detection.
  - Selective search / pruning and reductions:
      * Null-move pruning, with a zugzwang guard (only when the side to move has
        non-pawn material) and a verification search; the reduction R scales
        with depth.
      * Reverse futility pruning (static null-move pruning), with an
        "improving"-conditioned margin.
      * Futility pruning at frontier nodes.
      * Late move reductions (LMR), adjusted by move history.
      * Late move pruning (LMP).
      * Razoring (verified, shallow non-PV nodes).
      * Internal iterative reductions (IIR) when there is no TT move.
      * Singular extensions for forced/critical TT moves.
      * SEE-based capture pruning in the main search (skips clearly losing
        captures at shallow non-PV nodes).
  - Extensions: check extensions add a ply when a move gives check, so tactical
    sequences are not cut off prematurely.
  - Static Exchange Evaluation (SEE): used both in quiescence and for
    main-search move ordering / capture pruning; computed lazily at the point a
    capture is actually selected, so each capture is evaluated at most once.

--------------------------------------------------------------------------------
7. Move ordering
--------------------------------------------------------------------------------
To maximise alpha-beta cut-offs, moves are tried best-first:

  - TT / PV move first: the best move from the transposition table (or the
    previous iteration's PV) is locked into the first slot.
  - MVV-LVA for captures: most-valuable-victim / least-valuable-attacker, so
    e.g. pawn-takes-queen is tried before queen-takes-pawn.
  - SEE bad-capture demotion: captures that lose material by static exchange are
    pushed below quiet moves.
  - Killer heuristic: quiet moves that produced a beta cut-off at the same ply
    in sibling nodes are prioritised.
  - History heuristic: a two-sided (bonus/malus) from-to history table, with a
    symmetric ordering clamp, refines the ordering of the remaining quiet moves.

--------------------------------------------------------------------------------
8. Caching and draw detection
--------------------------------------------------------------------------------
  - Zobrist hashing: the position is folded into a 64-bit key by XORing random
    per-piece-per-square constants, for fast position identity.
  - Transposition table: stores score, depth, best move, and bound type for
    previously searched positions. It is runtime-resizable through the UCI Hash
    option and uses a compact 16-byte packed entry (move in 19 bits, plus score,
    depth, and flag), giving high entry density and good cache behaviour.
  - Evaluation cache (new in v2.0): a 1 MB table (2^17 entries) maps the
    position key to the network's evaluation, so a position met again is not
    evaluated twice. It returns exactly the stored value, so node counts do not
    depend on it, only speed. It is cleared whenever the network changes.
    (The pawn hash of v1.0 was removed together with the hand-crafted eval.)
  - Repetition and draw detection: game-history hashes detect three-fold
    repetition; the half-move clock enforces the fifty-move rule; and there is
    insufficient-material detection.

--------------------------------------------------------------------------------
9. Evaluation function (NNUE)
--------------------------------------------------------------------------------
The evaluation is a small efficiently-updatable neural network:

    768 piece-square inputs + side to move -> 256 -> 32 -> 1

  - Inputs: one feature per (piece, square), 12 x 64 = 768, feeding a single
    white-point-of-view accumulator of 256 neurons. A side-to-move column of
    256 weights is added at evaluation time when Black is to move, so the net
    learns the value of having the move itself.
  - Layers: clipped ReLU after each hidden layer; output in centipawns.
  - Integer arithmetic throughout: int16 weights and accumulator, int32 layer
    sums, quantisation scales QA = QB = 1024, output scale 400. The Pascal
    integer path is checked bit for bit against a Python reference.
  - Speed: AVX2 kernels (dot product, accumulator add/subtract, vector clipped
    ReLU) are chosen at runtime by CPUID; SSE2 kernels remain as a fallback and
    give identical results. "setoption name UseAVX2 value false" forces SSE2.
  - No king buckets, no second perspective (planned for after v2.0.0).

The network file format ("format 2"): 410,856 bytes, magic 'PKNU', version 2,
geometry and scales in the header, and a trailing byte-sum checksum. Every net
— the embedded one at each startup, or an external file — passes the same
checks (magic, version, geometry, scales, exact size, checksum) before it is
used. A net that fails is refused, and without a net the engine does not
search. Format-1 nets (no side-to-move input, v1.10 era) are no longer
accepted.

The embedded net of this version is nnue10.

--------------------------------------------------------------------------------
10. Network training (offline)
--------------------------------------------------------------------------------
The networks are trained on PasKnight's own games; nothing in this pipeline is
part of the normal engine binary or needed to play.

  - Data: the GenData build plays self-play games ("gendata selfplay") with a
    fixed node budget per move, from random openings or a PGN book plus a few
    random moves. Each position is stored (32 bytes) with the search score and
    the final game result.
  - Each new net labels the next generation's data, so strength builds up
    generation by generation.
  - Training is done in Python (outside this source tree): merging and
    splitting by game, training against a mix of the search score and the game
    result, and exporting the quantised .nnue file with test vectors.
  - Every new net passes engine gates (test vectors exact, an accumulator
    consistency check over long random games, bench) and is then tested in
    matches before it is promoted and embedded.

The Texel tuner of v1.0 was removed together with the hand-crafted evaluation;
it remains in the v1.0.1 tree.

--------------------------------------------------------------------------------
11. Time management
--------------------------------------------------------------------------------
PasKnight uses a stability-based time-management scheme. It computes a per-move
allocation from the remaining clock, the increment, and the moves-to-go, then:

  - shortens the effective budget once the best move has been stable for several
    consecutive iterations (an "easy move" needs less time);
  - clamps the allocation between a control-relative minimum and a maximum that
    always reserves a safety margin, so the engine does not lose on time;
  - has an emergency mid-search abort ceiling for the rare case where a single
    deepening iteration runs far over budget, with partial-depth recovery.

Move overhead (new in v2.0) is measured, not configured: the engine compares
what the GUI charged for its previous move with its own measured thinking time,
and also times its own stop-and-reply delay. The overhead is subtracted from
the clock before the allocation is computed. It uses a 1 ms clock and polls it
about every millisecond. There is no MoveOverhead option.

--------------------------------------------------------------------------------
12. Opening book
--------------------------------------------------------------------------------
PasKnight can play from opening books in PGN format placed in the same
directory as the executable. It uses book moves while the position is still in
book and switches to search once it leaves book. Moves that occur more often in
the book are chosen more often.

  - OwnBook (default true) switches the book on or off. For engine matches with
    an opening suite, set OwnBook to false.
  - BookFile selects the book file(s); the default loads every .pgn file in the
    executable's directory.
  - The book is loaded at the first "isready" (or "go"), and the engine
    reports which file(s) it loaded.

--------------------------------------------------------------------------------
13. UCI options and extra commands
--------------------------------------------------------------------------------
UCI options:

  - Hash      transposition-table size in MB (default 256, 1-4096).
  - EvalFile  the network. Default <embedded>: the net built into the
              executable. A path loads an external .nnue file instead (use an
              absolute path). If that file cannot be loaded, NO net is loaded
              and the engine will not search ("go" answers bestmove 0000), so a
              wrong path is noticed at once. <embedded> or an empty value
              returns to the built-in net.
  - UseAVX2   use the AVX2 kernels when the CPU has them (default true).
  - OwnBook   use the opening book (default true).
  - BookFile  opening-book file name (PGN, in the executable's directory).
  - LogFile   write a log file next to the executable (default false).

A depth limit is given per search with "go depth N" (the "depth" option of
earlier versions was removed in 2.0.0ß1).

The startup line, the "uci" reply and every "isready" name the network in use,
e.g. "embedded net (nnue10, 410856 bytes)" or the path of an external file.

Extra console commands beyond the UCI standard:

  - display                  ASCII board
  - bench [depth]            fixed benchmark over a set of positions
  - go perft N / perftauto   move-generator node counts
  - play                     a minimal text interface
  - help                     the full command list
  - nnue check [plies]       accumulator consistency over a long random game
  - nnue testvec <file>      the integer forward pass against test vectors
  - nnue stats               net in use, accumulator and cost counters
  - nnue embed <file.nnue> <out.inc> [name]
                             check a net and write it as pasknight_net.inc,
                             to build it into the executable
  - gendata selfplay ...     training data (GenData build only)

--------------------------------------------------------------------------------
14. Not included
--------------------------------------------------------------------------------
  - Multi-threaded search (Lazy SMP)
  - Endgame tablebases (Syzygy)
  - Larger network designs: two perspectives (side-to-move-relative output) and
    king buckets are planned for after v2.0.0.

--------------------------------------------------------------------------------
15. Licence
--------------------------------------------------------------------------------
Copyright (C) 2026 by Han Kleijn, www.hnsky.org. The source code is subject to
the terms of the Mozilla Public License, v. 2.0 (https://mozilla.org/MPL/2.0/).
