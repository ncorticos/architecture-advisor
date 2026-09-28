#!/bin/zsh
# Tests for the installer and the engine. Every external program and service is replaced by a
# stand-in (tests/stubs, tests/mock_server.py), so nothing is sent anywhere and no macOS is needed.
#
#   zsh tests/run-tests.zsh        (needs zsh, jq, curl and python3)

emulate -R zsh
setopt pipe_fail extended_glob no_nomatch

HERE=${0:A:h}
ROOT=${HERE:h}
T=$(mktemp -d "${TMPDIR:-/tmp}/ai-services-test.XXXXXX")
MOCK_PID=
cleanup() {
  [[ -n $MOCK_PID ]] && kill $MOCK_PID 2>/dev/null
  rm -rf -- $T
}
trap cleanup EXIT INT TERM

export HOME=$T/home
export STUB_LOG=$T/stub MOCK_STATE=$T/mock
export PATH=$HERE/stubs:$PATH
export AI_LOCALE=C.UTF-8
export TZ=Europe/Lisbon
export AI_SERVICES_LOG=$T/ai.log
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
unset ANTHROPIC_API_KEY OPENCODE_API_KEY XDG_DATA_HOME
mkdir -p $HOME $STUB_LOG $MOCK_STATE
chmod +x $HERE/stubs/* $ROOT/ai-service
cd $T   # away from the sources, as when installing from Terminal

python3 $HERE/mock_server.py $MOCK_STATE &
MOCK_PID=$!
for i in {1..50}; do
  [[ -s $MOCK_STATE/port ]] && break
  sleep 0.1
done
URL=http://127.0.0.1:$(<$MOCK_STATE/port)

PASSED=0 FAILED=0
ok()  { (( PASSED++ )); print -r -- "  ✓ $1" }
bad() { (( FAILED++ )); print -r -- "  ✗ $1"; [[ -n ${2:-} ]] && print -r -- "      $2" }
expect() {  # expect DESCRIPTION CONDITION...
  local d=$1
  shift
  if "$@"; then ok $d; else bad $d "failed: $*"; fi
}
expect_eq() {  # expect_eq DESCRIPTION ACTUAL EXPECTED
  if [[ $2 == $3 ]]; then ok $1; else bad $1 "expected ${(qqq)3}, got ${(qqq)2}"; fi
}
contains() { [[ $1 == *$2* ]] }
lacks() { [[ $1 != *$2* ]] }

plist() {  # plist FILE EXPRESSION — evaluates EXPRESSION on the parsed property list d
  python3 -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); print(eval(sys.argv[2]))' $1 $2
}
requests() {  # requests PATH — number of requests the mock received on PATH
  [[ -r $MOCK_STATE/requests.jsonl ]] || { print 0; return }
  jq -s --arg p $1 '[.[] | select(.path == $p)] | length' $MOCK_STATE/requests.jsonl
}
request() {  # request PATH FILTER — FILTER applied to the last request on PATH
  jq -s -r --arg p $1 "[.[] | select(.path == \$p)] | last | $2" $MOCK_STATE/requests.jsonl
}
events() {  # events KIND — the texts of the recorded dialogs or notifications, one per line
  [[ -r $STUB_LOG/osascript.jsonl ]] || return 0
  jq -r --arg k $1 'select(.kind == $k) | .text' $STUB_LOG/osascript.jsonl
}
claude_args() { [[ -r $STUB_LOG/claude.args ]] && tr '\0' '\n' < $STUB_LOG/claude.args }   # one argument per line, empty ones kept

# ------------------------------------------------------------------ installer

print "Installer"
SERVICES=$HOME/Library/Services
DEST="$HOME/Library/Application Support/AI Services"
OLD="$SERVICES/Claude: Reply.workflow"   # an old Service that replaced the selection
mkdir -p $OLD/Contents
cat > $OLD/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>NSServices</key><array><dict>
<key>NSMenuItem</key><dict><key>default</key><string>Claude: Reply</string></dict>
<key>NSMessage</key><string>runWorkflowAsService</string>
<key>NSReturnTypes</key><array><string>public.utf8-plain-text</string></array>
<key>NSSendTypes</key><array><string>public.utf8-plain-text</string></array>
</dict></array></dict></plist>
EOF
print -r -- '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > $OLD/Contents/document.wflow

AI_INSTALL_TEST=1 AI_ASSUME_ONLINE=1 zsh $ROOT/install.zsh > $T/install.log 2>&1
expect_eq "installer succeeds" $? 0
for name in "Add to Calendar" Improve Reply "Reply to Selection" Resume; do
  wf="$SERVICES/AI: $name.workflow"
  expect_eq "“AI: $name” is in the Services menu" "$(plist $wf/Contents/Info.plist 'd["NSServices"][0]["NSMenuItem"]["default"]' 2>&1)" "AI: $name"
  expect "“AI: $name” has a valid workflow document" python3 -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' $wf/Contents/document.wflow
done
expect "no Claude: Service is left in the menu" test -z "$(print -rl -- $SERVICES/Claude:*(N))"
expect "the old Claude: Reply is kept in a backup" test -n "$(print -rl -- $DEST/backup/*/Claude:\ Reply.workflow(N))"
# The keys of a Run Shell Script action as Automator saves it (taken from an Automator-made Service).
AUTOMATOR_KEYS="['AMAccepts', 'AMActionVersion', 'AMApplication', 'AMParameterProperties', 'AMProvides', 'ActionBundlePath', 'ActionName', 'ActionParameters', 'BundleIdentifier', 'CFBundleVersion', 'CanShowSelectedItemsWhenRun', 'CanShowWhenRun', 'Category', 'Class Name', 'InputUUID', 'Keywords', 'OutputUUID', 'ShowWhenRun', 'UUID', 'UnlocalizedApplications', 'arguments', 'isViewVisible', 'location', 'nibPath']"
expect_eq "the Run Shell Script action has the keys Automator writes" "$(plist "$SERVICES/AI: Improve.workflow/Contents/document.wflow" 'sorted(d["actions"][0]["action"])')" $AUTOMATOR_KEYS
expect_eq "the text arrives on stdin, run by zsh" "$(plist "$SERVICES/AI: Improve.workflow/Contents/document.wflow" '(d["actions"][0]["action"]["ActionParameters"]["inputMethod"], d["actions"][0]["action"]["ActionParameters"]["shell"])')" "(0, '/bin/zsh')"
cmd=$(plist "$SERVICES/AI: Improve.workflow/Contents/document.wflow" 'd["actions"][0]["action"]["ActionParameters"]["COMMAND_STRING"]')
expect_eq "Improve runs the engine" "$cmd" "exec ${(qq)DEST}/ai-service improve --output replace"
expect_eq "Improve replaces the selection" "$(plist "$SERVICES/AI: Improve.workflow/Contents/Info.plist" '"NSReturnTypes" in d["NSServices"][0]')" True
expect_eq "Resume does not replace the selection" "$(plist "$SERVICES/AI: Resume.workflow/Contents/Info.plist" '"NSReturnTypes" in d["NSServices"][0]')" False
expect_eq "Reply keeps the old Service's behaviour (replace)" "$(plist "$SERVICES/AI: Reply.workflow/Contents/document.wflow" 'd["actions"][0]["action"]["ActionParameters"]["COMMAND_STRING"].split()[-1]')" replace
expect_eq "Reply to Selection copies to the clipboard" "$(plist "$SERVICES/AI: Reply to Selection.workflow/Contents/document.wflow" 'd["workflowMetaData"]["serviceOutputTypeIdentifier"]')" com.apple.Automator.nothing
expect "the settings file is created" test -r "$DEST/config.zsh"
expect "the OpenCode agent is installed" test -r "$DEST/opencode/agents/ai-services.md"

# Point the engine at the stand-ins.
cat >> "$DEST/config.zsh" <<EOF
CLAUDE_CLI_BIN=$HERE/stubs/claude
LMS_BIN=$HERE/stubs/lms
OPENCODE_BIN=$HERE/stubs/opencode
CLAUDE_API_URL=$URL/v1/messages
MUSE_URL=$URL/zen/v1/responses
LMSTUDIO_URL=$URL
ONLINE_CHECK_URL=$URL/hotspot
[[ -r $T/overrides.zsh ]] && source $T/overrides.zsh
EOF

# ------------------------------------------------------------------ engine helpers

SSE_OK='{"status": 200, "sse": [
  {"type": "response.created", "response": {"id": "resp_1"}},
  {"type": "response.output_text.delta", "delta": "Muse "},
  {"type": "response.output_text.delta", "delta": "answer"},
  {"type": "response.completed", "response": {"output": [{"type": "message", "content": [{"type": "output_text", "text": "Muse answer"}]}]}}]}'
ZEN_429='{"status": 429, "body": {"error": {"message": "Rate limit exceeded for free models"}}}'
MODELS='{"models": [
  {"type": "llm", "key": "google/gemma-4-26b", "display_name": "Gemma 4 26B", "loaded_instances": [{"id": "gemma"}]},
  {"type": "llm", "key": "qwen/qwen3.6-35b-a3b", "display_name": "Qwen3.6 35B A3B", "loaded_instances": [],
   "capabilities": {"vision": false, "trained_for_tool_use": true, "reasoning": {"allowed_options": ["off", "on"]}}},
  {"type": "embedding", "key": "text-embedding-qwen3", "display_name": "Qwen3 Embedding"}]}'
QWEN_OK='{"status": 200, "body": {"model_instance_id": "qwen/qwen3.6-35b-a3b", "output": [{"type": "reasoning", "content": "…"}, {"type": "message", "content": "Qwen answer"}]}}'

scenario() {  # scenario JSON — clean logs and state, set the mock's answers
  rm -rf -- $STUB_LOG $MOCK_STATE/requests.jsonl $MOCK_STATE/lms_down "$DEST/state" $T/overrides.zsh
  mkdir -p $STUB_LOG
  print -r -- $1 > $MOCK_STATE/scenario.json
  unset CLAUDE_SCENARIO CLAUDE_TEXT DIALOG_ANSWER AI_ASSUME_ONLINE STUB_API_KEY OPENCODE_TEXT
}
override() { print -r -- $1 >> $T/overrides.zsh }
run() {  # run INPUT ACTION [ARGS...] — sets OUT (exact stdout) and RC
  local raw
  raw=$(print -rn -- $1 | "$DEST/ai-service" "${@[2,-1]}" 2> $T/stderr; print -rn -- "|$?")
  RC=${raw##*|}
  OUT=${raw%|*}
}

TEXT="Olá Ana, envio em anexo a versão revista do relatorio. Diz-me se podemos reunir na proxima semana."

# ------------------------------------------------------------------ engine

print "\nClaude answers"
scenario '{}'
export CLAUDE_TEXT="Olá Ana, envio em anexo a versão revista do relatório."
run "$TEXT" improve --output replace
expect_eq "the improved text replaces the selection" "$OUT" "$CLAUDE_TEXT"
args=$(claude_args)
expect "Claude Code runs in print mode with JSON output" contains "$args" "--output-format"$'\n'"json"
expect "Claude Code runs without tools (the empty --tools value is kept)" contains "$args" "--tools"$'\n'$'\n'"--system-prompt"
expect "Claude Code runs without customisations or a saved transcript" contains "$args" "--safe-mode"
expect "the system prompt holds the shared rules and the task" contains "$args" "Task — Improve"
expect "the selected text reaches Claude on stdin" contains "$(<$STUB_LOG/claude.stdin)" "<selected_text>"$'\n'$TEXT
expect_eq "no other provider is asked" "$(requests /zen/v1/responses)$(requests /api/v1/chat)" 00
expect_eq "no notification when Claude answers" "$(events notification)" ""

print "\nClaude out of tokens → Muse Spark (consent given before)"
scenario "{\"zen\": $SSE_OK}"
export CLAUDE_SCENARIO=limit
override MUSE_CONSENT=always
run "$TEXT" improve --output replace
expect_eq "Muse Spark's answer replaces the selection" "$OUT" "Muse answer"
expect_eq "the free model is requested" "$(request /zen/v1/responses .body.model)" muse-spark-1.3-contributor-free
expect_eq "without an OpenCode key the public free access is used" "$(request /zen/v1/responses '.headers.authorization')" "Bearer public"
expect_eq "the request identifies this tool" "$(request /zen/v1/responses '.headers["x-opencode-client"]')" ai-services
expect_eq "the system prompt travels as the system message" "$(request /zen/v1/responses '.body.input[0].role')" system
expect_eq "nothing is stored on the gateway" "$(request /zen/v1/responses '.body.store')" false
expect "the notification names Muse Spark and the reason" contains "$(events notification)" "Muse Spark 1.3 (OpenCode) (Claude: no tokens left"
expect_eq "no consent dialog when consent is 'always'" "$(events dialog)" ""

print "\nConsent dialog: send once"
scenario "{\"zen\": $SSE_OK}"
export CLAUDE_SCENARIO=limit DIALOG_ANSWER="Send once"
run "$TEXT" resume
expect "the dialog warns that Meta may train on the text" contains "$(events dialog | head -n 20)" "Meta may use the text"
expect "the dialog says why Claude cannot answer" contains "$(events dialog)" "no tokens left (usage limit)"
expect_eq "the summary is copied" "$(<$STUB_LOG/clipboard.txt)" "Muse answer"
expect "the summary is shown in a dialog" contains "$(events dialog)" "Muse answer"
expect "a one-off consent is not remembered" test ! -e "$DEST/state/muse-consent"

print "\nConsent dialog: always send"
scenario "{\"zen\": $SSE_OK}"
export CLAUDE_SCENARIO=limit DIALOG_ANSWER="Always send"
run "$TEXT" improve --output replace
expect_eq "Muse Spark answers" "$OUT" "Muse answer"
expect_eq "the choice is remembered" "$(<$DEST/state/muse-consent)" always

print "\nConsent dialog: keep the text on this Mac → Qwen"
scenario "{\"zen\": $SSE_OK, \"lms_models\": $MODELS, \"lms_chat\": $QWEN_OK}"
export CLAUDE_SCENARIO=limit DIALOG_ANSWER=""
run "$TEXT" improve --output replace
expect_eq "Qwen answers" "$OUT" "Qwen answer"
expect_eq "nothing is sent to OpenCode Zen" "$(requests /zen/v1/responses)" 0
expect_eq "a downloaded Qwen model is chosen (not the loaded Gemma, not an embedding)" "$(request /api/v1/chat .body.model)" qwen/qwen3.6-35b-a3b
expect_eq "Qwen's thinking is switched off" "$(request /api/v1/chat .body.reasoning)" off
expect_eq "a model loaded on demand gets room for long emails" "$(request /api/v1/chat .body.context_length)" 8192
expect_eq "the chat is not stored by LM Studio" "$(request /api/v1/chat .body.store)" false
expect "the notification names Qwen and Bionic" contains "$(events notification)" "Qwen · qwen/qwen3.6-35b-a3b (Bionic, local)"

print "\nOpenCode key from /connect"
scenario "{\"zen\": $SSE_OK}"
mkdir -p $HOME/.local/share/opencode
print -r -- '{"opencode": {"type": "api", "key": "sk-zen-test"}}' > $HOME/.local/share/opencode/auth.json
export CLAUDE_SCENARIO=limit
override MUSE_CONSENT=always
run "$TEXT" improve --output replace
expect_eq "the Zen key saved by OpenCode is used" "$(request /zen/v1/responses '.headers.authorization')" "Bearer sk-zen-test"
rm -f $HOME/.local/share/opencode/auth.json

print "\nMuse Spark rate-limited → Qwen"
scenario "{\"zen\": $ZEN_429, \"lms_models\": $MODELS, \"lms_chat\": $QWEN_OK}"
export CLAUDE_SCENARIO=limit
override MUSE_CONSENT=always
run "$TEXT" reply
expect_eq "the reply from Qwen is copied" "$(<$STUB_LOG/clipboard.txt)" "Qwen answer"
expect "the notification lists both reasons" contains "$(events notification)" "Claude: no tokens left (usage limit); Muse Spark: no tokens left (usage limit)"
expect_eq "the OpenCode CLI is not tried after a rate limit" "$(print -r -- $STUB_LOG/opencode.args(N))" ""

print "\nOffline → Qwen directly"
scenario "{\"online\": false, \"lms_models\": $MODELS, \"lms_chat\": $QWEN_OK}"
run "$TEXT" improve --output replace
expect_eq "Qwen answers" "$OUT" "Qwen answer"
expect "Claude is not tried" test ! -e $STUB_LOG/claude.calls
expect_eq "OpenCode Zen is not tried" "$(requests /zen/v1/responses)" 0
expect "the notification says offline" contains "$(events notification)" "(offline)"

print "\nLM Studio's server is off → started with lms"
scenario "{\"online\": false, \"lms_models\": $MODELS, \"lms_chat\": $QWEN_OK}"
: > $MOCK_STATE/lms_down
run "$TEXT" improve --output replace
expect_eq "Qwen answers" "$OUT" "Qwen answer"
expect "lms starts the server" contains "$(<$STUB_LOG/lms.log)" "server start"

print "\nNothing answers"
scenario "{\"zen\": $ZEN_429, \"lms_models\": $MODELS, \"lms_chat\": {\"status\": 500, \"body\": {\"error\": {\"message\": \"Model crashed\"}}}}"
export CLAUDE_SCENARIO=limit
override MUSE_CONSENT=always
run "  $TEXT"$'\n' improve --output replace
expect_eq "the selection is left unchanged" "$OUT" "  $TEXT"$'\n'
expect "a dialog explains why" contains "$(events dialog)" "No AI could answer."
expect "the dialog shows Qwen's error" contains "$(events dialog)" "Model crashed"

print "\nOlder Claude Code: usage limit reported as an answer"
scenario "{\"zen\": $SSE_OK}"
export CLAUDE_SCENARIO=old-limit
override MUSE_CONSENT=always
run "$TEXT" improve --output replace
expect_eq "the limit is recognised and Muse Spark answers" "$OUT" "Muse answer"

print "\nOlder Claude Code: unknown flag → plain call"
scenario '{}'
export CLAUDE_SCENARIO=badflag CLAUDE_TEXT="Claude answer"
run "$TEXT" improve --output replace
expect_eq "Claude answers on the second try" "$OUT" "Claude answer"
expect "the second call leaves out the newer flags" lacks "$(claude_args)" "--safe-mode"

print "\nClaude hangs → timeout"
scenario "{\"zen\": $SSE_OK}"
export CLAUDE_SCENARIO=hang
override MUSE_CONSENT=always
override CLAUDE_TIMEOUT=2
start=$EPOCHREALTIME
run "$TEXT" improve --output replace
elapsed=$(( EPOCHREALTIME - start ))
expect_eq "Muse Spark answers after the timeout" "$OUT" "Muse answer"
expect "the Service does not wait for the stopped process (${elapsed%.*} s)" test ${elapsed%.*} -lt 8

print "\nClaude API key: credits used up → Muse Spark"
scenario "{\"anthropic\": {\"status\": 402, \"body\": {\"type\": \"error\", \"error\": {\"type\": \"billing_error\", \"message\": \"Your credit balance is too low\"}}}, \"zen\": $SSE_OK}"
export STUB_API_KEY=sk-ant-test
override CLAUDE_METHOD=api
override MUSE_CONSENT=always
run "$TEXT" improve --output replace
expect_eq "Muse Spark answers" "$OUT" "Muse answer"
expect_eq "the API key is sent as a header" "$(request /v1/messages '.headers["x-api-key"]')" sk-ant-test
expect_eq "server-side refusal fallback is requested" "$(request /v1/messages '.body.fallbacks')" default
expect_eq "with its beta header" "$(request /v1/messages '.headers["anthropic-beta"]')" server-side-fallback-2026-07-01
expect_eq "the default API model" "$(request /v1/messages .body.model)" claude-opus-5

print "\nClaude API: beta not enabled → plain request"
scenario '{"anthropic": [{"status": 400, "body": {"type": "error", "error": {"type": "invalid_request_error", "message": "Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."}}}, {"status": 200, "body": {"model": "claude-opus-5", "stop_reason": "end_turn", "content": [{"type": "text", "text": "API answer"}]}}]}'
export STUB_API_KEY=sk-ant-test
override CLAUDE_METHOD=api
run "$TEXT" improve --output replace
expect_eq "the retried request answers" "$OUT" "API answer"
expect_eq "the retry has no fallbacks parameter" "$(request /v1/messages '.body.fallbacks')" null

print "\nAuto: Claude Code out of usage, API key stored → API"
scenario '{"anthropic": {"status": 200, "body": {"model": "claude-opus-5", "stop_reason": "end_turn", "content": [{"type": "text", "text": "API answer"}]}}}'
export CLAUDE_SCENARIO=limit STUB_API_KEY=sk-ant-test
run "$TEXT" improve --output replace
expect_eq "the API answers" "$OUT" "API answer"

print "\nOpenCode Zen refuses the direct call → OpenCode CLI"
scenario '{"zen": {"status": 401, "body": {"error": {"message": "Unauthorized client"}}}}'
export CLAUDE_SCENARIO=limit OPENCODE_TEXT="OpenCode answer"
override MUSE_CONSENT=always
run "$TEXT" improve --output replace
expect_eq "OpenCode's answer is used" "$OUT" "OpenCode answer"
expect_eq "OpenCode reads the tool-less agent from the Services folder" "$(<$STUB_LOG/opencode.configdir)" "$DEST/opencode"
expect "OpenCode runs the free Muse Spark model with the tool-less agent" contains "$(tr '\0' ' ' < $STUB_LOG/opencode.args)" "--agent ai-services -m opencode/muse-spark-1.3-contributor-free"

print "\nAdd to Calendar"
scenario '{}'
export CLAUDE_TEXT='{"title": "Reunião de júri, sala 2.14", "start": "2026-11-02T10:00", "end": null, "all_day": false, "timezone": "Atlantic/Azores", "location": "Ponta Delgada; Campus", "notes": null, "url": null}'
run "Reunião dia 2 de novembro às 10h (hora dos Açores)." calendar
ics=$(<$STUB_LOG/opened.ics 2>/dev/null)
expect "Calendar is asked to open an event" contains "$ics" "BEGIN:VEVENT"
expect "10:00 in the Azores is 11:00 UTC in November" contains "$ics" "DTSTART:20261102T110000Z"
expect "without an end time the event lasts one hour" contains "$ics" "DTEND:20261102T120000Z"
expect "commas and semicolons are escaped" contains "$ics" 'SUMMARY:Reunião de júri\, sala 2.14'
expect "the location is kept" contains "$ics" 'LOCATION:Ponta Delgada\; Campus'
expect "lines end in CRLF" contains "$ics" $'END:VEVENT\r\n'
expect "the notification gives the date and time zone" contains "$(events notification)" "2026-11-02 10:00 (Atlantic/Azores)"

scenario '{}'
export CLAUDE_TEXT='```json
{"title": "Entrega do relatório", "start": "2026-10-30", "end": "2026-10-31", "all_day": true, "timezone": null}
```'
run "Entrega até 30 e 31 de outubro." calendar
ics=$(<$STUB_LOG/opened.ics 2>/dev/null)
expect "an all-day event uses dates" contains "$ics" "DTSTART;VALUE=DATE:20261030"
expect "the inclusive last day becomes the exclusive end" contains "$ics" "DTEND;VALUE=DATE:20261101"

scenario '{}'
export CLAUDE_TEXT='{"error": "no event"}'
run "Obrigado pela mensagem." calendar
expect "no event: nothing is opened" test ! -e $STUB_LOG/opened.ics
expect "no event: the user is told" contains "$(events notification)" "No event with a date"

print "\nOutput clean-up"
scenario "{\"online\": false, \"lms_models\": $MODELS, \"lms_chat\": {\"status\": 200, \"body\": {\"output\": [{\"type\": \"message\", \"content\": \"<think>plan</think>\\n\`\`\`\\nClean text\\n\`\`\`\"}]}}}"
run $'\n'"Draft text"$'\n\n' improve --output replace
expect_eq "think blocks and a wrapping code fence are removed; outer blank lines kept" "$OUT" $'\n'"Clean text"$'\n\n'

print "\nOther behaviour"
scenario '{}'
run "__AI_SERVICES_SELFTEST__" improve --output replace
expect_eq "the installer's test marker is answered without any AI" "$OUT" "AI-SERVICES-OK improve replace"$'\n'
expect "no AI is called for the marker" test ! -e $STUB_LOG/claude.calls
run "   " improve --output replace
expect_eq "an empty selection is left as it is" "$OUT" "   "

scenario '{}'
override 'CLAUDE_CLI_MODEL=sonnet'
export CLAUDE_TEXT=ok
run "$TEXT" improve --output stdout
expect "a model can be chosen for Claude Code" contains "$(claude_args)" "--model"$'\n'"sonnet"

scenario "{\"zen\": $SSE_OK, \"lms_models\": $MODELS, \"lms_chat\": $QWEN_OK}"
override 'MUSE_CONSENT=never'
export CLAUDE_SCENARIO=limit
run "$TEXT" improve --output replace
expect_eq "MUSE_CONSENT=never skips Muse Spark" "$OUT|$(requests /zen/v1/responses)" "Qwen answer|0"
expect "the log holds no text from the selection" lacks "$(<$AI_SERVICES_LOG)" "relatorio"

print "\nUninstall"
AI_INSTALL_TEST=1 zsh $ROOT/install.zsh --uninstall > $T/uninstall.log 2>&1
expect "the AI: Services are removed" test -z "$(print -rl -- $SERVICES/AI:*(N))"
expect "the old Claude: Reply is restored" test -d "$SERVICES/Claude: Reply.workflow"

print "\n$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
