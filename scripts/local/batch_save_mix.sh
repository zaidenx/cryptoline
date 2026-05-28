#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CV="${CV:-$ROOT/_build/default/cv.exe}"
SRC="${1:-$ROOT/examples}"
OUTROOT="${2:-$ROOT/examples_smt2}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

if [[ ! -x "$CV" ]]; then
  echo "[ERR] cv.exe not found or not executable: $CV" >&2
  exit 1
fi

if [[ ! -d "$SRC" ]]; then
  echo "[ERR] source dir not found: $SRC" >&2
  exit 1
fi

mkdir -p "$OUTROOT"
rm -f "$OUTROOT/failed_relpaths.txt"

mapfile -t FILES < <(find "$SRC" -type f -name "*.cl" | sort)

echo "[INFO] ROOT       = $ROOT"
echo "[INFO] CV         = $CV"
echo "[INFO] SRC        = $SRC"
echo "[INFO] OUTROOT    = $OUTROOT"
echo "[INFO] EXTRA_ARGS = $EXTRA_ARGS"
echo "[INFO] files      = ${#FILES[@]}"

ok=0
skip=0
fail=0

pick_proc() {
  local in_path="$1"
  grep -E '^\s*(proc|procedure)\s+[A-Za-z_][A-Za-z0-9_]*' "$in_path" \
    | tail -n 1 \
    | sed -E 's/^\s*(proc|procedure)\s+([A-Za-z_][A-Za-z0-9_]*).*/\2/'
}

for in_path in "${FILES[@]}"; do
  rel="${in_path#$SRC/}"
  out_base="$OUTROOT/${rel%.cl}"
  mkdir -p "$(dirname "$out_base")"

  if [[ -f "${out_base}_0.smt2" && "${out_base}_0.smt2" -nt "$in_path" ]]; then
    echo "[SKIP] $rel"
    ((++skip))
    continue
  fi

  echo "[DO]   $rel -> ${out_base#$OUTROOT/}_*.smt2"

  run_cv() {
    local retry_args="${1:-}"
    # shellcheck disable=SC2086
    $CV $EXTRA_ARGS $retry_args \
      -save-mix "$out_base" "$in_path" \
      >"${out_base}.log" 2>"${out_base}.err" || true
  }

  run_cv ""

  if [[ ! -f "${out_base}_0.smt2" ]]; then
    if grep -q 'Stack overflow' "${out_base}.err" 2>/dev/null; then
      OCAMLRUNPARAM=s=512M run_cv ""
    fi
  fi

  if [[ ! -f "${out_base}_0.smt2" ]]; then
    if grep -q -- '-implicit-const-conversion' "${out_base}.err" 2>/dev/null; then
      run_cv "-implicit-const-conversion"
    fi
  fi

  if [[ ! -f "${out_base}_0.smt2" ]]; then
    if grep -q 'Procedure main is not defined' "${out_base}.err" 2>/dev/null; then
      proc="$(pick_proc "$in_path")"
      if [[ -n "${proc:-}" ]]; then
        run_cv "-f $proc"
      fi
    fi
  fi

  if [[ ! -f "${out_base}_0.smt2" ]]; then
    if grep -q 'cut_spec cannot cut' "${out_base}.err" 2>/dev/null; then
      run_cv "-pssa -rmcuts"
    fi
  fi

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