#!/bin/zsh
# Runs the test suite with a stall watchdog: once tests are running, if no test starts for 40 s the stuck
# process is sampled (stacks in /tmp/convertable-sample.txt) and killed, instead of hanging a CI run forever.
# The build phase is not timed — a clean rebuild after a dependency update takes minutes.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
LOG=/tmp/convertable-test.log
swift test "$@" > "$LOG" 2>&1 &
TP=$!
last=""; same=0
while kill -0 $TP 2>/dev/null; do
  sleep 5
  cur=$(grep -c "started\." "$LOG")
  if [ "$cur" = "$last" ] && [ "$cur" -gt 0 ]; then same=$((same+1)); else same=0; fi
  last=$cur
  if [ $same -ge 8 ]; then
    echo "STALLED at:"; grep "started\." "$LOG" | tail -1
    XP=$(pgrep -f "xctest .*ConvertablePackageTests" | head -1)
    [ -n "$XP" ] && sample "$XP" 2 -file /tmp/convertable-sample.txt >/dev/null 2>&1 && echo "stacks: /tmp/convertable-sample.txt"
    pkill -f "xctest .*ConvertablePackageTests"; kill $TP 2>/dev/null
    exit 1
  fi
done
wait $TP; RC=$?
grep -E "error:|failed \(|Executed .* tests" "$LOG" | tail -8
exit $RC
