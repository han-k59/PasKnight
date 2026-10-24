#!/usr/bin/env python3
"""
export_nnue.py -- quantize a trained net and emit the .nnue file plus the
test vectors that check the Pascal port.

    python export_nnue.py --net net.npz --out pasknight.nnue \
                          --testvec testvec.txt --val val.bin

Takes numpy (.npz), not a torch checkpoint, so export needs no torch and the
quantization path can be run and checked on its own.

Three things happen here, in order, and any of them can fail the build:

  1. range check     -- can the int16 accumulator overflow for ANY legal
                        32-piece position? Checked against the worst case, not
                        against the positions that happen to be in the
                        validation set.
  2. write           -- header, weights, checksum. The header records the
                        geometry and the quantization scales, and unit_nnue
                        refuses to load on any mismatch.
  3. verify + vectors-- re-read the written file, run both the float and the
                        integer paths over real positions, report the
                        quantization-only error, and emit per-layer test
                        vectors for `nnue testvec`.
"""
import argparse, struct
import numpy as np
import nnue_quant_reference as R

REC = np.dtype([('occ', '<u8'), ('nib', 'u1', 16), ('score', '<i2'),
                ('stm', 'u1'), ('phase', 'u1'),
                ('res', 'u1'), ('ply', 'u1'), ('pad', 'u1', 2)])


def decode(path, n_max):
    """-> list of (sorted active features, label, stm)."""
    raw = np.fromfile(path, dtype=REC)[:n_max]
    out = []
    decode.labels_are_search_scores = bool((raw['res'] != 0).any())
    for r in raw:
        occ = int(r['occ'])
        nib = r['nib']
        active, k = [], 0
        while occ:
            sq = (occ & -occ).bit_length() - 1
            occ &= occ - 1
            piece = int(nib[k >> 1] & 15) if (k & 1) == 0 else int(nib[k >> 1] >> 4)
            active.append(piece * 64 + sq)
            k += 1
        out.append((sorted(active), int(r['score']), int(r['stm'])))
    return out


def write_net(path, q):
    buf = bytearray()
    has_stm = 'wstm' in q
    ver = R.FORMAT_VERSION_STM if has_stm else R.FORMAT_VERSION
    buf += struct.pack('<III', R.MAGIC, ver, R.N_IN)
    buf += struct.pack('<II', R.N_L1, R.N_L2)
    buf += struct.pack('<iii', R.QA, R.QB, R.OUTPUT_SCALE)
    assert len(buf) == 32, len(buf)

    # L1 weights feature-major: w0 is (N_L1, N_IN); the engine wants
    # [feature][neuron] so one feature's column is contiguous.
    buf += q['w0'].T.astype('<i2').tobytes()          # (N_IN, N_L1)
    buf += q['b0'].astype('<i2').tobytes()
    if has_stm:                                       # format 2 only
        buf += q['wstm'].astype('<i2').tobytes()      # (N_L1,)
    buf += q['w1'].astype('<i2').tobytes()            # (N_L2, N_L1)
    buf += q['b1'].astype('<i4').tobytes()
    buf += q['w2'].reshape(-1).astype('<i2').tobytes()
    buf += q['b2'].reshape(-1)[:1].astype('<i4').tobytes()

    buf += struct.pack('<I', sum(buf) & 0xFFFFFFFF)
    with open(path, 'wb') as f:
        f.write(buf)
    return len(buf)


def read_net(path):
    """Read back what we just wrote. Round-tripping through the file catches
    layout and endianness mistakes that comparing in-memory arrays cannot."""
    b = open(path, 'rb').read()
    magic, ver, n_in = struct.unpack('<III', b[0:12])
    n_l1, n_l2 = struct.unpack('<II', b[12:20])
    qa, qb, osc = struct.unpack('<iii', b[20:32])
    assert magic == R.MAGIC
    assert ver in (R.FORMAT_VERSION, R.FORMAT_VERSION_STM), ver
    assert (n_in, n_l1, n_l2) == (R.N_IN, R.N_L1, R.N_L2)
    assert (qa, qb, osc) == (R.QA, R.QB, R.OUTPUT_SCALE)
    assert sum(b[:-4]) & 0xFFFFFFFF == struct.unpack('<I', b[-4:])[0], "checksum"

    o = 32
    def take(cnt, dt):
        nonlocal o
        a = np.frombuffer(b, dtype=dt, count=cnt, offset=o)
        o += cnt * np.dtype(dt).itemsize
        return a.astype(np.int64)

    w0 = take(n_in * n_l1, '<i2').reshape(n_in, n_l1).T.copy()
    b0 = take(n_l1, '<i2')
    wstm = take(n_l1, '<i2') if ver == R.FORMAT_VERSION_STM else None
    w1 = take(n_l2 * n_l1, '<i2').reshape(n_l2, n_l1)
    b1 = take(n_l2, '<i4')
    w2 = take(n_l2, '<i2').reshape(1, n_l2)
    b2 = take(1, '<i4')
    assert o + 4 == len(b), (o, len(b))
    r = {'w0': w0, 'b0': b0, 'w1': w1, 'b1': b1, 'w2': w2, 'b2': b2}
    if wstm is not None:
        r['wstm'] = wstm
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--net', required=True, help='net.npz from train_nnue.py')
    ap.add_argument('--out', default='pasknight.nnue')
    ap.add_argument('--testvec', default='testvec.txt')
    ap.add_argument('--val', help='val.bin, for the quantization error report')
    ap.add_argument('--n-testvec', type=int, default=64)
    ap.add_argument('--n-verify', type=int, default=4000)
    a = ap.parse_args()

    z = np.load(a.net)
    p = (z['w0'], z['b0'], z['w1'], z['b1'], z['w2'], z['b2'])
    wstm = z['wstm'] if 'wstm' in z.files else None
    q = R.quantize(*p, wstm=wstm)
    print(f"format {R.FORMAT_VERSION_STM if wstm is not None else R.FORMAT_VERSION}: "
          f"{'768 inputs + side-to-move column' if wstm is not None else '768 inputs'}")

    # ---- 1. range check ---------------------------------------------------
    msgs, worst_acc, s_max = R.check_ranges(q)
    print(f"worst-case |accumulator| {worst_acc} / 32767 "
          f"({100*worst_acc/32767:.0f}% of int16)")
    print(f"worst-case |layer-2 sum| {s_max} / 2147483647")
    if msgs:
        for m in msgs:
            print("  EXPORT FAILED:", m)
        raise SystemExit(1)
    print("range check: PASS")

    # ---- 2. write ---------------------------------------------------------
    size = write_net(a.out, q)
    print(f"wrote {a.out} ({size} bytes)")

    qr = read_net(a.out)
    assert set(q) == set(qr), (sorted(q), sorted(qr))
    for k in q:
        assert np.array_equal(np.asarray(q[k]).reshape(-1),
                              np.asarray(qr[k]).reshape(-1)), f"round-trip {k}"
    print("file round-trip: PASS")

    # ---- 3. quantization error + test vectors -----------------------------
    if a.val:
        samples = decode(a.val, a.n_verify)
        lab_is_search = decode.labels_are_search_scores
        qe, ne = [], []
        for active, label, stm in samples:
            cp_q = R.forward_quant(active, qr, stm=stm)
            cp_f = R.forward_float(active, *p, wstm=wstm, stm=stm)
            qe.append(cp_q - cp_f)
            ne.append(cp_q - label)
        qe, ne = np.array(qe), np.array(ne)
        print(f"\nquantization error (int vs float, {len(qe)} positions):")
        print(f"  MAE {np.abs(qe).mean():.2f} cp   max {np.abs(qe).max():.1f} cp"
              f"   bias {qe.mean():+.2f} cp")
        # Agreement with the file's own label. For a distillation file that
        # label is Evaluate(), and this is the headline accuracy number. For a
        # self-play file it is the search score, and the net was deliberately
        # trained to depart from it wherever the game result disagreed -- so
        # this is a sanity check that the net is in the right universe, not a
        # quality measure. The quantization error above is the number that
        # must be small either way.
        print(f"agreement with the file's label "
              f"({'search score' if lab_is_search else 'Evaluate()'}):")
        print(f"  MAE {np.abs(ne).mean():.2f} cp   max {np.abs(ne).max():.1f} cp"
              f"   RMSE {np.sqrt((ne**2).mean()):.2f} cp")
        vec_src = [(s[0], s[2]) for s in samples[:a.n_testvec]]
    else:
        rng = np.random.default_rng(0)
        vec_src = [(sorted(rng.choice(R.N_IN, size=int(rng.integers(3, 33)),
                                      replace=False).tolist()), i % 2)
                   for i in range(a.n_testvec)]

    with open(a.testvec, 'w') as f:
        f.write("# PasKnight NNUE test vectors -- `nnue testvec <file>`\n")
        if wstm is not None:
            # Format 2: a leading w/b gives the side to move. Format-1 files
            # keep the old layout exactly, so old test vectors stay valid.
            f.write("# format 2: stm(w|b) n f1..fn accSum sSum o cp\n")
        else:
            f.write("# n f1..fn accSum sSum o cp\n")
        for active, stm in vec_src:
            cp, acc, a0, s, a1, o = R.forward_quant(active, qr, trace=True,
                                                   stm=stm)
            if wstm is not None:
                f.write('b ' if stm == 1 else 'w ')
            f.write(f"{len(active)} " + " ".join(map(str, active)) +
                    f" {int(acc.sum())} {int(s.sum())} {int(o)} {int(cp)}\n")
    print(f"\nwrote {len(vec_src)} test vectors to {a.testvec}")
    print("check the Pascal port with:  nnue testvec " + a.testvec)


if __name__ == '__main__':
    main()
