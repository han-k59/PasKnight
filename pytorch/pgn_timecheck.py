#!/usr/bin/env python3
"""
pgn_timecheck.py -- is the fixed-nodes / fixed-time gap about clock, not eval?

    python pgn_timecheck.py nnue2b_vs_hce_40-7.pgn [--period 40 --base 7]

Reads a cutechess-cli PGN whose move comments look like
    {+0.34/12 0.156s}     {-M5/20 0.08s}     {book}
and reports, per engine:

  results        W/D/L and every non-ordinary termination (time forfeit,
                 illegal move, disconnect, adjudication) with its count
  time per move  mean, median, p99 and max, against the nominal slice
                 base/period
  period usage   seconds used per completed time-control period (moves 1-40,
                 41-80, ...). Unspent time carries over into the next period,
                 so a single period may legitimately use more than the base.
  clock left     the clock at the end of each period, carry-over included --
                 the real margin to a flag. Below zero means the side
                 overstepped and survived only through a GUI time margin.
  depth by stage mean completed depth in move-number bins, so a speed deficit
                 shows up as a depth deficit where it happens

Terminations come from the [Termination] tag (cutechess-cli) or, when that tag
is absent (cutechess GUI), from the reason in the last move comment.

Engines are keyed by the PGN White/Black names, so give them distinct names in
cutechess (name=NNUE2b / name=HCE) -- two players both called "PasKnight"
would be pooled into one row.
"""
import argparse
import math
import re
import statistics as st
from collections import defaultdict

TAG = re.compile(r'\[(\w+)\s+"([^"]*)"\]')
COMMENT = re.compile(r'\{([^}]*)\}')
EVAL = re.compile(r'([+-]?(?:M?\d+(?:\.\d+)?))/(\d+)\s+([\d.]+)s')
TOK = re.compile(r'\{[^}]*\}|[^\s{}]+')
MOVENUM = re.compile(r'^\d+\.+$')
RESULTS = {'1-0', '0-1', '1/2-1/2', '*'}
BINS = [(1, 20), (21, 40), (41, 60), (61, 80), (81, 9999)]
# Final-comment phrases of the cutechess GUI -> cutechess-cli Termination names.
TAIL_REASONS = [('loses on time', 'time forfeit'),
                ('illegal move', 'illegal move'),
                ('disconnects', 'abandoned'),
                ('connection stalls', 'stalled connection'),
                ('adjudication', 'adjudication')]


def games(path):
    """Yield (tags, movetext) per game."""
    tags, moves, in_moves = {}, [], False
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            s = line.strip()
            if s.startswith('['):
                if in_moves:
                    yield tags, ' '.join(moves)
                    tags, moves, in_moves = {}, [], False
                m = TAG.match(s)
                if m:
                    tags[m.group(1)] = m.group(2)
            elif s:
                in_moves = True
                moves.append(s)
    if tags:
        yield tags, ' '.join(moves)


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p / 100 * len(xs)))] if xs else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('pgn')
    ap.add_argument('--period', type=int, default=40, help='moves per control')
    ap.add_argument('--base', type=float, default=7.0, help='seconds per control')
    a = ap.parse_args()

    res = defaultdict(lambda: [0, 0, 0])          # engine -> W D L
    term = defaultdict(lambda: defaultdict(int))  # engine -> reason -> count (as loser/any)
    tmove = defaultdict(list)                     # engine -> seconds per move
    period = defaultdict(list)                    # engine -> seconds per full period
    depth = defaultdict(lambda: defaultdict(list))
    nocomment = defaultdict(int)                  # engine -> moves with no comment
    flagged = defaultdict(list)                   # engine -> (move flagged on, s used in period)
    tbin = defaultdict(lambda: defaultdict(list))  # engine -> move bin -> seconds
    banks = defaultdict(list)                     # engine -> clock left at each period end
    overrun = defaultdict(int)                    # engine -> games ending below zero
    bank_sd = defaultdict(list)                   # engine -> 1-sigma rounding error of each bank
    ngames = 0

    for tags, text in games(a.pgn):
        ngames += 1
        w, b, r = tags.get('White', '?'), tags.get('Black', '?'), tags.get('Result', '*')
        if r == '1-0':
            res[w][0] += 1; res[b][2] += 1
        elif r == '0-1':
            res[w][2] += 1; res[b][0] += 1
        elif r == '1/2-1/2':
            res[w][1] += 1; res[b][1] += 1

        # Pair every SAN move with the comment that follows it. A move can
        # have NO comment: the engine plays a single legal reply instantly,
        # without an info line. Counting comments instead of moves would then
        # shift every later move onto the wrong side.
        plies = []                                # [san, comment or None]
        for tok in TOK.findall(text):
            if tok.startswith('{'):
                if plies and plies[-1][1] is None:
                    plies[-1][1] = tok[1:-1]
            elif MOVENUM.match(tok) or tok in RESULTS:
                continue
            else:
                plies.append([tok, None])
        tail = plies[-1][1] if plies and plies[-1][1] else ''

        t = tags.get('Termination', '')
        if not t:
            # cutechess GUI writes no Termination tag; the reason is appended
            # to the last move comment instead ("..., White loses on time").
            low = tail.lower()
            for key, reason in TAIL_REASONS:
                if key in low:
                    t = reason
                    break
        if t and t != 'normal':
            if t == 'time forfeit':
                # The flag falls on the side to move after the last recorded
                # ply. Works also for 'Draw by timeout' (the flagger's opponent
                # cannot mate, so the GUI scores it 1/2), where the result and
                # the comment name nobody.
                first = b if ' b ' in tags.get('FEN', '') else w
                other = w if first == b else b
                loser = first if len(plies) % 2 == 0 else other
                if r == '1/2-1/2':
                    t = 'time forfeit, scored as draw (opponent cannot mate)'
            elif 'White' in tail or r == '0-1':
                loser = w
            elif 'Black' in tail or r == '1-0':
                loser = b
            else:
                loser = 'draw/unknown'
            term[loser][t] += 1

        # Plies alternate from the side to move in the start position. A move
        # with no comment (forced reply) or a book move counts for move
        # numbering and period boundaries but carries no time or depth.
        side_of = [w, b]
        if ' b ' in tags.get('FEN', ''):
            side_of = [b, w]
        movenum = {w: 0, b: 0}
        cur = {w: 0.0, b: 0.0}
        # Repeating control: unspent time CARRIES OVER, so each period may use
        # base + whatever the previous periods left. 'bank' is the clock left
        # at the end of each period; below zero is a real overrun.
        bank = {w: 0.0, b: 0.0}
        # cutechess writes move times with 2 significant digits (0.15s,
        # 0.086s, 3.2s): each is off by up to half a unit in the last digit.
        # Summed over a period -- and carried over with the bank -- that is
        # tens of ms. Track the variance so the report can say how precise
        # the reconstructed clock is.
        bvar = {w: 0.0, b: 0.0}
        for i, (san, c) in enumerate(plies):
            eng = side_of[i % 2]
            movenum[eng] += 1
            m = EVAL.search(c or '')
            if m:
                secs = float(m.group(3))
                tmove[eng].append(secs)
                if secs > 0:
                    q = 10 ** (math.floor(math.log10(secs)) - 1)   # last-digit unit
                    bvar[eng] += q * q / 12.0                      # uniform rounding error
                cur[eng] += secs
                for lo, hi in BINS:
                    if lo <= movenum[eng] <= hi:
                        depth[eng][(lo, hi)].append(int(m.group(2)))
                        tbin[eng][(lo, hi)].append(secs)
            else:
                nocomment[eng] += 1
            if movenum[eng] % a.period == 0:
                period[eng].append(cur[eng])
                bank[eng] += a.base - cur[eng]
                banks[eng].append(bank[eng])
                bank_sd[eng].append(math.sqrt(bvar[eng]))
                cur[eng] = 0.0
        for eng in (w, b):              # clock left at the end of the game
            left = bank[eng] + a.base - cur[eng]
            if left < 0:
                overrun[eng] += 1
        # A game lost on time ends inside a period: record how much of it the
        # loser had used, which is the number that shows how close to the
        # limit it was running.
        if t.startswith('time forfeit') and loser in (w, b):
            flagged[loser].append((movenum[loser] + 1, cur[loser]))

    slice_s = a.base / a.period
    print(f"{ngames} games, control {a.period}/{a.base:g}s, nominal slice {1000 * slice_s:.0f} ms\n")
    for eng in sorted(res):
        W, D, L = res[eng]
        tm, pu = tmove[eng], period[eng]
        print(f"== {eng}:  +{W} ={D} -{L}")
        if term.get(eng):
            print("   lost by: " + ", ".join(f"{k} x{v}" for k, v in term[eng].items()))
        if tm:
            print(f"   time/move ms: mean {1000 * st.mean(tm):.0f}  median {1000 * st.median(tm):.0f}  "
                  f"p99 {1000 * pct(tm, 99):.0f}  max {1000 * max(tm):.0f}   "
                  f"(>{a.base * 0.25:.2f}s: {sum(x > a.base * 0.25 for x in tm)} moves)")
        if pu:
            print(f"   per completed {a.period}-move period: mean {st.mean(pu):.2f}s  "
                  f"min {min(pu):.2f}s  max {max(pu):.2f}s  of {a.base:g}s  "
                  f"({len(pu)} periods, mean unspent {a.base - st.mean(pu):.2f}s)")
            bk = banks[eng]
            neg = sum(x < 0 for x in bk) + overrun[eng]
            print(f"   clock left at each period end (carry-over included): min {min(bk):.2f}s, "
                  f"p1 {pct(bk, 1):.2f}s, median {st.median(bk):.2f}s;  "
                  f"below zero: {neg}")
            sd = bank_sd[eng]
            print(f"   precision of that clock (2-digit move times): 1 sigma median "
                  f"{1000 * st.median(sd):.0f} ms, max {1000 * max(sd):.0f} ms -- the "
                  f"min of {len(bk)} periods carries ~3-4 sigma of rounding noise; "
                  f"a real flag shows as a time forfeit")
        if flagged.get(eng):
            print("   flagged on: " + ", ".join(f"move {m} after {u:.2f}s of the period"
                                            for m, u in flagged[eng]))
        if nocomment.get(eng):
            print(f"   moves without a comment (forced replies / book): {nocomment[eng]}")
        row = []
        for lo, hi in BINS:
            ds = depth[eng].get((lo, hi))
            if ds:
                row.append(f"{lo}-{hi if hi < 9999 else '':}: {st.mean(ds):.2f} (n={len(ds)})")
        print("   mean depth by move: " + " | ".join(row))
        row = []
        for lo, hi in BINS:
            ts = tbin[eng].get((lo, hi))
            if ts:
                row.append(f"{lo}-{hi if hi < 9999 else '':}: {1000 * st.mean(ts):.0f}")
        print("   mean ms/move by move: " + " | ".join(row))
        print()
    if 'draw/unknown' in term:
        print("non-decisive special terminations: " +
              ", ".join(f"{k} x{v}" for k, v in term['draw/unknown'].items()))


if __name__ == '__main__':
    main()
