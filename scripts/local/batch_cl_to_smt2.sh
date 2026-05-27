#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # ~/cryptoline
CV="${CV:-$ROOT/_build/default/cv.exe}"
SRC="${1:-$ROOT/examples}"
OUTROOT="${2:-$ROOT/examples_smt2}"

if [[ ! -x "$CV" ]]; then
  echo "[ERR] cv.exe not found or not executable: $CV" >&2
  exit 1
fi
if [[ ! -d "$SRC" ]]; then
  echo "[ERR] source dir not found: $SRC" >&2
  exit 1
fi

mkdir -p "$OUTROOT"

mapfile -t FILES < <(find "$SRC" -type f -name "*.cl" | sort)

echo "[INFO] ROOT    = $ROOT"
echo "[INFO] CV      = $CV"
echo "[INFO] SRC     = $SRC"
echo "[INFO] OUTROOT = $OUTROOT"
echo "[INFO] files   = ${#FILES[@]}"

ok=0; skip=0; fail=0

for in_path in "${FILES[@]}"; do
    rel="${in_path#$SRC/}"

  
  out_base="$OUTROOT/${rel%.cl}"        # 例：out_smt2/blst/armv8/add_fp6-armv8
  mkdir -p "$(dirname "$out_base")"

  # incremental：如果已經有輸出且比輸入新就跳過
  # 以 _0.smt2 當作是否已生成的代表
  if [[ -f "${out_base}_0.smt2" && "${out_base}_0.smt2" -nt "$in_path" ]]; then
    echo "[SKIP] $rel"
    ((++skip))
    continue
  fi

  echo "[DO]   $rel -> ${out_base#$OUTROOT/}_*.smt2"

  run_cv() {
      # 用法：run_cv "額外參數字串"
      local extra="${1:-}"
      # 將 -no_carry_constraint 直接加在這裡
      # shellcheck disable=SC2086
      $CV $extra -no_carry_constraint -disable_safety -disable_range -slicing -save-mix "$out_base" "$in_path" >"${out_base}.log" 2>"${out_base}.err" || true
    }

  pick_proc() {
  grep -E '^\s*(proc|procedure)\s+[A-Za-z_][A-Za-z0-9_]*' "$in_path" \
    | tail -n 1 \
    | sed -E 's/^\s*(proc|procedure)\s+([A-Za-z_][A-Za-z0-9_]*).*/\2/'
}



  # 1) 先跑一次（無額外參數）
  run_cv ""

  # 2) 若沒產生輸出，依錯誤訊息重試（可堆疊）
  if [[ ! -f "${out_base}_0.smt2" ]]; then
    # 2-1) Stack overflow：加大 OCaml stack
    if grep -q 'Stack overflow' "${out_base}.err"; then
      OCAMLRUNPARAM=s=512M run_cv ""
    fi
  fi

  if [[ ! -f "${out_base}_0.smt2" ]]; then
    # 2-2) implicit const conversion
    if grep -q -- '-implicit-const-conversion' "${out_base}.err"; then
      run_cv "-implicit-const-conversion"
    fi
  fi

  if [[ ! -f "${out_base}_0.smt2" ]]; then
    # 2-3) main not defined：指定 procedure
    if grep -q 'Procedure main is not defined' "${out_base}.err"; then
      proc="$(pick_proc)"
      if [[ -n "${proc:-}" ]]; then
        run_cv "-f $proc"
      fi
    fi
  fi

  if [[ ! -f "${out_base}_0.smt2" ]]; then
    # 2-4) cut_spec cannot cut ... ：嘗試移除 cuts 後再輸出
    if grep -q 'cut_spec cannot cut' "${out_base}.err"; then
      run_cv "-pssa -rmcuts"
    fi
  fi

  # 成敗判斷：是否產生 _0.smt2
  if [[ -f "${out_base}_0.smt2" ]]; then
    ((++ok))
    if [[ ! -s "${out_base}.err" ]]; then
      rm -f "${out_base}.err"
    fi
  else
    echo "[FAIL] $rel (no ${out_base}_0.smt2 produced; see: ${out_base}.err, ${out_base}.log)" >&2
    echo "$rel" >> "$OUTROOT/failed_relpaths.txt"
    ((++fail))
  fi




done

echo "[DONE] ok=$ok skip=$skip fail=$fail"
exit "$fail"
