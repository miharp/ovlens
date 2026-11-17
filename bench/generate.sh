#!/bin/bash
# generate.sh <ovlens command> <docs dir> <environments dir>
#
# The generate measurements: a cold run over every environment, an unchanged
# rerun, a run after one manifest edit, and one named environment. Restores
# the edited file afterwards, so the estate is the same for the next run.
set -u
cmd=$1 docs=$2 envs=$3
count=$(find "$envs" -mindepth 1 -maxdepth 1 -type d | wc -l)
rm -rf "$docs"
run() {
  local label=$1
  shift
  /usr/bin/time -f "%e s elapsed, %U s user, %S s sys, %M KB max RSS" -o /tmp/time.txt "$@" > /tmp/out.txt 2> /tmp/err.txt
  echo "$label: $(cat /tmp/time.txt)"
}
run "cold, all $count" "$cmd" generate --environmentpath "$envs" --docs-dir "$docs" --all
echo "  modules parsed: $(grep -o '([0-9]* parsed)' /tmp/out.txt | tr -dc '0-9\n' | awk '{s+=$1} END {print s}')"
echo "  docs on disk: $(du -sh "$docs" | cut -f1) (du counts a hard-linked file once)"
echo "  module files: $(find "$docs" -path '*/modules/*.json' | wc -l), distinct: $(find "$docs" -path '*/modules/*.json' -printf '%i\n' | sort -u | wc -l)"
run "unchanged, all $count" "$cmd" generate --environmentpath "$envs" --docs-dir "$docs" --all
echo "  $(grep -c ': unchanged' /tmp/out.txt) of $count reported unchanged"
file=$envs/team07_feature/modules/apache/manifests/init.pp
cp -p "$file" /tmp/init.pp.saved
echo "# edit" >> "$file"
run "one manifest edited, all $count" "$cmd" generate --environmentpath "$envs" --docs-dir "$docs" --all
grep -v ': unchanged' /tmp/out.txt | sed 's/^/  /'
echo "# edit 2" >> "$file"
run "one manifest edited, that environment named" "$cmd" generate --environmentpath "$envs" --docs-dir "$docs" team07_feature
sed 's/^/  /' /tmp/out.txt
cp -p /tmp/init.pp.saved "$file"
