#!/usr/bin/env bash
# Keep `helm.sh/resource-policy: keep` on every vendored CRD under
# helm/kagent/crds.
#
#   hack/crd-keep.sh           inject it        (run by `make sync`)
#   hack/crd-keep.sh --check   fail if missing  (run by `make verify`)
#
# Without the annotation a chart uninstall deletes the kagent.dev and kmcp CRDs,
# and Kubernetes garbage-collects every Agent, ToolServer and MCPServer CR with
# them. A bare `vendir sync` -- what the Renovate vendir manager runs -- restores
# the pristine upstream files, which do not carry it, so --check is the gate for
# a bump that skipped `make sync`.
#
# The insert appends one line to the existing metadata.annotations block rather
# than rewriting the document with `yq -i`: yq re-emits the whole file in its own
# sequence indentation, which turns a one-line change into a full-file diff and
# makes an upstream bump unreviewable. --check runs the same insert and reports
# instead of writing, so the gate cannot drift from the fix.
set -euo pipefail
cd "$(dirname "$0")/.."

case ${1:-} in
  "") check=false ;;
  --check) check=true ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

KEY="helm.sh/resource-policy"
VALUE="keep"
CRD_DIR="helm/kagent/crds"

mapfile -t files < <(find "$CRD_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "FAIL: no CRD files found under $CRD_DIR" >&2
  exit 1
fi
echo "$KEY: $VALUE on ${#files[@]} vendored CRDs"

# Appends the annotation at the end of the metadata.annotations block, adds the
# block when the document has none, and leaves a file that already carries the
# annotation byte-identical. Exits 3 on a document with no top-level metadata.
read -r -d '' prog <<'AWK' || true
BEGIN { state = 0; found = 0; sawmeta = 0 }
function emit() { print "    " key ": " value }
state == 2 && $0 !~ /^ {4}/            { if (!found) emit(); state = 0 }
state == 1 && $0 !~ /^ {2}/            { print "  annotations:"; emit(); state = 0 }
state == 2 && $0 ~ "^ {4}" key ":"     { found = 1 }
state == 1 && $0 ~ /^ {2}annotations:[[:space:]]*$/ { print; state = 2; next }
/^metadata:[[:space:]]*$/              { print; state = 1; found = 0; sawmeta = 1; next }
{ print }
END {
  if (state == 2 && !found) emit()
  else if (state == 1) { print "  annotations:"; emit() }
  if (!sawmeta) exit 3
}
AWK

rc=0
for f in "${files[@]}"; do
  tmp="$f.crdkeep.tmp"
  if ! awk -v key="$KEY" -v value="$VALUE" "$prog" "$f" > "$tmp"; then
    rm -f "$tmp"
    printf '  FAIL  %s (no top-level metadata: block)\n' "$f"
    rc=1
  elif cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
    printf '  ok    %s\n' "$f"
  elif $check; then
    rm -f "$tmp"
    printf '  FAIL  %s (annotation missing)\n' "$f"
    rc=1
  else
    mv "$tmp" "$f"
    printf '  added %s\n' "$f"
  fi
done

if [[ $rc -ne 0 ]] && $check; then
  echo
  echo "Run './hack/crd-keep.sh' (or 'make sync') and commit the result."
fi
exit $rc
