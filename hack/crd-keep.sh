#!/usr/bin/env bash
# Keep `helm.sh/resource-policy: keep` on every vendored CRD under
# helm/kagent/crds.
#
#   hack/crd-keep.sh              inject it           (run by `make sync`)
#   hack/crd-keep.sh --check      fail if absent      (run by `make verify`)
#   hack/crd-keep.sh --self-test  test the transform  (run by `make verify`)
#
# Helm never deletes a CRD that ships in a chart's crds/ directory, and it does
# not read helm.sh/resource-policy there: the annotation binds resources Helm
# tracks in the release manifest, which crds/ files are not. The annotation is
# defence in depth for the tools that do honour it and for the day a CRD moves
# into templates/. `make sync` and the README both promise it is present, so
# --check is what makes the promise true. A bare `vendir sync` -- what the
# Renovate vendir manager runs -- restores the pristine upstream files, which do
# not carry it.
#
# The insert appends one line to the existing metadata.annotations block rather
# than rewriting the document with `yq -i`: yq re-emits the whole file in its own
# sequence indentation, which turns a one-line change into a full-file diff and
# makes an upstream bump unreviewable. --check runs the same transform and
# reports instead of writing, so the gate cannot drift from the fix.
set -euo pipefail
cd "$(dirname "$0")/.."

case ${1:-} in
  "") mode=inject ;;
  --check) mode=check ;;
  --self-test) mode=self-test ;;
  *) echo "usage: $0 [--check|--self-test]" >&2; exit 2 ;;
esac

KEY="helm.sh/resource-policy"
VALUE="keep"
CRD_DIR="helm/kagent/crds"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Matches the annotation by literal prefix, not as a regex: the `.` in `helm.sh`
# would otherwise match any character. A line carrying the key always ends up as
# `want`, so a wrong value is rewritten and a repeated key collapses to one line.
# Adds the annotations block when the document has none, leaves a document that
# already carries the annotation byte-identical, and exits 3 on a document with
# no top-level metadata.
read -r -d '' prog <<'AWK' || true
BEGIN { state = 0; found = 0; sawmeta = 0 }
state == 2 && $0 !~ /^ {4}/                         { if (!found) print want; state = 0 }
state == 1 && $0 !~ /^ {2}/                         { print "  annotations:"; print want; state = 0 }
state == 2 && index($0, keyline) == 1               { if (!found) { print want; found = 1 } next }
state == 1 && $0 ~ /^ {2}annotations:[[:space:]]*$/ { print; state = 2; next }
/^metadata:[[:space:]]*$/                           { print; state = 1; found = 0; sawmeta = 1; next }
{ print }
END {
  if (state == 2 && !found) print want
  else if (state == 1) { print "  annotations:"; print want }
  if (!sawmeta) exit 3
}
AWK

# transform <in> <out> -- exits 3 when <in> has no top-level metadata: block.
transform() {
  awk -v want="    $KEY: $VALUE" -v keyline="    $KEY:" "$prog" "$1" > "$2"
}

# --self-test covers the document shapes the vendored corpus does not currently
# contain but an upstream bump could introduce. Every case is also re-run over
# its own output: the transform must be a fixed point, otherwise `make sync`
# would produce a diff on every invocation.
self_test() {
  local dir="$tmpdir/self-test" pass=0 fail=0
  mkdir -p "$dir"

  run_case() { # run_case <name> <want-rc> <input> <expected>
    local name=$1 want_rc=$2 input=$3 expected=$4
    local in="$dir/in.yaml" got="$dir/got.yaml" again="$dir/again.yaml" rc=0
    printf '%s\n' "$input" > "$in"
    transform "$in" "$got" || rc=$?
    if [[ $rc -ne $want_rc ]]; then
      printf '  FAIL  %s (exit %d, want %d)\n' "$name" "$rc" "$want_rc"
      fail=$((fail + 1)); return
    fi
    [[ $want_rc -ne 0 ]] && { printf '  ok    %s\n' "$name"; pass=$((pass + 1)); return; }
    if ! printf '%s\n' "$expected" | diff -u --label expected --label got - "$got" > "$dir/d"; then
      printf '  FAIL  %s\n' "$name"; sed 's/^/          /' "$dir/d"
      fail=$((fail + 1)); return
    fi
    transform "$got" "$again"
    if ! cmp -s "$got" "$again"; then
      printf '  FAIL  %s (not a fixed point)\n' "$name"
      fail=$((fail + 1)); return
    fi
    printf '  ok    %s\n' "$name"; pass=$((pass + 1))
  }

  run_case "already annotated" 0 \
'metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com'

  run_case "annotation missing from an existing block" 0 \
'metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com'

  run_case "no annotations block at all" 0 \
'metadata:
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  name: a.example.com
  annotations:
    helm.sh/resource-policy: keep
spec:
  group: example.com'

  run_case "wrong value is rewritten" 0 \
'metadata:
  annotations:
    helm.sh/resource-policy: delete
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com'

  run_case "quoted value is normalised" 0 \
'metadata:
  annotations:
    helm.sh/resource-policy: "keep"
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com'

  run_case "a repeated key collapses to one line" 0 \
'metadata:
  annotations:
    helm.sh/resource-policy: delete
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com'

  run_case "a key that only looks like ours does not count" 0 \
'metadata:
  annotations:
    helmXsh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    helmXsh/resource-policy: keep
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com'

  run_case "a longer key that shares our prefix does not count" 0 \
'metadata:
  annotations:
    helm.sh/resource-policy-override: keep
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    helm.sh/resource-policy-override: keep
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com'

  run_case "every document in a multi-document file" 0 \
'metadata:
  annotations:
    a: b
  name: one.example.com
spec:
  group: example.com
---
metadata:
  name: two.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    a: b
    helm.sh/resource-policy: keep
  name: one.example.com
spec:
  group: example.com
---
metadata:
  name: two.example.com
  annotations:
    helm.sh/resource-policy: keep
spec:
  group: example.com'

  run_case "an annotations block that ends the file" 0 \
'metadata:
  name: a.example.com
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0' \
'metadata:
  name: a.example.com
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
    helm.sh/resource-policy: keep'

  run_case "a metadata block that ends the file" 0 \
'metadata:
  name: a.example.com' \
'metadata:
  name: a.example.com
  annotations:
    helm.sh/resource-policy: keep'

  run_case "no top-level metadata block" 3 \
'apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
spec:
  group: example.com' ''

  run_case "flow-style metadata is not edited silently" 3 \
'metadata: {name: a.example.com}
spec:
  group: example.com' ''

  run_case "a nested metadata: key is not mistaken for the document one" 0 \
'metadata:
  name: a.example.com
spec:
  versions:
  - schema:
      openAPIV3Schema:
        properties:
          metadata:
            type: object' \
'metadata:
  name: a.example.com
  annotations:
    helm.sh/resource-policy: keep
spec:
  versions:
  - schema:
      openAPIV3Schema:
        properties:
          metadata:
            type: object'

  printf '%d passed, %d failed\n' "$pass" "$fail"
  [[ $fail -eq 0 ]]
}

if [[ $mode == self-test ]]; then
  echo "hack/crd-keep.sh transform self-test"
  self_test
  exit
fi

mapfile -t files < <(find "$CRD_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "FAIL: no CRD files found under $CRD_DIR" >&2
  exit 1
fi
echo "$KEY: $VALUE on ${#files[@]} vendored CRDs"

rc=0
out="$tmpdir/out.yaml"
for f in "${files[@]}"; do
  if ! transform "$f" "$out"; then
    printf '  FAIL  %s (no top-level metadata: block)\n' "$f"
    rc=1
  elif cmp -s "$f" "$out"; then
    printf '  ok    %s\n' "$f"
  elif [[ $mode == check ]]; then
    printf '  FAIL  %s (%s: %s absent or wrong)\n' "$f" "$KEY" "$VALUE"
    rc=1
  else
    # Write through the existing file rather than `mv` the temp one over it, to
    # keep the committed mode and not inherit mktemp's 0600.
    cat "$out" > "$f"
    printf '  fixed %s\n' "$f"
  fi
done

if [[ $rc -ne 0 && $mode == check ]]; then
  echo
  echo "Run './hack/crd-keep.sh' (or 'make sync') and commit the result."
fi
exit $rc
