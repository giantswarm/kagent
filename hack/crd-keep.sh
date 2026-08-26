#!/usr/bin/env bash
# Keep `helm.sh/resource-policy: keep` on every vendored CRD under
# helm/kagent/crds.
#
#   hack/crd-keep.sh              inject it           (run by `make sync`)
#   hack/crd-keep.sh --check      fail if absent      (run by `make verify`)
#   hack/crd-keep.sh --self-test  test the transform  (run by `make verify`)
#
# Exit: 0 all good; 1 a CRD needs the annotation (--check), a CRD the transform
# refuses, or a self-test case failed; 2 bad usage. The transform itself exits 3
# on a document with no top-level `metadata:` block, 4 on an `annotations:` key
# whose value is not a block, 5 on flow-style `metadata:`, and 6 when its own
# output does not parse or does not carry the annotation on every document.
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
# makes an upstream bump unreviewable. yq still reads the result: a line-oriented
# insert can produce a document that parses differently than it reads, and a
# wrong result that is a fixed point would pass --check. --check runs the same
# transform and the same validation as the fix, so the gate cannot drift from it.
#
# yq here is an executable on PATH (override with YQ=, AWK= for awk), not the
# `docker run` line Makefile.gen.app.mk assigns to YQ: the file under test lives
# in a temp dir, which that container does not mount.
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
YQ=${YQ:-yq}
AWK=${AWK:-awk}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Matches the annotation by literal prefix, not as a regex: the `.` in `helm.sh`
# would otherwise match any character. A line carrying the key always ends up as
# `want`, so a wrong value is rewritten and a repeated key collapses to one line.
# Adds the annotations block when the document has none, and leaves a document
# that already carries the annotation byte-identical.
#
# Indentation is read from the document rather than assumed: the insert takes the
# indentation of the annotations block it joins, or of the metadata block plus
# two when it creates the block. A fixed four-space insert into a block indented
# deeper mixes indentation inside one mapping, which does not parse -- and the
# broken result is a fixed point, so --check would report it as correct.
#
# Every document needs its own top-level `metadata:` block. The transform refuses
# a document it cannot place the line in -- no metadata block, flow-style
# metadata, or an annotations key whose value is not a block -- instead of
# leaving it untouched: an untouched document is a fixed point too. Appending a
# second `annotations:` to a mapping that already has one is a duplicate key, and
# that result is also a fixed point. A blank line closes no block, so it does not
# split the insert off from the annotations that follow it.
read -r -d '' prog <<'AWK' || true
function ind(s) { match(s, /^ */); return RLENGTH }
function sp(n, s) { s = ""; while (length(s) < n) s = s " "; return s }
function want() { return sp(aind >= 0 ? aind : mind + 2) key ": " value }
function enddoc() {
  if (state == 1 && mind < 0) mind = 2
  if (state == 2) { if (!found) print want(); state = 1 }
  if (state == 1 && !hasann) { print sp(mind) "annotations:"; print want() }
  if (docany && !docmeta) { bail = 3; exit 3 }
  state = 0; mind = -1; aind = -1; found = 0; hasann = 0; docmeta = 0; docany = 0
}
BEGIN { state = 0; mind = -1; aind = -1; found = 0; hasann = 0
        docmeta = 0; docany = 0; bail = 0 }
/^[[:space:]]*$/ && state > 0                { print; next }
state == 2 && aind < 0                       { aind = ind($0) > mind ? ind($0) : mind + 2 }
state == 2 && ind($0) < aind                 { if (!found) print want(); state = 1 }
state == 2 && ind($0) == aind && index(substr($0, aind + 1), key ":") == 1 {
                                               if (!found) { print want(); found = 1 } next }
state == 2                                   { print; next }
state == 1 && mind < 0                       { mind = ind($0) > 0 ? ind($0) : 2 }
state == 1 && ind($0) < mind                 { if (!hasann) { print sp(mind) "annotations:"
                                                              print want() }
                                               state = 0 }
state == 1 && ind($0) == mind && $0 ~ /^ *annotations:[[:space:]]*$/ {
                                               print; state = 2; aind = -1; hasann = 1; next }
state == 1 && ind($0) == mind && $0 ~ /^ *annotations:/ { bail = 4; exit 4 }
state == 1                                   { print; next }
/^---/                                       { enddoc(); print; next }
/^metadata:[[:space:]]*$/                    { print; state = 1; docmeta = 1; docany = 1; next }
/^metadata:[[:space:]]*[^[:space:]]/         { bail = 5; exit 5 }
/^[[:space:]]*#/                             { print; next }
/^[[:space:]]*$/                             { print; next }
{ docany = 1; print }
END {
  if (bail) exit bail
  enddoc()
  if (bail) exit bail
}
AWK

# transform <in> <out> -- the awk pass alone, without the yq validation.
transform() {
  "$AWK" -v key="$KEY" -v value="$VALUE" "$prog" "$1" > "$2"
}

# validate <file> -- the annotation is set, as YAML, on every document. Catches
# an insert that parses differently than it reads: a duplicate key at another
# indentation, a document the transform skipped, a block it corrupted.
validate() {
  local values
  if ! values=$("$YQ" ea '[select(. != null) | .metadata.annotations."'"$KEY"'" // "MISSING"] | .[]' "$1" 2>&1); then
    # Drop yq's path to the temp file: the caller names the file under review.
    printf 'does not parse as YAML: %s' \
      "$(printf '%s' "$values" | sed "s|bad file '[^']*': ||" | tr '\n' ' ')"
    return 1
  fi
  if [[ -z $values ]]; then
    printf 'no YAML document to annotate'
    return 1
  fi
  local doc=0 v
  while IFS= read -r v; do
    doc=$((doc + 1))
    [[ $v == "$VALUE" ]] && continue
    printf 'document %d: %s is %s' "$doc" "$KEY" "$v"
    return 1
  done <<<"$values"
}

# apply <in> <out> -- transform, then refuse a result yq disagrees with. Exit 3,
# 4 and 5 come from the transform; 6 is a result that does not hold up.
apply() {
  local why rc=0
  transform "$1" "$2" || rc=$?
  if [[ $rc -ne 0 ]]; then
    case $rc in
      3) reason="a document has no top-level metadata: block" ;;
      4) reason="an annotations key whose value is not a block" ;;
      5) reason="flow-style metadata:" ;;
      *) reason="the transform failed (exit $rc)" ;;
    esac
    return "$rc"
  fi
  if ! why=$(validate "$2"); then
    reason="$why"
    return 6
  fi
  reason=""
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
    apply "$in" "$got" || rc=$?
    if [[ $rc -ne $want_rc ]]; then
      printf '  FAIL  %s (exit %d, want %d: %s)\n' "$name" "$rc" "$want_rc" "${reason:-none}"
      fail=$((fail + 1)); return
    fi
    [[ $want_rc -ne 0 ]] && { printf '  ok    %s (%s)\n' "$name" "$reason"; pass=$((pass + 1)); return; }
    if ! printf '%s\n' "$expected" | diff -u --label expected --label got - "$got" > "$dir/d"; then
      printf '  FAIL  %s\n' "$name"; sed 's/^/          /' "$dir/d"
      fail=$((fail + 1)); return
    fi
    apply "$got" "$again"
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

  run_case "flow-style metadata is not edited silently" 5 \
'metadata: {name: a.example.com}
spec:
  group: example.com' ''

  run_case "an annotations key that is not a block is not edited silently" 4 \
'metadata:
  annotations: {}
  name: a.example.com
spec:
  group: example.com' ''

  run_case "a second document without metadata is not skipped silently" 3 \
'metadata:
  name: one.example.com
spec:
  group: example.com
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
spec:
  group: example.com' ''

  run_case "a second document with flow-style metadata is not skipped silently" 5 \
'metadata:
  name: one.example.com
spec:
  group: example.com
---
metadata: {name: two.example.com}
spec:
  group: example.com' ''

  run_case "a second document with a non-block annotations key is not skipped silently" 4 \
'metadata:
  name: one.example.com
spec:
  group: example.com
---
metadata:
  annotations: {}
  name: two.example.com' ''

  run_case "a blank line inside metadata does not split the block" 0 \
'metadata:

  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
  name: a.example.com' \
'metadata:

  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0
    helm.sh/resource-policy: keep
  name: a.example.com'

  run_case "a blank line inside the annotations block" 0 \
'metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0

    a: b
  name: a.example.com' \
'metadata:
  annotations:
    controller-gen.kubebuilder.io/version: v0.19.0

    a: b
    helm.sh/resource-policy: keep
  name: a.example.com'

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

  run_case "an input that does not parse is refused" 6 \
'metadata:
  annotations:
    a: b
      helm.sh/resource-policy: keep
  name: a.example.com' ''

  run_case "a deeper-indented annotations block keeps its own indentation" 0 \
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

  run_case "a deeper-indented metadata block keeps its own indentation" 0 \
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

  run_case "an empty annotations block" 0 \
'metadata:
  annotations:
  name: a.example.com
spec:
  group: example.com' \
'metadata:
  annotations:
    helm.sh/resource-policy: keep
  name: a.example.com
spec:
  group: example.com'

  run_case "an empty metadata block" 0 \
'metadata:
spec:
  group: example.com' \
'metadata:
  annotations:
    helm.sh/resource-policy: keep
spec:
  group: example.com'

  run_case "a leading document separator" 0 \
'---
metadata:
  name: a.example.com
spec:
  group: example.com' \
'---
metadata:
  name: a.example.com
  annotations:
    helm.sh/resource-policy: keep
spec:
  group: example.com'

  run_case "a comment before the first document" 0 \
'# generated
metadata:
  name: a.example.com
spec:
  group: example.com' \
'# generated
metadata:
  name: a.example.com
  annotations:
    helm.sh/resource-policy: keep
spec:
  group: example.com'

  printf '%d passed, %d failed\n' "$pass" "$fail"
  [[ $fail -eq 0 ]]
}

if [[ $mode == self-test ]]; then
  echo "hack/crd-keep.sh transform self-test"
  self_test
  exit
fi

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(find "$CRD_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "FAIL: no CRD files found under $CRD_DIR" >&2
  exit 1
fi
echo "$KEY: $VALUE on ${#files[@]} vendored CRDs"

rc=0
reason=""
out="$tmpdir/out.yaml"
for f in "${files[@]}"; do
  if ! apply "$f" "$out"; then
    printf '  FAIL  %s (%s)\n' "$f" "$reason"
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
