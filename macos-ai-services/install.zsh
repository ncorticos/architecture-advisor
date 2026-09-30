#!/bin/zsh
# install.zsh — installs the "AI: …" entries of the macOS Services menu and the engine behind them.
#
#   zsh install.zsh               install or update
#   zsh install.zsh --uninstall   remove the AI: Services and put the old Claude: ones back
#
# Straight from GitHub, in Terminal:
#   curl -fsSL https://raw.githubusercontent.com/ncorticos/architecture-advisor-pt/claude/exciting-shannon-33prun/macos-ai-services/install.zsh | zsh
# (if that branch has been merged, add AI_SERVICES_REF=main before zsh)

emulate -R zsh
setopt pipe_fail extended_glob no_nomatch
zmodload zsh/datetime

REPO=ncorticos/architecture-advisor-pt
REF=${AI_SERVICES_REF:-claude/exciting-shannon-33prun}
DEST=${AI_SERVICES_HOME:-$HOME/Library/Application Support/AI Services}
SERVICES=${AI_SERVICES_DIR:-$HOME/Library/Services}
TEST_MODE=${AI_INSTALL_TEST:-}   # set by the tests: skips the steps that only exist on macOS
STAMP=$(strftime '%Y%m%d-%H%M%S' $EPOCHSECONDS)
SELF_DIR=${0:A:h}                # here, not in a function: there $0 is the function's name

# Menu title | action | output (used when no old Claude: Service says otherwise)
MENU=(
  "Add to Calendar|calendar|calendar"
  "Improve|improve|replace"
  "Reply|reply|clipboard"
  "Reply to Selection|reply-selection|clipboard"
  "Resume|resume|dialog"
)

typeset -gA OLD_MODE

say()  { print -r -- "$*" }
warn() { print -r -- "! $*" >&2 }
die()  { print -r -- "✗ $*" >&2; exit 1 }
mac()  { [[ -z $TEST_MODE ]] }

xml_escape() {
  local t=$1
  t=${t//&/&amp;}
  t=${t//</&lt;}
  t=${t//>/&gt;}
  print -rn -- $t
}

new_uuid() {
  local u
  u=$(uuidgen 2>/dev/null) || { [[ -r /proc/sys/kernel/random/uuid ]] && u=$(</proc/sys/kernel/random/uuid) } || u=$EPOCHSECONDS-$RANDOM-$RANDOM
  print -r -- ${(U)u}
}

describe() {
  case $1 in
    replace) print "replaces the selected text" ;;
    clipboard) print "copies the result and notifies you" ;;
    dialog) print "shows the result and copies it" ;;
    calendar) print "opens the event in Calendar" ;;
  esac
}

find_sources() {
  SRC=$SELF_DIR
  [[ -f $SRC/ai-service && -d $SRC/prompts ]] && return 0
  # Started with `curl … | zsh`: fetch the other files from GitHub.
  TMP_SRC=$(mktemp -d "${TMPDIR:-/tmp}/ai-services-src.XXXXXX") || die "No temporary folder"
  say "Downloading the AI Services files from github.com/$REPO ($REF)…"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" | tar -xzf - -C $TMP_SRC ||
    die "Download failed. Download the macos-ai-services folder and run: zsh install.zsh"
  local -a found=($TMP_SRC/*/macos-ai-services(N/))
  SRC=${found[1]:-}
  [[ -n $SRC && -f $SRC/ai-service ]] || die "The download does not contain macos-ai-services/"
}

preflight() {
  mac && [[ $OSTYPE != darwin* ]] && die "This installer is for macOS."
  local t
  for t in curl jq zsh; do
    whence -p $t > /dev/null || die "$t is missing. jq ships with macOS 15 and later; on older versions: brew install jq"
  done
  if mac; then
    for t in osascript plutil pbcopy defaults; do
      whence -p $t > /dev/null || die "$t is missing"
    done
  fi
}

install_files() {
  mkdir -p $DEST/{prompts,prompts.local,opencode/agents,state,work,events,backup} || die "Cannot write to $DEST"
  cp -f $SRC/ai-service $DEST/ai-service && chmod 755 $DEST/ai-service || die "Cannot copy the engine"
  cp -f $SRC/prompts/*.md $DEST/prompts/
  cp -f $SRC/opencode/agents/*.md $DEST/opencode/agents/
  cp -f $SRC/config.example.zsh $DEST/config.example.zsh
  [[ -e $DEST/config.zsh ]] || cp $SRC/config.example.zsh $DEST/config.zsh
  cp -f $SRC/install.zsh $DEST/install.zsh
  [[ -f $SRC/README.md ]] && cp -f $SRC/README.md $DEST/README.md
  mac && xattr -dr com.apple.quarantine $DEST 2>/dev/null   # files from a browser download
  say "✓ Engine and prompts in $DEST"
}

# Moves the old Claude: Services out of the menu (they stay in a backup folder) and notes
# whether each one replaced the selected text, so that the AI: version behaves the same way.
retire_claude_services() {
  local wf name dir=$DEST/backup/$STAMP n=0
  for wf in $SERVICES/Claude:*.workflow(N/); do
    name=${${wf:t:r}#Claude:}
    name=${name## ##}
    mkdir -p $dir
    if plutil -extract NSServices.0.NSReturnTypes xml1 -o /dev/null $wf/Contents/Info.plist > /dev/null 2>&1; then
      OLD_MODE[$name]=replace
    else
      OLD_MODE[$name]=noreplace
    fi
    # Keep a readable copy of what the old Service ran, to compare prompts later.
    if [[ -x /usr/libexec/PlistBuddy ]]; then
      /usr/libexec/PlistBuddy -c 'Print :actions' $wf/Contents/document.wflow > "$dir/${wf:t:r} — actions.txt" 2>/dev/null
    fi
    mv $wf $dir/ && (( n++ ))
  done
  (( n )) && say "✓ Moved $n Claude: Service(s) out of the menu, into $dir"
  return 0
}

make_workflow() {  # make_workflow TITLE ACTION OUTPUT
  local title=$1 action=$2 output=$3
  local wf="$SERVICES/AI: $title.workflow"
  local cmd="exec ${(qq)DEST}/ai-service $action --output $output"
  local returns= out_type=com.apple.Automator.nothing
  if [[ $output == replace ]]; then
    returns=$'\n\t\t\t<key>NSReturnTypes</key>\n\t\t\t<array>\n\t\t\t\t<string>public.utf8-plain-text</string>\n\t\t\t</array>'
    out_type=com.apple.Automator.text
  fi
  rm -rf -- $wf
  mkdir -p $wf/Contents || die "Cannot write to $SERVICES"

  cat > $wf/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AIServicesGenerated</key>
	<true/>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSBackgroundColorName</key>
			<string>background</string>
			<key>NSIconName</key>
			<string>NSActionTemplate</string>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>AI: $(xml_escape $title)</string>
			</dict>
			<key>NSMessage</key>
			<string>runWorkflowAsService</string>$returns
			<key>NSSendTypes</key>
			<array>
				<string>public.utf8-plain-text</string>
			</array>
			<key>NSTimeout</key>
			<string>600000</string>
		</dict>
	</array>
</dict>
</plist>
EOF

  cat > $wf/Contents/document.wflow <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key>
	<string>523</string>
	<key>AMApplicationVersion</key>
	<string>2.10</string>
	<key>AMDocumentVersion</key>
	<string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Optional</key>
					<true/>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>AMActionVersion</key>
				<string>2.0.3</string>
				<key>AMApplication</key>
				<array>
					<string>Automator</string>
				</array>
				<key>AMParameterProperties</key>
				<dict>
					<key>COMMAND_STRING</key>
					<dict/>
					<key>CheckedForUserDefaultShell</key>
					<dict/>
					<key>inputMethod</key>
					<dict/>
					<key>shell</key>
					<dict/>
					<key>source</key>
					<dict/>
				</dict>
				<key>AMProvides</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>ActionBundlePath</key>
				<string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key>
				<string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key>
					<string>$(xml_escape $cmd)</string>
					<key>CheckedForUserDefaultShell</key>
					<true/>
					<key>inputMethod</key>
					<integer>0</integer>
					<key>shell</key>
					<string>/bin/zsh</string>
					<key>source</key>
					<string></string>
				</dict>
				<key>BundleIdentifier</key>
				<string>com.apple.RunShellScript</string>
				<key>CFBundleVersion</key>
				<string>2.0.3</string>
				<key>CanShowSelectedItemsWhenRun</key>
				<false/>
				<key>CanShowWhenRun</key>
				<true/>
				<key>Category</key>
				<array>
					<string>AMCategoryUtilities</string>
				</array>
				<key>Class Name</key>
				<string>RunShellScriptAction</string>
				<key>InputUUID</key>
				<string>$(new_uuid)</string>
				<key>Keywords</key>
				<array>
					<string>Shell</string>
					<string>Script</string>
					<string>Command</string>
					<string>Run</string>
					<string>Unix</string>
				</array>
				<key>OutputUUID</key>
				<string>$(new_uuid)</string>
				<key>ShowWhenRun</key>
				<false/>
				<key>UUID</key>
				<string>$(new_uuid)</string>
				<key>UnlocalizedApplications</key>
				<array>
					<string>Automator</string>
				</array>
				<key>arguments</key>
				<dict>
					<key>0</key>
					<dict>
						<key>default value</key>
						<integer>0</integer>
						<key>name</key>
						<string>inputMethod</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>0</string>
					</dict>
					<key>1</key>
					<dict>
						<key>default value</key>
						<string></string>
						<key>name</key>
						<string>source</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>1</string>
					</dict>
					<key>2</key>
					<dict>
						<key>default value</key>
						<false/>
						<key>name</key>
						<string>CheckedForUserDefaultShell</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>2</string>
					</dict>
					<key>3</key>
					<dict>
						<key>default value</key>
						<string></string>
						<key>name</key>
						<string>COMMAND_STRING</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>3</string>
					</dict>
					<key>4</key>
					<dict>
						<key>default value</key>
						<string>/bin/sh</string>
						<key>name</key>
						<string>shell</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>4</string>
					</dict>
				</dict>
				<key>isViewVisible</key>
				<integer>1</integer>
				<key>location</key>
				<string>309.000000:253.000000</string>
				<key>nibPath</key>
				<string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
			</dict>
			<key>isViewVisible</key>
			<integer>1</integer>
		</dict>
	</array>
	<key>connectors</key>
	<dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>applicationBundleIDsByPath</key>
		<dict/>
		<key>applicationPaths</key>
		<array/>
		<key>inputTypeIdentifier</key>
		<string>com.apple.Automator.text</string>
		<key>outputTypeIdentifier</key>
		<string>$out_type</string>
		<key>presentationMode</key>
		<integer>11</integer>
		<key>processesInput</key>
		<integer>0</integer>
		<key>serviceInputTypeIdentifier</key>
		<string>com.apple.Automator.text</string>
		<key>serviceOutputTypeIdentifier</key>
		<string>$out_type</string>
		<key>serviceProcessesInput</key>
		<integer>0</integer>
		<key>systemImageName</key>
		<string>NSActionTemplate</string>
		<key>useAutomaticInputType</key>
		<integer>0</integer>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
EOF

  plutil -lint -s $wf/Contents/Info.plist $wf/Contents/document.wflow || die "The generated AI: $title Service is not a valid property list"
}

# Keyboard shortcuts and menu settings are stored per Service name: copy them to the new names.
migrate_shortcuts() {
  mac || return 0
  local tmp spec title entry n=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ai-services-pbs.XXXXXX") || return 0
  if ! defaults export pbs $tmp/pbs.plist 2>/dev/null; then
    rm -rf -- $tmp
    return 0
  fi
  cp $tmp/pbs.plist $DEST/backup/pbs-$STAMP.plist
  plutil -convert xml1 $tmp/pbs.plist 2>/dev/null
  for spec in $MENU; do
    title=${spec%%|*}
    entry=$(plutil -extract "NSServicesStatus.(null) - Claude: $title - runWorkflowAsService" json -o - $tmp/pbs.plist 2>/dev/null) || continue
    plutil -replace "NSServicesStatus.(null) - AI: $title - runWorkflowAsService" -json $entry $tmp/pbs.plist 2>/dev/null && (( n++ ))
  done
  if (( n )) && defaults import pbs $tmp/pbs.plist 2>/dev/null; then
    say "✓ Kept the keyboard shortcuts and menu settings of $n renamed Service(s)"
  fi
  rm -rf -- $tmp
  return 0
}

refresh_services() {
  mac || return 0
  /System/Library/CoreServices/pbs -flush > /dev/null 2>&1
  /System/Library/CoreServices/pbs -update > /dev/null 2>&1
  return 0
}

check_shortcuts() {  # Shortcuts named "Claude: …" also appear in the Services menu
  mac || return 0
  whence -p shortcuts > /dev/null || return 0
  local -a found
  found=(${(f)"$(shortcuts list < /dev/null 2>/dev/null | grep '^Claude: ')"})
  (( ${#found} )) || return 0
  warn "These Shortcuts still appear as “Claude: …” in the Services menu: ${(j:, :)found}"
  warn "Rename them to “AI: …” or delete them in the Shortcuts app."
}

run_limited() {  # run_limited SECONDS COMMAND... — stops COMMAND after SECONDS
  local secs=$1
  shift
  "$@" < /dev/null &
  local pid=$!
  ( sleep $secs; kill $pid 2>/dev/null ) < /dev/null > /dev/null 2>&1 &
  local watcher=$!
  wait $pid
  local rc=$?
  kill $watcher 2>/dev/null
  return $rc
}

selftest() {  # runs each Service once with a marker text; the engine answers without calling any AI
  mac || return 0
  whence -p automator > /dev/null || return 0
  local spec title out failed=0
  say "Test run of each Service (nothing is sent to any AI):"
  for spec in $MENU; do
    title=${spec%%|*}
    out=$(run_limited 60 automator -i __AI_SERVICES_SELFTEST__ "$SERVICES/AI: $title.workflow" 2>&1)
    if [[ $out == *AI-SERVICES-OK* ]]; then
      say "  ✓ AI: $title"
    else
      warn "  AI: $title did not run: ${out[1,300]}"
      failed=1
    fi
  done
  if (( failed )); then
    warn "Open that Service in Automator (open -a Automator \"$SERVICES/AI: <name>.workflow\"),"
    warn "save it once with ⌘S and try again from the Services menu."
  fi
  return 0
}

next_steps() {
  say ""
  say "Next steps"
  say "  • The five AI: entries are on by default. If one is missing from the menu:"
  say "    System Settings → Keyboard → Keyboard Shortcuts… → Services → Text."
  say "  • Offline answers need a Qwen model in Bionic: Settings → Local Models → Explore."
  say "  • LongCat and Muse Spark need no setup. To use your OpenCode Zen key: run opencode, then /connect."
  say "  • When Claude and LongCat both cannot answer, a dialog asks before any text goes to Muse Spark."
  say "  • Settings: $DEST/config.zsh"
  say "  • Your own prompts: copy a file from prompts/ into prompts.local/ and edit that copy."
}

uninstall() {
  local wf n=0
  local -a backups
  for wf in $SERVICES/AI:*.workflow(N/); do
    grep -q AIServicesGenerated $wf/Contents/Info.plist 2>/dev/null && rm -rf -- $wf && (( n++ ))
  done
  say "✓ Removed $n AI: Service(s)"
  backups=($DEST/backup/<->-<->(N/On))
  if (( ${#backups} )); then
    for wf in ${backups[1]}/*.workflow(N/); do
      if [[ -e $SERVICES/${wf:t} ]]; then
        warn "${wf:t:r} already exists; the backup stays in ${backups[1]}"
      else
        mv $wf $SERVICES/ && say "✓ Restored ${wf:t:r}"
      fi
    done
  fi
  refresh_services
  say "Settings and prompts stay in $DEST; delete that folder to remove them as well."
}

main() {
  case ${1:-} in
    --uninstall) uninstall; return ;;
    '') ;;
    *) say "usage: zsh install.zsh [--uninstall]"; return 2 ;;
  esac
  find_sources
  preflight
  mkdir -p $SERVICES || die "Cannot create $SERVICES"
  install_files
  retire_claude_services
  local spec title action output
  for spec in $MENU; do
    title=${spec%%|*}
    action=${${spec#*|}%%|*}
    output=${spec##*|}
    # Keep what the old Claude: Service did with the selection.
    case ${OLD_MODE[$title]:-} in
      replace) [[ $action != calendar ]] && output=replace ;;
      noreplace) [[ $output == replace ]] && output=dialog ;;
    esac
    make_workflow $title $action $output
    say "✓ AI: $title — $(describe $output)"
  done
  migrate_shortcuts
  refresh_services
  check_shortcuts
  selftest
  say ""
  $DEST/ai-service --doctor < /dev/null
  next_steps
  [[ -n ${TMP_SRC:-} ]] && rm -rf -- $TMP_SRC
  return 0
}

main "$@"
