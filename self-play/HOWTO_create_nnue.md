# How to create a new PasKnight `.nnue` file

The full procedure, from generating self-play data to a verified, tested net.
Every step has a check. Skip none of them: each one exists because its absence
once cost hours — or a whole generation.

Paths assume the engine in `C:\PasKnight2.fpc` and the Python environment in
`E:\pytorch\pasknight-nnue`. Adjust if yours differ.

---

## Overview

```
 1. build both binaries           pasknight_gen.exe (GenData), pasknight_nnue.exe (release)
 2. pick the labeller             the best net so far, by its result against the HCE
 3. probe (optional)              20,000 positions, read the summary
 4. launch 6 instances            start_selfplay.bat, ~21 h for 24M positions
 5. verify the six summaries      logs and file sizes
 6. merge + split                 merge_shuffle.py  -> allN_train.bin / allN_val.bin
 7. train                         train_nnue.py     -> nnueN.npz        (~17 h at 108M)
 8. export                        export_nnue.py    -> nnueN.nnue + testvecN.txt
 9. engine gates                  bench, testvec, check
10. matches                       vs the HCE at 40/7s (the yardstick), head-to-head as a check
11. promote and archive          nnue embed -> pasknight_net.inc, rebuild both binaries
```

Name everything after the net that produced or uses it — `n5s_` data is
labelled by `nnue5s.nnue`, the net trained on it is `nnue6s`, its vectors
`testvec6s.txt` — and never overwrite a file that is still a reference.

### The rules that cost the most to learn

- **One net path, one place.** The labeller, the file prefix and the seeds are
  set in `start_selfplay.bat` and nowhere else. A generation was once labelled
  by the wrong net because the prefix was updated and the net path was not.
- **Every `EvalFile` absolute, every `UseNNUE` explicit** — in command files and
  in every cutechess engine entry. The engine always starts with the net
  **embedded in the executable** (v2.0.0alpha3); anything not set explicitly
  silently uses that. A wrong path does *not* fall back to it: no net is
  loaded and the engine answers `go` with `bestmove 0000`.
- **Never reuse a seed range** (register in step 4).
- **The HCE is the yardstick.** Head-to-head against the previous net has
  overstated the gain by up to ~35 Elo.

---

## 1. Build the binaries

Two build modes in Lazarus (toolbar dropdown, or Project → Project Options →
Build Modes):

| mode | define | output | use for |
|---|---|---|---|
| Release | — | `pasknight_nnue.exe` | gates, bench, all matches |
| GenData | `-dNNUE_GENDATA` | `pasknight_gen.exe` | self-play generation only |

Both with target processor `COREAVX2`. Command line:
`lazbuild --build-mode=GenData pasknight_nnue.lpi`.

**Rebuild both after any change to `unit_nnue.pas`.** An old GenData build
cannot load a format-2 net (`version 2, expected 1`).

**Check:** start `pasknight_gen.exe` and type `gendata`. The usage line must
read `gendata selfplay <count> <file> [nodes] [seed] [book.epd | pgnbook]`.

Never use the GenData build for bench or matches: it compiles an extra branch
into `Evaluate()`.

---

## 2. Pick the labeller

The net loaded during generation both **chooses the moves** and **produces the
search score** stored with every position, so use the strongest net — the one
with the best result **against the HCE at 40/7s** (step 10), not the best
head-to-head.

It must be in `C:\PasKnight2.fpc` under its own name (`nnue5s.nnue`) and be
loaded by that path. Never rely on the embedded net: it changes on promotion.

Format 1 and format 2 nets both work as labellers.

---

## 3. Probe (optional, ~7 min)

Worth doing after any change to the generator or a new book. In the folder of
`pasknight_gen.exe`, with `8moves_v3.pgn` next to it:

```
setoption name EvalFile value C:\PasKnight2.fpc\nnue5s.nnue
setoption name UseNNUE value true
setoption name Hash value 8
setoption name BookFile value 8moves_v3.pgn
gendata selfplay 20000 probe.bin 5000 1 pgnbook
quit
```

Save as `probe_cmds.txt`, then `pasknight_gen.exe < probe_cmds.txt > probe.log 2>&1`.

| line | expect | if not |
|---|---|---|
| `NNUE: loaded ...` | the intended file, and `format 2` for an stm net | fix the path |
| `info string Book: Opening book 8moves_v3.pgn active with 555200 positions` | present | book not next to the exe |
| `labelling with the NNUE eval (...)` | the intended file | labeller is not what you think |
| `openings from the engine's PGN book ... + 2..6 random plies` | present | `pgnbook` missing from the command |
| `eval used:` (last line) | `NNUE` | **stop** — it fell back to the HCE |
| results W/D/B | ~36 / 26 / 37 % | lopsided → see Troubleshooting |
| positions kept per game | ~66 with the book (~75 with random openings) | filters misbehaving |
| discarded | ~1 % | games hitting the ply limit |
| mean nodes per move | ~8,600 | node accounting wrong |

Seed 1 is for probes only. Delete `probe.bin` afterwards.

---

## 4. Launch six instances: `start_selfplay.bat`

One batch file does everything: writes the six command files, checks every
precondition before launching anything, launches six instances, and after 30 s
checks every log for the labeller and the book.

**The only lines to edit** are at the top:

```bat
set LABELLER=5s
set SEEDBASE=701
```

From these it derives the prefix `n5s_`, the net `C:\PasKnight2.fpc\nnue5s.nnue`
and the seeds 701–706. Before launching it prints

```
Labeller nnue5s.nnue, files n5s_sp0..5.bin, seeds 701..
```

— **read that line before pressing a key.** It refuses to start if the exe,
the net or the book is missing, or if any output `.bin` already exists
(`gendata` would truncate it without asking).

After launch it must report, per instance, `NNUE labeller OK` and `book OK`.
If not: close all six windows, delete the `.bin` files, fix, restart.

### Seed register — never reuse a block

| block | data | labeller | openings | status |
|---|---|---|---|---|
| 1 | probes | — | — | probes only |
| 101–106 | `sp` | HCE | random | in use |
| 201–206 | `n1_` | NNUE1 | random | in use (`g2_` with the same seeds: deleted) |
| 301–306 | `n2_` | NNUE2b | random | in use |
| 401–406 | `n3_` | NNUE3 | book | in use |
| 501–506 | `n3b_` | NNUE3 | book, even extra plies only | **not used**: colour-skewed (48/27/23) |
| 601–606 | `n4_` | NNUE4 | book | in use |
| **701–706** | `n5s_` | NNUE5s | book | next |
| 801–806 | | | | the one after |

### Parameters

| parameter | value | why |
|---|---|---|
| positions per instance | 4,000,000 | 24M per generation |
| nodes | 5000 per deepening iteration | ~8,600 per move, depth 6–7 |
| Hash | 8 MB | TT cleared between games, reused within one |
| openings | `8moves_v3.pgn` + 2–6 random plies | see below |
| instances | 6 | one per physical core |

**The extra random plies must stay a mix of odd and even (2–6).** Whoever plays
the last random move hands the opponent the first searched move, an advantage.
With even counts only, Black always played last and White won 48 % to 23 %.
The mix cancels out on average.

Duration: ~50 pos/s per instance → **about 21 hours**. Don't run training or
matches on the same machine meanwhile; both want all cores.

Keep nodes at or below 10,000 per iteration (the `InputReady` poll can abort
searches under redirected stdin on Linux; Windows is safe).

---

## 5. Monitoring

The logs are written by PowerShell's `Tee-Object` **as UTF-16**. `findstr` cannot
search them directly; pipe through `type`, which converts:

```bat
type n5s_sp0.log | findstr /C:"gendata"
```

Last line of each log:

```powershell
Get-ChildItem n5s_sp?.log | ForEach-Object { '{0}: {1}' -f $_.Name, (Get-Content $_ -Tail 1) }
```

A progress line appears at each whole percent — about every 13 minutes. Real
file sizes while the files are open (Explorer shows 0 bytes):

```powershell
Get-ChildItem n5s_sp?.bin | ForEach-Object {
  $fs = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
  "{0}: {1,12:N0} records ({2:P1})" -f $_.Name, ($fs.Length/32), ($fs.Length/32/4000000)
  $fs.Close()
}
```

Data is flushed every 8,192 records. A partial file is valid (trim to a multiple
of 32 bytes). **Restarting does not resume** — it truncates. Rename a partial
file and restart with a new seed range and prefix.

---

## 6. Verify the six summaries

```powershell
Get-ChildItem n5s_sp?.log | ForEach-Object { $_.Name; Get-Content $_ -Tail 12; '' }
Get-ChildItem n5s_sp?.bin | Select-Object Name, Length
```

- Every file exactly **128,000,000 bytes** (4M × 32).
- Every log: `labelling with the NNUE eval (c:\pasknight2.fpc\nnue5s.nnue)` — **the
  intended net** — and ends with `eval used: NNUE`.
- W/D/B around 36 / 26 / 37 %.
- The six agree within a fraction of a percent on games, discards, results,
  positions per game and nodes per move.

---

## 7. Merge and split

In the venv (`(venv)` in the prompt):

```
cd /d E:\pytorch\pasknight-nnue
venv\Scripts\activate
python merge_shuffle.py <all data files> --train all6_train.bin --val all6_val.bin
```

**Which files:** `sp0..5`, `n1_sp0..5`, `n2_sp0..5`, `n3_sp0..5`, `n4_sp0..5`,
plus each new generation (`n5s_sp0..5`, …), all from `C:\PasKnight2.fpc\`, as
full paths on one line. **Never** `n3b_`, `probe.bin`, `train.bin`, `val.bin`.

Recovers game boundaries from the ply byte and holds out **whole games** (2 %)
for validation, so near-identical positions never straddle the split. The split
is deterministic: the same inputs give the same files.

**Check:** no `ply-255 cap` note; games per file ~1 % below the generator's
`kept` count; train and val agree on mean |score|, p99, W/D/B, pieces and ply.

Memory: ~70 MB per million positions (132M ≈ 9 GB).

---

## 8. Train

```
python -u train_nnue.py --train all6_train.bin --val all6_val.bin --out nnue6s.npz --epochs 30 --threads 6 --loss wdl > nnue6s_train.log 2>&1
```

The side-to-move input (format 2) is the **default**; the log says
`side-to-move input ON (format 2)`. `--no-stm` trains a format-1 net, as NNUE1–5
were.

Follow it live in a second PowerShell window:

```powershell
Get-Content nnue6s_train.log -Wait -Tail 20
```

One line per epoch, nothing in between. **If that window stops updating, check
Task Manager before assuming a hang:** clicking into a console window pauses its
output until Esc. The training itself is unaffected.

| option | value | meaning |
|---|---|---|
| `--loss wdl` | | search score blended with game result |
| `--lambda-start / --lambda-end` | 1.0 / 0.7 | weight on the search score, annealed over the epochs |
| `--epochs` | 30 | the λ schedule spans exactly these epochs |
| `--threads` | 6 | |
| `--stm / --no-stm` | stm | format 2 / format 1 |
| `--max-train N` | | first N positions only, for quick A/B tests |

Time and memory: **~19 s per million positions per epoch** (108M ≈ 34 min per
epoch, ~17 h for 30), about **10 GB RAM** at 108M. Sleep only pauses it; a power
cut or a Windows Update restart loses it. There is no resume — but the `.npz`
on disk always holds the best epoch so far.

**Reading the log:**

- The first two lines repeat merge_shuffle's statistics. Negative percentages
  would mean an old trainer (int32 overflow in the display only).
- **`val` is the selection metric**, at fixed λ = 0.7. It falls and flattens;
  the `.npz` is rewritten only when it improves.
- Training loss and the bracketed MAE **rise** as λ falls. Expected; never
  select on MAE.
- Best epochs so far: 24–29, with less than 0.1 % change over the last five.
  **If the best epoch is the last one and `val` is still clearly falling, train
  longer.** 30 epochs becomes *more* than enough as data grows (more steps per
  epoch); `--epochs 20` is worth one A/B test once training time hurts.
- **Validation losses are comparable only on the same validation file.** A new
  merge makes a new file. To compare two training choices (e.g. stm vs no-stm),
  use the same `allN_*.bin` and the same settings.

---

## 9. Export

```
python export_nnue.py --net nnue6s.npz --out nnue6s.nnue --testvec testvec6s.txt --val all6_val.bin > nnue6s_export.log 2>&1
type nnue6s_export.log
```

| line | expect |
|---|---|
| `format 2: 768 inputs + side-to-move column` | (format 1 for a `--no-stm` net) |
| `worst-case |accumulator|` | below 100 % **by construction** (weight clip 0.95 + bias clip 1.5) |
| `range check:` | **PASS** |
| `wrote ... (410856 bytes)` | format 2; format 1 is 410,344 |
| `file round-trip:` | **PASS** |
| quantization error | MAE < 1 cp, max a few cp |
| agreement with the file's label | ~100–120 cp MAE is normal |

Copy the `.nnue` and the `testvec` file to `C:\PasKnight2.fpc`. Do not embed
it yet (step 12).

---

## 10. Engine gates

Release build. **Set the net first** — every `nnue` command prints which net it
tests, read that line.

```
setoption name UseNNUE value false
bench 12
setoption name UseNNUE value true
setoption name EvalFile value C:\PasKnight2.fpc\nnue6s.nnue
nnue testvec C:\PasKnight2.fpc\testvec6s.txt
nnue check 200000
bench 12
quit
```

| gate | pass condition |
|---|---|
| startup | `NNUE: loaded embedded net <name>`, then `NNUE: AVX2 kernels` |
| `bench 12`, HCE | **16,871,716** nodes, exactly |
| load line | the intended file; `768+stm->256->32->1, format 2` for an stm net |
| `nnue testvec` | **all 64 cases match exactly** |
| `nnue check 200000` | exact at every ply; non-zero castles, promotions, en passants |
| `nnue tempo 50000` | format 1 only: max error ≤ 2 cp. Format 2: reports *not applicable* |
| `bench 12`, net | note nodes, time, nps — **excluding position 10** (a mate search that dominates totals) |

**After a change to `unit_nnue.pas`** also run `bench 12` with a known format-1
net (NNUE5) in the old and the new build: the node counts must be identical.

---

## 11. Matches (cutechess GUI)

### Engine entries

One entry per net, all pointing at the **same** release exe. In
Engine configuration → Advanced, press **Detect**, then set every option
explicitly:

| option | net entry | HCE entry |
|---|---|---|
| Name | e.g. `NNUE6s` (distinct!) | `HCE` |
| UseNNUE | true | **false** |
| EvalFile | absolute path to its `.nnue` — also for the embedded net, so an entry never changes meaning when the embedded net does | (any) |
| OwnBook | **false** | **false** |
| LogFile | false | false |
| UseAVX2 | true | true |
| Hash | the same everywhere | the same everywhere |

### Tournament

| setting | value |
|---|---|
| rounds / games per encounter | 1 / 9998 |
| SPRT | elo0 0, elo1 5, alpha 0.05, beta 0.05 — `lbound -inf, ubound inf` in the result means it was **not** active |
| opening suite | EPD/PGN in random order, repeat openings on — **never `8moves_v3`**, the training book |
| time control | 40/7s, margin **0** |
| fixed nodes | Infinite with Nodes 30000 (a per-iteration limit, ~50k nodes per move) |
| concurrency | the same in every comparable run |
| PGN output | always, with move comments |

### What to run, and how to read it

1. **New net vs the HCE at 40/7s** — the yardstick. The gain over the previous
   net is the difference of the two HCE results (each ±13 at ~2,000 games, so
   the difference ±18). Same opening suite and settings every time.
2. **Head-to-head vs the previous net**, fixed nodes then 40/7s — a sanity
   check only. It has overstated real gains by up to ~35 Elo.
3. Check the colour split against the HCE (`playing White` vs `playing Black`).
   A large asymmetry points at skewed training data.
4. Run `pgn_timecheck.py` on the 40/7s PGN: no time forfeits, nothing below zero
   in the clock line.

Before trusting a result: the first game's engine output shows
`info string eval: NNUE <file>` with each side's own net (or `HCE`).

---

## 12. Promote and archive

If the new net beats the previous one against the HCE: label the next
generation with it (by its own path, step 2), and embed it in the executable
for normal play.

### Deploy a new net: embed it (v2.0.0alpha3)

The engine plays with the net compiled into it; no `.nnue` file is needed next
to the exe. A `.nnue` there (also `pasknight.nnue`) is only loaded when
`EvalFile` names it — a cutechess entry stored with the old default
`pasknight.nnue` still does, so re-detect old entries. The net lives in
`pasknight_net.inc` (next to `unit_nnue.pas`), written by the engine itself:

```
nnue embed C:\PasKnight2.fpc\nnue10.nnue C:\PasKnight2.fpc\pasknight_net.inc
quit
```

`nnue embed <file.nnue> <out.inc> [name]` checks the net with the loader's own
checks (magic, version, geometry, scales, size, checksum) and writes the
include only if all pass. The name defaults to the file name (`nnue10.nnue` →
`nnue10`); `pasknight` is refused, give a name. Quote paths with spaces. The
active net is not changed by it.

| line | expect |
|---|---|
| `passed all checks (410856 bytes, checksum $…)` | present |
| `wrote …\pasknight_net.inc  (net name 'nnue10')` | the intended name |
| `replaces, after a rebuild, …` | the old embedded net |

Then **rebuild both build modes** (Release and GenData) and check:

| gate | pass condition |
|---|---|
| startup line | `NNUE: loaded embedded net nnue10 (410856 bytes, …)` |
| `uci` / `isready` | `NNUE: embedded net (nnue10, 410856 bytes)` / `eval: NNUE embedded net (…)` |
| `bench 12`, no `.nnue` in the folder | equal to `bench 12` with `setoption name EvalFile value <abs path>\nnue10.nnue` |
| `nnue testvec <its testvec>` | 64/64, embedded and external |
| exe size | about 411 KB larger than without a net |

Record the new bench reference in the status block of the `.lpr`.
`setoption name EvalFile value <embedded>` (or an empty value) returns to the
embedded net after an external one; `nnue stats` names both the active and the
embedded net.


Keep for every net: `.npz`, `.nnue`, `testvec`, training log, export log, and
the list of data files it was trained on. Record the result in the results
register below and in the status block in `pasknight_nnue.lpr`.

### Results register (vs the HCE at 40/7s)

| net | trained on | format | vs HCE | notes |
|---|---|---|---|---|
| NNUE1 | 12M | 1 | (+68 fixed nodes) | |
| NNUE2b | 36M | 1 | +113 ± 13 | first measured after the move-40 flag fix |
| NNUE3 | 60M | 1 | +134 ± 11 | |
| NNUE4 | 84M | 1 | +147 ± 13 | colour-asymmetric (73 % / 67 %) |
| NNUE5 | 108M | 1 | +168 ± 13 | |
| **NNUE5s** | 108M | **2** | **+186 ± 13** | side-to-move input, same data as NNUE5 |

### When to stop adding generations

When **two generations in a row** each gain less than ~10 Elo against the HCE.
One weak generation is within the noise (gen 4 gave +13, gen 5 +21 again).
Then the next levers are speed (eval cache), two perspectives, king buckets.

---

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `gendata` unknown command | release build | GenData build |
| `NNUE: version 2, expected 1` | old build, format-2 net | rebuild with the current `unit_nnue.pas` |
| `NNUE: could not load "…" from working directory …`, then `NO NET LOADED` | relative path / missing file | absolute `EvalFile` |
| `bestmove 0000`, `ERROR: no net loaded (<path>)` | the `EvalFile` path failed (there is no fallback) | fix the path, or `value <embedded>` |
| startup names the old embedded net | `nnue embed` not run, or not rebuilt | `nnue embed`, rebuild both modes |
| compile: cannot find `pasknight_net.inc` | include missing next to `unit_nnue.pas` | copy it there, or `nnue embed` with an older exe |
| `nnue embed`: the output file must end in .inc | wrong argument order | `nnue embed <file.nnue> <out.inc> [name]` |
| log says a different net than intended | prefix and net set separately | `start_selfplay.bat` derives both from `LABELLER` |
| batch reports "NOT labelling" / "NOT using the book" but the log looks fine | old batch: `findstr` on a UTF-16 log | current batch (`type … \| findstr`) |
| W/D/B around 48 / 27 / 23 | extra plies even-only | 2–6 mixed (`Random(MAX - MIN + 1)`) |
| `eval used: HCE` when NNUE was intended | net didn't load | read the first log lines |
| identical data from all instances | same seed | the batch's `!SEED!` |
| training window stopped updating | console paused by a click | Esc; check Task Manager |
| negative percentages in the train log | old trainer | current `train_nnue.py` |
| export: range check FAIL | bias grown too large | current trainer (bias clip) |
| `testvec`: 64/64 MISMATCH, all at the accumulator | wrong net loaded | `setoption name EvalFile value …` first |
| `testvec`: "FORMAT-1 vectors / FORMAT-2 net" or vice versa | vectors and net from different exports | load the matching net |
| SPRT ~0 Elo between NNUE and HCE | stored cutechess option | set every option in each entry |
| `lbound -inf, ubound inf` | SPRT fields empty | fill them in |
| time forfeits at move 40 | pre-fix build (≤100 ms clock → unlimited search) | current `.lpr` time management |
| bench nps very different between nets | position 10 dominates | compare excluding it |

---

## Reference

### Record format (32 bytes)

```
QWord    occ     occupancy bitboard, a1 = bit 0
byte[16] nib     piece nibbles in ascending square order, low nibble first
SmallInt score   white-POV centipawns (the search score)
byte     stm     0 = white to move
byte     phase   0..24
byte     res     0 unknown, 1 black won, 2 draw, 3 white won (white POV)
byte     ply     plies from game start, capped 255
byte[2]  pad     zero
```

### Net file formats

| | format 1 | format 2 |
|---|---|---|
| inputs | 768 | 768 + side-to-move column |
| size | 410,344 bytes | 410,856 bytes |
| tempo | fixed bonus added by `NNUE_Evaluate` | learned by the net; no bonus |
| test vectors | `n f1..fn accSum sSum o cp` | `w`/`b` + the same |
| nets | NNUE1–5 | NNUE5s onward |

The side-to-move column is added at eval time before the first CReLU, not in
the incremental accumulator.

The embedded net (`pasknight_net.inc`) is the format-2 file byte for byte, as
`const EMBEDDED_NET: array[0..EMBEDDED_NET_SIZE - 1] of byte`, plus its name,
size and checksum. It is checked at every startup exactly like a file.

### Generator constants (`pasknight_nnue_gendata.inc`)

| constant | value | meaning |
|---|---|---|
| `SP_OPEN_MIN / MAX` | 6 / 12 | random plies without a book |
| `SP_BOOK_EXTRA_MIN / MAX` | 2 / 6 | random plies after a book line — keep odd and even mixed |
| `SP_MAX_PLIES` | 250 | per game, counted from the game's own start |
| `SP_ADJ_WIN_CP / PLIES` | 2500 / 4 | win adjudication |
| `SP_ADJ_DRAW_CP / PLIES / AFTER` | 15 / 16 / 80 | draw adjudication |
| `SP_MATE_BOUND` | 28000 | mate scores are not recorded |

Positions are skipped when the side to move is in check, the best move is a
capture, or the score is a mate score.

### Measured throughput

| stage | rate |
|---|---|
| generation, NNUE labeller, book | ~50 pos/s per instance (~21 h per 24M) |
| merge | ~70 MB RAM per million positions |
| training | ~19 s per million positions per epoch; ~10 GB RAM at 108M |
