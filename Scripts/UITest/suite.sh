#!/bin/zsh
# UI smoke tests for Roger: drives the running app through the macOS Accessibility API and
# checks both what is on screen and what was saved to disk. Needs Roger running, Ollama with
# qwen2.5:14b and a thinking model (jaahas/qwen3.5-uncensored), and Accessibility permission
# for the terminal running this script. Each run creates one new chat named by the model.
HERE=${0:A:h}; ROOT=${HERE:h:h}
AX=$HERE/axdriver; CHK="python3 $HERE/chk.py"; LOG=$HERE/results.log; : > $LOG
[[ -x $AX && $AX -nt $HERE/axdriver.swift ]] || swiftc -O -o $AX $HERE/axdriver.swift || exit 1
chk(){ python3 $HERE/chk.py "$@"; }
pass=0; fail=0
log(){ echo "$(date +%H:%M:%S) $1" | tee -a $LOG; }
ok(){ log "PASS: $1"; pass=$((pass+1)); }
ko(){ log "FAIL: $1"; fail=$((fail+1)); }
check(){ local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else ko "$name"; fi }
has_text(){ $AX texts | grep -q -- "$1"; }
no_text(){ ! $AX texts | grep -q -- "$1"; }
last_has(){ chk last "$FILE" | grep -q -- "$1"; }
tools_have(){ chk tools "$FILE" | grep -q -- "$1"; }
wait_done(){ local t=${1:-240} i=0; while ((i<t)); do if $AX exists "Arrow Up Circle" && chk done "$FILE"; then sleep 1; return 0; fi; sleep 2; i=$((i+2)); done; log "timeout after ${t}s"; return 1; }
snap(){ log "   last: $(chk last "$FILE" | cut -c1-400)"; }

log "=== Roger UI test suite ==="
log "prompts: plain reply, list_directory, run_command with approval, swift code block, web_search via the configured route, stop mid-reply, sidebar search, thinking model, regenerate, jump to latest"
$AX key cmd+n; sleep 2
FILE=$(chk latest); log "chat file: $FILE"
check "1. ⌘N creates an empty chat" test "$(chk count "$FILE")" = "0"
$AX menu model "qwen2.5:14b"; sleep 2
check "2. model picker switches the chat to qwen2.5:14b" test "$(chk field "$FILE" model)" = "qwen2.5:14b"

log "--- P1 plain reply"
$AX type "Reply with exactly the text ROGER-OK-1 and nothing else."
wait_done 240; snap
check "3. reply contains ROGER-OK-1 (stored)" last_has "ROGER-OK-1"
check "4. reply visible on screen" has_text "ROGER-OK-1"
check "5. per-message model label shown" has_text "qwen2.5:14b"
check "6. token stats shown" has_text "tok/s"
check "7. user bubble shown" has_text "Reply with exactly"
i=0; while ((i<45)); do t=$(chk title "$FILE"); echo "$t" | grep -q '"generated": true' && ! echo "$t" | grep -q '"title": "New chat"' && break; sleep 3; i=$((i+3)); done
log "   title: $(chk title "$FILE")"
check "8. chat was auto-named by the model" sh -c "$CHK title '$FILE' | grep -q '\"generated\": true' && ! $CHK title '$FILE' | grep -q '\"title\": \"New chat\"'"

log "--- P2 read-only tool (list_directory)"
$AX type "List the files in $ROOT using your list_directory tool and tell me how many entries there are."
wait_done 300; snap
check "9. list_directory tool ran and finished" sh -c "$CHK tools '$FILE' | grep -q '\"list_directory\", \"done\"'"
check "10. tool output disclosure visible" $AX exists "lines of output"
check "11. answer mentions Roger project files" sh -c "$CHK last '$FILE' | grep -qiE 'README|project.yml|Roger'"

log "--- P3 command with approval"
$AX type "Run the shell command echo ROGER-CMD-OK with your run_command tool and show me the exact output."
if $AX wait "Allow" 180; then ok "12. approval card appeared with Allow button"; sleep 1; $AX press "Allow"; else ko "12. approval card appeared with Allow button"; fi
wait_done 300; snap
check "13. run_command finished with the expected output" sh -c "$CHK tools '$FILE' | grep -q '\"run_command\", \"done\", \"ROGER-CMD-OK'"
check "14. command output visible on screen" has_text "ROGER-CMD-OK"

log "--- P4 code block"
$AX type "Write a Swift function that reverses a string. Reply with only a swift fenced code block, no explanation."
wait_done 300; snap
check "15. reply contains a swift code block" last_has '```swift'
check "16. code block header shows language and Copy" sh -c "$AX texts | grep -qx 'swift' && $AX exists 'Copy'"

log "--- P5 web search through Tor"
$AX type "Use your web_search tool to find the official website of the Tor Project and tell me its URL."
wait_done 360; snap
check "17. web_search tool ran" sh -c "$CHK tools '$FILE' | grep -q '\"web_search\", \"done\"'"
check "18. search results mention torproject.org" sh -c "$CHK tools '$FILE' | grep -qi 'torproject.org'"
check "19. search card visible" has_text "Search the web for"

log "--- P6 stop mid-reply keeps partial output"
$AX type "Write a 1200-word story about a lighthouse keeper who finds a message in a bottle."
if $AX waitgone "Arrow Up Circle" 60; then
  sleep 8; log "   buttons while generating: $($AX buttons | grep -viE 'Hide Sidebar|New Chat|Models|Refresh|New Folder|Attachments|Copy|Thought|lines of output|Regenerate' | tr '\n' ';')"
  $AX press "Stop" || $AX key cmd+.
  ok "20. send button swapped for stop while generating"
else ko "20. send button swapped for stop while generating"; fi
wait_done 90; snap
check "21. stopped flag set, partial content kept" sh -c "$CHK last '$FILE' | grep -q '\"stopped\": true' && ! $CHK last '$FILE' | grep -q '\"content\": \"\"'"
check "22. 'Stopped · partial reply' badge visible" has_text "Stopped · partial reply"

log "--- P7 search chats"
$AX key cmd+f; sleep 1
$AX typeinto "Search chats" lighthouse; sleep 2
check "23. search filters out non-matching chats" no_text "Fixing Syntax Error"
check "24. matching snippet shown in sidebar" has_text "lighthouse"
$AX typeinto "Search chats" ""; $AX key escape; sleep 1
check "25. clearing search restores the list" has_text "Fixing Syntax Error"

check "26. context meter visible in composer" $AX exists "≈"
check "27. web/Tor status in sidebar footer" has_text "Web: Tor"

log "--- P8 thinking model"
$AX menu model "jaahas"; sleep 2
$AX type "What is 17 multiplied by 23? Think it through briefly, then give the final number."
wait_done 360; snap
check "28. thinking captured separately" sh -c "$CHK last '$FILE' | grep -qE '\"thinking_len\": [1-9]'"
check "29. 'Thought process' disclosure visible" $AX exists "Thought process"
check "30. correct answer 391 in visible reply" last_has "391"

log "--- P9 regenerate"
before=$(chk last "$FILE" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
$AX press "Regenerate"; sleep 3
wait_done 360; snap
after=$(chk last "$FILE" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
check "31. regenerate produced a new reply" test "$before" != "$after"

log "--- P10 jump to latest"
$AX scrollhid 20; sleep 1
check "32. 'Jump to' pill appears after scrolling up" $AX exists "Jump to"
$AX press "Jump to"; sleep 1
check "33. pill disappears after jumping" $AX waitgone "Jump to" 5

log "=== done: $pass passed, $fail failed ==="
