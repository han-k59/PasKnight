@echo off
setlocal enabledelayedexpansion
rem =====================================================================
rem  PasKnight NNUE -- self-play generation
rem  Set LABELLER and SEEDBASE below; the file prefix and the net path are
rem  derived from LABELLER, so they cannot disagree. 6 x 4M = 24M positions,
rem  openings from the engine's own PGN book (needs the book-enabled gendata build).
rem  Writes the command files, checks everything, launches 6 instances,
rem  then verifies from the logs that every instance labels with the NNUE.
rem =====================================================================

rem --- settings -----------------------------------------------------------
rem LABELLER: number of the net that labels this generation (4 = nnue4.nnue).
rem SEEDBASE: never reuse a seed range. Used so far: 101 201 301 401 501, 601.
rem LABELLER: the net that labels this generation = the best net so far
rem           (5s -> nnue5s.nnue, files n5s_sp0..5.bin,  6 for nnue6 for generation 7,  7 for nnue6 for generation 8).).
set LABELLER=8
rem SEEDBASE sets the starting values of the random-number generator, one per instance: instance 0 gets 701, instance 1 gets 702, and so on up to 706.
rem SEEDBASE: never reuse a seed range. Used so far: 101 201 301 401 501 601 701, 801.
set SEEDBASE=1001
set P=n%LABELLER%_
set NET=C:\PasKnight2.fpc\nnue%LABELLER%.nnue
set COUNT=4000000
set NODES=5000
set EXE=pasknight_gen.exe
rem The PGN book must be in the SAME folder as the executable (the engine
rem looks for BookFile next to itself).
set BOOK=8moves_v3.pgn

rem Run from the folder this batch file is in.
cd /d "%~dp0"

rem --- checks BEFORE anything is written or launched ------------------------
if not exist %EXE% echo %EXE% not found in %CD% & pause & exit /b
if not exist "%NET%" echo Net not found: %NET% & pause & exit /b
if not exist "%BOOK%" echo Book %BOOK% not found next to %EXE% in %CD% & pause & exit /b

for %%i in (0 1 2 3 4 5) do (
  if exist %P%sp%%i.bin echo %P%sp%%i.bin already exists - move it away first, gendata would overwrite it & pause & exit /b
)

rem --- write the command files ---------------------------------------------
for %%i in (0 1 2 3 4 5) do (
  set /a SEED=SEEDBASE+%%i
  >  %P%sp%%i_cmds.txt echo setoption name EvalFile value %NET%
  >> %P%sp%%i_cmds.txt echo setoption name UseNNUE value true
  >> %P%sp%%i_cmds.txt echo setoption name Hash value 8
  >> %P%sp%%i_cmds.txt echo setoption name BookFile value %BOOK%
  >> %P%sp%%i_cmds.txt echo gendata selfplay %COUNT% %P%sp%%i.bin %NODES% !SEED! pgnbook
  >> %P%sp%%i_cmds.txt echo quit
)
echo Wrote %P%sp0_cmds.txt .. %P%sp5_cmds.txt. First one:
echo.
type %P%sp0_cmds.txt
echo.
echo Labeller nnue%LABELLER%.nnue, files %P%sp0..5.bin, seeds %SEEDBASE%..
echo Check the net path and the seeds above, then press a key to launch 6 instances
echo (or close this window to cancel).
pause >nul

rem --- launch --------------------------------------------------------------
for %%i in (0 1 2 3 4 5) do (
  start "%P%gen%%i" powershell -NoProfile -Command "Get-Content %P%sp%%i_cmds.txt | .\%EXE% | Tee-Object %P%sp%%i.log"
)
echo Launched 6. Waiting 30 seconds, then checking the labeller in each log...
timeout /t 30 /nobreak >nul

rem --- verify the labeller and the book --------------------------------------
rem PowerShell's Tee-Object writes the logs as UTF-16, which findstr cannot
rem search directly. 'type' converts UTF-16 to plain text, so pipe through it.
set BAD=0
for %%i in (0 1 2 3 4 5) do (
  type %P%sp%%i.log | findstr /C:"labelling with the NNUE eval" >nul
  if errorlevel 1 (
    echo   instance %%i: NOT labelling with nnue%LABELLER%.nnue -- see %P%sp%%i.log
    set BAD=1
  ) else (
    echo   instance %%i: NNUE labeller OK
  )
  type %P%sp%%i.log | findstr /C:"openings from the engine's PGN book" >nul
  if errorlevel 1 (
    echo   instance %%i: NOT using the book -- see %P%sp%%i.log
    set BAD=1
  ) else (
    echo   instance %%i: book OK
  )
)
echo.
if !BAD!==1 (
  echo *** At least one instance is NOT using the NNUE or the book. Close ALL six windows,
  echo *** delete the %P%sp*.bin files and fix the problem before restarting.
) else (
  echo All six instances label with the NNUE. Leave the windows running.
)
pause
