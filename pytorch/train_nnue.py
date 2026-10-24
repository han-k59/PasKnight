#!/usr/bin/env python3
"""
train_nnue.py -- train PasKnight's 768-256-32-1 NNUE.

Two targets, selected by --loss:

  --loss wdl     (v2.0, default)  search score blended with the game result:

                     loss = MSE( sigmoid(pred/K),
                                 lam * sigmoid(score/K) + (1-lam) * result )

                 This is the standard NNUE objective. It needs data from
                 `gendata selfplay`, which records a game result alongside the
                 search score.

  --loss huber   (v1.10)  plain regression on exact centipawns. This is the
  --loss mse     DISTILLATION objective: it reproduces Evaluate(), and its
                 strength ceiling is Evaluate(). Kept so the v2.0.0alpha1
                 result stays reproducible, not because it is the thing to run.

    python train_nnue.py --train sp_train.bin --val sp_val.bin --out net.npz

Reads the 32-byte record written by `gendata` (see pasknight_nnue_gendata.inc):
    QWord occ | byte[16] nibbles | int16 score | byte stm | byte phase
              | byte res | byte ply | 2 pad

`res` is the game result from WHITE's point of view: 0 unknown, 1 black won,
2 draw, 3 white won. Files written before v2.0 have it zero throughout, which
is why 0 means "absent" rather than "black won" -- see the .inc header.

Writes net.npz (numpy, for export_nnue.py) and net.pt (torch checkpoint).

----------------------------------------------------------------------------
WHY K = OUTPUT_SCALE, AND WHY THAT MATTERS FOR THE QUANTIZATION

The net's float output is in units of OUTPUT_SCALE centipawns: the exported
integer path computes cp = o * OUTPUT_SCALE / (QA*QB), and nnue_quant_reference
asserts OUTPUT_SCALE against the file header. So with K = OUTPUT_SCALE = 400
the blend is just sigmoid(out) on the net's own output units, and NOTHING in
the quantization path changes -- no re-derivation of scales, no new range
check, the existing testvec path stays valid.

K is still exposed as a knob because it controls how steep the win-probability
mapping is, but changing it does NOT require changing OUTPUT_SCALE: the code
scales by OUTPUT_SCALE/K explicitly. Leave OUTPUT_SCALE alone. If you ever do
change OUTPUT_SCALE, nnue_quant_reference.py, export_nnue.py and the loader in
unit_nnue.pas all have to agree, and the .nnue header check will fail loudly
if they do not.
"""
import argparse, time
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

N_IN, N_L1, N_L2 = 768, 256, 32
OUTPUT_SCALE = 400.0     # must match nnue_quant_reference.py / unit_nnue.pas
L1_CLIP = 0.95           # keeps the int16 accumulator inside range
# The L1 BIAS was never clipped, and the export's worst case is
# |bias| + the 32 largest |weights| of a neuron. With weights at the clip that
# is 32 * 973 = 31136 in integer units, leaving 1631 for the bias. Clipping the
# bias at 1.5 (1536) makes the range check pass BY CONSTRUCTION, whatever the
# data. It does not bind for the nets so far (their largest bias ~0.7).
FT_BIAS_CLIP = 1.5
LN_CLIP = 1.98           # keeps L2/L3 weights inside int16 at QB=1024
PAD = N_IN               # padding feature; its embedding row is held at zero
# --stm EXPERIMENT: one extra input, active when Black is to move. It gets its
# own embedding row after PAD and a 33rd feature slot (a position can hold all
# 32 pieces). The output stays white-POV; the net can then learn the value of
# having the move instead of relying on the engine's fixed tempo bonus.
STM_IDX = N_IN + 1

REC = np.dtype([('occ', '<u8'), ('nib', 'u1', 16), ('score', '<i2'),
                ('stm', 'u1'), ('phase', 'u1'),
                ('res', 'u1'), ('ply', 'u1'), ('pad', 'u1', 2)])

# res byte -> white-POV result in [0,1]. Index 0 (unknown) is never used; the
# loader removes those records or refuses outright.
RES_TO_W = np.array([np.nan, 0.0, 0.5, 1.0], dtype=np.float32)


def load(path, max_n=None, max_label=0, need_wdl=False, drop_missing=False,
         use_stm=False):
    """Decode the packed records into a dense (N, 32) feature-index array.

    Costs 64 MB per million positions. For datasets that do not fit, decode
    per batch instead -- the decode is pure numpy and cheap."""
    # Memory-mapped, not read: the 32-byte records stay on disk and are paged
    # in chunk by chunk by the decode below (7 GB less RAM at 220M positions).
    raw = np.memmap(path, dtype=REC, mode='r')
    if max_n:
        raw = raw[:max_n]
    n = len(raw)
    if n == 0:
        raise SystemExit(f"{path}: empty")

    # Decode in chunks. Decoding the whole file at once builds several int64
    # index arrays of ~18 entries per position (about 0.7 kB per position at
    # the peak -- tens of GB at 80M+ positions). Per chunk the result is
    # bit-identical and the peak is a few hundred MB.
    feats = np.full((n, 33 if use_stm else 32), PAD, dtype=np.int16)
    counts = np.empty(n, dtype=np.uint8)       # pieces per position, <= 32
    if use_stm:
        feats[raw['stm'] == 1, 32] = STM_IDX
    CH = 1 << 22
    for c0 in range(0, n, CH):
        part = raw[c0:c0 + CH]
        m = len(part)
        occ8 = np.ascontiguousarray(part['occ']).view(np.uint8).reshape(m, 8)
        bits = np.unpackbits(occ8,
                             axis=1, bitorder='little')      # (m, 64), col = LERF sq
        nib = np.ascontiguousarray(part['nib'])
        pieces = np.stack([nib & 15, nib >> 4], axis=-1).reshape(m, 32)  # low nibble first

        rows, cols = np.nonzero(bits)    # sorted by row then col == ascending square
        cnt = bits.sum(1).astype(np.int64)
        k = np.arange(len(rows), dtype=np.int64) - np.repeat(np.cumsum(cnt) - cnt, cnt)

        feats[c0 + rows, k] = pieces[rows, k].astype(np.int16) * 64 + cols.astype(np.int16)
        counts[c0:c0 + m] = cnt

    y = raw['score'].astype(np.float32) / OUTPUT_SCALE
    absscore = np.abs(raw['score'].astype(np.int32))
    res_byte = raw['res']
    if res_byte.max() > 3:
        raise SystemExit(f"{path}: result byte out of range ({res_byte.max()}). "
                         f"This file was not written by `gendata selfplay`.")
    has_wdl = res_byte != 0
    w = RES_TO_W[np.clip(res_byte, 0, 3)]

    keep = absscore < 30000                    # drop clamped rails
    if max_label:
        keep &= absscore <= max_label

    n_missing = int((~has_wdl).sum())
    if need_wdl and n_missing:
        if not drop_missing:
            raise SystemExit(
                f"{path}: {n_missing} of {n} records carry no game result.\n"
                f"  --loss wdl needs data from `gendata selfplay`. A file from "
                f"the old `gendata <count> <file>` path has no result byte, and "
                f"training the blend against a fabricated one is training "
                f"against noise.\n"
                f"  Use --loss huber for distillation data, or "
                f"--drop-missing-wdl to keep only the records that have a "
                f"result.")
        keep &= has_wdl

    # --- sampler inspection ------------------------------------------------
    # Cheap, and it is what caught the four-queens positions and the 2%
    # synthetic share last time. Read it before starting a long run.
    print(f"{path}: {n} records, {(~keep).sum()} dropped, "
          f"mean |score| {absscore.mean():.1f} cp, "
          f"p99 {np.percentile(absscore, 99):.0f} cp, "
          f"max {absscore.max()} cp, pieces/pos {counts.mean():.1f}")
    if has_wdl.any():
        kb = res_byte[keep]
        tot = max(len(kb), 1)
        # int(): on Windows with NumPy 1.x a count is int32, and 100 * count
        # overflows past ~21M -- a display-only bug that printed negative %.
        nW, nD, nB = int((kb == 3).sum()), int((kb == 2).sum()), int((kb == 1).sum())
        print(f"  results (white POV): {100*nW/tot:.1f}% W / "
              f"{100*nD/tot:.1f}% D / {100*nB/tot:.1f}% B"
              f"   mean ply {raw['ply'][keep].mean():.0f}")
        if abs(nW - nB) > 0.15 * tot:
            print("  NOTE: the win/loss split is lopsided. Self-play from a "
                  "symmetric start should be near-symmetric; check the opening "
                  "sampler and the seeds.")
    if np.percentile(absscore, 99) > 4000:
        print(f"  NOTE: heavy label tail. The clipped-ReLU output saturates on "
              f"very large evals, and those positions are ones the search "
              f"already understands. Consider --max-label 4000.")
    phase = np.array(raw['phase'])
    if keep.all():
        # The normal case for self-play data: nothing dropped. Return the
        # arrays as they are. 'feats[keep]' would build a second full copy of
        # the feature array (13.7 GB at 223M positions) just to drop nothing.
        return feats, y, phase, w
    # Compact in place, chunk by chunk. The destination never overtakes the
    # source (dst <= c0), so no element is overwritten before it is read, and
    # the only extra memory is one chunk.
    dst = 0
    CH = 1 << 22
    for c0 in range(0, n, CH):
        k = keep[c0:c0 + CH]
        m = int(k.sum())
        feats[dst:dst + m] = feats[c0:c0 + CH][k]
        y[dst:dst + m] = y[c0:c0 + CH][k]
        phase[dst:dst + m] = phase[c0:c0 + CH][k]
        w[dst:dst + m] = w[c0:c0 + CH][k]
        dst += m
    return feats[:dst], y[:dst], phase[:dst], w[:dst]


class Net(nn.Module):
    def __init__(self, use_stm=False):
        super().__init__()
        self.use_stm = use_stm
        # EmbeddingBag(mode='sum') fuses the gather and the sum. nn.Embedding
        # would materialise a (batch, 32, N_L1) intermediate first -- about
        # 270 MB at batch 8192 -- which dominates runtime on CPU.
        self.ft = nn.EmbeddingBag(N_IN + (2 if use_stm else 1), N_L1,
                                  mode='sum', padding_idx=PAD)
        self.ft_bias = nn.Parameter(torch.zeros(N_L1))
        self.l2 = nn.Linear(N_L1, N_L2)
        self.l3 = nn.Linear(N_L2, 1)
        nn.init.uniform_(self.ft.weight, -0.05, 0.05)
        with torch.no_grad():
            self.ft.weight[PAD].zero_()

    def forward(self, idx):
        h0 = torch.clamp(self.ft(idx) + self.ft_bias, 0.0, 1.0)
        h1 = torch.clamp(self.l2(h0), 0.0, 1.0)
        return self.l3(h1).squeeze(-1)

    def clip(self):
        """Quantization-aware clipping. Enforced every step so the exported
        integer weights never saturate -- an overflow found at export time is a
        build failure, but an overflow found at search time is a mystery."""
        with torch.no_grad():
            self.ft.weight.clamp_(-L1_CLIP, L1_CLIP)
            self.ft_bias.clamp_(-FT_BIAS_CLIP, FT_BIAS_CLIP)
            self.ft.weight[PAD].zero_()
            self.l2.weight.clamp_(-LN_CLIP, LN_CLIP)
            self.l3.weight.clamp_(-LN_CLIP, LN_CLIP)


def wdl_loss(out, tgt_score, result, lam, k_ratio):
    """The standard NNUE objective.

    out and tgt_score are in the net's output units (centipawns/OUTPUT_SCALE);
    k_ratio = OUTPUT_SCALE/K converts them to the sigmoid's units, so K is a
    free knob that does not touch the quantization scales.

    MSE in probability space, not in centipawn space, is the whole point: it
    weights a 50 cp error near equality far more heavily than a 50 cp error at
    +900, which is the correct weighting for a search that only has to order
    sibling moves. It is also what makes a 0/0.5/1 game result usable as a
    target at all."""
    p = torch.sigmoid(out * k_ratio)
    t = lam * torch.sigmoid(tgt_score * k_ratio) + (1.0 - lam) * result
    return F.mse_loss(p, t)


@torch.no_grad()
def evaluate(model, feats, y, w, dev, lam, k_ratio, bs=16384):
    """Returns (val_loss, cp MAE, cp RMSE, cp max, r, err).

    val_loss is the model-selection metric and is computed at a FIXED lambda,
    not at the current epoch's annealed one: a target that moves between
    epochs makes the per-epoch numbers incomparable and picks whichever epoch
    happened to have the easiest target.

    The centipawn statistics are DIAGNOSTIC ONLY under --loss wdl. They measure
    agreement with the search score, and agreement with the search score is
    exactly what lambda < 1 deliberately trades away. Expect MAE to rise as
    lambda anneals down. That is the objective working, not the net getting
    worse."""
    model.eval()
    preds = []
    for i in range(0, len(feats), bs):
        idx = torch.from_numpy(feats[i:i + bs].astype(np.int64)).to(dev)
        preds.append(model(idx).cpu().numpy())
    pf = np.concatenate(preds)

    if w is not None:
        out_t = torch.from_numpy(pf)
        loss = float(wdl_loss(out_t, torch.from_numpy(y),
                              torch.from_numpy(w), lam, k_ratio))
    else:
        loss = float(np.mean((pf - y) ** 2))

    p = pf * OUTPUT_SCALE
    t = y * OUTPUT_SCALE
    err = p - t
    return (loss, np.abs(err).mean(), np.sqrt((err ** 2).mean()),
            np.abs(err).max(), np.corrcoef(p, t)[0, 1], err)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--train', required=True)
    ap.add_argument('--val', required=True)
    ap.add_argument('--out', default='net.npz')
    ap.add_argument('--epochs', type=int, default=40)
    ap.add_argument('--bs', type=int, default=4096)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--loss', choices=['wdl', 'mse', 'huber'], default='wdl')
    ap.add_argument('--k', type=float, default=400.0,
                    help='centipawns per sigmoid unit. Smaller = steeper = '
                         'more weight on near-equal positions')
    ap.add_argument('--lambda-start', type=float, default=1.0,
                    help='weight on the search score at epoch 1')
    ap.add_argument('--lambda-end', type=float, default=0.7,
                    help='weight on the search score at the last epoch; '
                         'annealed linearly between the two')
    ap.add_argument('--val-lambda', type=float, default=None,
                    help='fixed lambda for the validation loss; '
                         'defaults to --lambda-end')
    ap.add_argument('--drop-missing-wdl', action='store_true',
                    help='keep only records that carry a game result, instead '
                         'of refusing the file')
    ap.add_argument('--max-label', type=int, default=0,
                    help='drop positions with |label| above this many cp; '
                         '0 keeps everything')
    ap.add_argument('--huber-delta', type=float, default=1.0,
                    help='in output units; 1.0 == 400 cp')
    ap.add_argument('--stm', action=argparse.BooleanOptionalAction, default=True,
                    help='side-to-move input (format 2, the default since '
                         'NNUE5s). --no-stm trains a format-1 net as NNUE1-5 '
                         'were, e.g. to reproduce one.')
    ap.add_argument('--max-train', type=int, default=0,
                    help='use only the first N training positions (the file '
                         'is already shuffled), for quick A/B experiments')
    ap.add_argument('--device', default='cuda' if torch.cuda.is_available() else 'cpu')
    ap.add_argument('--threads', type=int, default=0,
                    help='torch CPU threads; 0 leaves the default')
    a = ap.parse_args()

    use_wdl = (a.loss == 'wdl')
    k_ratio = OUTPUT_SCALE / a.k
    val_lam = a.val_lambda if a.val_lambda is not None else a.lambda_end

    Xtr, ytr, _, wtr = load(a.train, max_n=a.max_train or None,
                            max_label=a.max_label, need_wdl=use_wdl,
                            drop_missing=a.drop_missing_wdl, use_stm=a.stm)
    Xva, yva, pva, wva = load(a.val, max_label=a.max_label, need_wdl=use_wdl,
                              drop_missing=a.drop_missing_wdl, use_stm=a.stm)
    print("side-to-move input ON (format 2)" if a.stm else
          "side-to-move input OFF (--no-stm: format 1, as NNUE1-5)")
    if not use_wdl:
        wtr = wva = None

    if a.threads:
        torch.set_num_threads(a.threads)
    dev = torch.device(a.device)
    print(f"device {a.device}, torch {torch.__version__}, "
          f"{torch.get_num_threads()} threads")
    if use_wdl:
        print(f"loss wdl: K={a.k:.0f} cp, lambda {a.lambda_start:.2f} -> "
              f"{a.lambda_end:.2f} over {a.epochs} epochs, "
              f"validation at lambda {val_lam:.2f}")
    model = Net(use_stm=a.stm).to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=0.0)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=a.epochs)

    ytr_t = torch.from_numpy(ytr)
    wtr_t = torch.from_numpy(wtr) if use_wdl else None
    n = len(Xtr)
    best = float('inf')

    for ep in range(a.epochs):
        model.train()
        frac = ep / max(a.epochs - 1, 1)
        lam = a.lambda_start + (a.lambda_end - a.lambda_start) * frac
        perm = np.random.permutation(n)
        t0, tot, nb = time.time(), 0.0, 0
        for i in range(0, n, a.bs):
            sel = perm[i:i + a.bs]
            idx = torch.from_numpy(Xtr[sel].astype(np.int64)).to(dev)
            tgt = ytr_t[sel].to(dev)
            out = model(idx)
            if use_wdl:
                loss = wdl_loss(out, tgt, wtr_t[sel].to(dev), lam, k_ratio)
            elif a.loss == 'mse':
                loss = F.mse_loss(out, tgt)
            else:
                loss = F.huber_loss(out, tgt, delta=a.huber_delta)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            model.clip()
            tot += loss.item(); nb += 1
        sched.step()

        vl, mae, rmse, mx, corr, _ = evaluate(model, Xva, yva, wva, dev,
                                              val_lam, k_ratio)
        print(f"epoch {ep+1:3d}/{a.epochs}  lam {lam:.2f}  "
              f"loss {tot/nb:.6f}  val {vl:.6f}  "
              f"[vs search: MAE {mae:7.2f} cp  RMSE {rmse:7.2f}  "
              f"r {corr:.4f}]  [{time.time()-t0:.0f}s]")
        if vl < best:
            best = vl
            save(model, a.out)

    print(f"\nbest validation loss {best:.6f} -> {a.out}")

    # Error by game phase: a net that fits well in the middlegame and badly in
    # the endgame will still look fine on the headline number, and the endgame
    # is where a mismatch costs the most Elo per centipawn.
    vl, mae, rmse, mx, corr, err = evaluate(model, Xva, yva, wva, dev,
                                            val_lam, k_ratio)
    print("\nerror vs search score by phase (0 = pure endgame, 24 = opening):")
    for lo, hi in [(0, 3), (4, 8), (9, 14), (15, 19), (20, 24)]:
        m = (pva >= lo) & (pva <= hi)
        if m.sum():
            print(f"  phase {lo:2d}-{hi:2d}: n={m.sum():8d}  "
                  f"MAE {np.abs(err[m]).mean():7.2f} cp  "
                  f"max {np.abs(err[m]).max():8.1f} cp")
    if use_wdl:
        print("  (these are diagnostics, not the objective -- see evaluate())")


def save(model, path):
    sd = {k: v.detach().cpu().numpy() for k, v in model.state_dict().items()}
    extra = {}
    if getattr(model, 'use_stm', False):
        extra['wstm'] = sd['ft.weight'][STM_IDX].copy()      # (N_L1,)
    np.savez(path, **extra,
             w0=sd['ft.weight'][:N_IN].T.copy(),   # (N_L1, N_IN)
             b0=sd['ft_bias'],
             w1=sd['l2.weight'], b1=sd['l2.bias'],
             w2=sd['l3.weight'], b2=sd['l3.bias'])
    torch.save(model.state_dict(), path.replace('.npz', '.pt'))


if __name__ == '__main__':
    main()
