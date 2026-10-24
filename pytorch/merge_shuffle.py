#!/usr/bin/env python3
"""
merge_shuffle.py -- combine the parallel `gendata selfplay` outputs into a
shuffled training set and a validation set that shares no games with it.

    python merge_shuffle.py sp0.bin sp1.bin ... --train train.bin --val val.bin

Two things this does that a `cat` and a random permutation do not.

1. THE VALIDATION SPLIT IS BY GAME, NOT BY POSITION.

   Positions from one game are enormously correlated: same pawn structure,
   same material, forty plies apart at most. Split at random and roughly every
   validation position has a near-twin in the training set, so validation
   measures memorisation and reports a number that keeps improving while the
   net gets worse at chess. The measured SPRT then disagrees with the
   validation curve and there is nothing in the logs to explain why.

   The record format carries no game id, but it does not need one: `gendata`
   writes each game's positions consecutively with a non-decreasing ply, so a
   ply that does NOT increase marks the start of a new game. That is exact for
   every game under 256 plies and harmless above it (two long games get merged
   into one group, which only makes the split more conservative).

2. THE SHUFFLE IS OVER THE WHOLE MERGED SET.

   Training reads batches in permuted order anyway, so this matters less than
   the split, but concatenated files leave each source's games contiguous, and
   any per-instance quirk -- a different node count, a seed that drew unusual
   openings -- then arrives as a block rather than spread out.

Memory: the whole set is held in RAM. 8M positions is 256 MB, which is fine;
past roughly 40M, switch to shuffling in chunks.
"""
import argparse, glob, os
import numpy as np

REC = np.dtype([('occ', '<u8'), ('nib', 'u1', 16), ('score', '<i2'),
                ('stm', 'u1'), ('phase', 'u1'),
                ('res', 'u1'), ('ply', 'u1'), ('pad', 'u1', 2)])


def game_ids(ply):
    """Group id per record: incremented wherever ply fails to increase.

    The ply byte SATURATES at 255, so a game running past ply 255 emits a run
    of records all reading 255. Treating each of those as a new game shreds one
    long game into dozens of fragments -- and fragments of the same game then
    land on both sides of the train/val split, which is the precise leakage
    this function exists to prevent. A 255-to-255 step is therefore a
    continuation, not a boundary.

    That leaves one genuinely ambiguous case: a game that ends at or beyond ply
    255 followed by another that also reaches it. Both are then one group. That
    is conservative -- it over-merges, never over-splits -- and it is rare,
    because games this long are rare. If it is not rare in your data, lower
    SP_MAX_PLIES below 256 in the generator and the ambiguity disappears
    entirely."""
    if len(ply) == 0:
        return np.zeros(0, dtype=np.int64)
    p = ply.astype(np.int32)
    boundary = np.empty(len(p), dtype=bool)
    boundary[0] = True
    boundary[1:] = (p[1:] <= p[:-1]) & ~((p[1:] == 255) & (p[:-1] == 255))
    return np.cumsum(boundary) - 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('files', nargs='+')
    ap.add_argument('--train', default='train.bin')
    ap.add_argument('--val', default='val.bin')
    ap.add_argument('--val-games', type=float, default=0.02,
                    help='fraction of GAMES held out for validation')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args()

    # Wildcards. The Windows command prompt passes '*' and '?' through
    # unexpanded, so expand them here. Each pattern must match something, a
    # file is never taken twice, and the final list is printed before anything
    # is read -- check it: a pattern like n*_sp?.bin would also take n3b_.
    files = []
    for pat in a.files:
        if any(c in pat for c in '*?['):
            hits = sorted(glob.glob(pat))
            if not hits:
                raise SystemExit(f"pattern matches no file: {pat}")
        else:
            hits = [pat]
        for h in hits:
            if os.path.abspath(h).lower() not in {os.path.abspath(x).lower() for x in files}:
                files.append(h)
    total = sum(os.path.getsize(f) for f in files)
    print(f"{len(files)} input files, {total // 32:,} positions:")
    for f in files:
        print(f"  {f}")
    print()

    parts, gid_parts, base = [], [], 0
    for f in files:
        r = np.fromfile(f, dtype=REC)
        if len(r) == 0:
            print(f"{f}: empty, skipped")
            continue
        g = game_ids(r['ply']) + base
        base = g[-1] + 1
        parts.append(r)
        gid_parts.append(g)
        n_missing = int((r['res'] == 0).sum())
        n_sat = int((r['ply'] == 255).sum())
        print(f"{f}: {len(r)} positions, {g[-1] - g[0] + 1} games, "
              f"{len(r) / max(g[-1] - g[0] + 1, 1):.1f} per game"
              + (f", {n_missing} WITH NO RESULT" if n_missing else "")
              + (f", {n_sat} at the ply-255 cap" if n_sat else ""))
        # Cross-check this against the `kept` count the generator printed. They
        # should agree. A count well ABOVE it means boundaries are being found
        # inside games; well BELOW means games are being merged.

    if not parts:
        raise SystemExit("nothing to merge")
    rec = np.concatenate(parts)
    gid = np.concatenate(gid_parts)
    n_games = int(gid[-1]) + 1
    print(f"\nmerged: {len(rec)} positions from {n_games} games")

    rng = np.random.default_rng(a.seed)
    perm_games = rng.permutation(n_games)
    n_val_games = max(1, int(round(n_games * a.val_games)))
    val_games = np.zeros(n_games, dtype=bool)
    val_games[perm_games[:n_val_games]] = True

    is_val = val_games[gid]
    tr, va = rec[~is_val], rec[is_val]
    rng.shuffle(tr)
    rng.shuffle(va)

    tr.tofile(a.train)
    va.tofile(a.val)
    print(f"{a.train}: {len(tr)} positions from {n_games - n_val_games} games")
    print(f"{a.val}:   {len(va)} positions from {n_val_games} games "
          f"(disjoint -- no game appears in both)")

    for name, d in (('train', tr), ('val', va)):
        s = np.abs(d['score'].astype(np.int32))
        r = d['res']
        print(f"  {name}: mean |score| {s.mean():.0f} cp, "
              f"p99 {np.percentile(s, 99):.0f} cp, "
              f"results {100*(r==3).mean():.0f}/{100*(r==2).mean():.0f}/"
              f"{100*(r==1).mean():.0f} W/D/B, "
              f"mean phase {d['phase'].mean():.1f}, "
              f"mean ply {d['ply'].mean():.0f}")


if __name__ == '__main__':
    main()
