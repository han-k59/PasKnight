#!/usr/bin/env python3
"""
make_smoke_data.py -- synthetic training data with a label you already know.

    python make_smoke_data.py

Writes smoke_train.bin (400k) and smoke_val.bin (40k) in exactly the record
format the Pascal `gendata` command emits, so the whole Python pipeline can be
exercised before the engine side is built.

The label here is a PURE LINEAR function of the 768 features -- material plus a
small piece-square table, tapered by phase the way Evaluate() is. A
768-256-32-1 net can represent that essentially exactly, so training should
drive validation MAE to a couple of centipawns or less.

That makes this a real test, not just a "does it crash" test:

Material is drawn symmetrically and then perturbed slightly, so labels stay in
the range a real game produces (mean |label| a few hundred cp). The generated
set has a mean |label| of roughly 300 cp, so:

  * MAE in the low single digits across EVERY phase bucket -> decode, model,
                               loss, clipping, export and quantization are all
                               wired up correctly.
  * MAE stuck near the mean |label| -> the net is predicting the mean. The
                               label is not reaching the loss, or the learning
                               rate is far off.
  * MAE flat from early on, somewhere in between -> the feature decode is
                               wrong; the net is seeing the wrong squares or
                               the wrong pieces and is fitting noise.
  * MAE fine in the low-phase buckets but bad in the high-phase ones -> the
                               label distribution has a heavy tail again;
                               check the p99 printed above.

Do NOT read anything into these numbers about how well the real net will match
Evaluate(). This target is linear by construction; Evaluate() is not.
"""
import numpy as np

REC = np.dtype([('occ', '<u8'), ('nib', 'u1', 16), ('score', '<i2'),
                ('stm', 'u1'), ('phase', 'u1'),
                ('res', 'u1'), ('ply', 'u1'), ('pad', 'u1', 2)])

# Synthetic game results, so the --loss wdl path has a smoke test too. The
# result is DRAWN from the label: p(white win) = sigmoid(score/400), with a
# draw band around equality. That makes the WDL target unbiased with respect
# to the same linear function the score encodes, so a correctly wired blended
# loss still recovers that function at any lambda. If training with
# --loss wdl gives a much worse fit than --loss huber on this data, the blend
# is wired up wrong -- the data cannot be blamed.
K_SMOKE = 400.0

# piece index: 0=wP 1=wN 2=wB 3=wR 4=wQ 5=wK  6=bP .. 11=bK
VAL = np.array([100, 320, 330, 500, 900, 0], dtype=np.int32)
PHASE_W = np.array([0, 1, 1, 2, 4, 0], dtype=np.int32)
MAX_PHASE = 24

rng = np.random.default_rng(20260919)

# A toy PST: centre bonus in the middlegame, advancement bonus in the endgame.
# Square index is LERF (a1 = 0), matching the engine's SquareIndex.
_f = np.arange(64) % 8
_r = np.arange(64) // 8
CENTRE = (3.5 - np.abs(_f - 3.5)) + (3.5 - np.abs(_r - 3.5))
PST_MG = np.rint(CENTRE * 4).astype(np.int32)      # white POV
PST_EG = np.rint((_r - 3.5) * 3).astype(np.int32)


def label(pieces, squares):
    """Tempo-free, white-POV, tapered. Same shape as the real target."""
    mg = eg = phase = 0
    for p, s in zip(pieces, squares):
        side = 1 if p < 6 else -1
        base = p if p < 6 else p - 6
        sq = s if p < 6 else (s ^ 56)          # mirror rank for black
        phase += PHASE_W[base]
        v = int(VAL[base])
        mg += side * (v + int(PST_MG[sq]))
        eg += side * (v + int(PST_EG[sq]))
    phase = min(phase, MAX_PHASE)
    return (mg * phase + eg * (MAX_PHASE - phase)) // MAX_PHASE, phase


def draw_material():
    """Symmetric template, then drop up to three pieces from one side.

    Drawing each piece independently produces four-queens-against-a-bare-king
    positions: labels in the thousands of centipawns that no search tree
    contains and that the clipped-ReLU output range cannot express without
    saturating. Bounded imbalance keeps the labels in the range the engine
    actually meets."""
    n = {0: int(rng.integers(0, 9)),          # pawns
         1: int(rng.integers(0, 3)),          # knights
         2: int(rng.integers(0, 3)),          # bishops
         3: int(rng.integers(0, 3)),          # rooks
         4: 1 if rng.random() < 0.40 else 0}  # queens
    if rng.random() < 0.5:                    # thin it out half the time
        n = {k: v // 2 for k, v in n.items()}

    bag = []
    for base, cnt in n.items():
        bag += [base] * cnt + [base + 6] * cnt

    side_white = rng.random() < 0.5
    for _ in range(int(rng.integers(0, 4))):
        cand = [i for i, p in enumerate(bag) if (p < 6) == side_white]
        if not cand:
            break
        bag.pop(int(rng.choice(cand)))
    return [5, 11] + bag


def make(n, path):
    recs = np.zeros(n, dtype=REC)
    for i in range(n):
        pieces = draw_material()
        squares = list(rng.choice(64, size=len(pieces), replace=False))

        keep_p, keep_s = [], []
        for p, s in zip(pieces, squares):
            if p in (0, 6) and (s < 8 or s >= 56):   # no pawns on rank 1 or 8
                continue
            keep_p.append(int(p)); keep_s.append(int(s))

        order = np.argsort(keep_s)
        sq_sorted = [keep_s[j] for j in order]
        pc_sorted = [keep_p[j] for j in order]

        occ = 0
        for s in sq_sorted:
            occ |= 1 << s
        nib = np.zeros(16, dtype=np.uint8)
        for k, p in enumerate(pc_sorted):
            if k % 2 == 0:
                nib[k >> 1] |= p
            else:
                nib[k >> 1] |= p << 4

        sc, ph = label(pc_sorted, sq_sorted)
        pw = 1.0 / (1.0 + np.exp(-sc / K_SMOKE))
        u = rng.random()
        # 20% of the probability mass around equality becomes a draw, split
        # evenly off the two tails, so the result distribution looks like a
        # real engine's rather than a coin flip.
        if abs(pw - 0.5) < 0.10:
            res = 2
        else:
            res = 3 if u < pw else 1
        recs[i]['occ'] = occ
        recs[i]['nib'] = nib
        recs[i]['score'] = int(np.clip(sc, -30000, 30000))
        recs[i]['stm'] = i & 1
        recs[i]['phase'] = ph
        recs[i]['res'] = res
        recs[i]['ply'] = min(255, int(rng.integers(8, 120)))
    recs.tofile(path)
    s = np.abs(recs['score'].astype(int))
    r = recs['res']
    print(f"{path}: {n} records, {n*32} bytes, mean |score| {s.mean():.0f} cp, "
          f"p99 {np.percentile(s,99):.0f} cp, mean phase {recs['phase'].mean():.1f}, "
          f"results {100*(r==3).mean():.0f}/{100*(r==2).mean():.0f}/"
          f"{100*(r==1).mean():.0f} W/D/B")


if __name__ == '__main__':
    make(400_000, 'smoke_train.bin')
    make(40_000, 'smoke_val.bin')
    print("\nnow run:")
    print("  python train_nnue.py --train smoke_train.bin --val smoke_val.bin "
          "--out smoke.npz --epochs 15 --loss huber")
    print("  expect low single-digit cp MAE in every phase bucket by epoch 15")
    print("\nand the same data through the v2.0 objective:")
    print("  python train_nnue.py --train smoke_train.bin --val smoke_val.bin "
          "--out smoke_wdl.npz --epochs 15 --loss wdl --lambda-start 1.0 "
          "--lambda-end 0.7")
    print("  expect the validation loss to fall monotonically and the "
          "diagnostic cp MAE to land in the tens, not the hundreds. Hundreds "
          "means the blend is wired wrong, because this label is recoverable "
          "at any lambda by construction.")
