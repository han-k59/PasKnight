"""
Bit-exact Python mirror of the PasKnight quantized NNUE forward pass.

This file is the SPECIFICATION that unit_nnue.pas must reproduce integer for
integer. export_nnue.py uses it to emit test vectors, so the Pascal port can
be checked to the last bit without playing a single game.

Architecture:  768 -> 256 (CReLU) -> 32 (CReLU) -> 1

Format 2 adds a side-to-move input: one extra column of 256 L1 weights (wstm),
added to the accumulator when BLACK is to move, just before the first CReLU.
It is NOT part of the incrementally updated int16 accumulator. The engine adds
it at eval time with a saturating 16-bit add; since the CReLU clamps to
[0, QA] anyway, that equals the exact sum clamped, which is what is computed
here. The output stays white-POV; a format-2 net learns tempo itself, so the
engine adds no tempo bonus for it.

Integer format (see REPORT.md "Quantization" for why these scales):
  L1 weights/bias   int16, scale QA
  accumulator       int16, scale QA
  L2/L3 weights     int16, scale QB        <-- int16, NOT int8; see REPORT.md
  L2/L3 biases      int32, scale QA*QB
  layer sums        int32
  final scaling     Int64 (o*OUTPUT_SCALE overflows int32)
"""
import numpy as np

N_IN, N_L1, N_L2 = 768, 256, 32

QA = 1024           # activation scale: CReLU output lives in [0, QA]
QB = 1024           # weight scale for layers 2 and 3
OUTPUT_SCALE = 400  # float net output * OUTPUT_SCALE = centipawns

# Training-time weight clips. L1_CLIP is what keeps the int16 accumulator
# from overflowing in the worst case (bias + 32 pieces); see check_ranges.
L1_CLIP = 0.95
LN_CLIP = 1.98

MAGIC = 0x504B4E55   # 'PKNU'
FORMAT_VERSION = 1       # 768 inputs
FORMAT_VERSION_STM = 2   # 768 inputs + side-to-move column


def trunc_div(a, b):
    """Pascal 'div' truncates toward zero; Python '//' floors. They differ on
    negative operands -- the classic source of float/int mismatch."""
    a, b = int(a), int(b)
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def quantize(w0, b0, w1, b1, w2, b2, wstm=None):
    """Float params -> integer params.
    Shapes: w0 (256,768) b0 (256,) w1 (32,256) b1 (32,) w2 (1,32) b2 (1,)
            wstm (256,) or None"""
    q = {
        'w0': np.rint(w0 * QA).astype(np.int64),
        'b0': np.rint(b0 * QA).astype(np.int64),
        'w1': np.rint(w1 * QB).astype(np.int64),
        'b1': np.rint(b1 * QA * QB).astype(np.int64),
        'w2': np.rint(w2 * QB).astype(np.int64),
        'b2': np.rint(b2 * QA * QB).astype(np.int64),
    }
    if wstm is not None:
        q['wstm'] = np.rint(np.asarray(wstm).reshape(-1) * QA).astype(np.int64)
    return q


def forward_float(active, w0, b0, w1, b1, w2, b2, wstm=None, stm=0):
    """Reference float path. `active` = indices of the 1-valued inputs,
    stm = 1 when Black is to move (used only by a format-2 net)."""
    pre = w0[:, active].sum(axis=1) + b0
    if wstm is not None and stm == 1:
        pre = pre + np.asarray(wstm).reshape(-1)
    h0 = np.clip(pre, 0.0, 1.0)
    h1 = np.clip(w1 @ h0 + b1, 0.0, 1.0)
    return float((w2 @ h1 + b2).ravel()[0]) * OUTPUT_SCALE


def forward_quant(active, q, trace=False, stm=0):
    """Integer path. Mirrors unit_nnue.pas line for line. The traced `acc` is
    the accumulator itself, WITHOUT the side-to-move column."""
    acc = q['b0'].copy()
    for f in active:
        acc += q['w0'][:, f]              # int16 accumulator
    pre = acc + q['wstm'] if ('wstm' in q and stm == 1) else acc
    a0 = np.clip(pre, 0, QA)

    s = q['b1'] + q['w1'] @ a0            # int32, scale QA*QB
    a1 = np.clip(np.array([trunc_div(v + QB // 2, QB) for v in s]), 0, QA)

    o = int(q['b2'][0] + q['w2'][0] @ a1)  # int32, scale QA*QB
    cp = trunc_div(o * OUTPUT_SCALE, QA * QB)   # Int64 product
    return (cp, acc, a0, s, a1, o) if trace else cp


def check_ranges(q):
    """Run at export time so an overflow is a build failure, not a silent
    hundreds-of-centipawns bug during search."""
    msgs = []
    if np.abs(q['w0']).max() > 32767 or np.abs(q['b0']).max() > 32767:
        msgs.append("L1 weights/biases exceed int16")
    if 'wstm' in q and np.abs(q['wstm']).max() > 32767:
        msgs.append("side-to-move column exceeds int16")
    if np.abs(q['w1']).max() > 32767 or np.abs(q['w2']).max() > 32767:
        msgs.append("L2/L3 weights exceed int16")
    if np.abs(q['b1']).max() > 2**31 - 1 or np.abs(q['b2']).max() > 2**31 - 1:
        msgs.append("L2/L3 biases exceed int32")
    # Worst case accumulator: bias + the 32 largest-magnitude columns per row.
    worst = (np.abs(q['b0']) +
             np.sort(np.abs(q['w0']), axis=1)[:, -32:].sum(axis=1)).max()
    if worst > 32767:
        msgs.append(f"int16 accumulator can overflow (worst case {worst}); "
                    f"lower L1_CLIP or widen the accumulator to int32")
    # int32 headroom on the layer sums.
    s_max = N_L1 * QA * int(np.abs(q['w1']).max()) + int(np.abs(q['b1']).max())
    if s_max > 2**31 - 1:
        msgs.append(f"L2 sum can overflow int32 ({s_max})")
    return msgs, int(worst), int(s_max)
