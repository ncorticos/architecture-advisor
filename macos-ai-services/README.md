# AI Services for the macOS Services menu

Five entries in the Services menu — **AI: Add to Calendar**, **AI: Improve**, **AI: Reply**, **AI: Reply to Selection**, **AI: Resume** — replacing the "Claude: …" entries. Each one asks Claude first and falls back to another model when Claude cannot answer.

## Which AI answers

| Situation | Answered by |
|---|---|
| Online | **Claude** — Claude Code on your Claude subscription (`claude -p`); then an Anthropic API key, if one is stored |
| Online, Claude cannot answer: usage limit or credits used up, not signed in, error, no answer within 120 s | **LongCat 2.5 Preview Free** (`longcat-2.5-preview-free`) on OpenCode Zen |
| Online, LongCat cannot answer either | **Muse Spark 1.3 Free** (`muse-spark-1.3-contributor-free`) on OpenCode Zen, after a consent dialog |
| Offline, or Muse Spark fails, is rate-limited or declined | **Qwen** in Bionic (LM Studio runtime), on this Mac |

"Online" means Apple's connectivity check (`captive.apple.com`) or the Anthropic API answers within 4 s. Offline, Claude, LongCat and Muse Spark are skipped. Whenever a fallback answers, a notification names the model and the reason.

## What happens to the text

- **Claude**: processed by Anthropic under the terms of your plan or API account. Claude Code runs without tools, plugins or MCP servers and saves no transcript.
- **LongCat 2.5 Preview Free**: OpenCode's Zen documentation states that this model's provider "follows a zero-retention policy and does not use your data for model training"; all Zen models are hosted in the US. No dialog.
- **Muse Spark 1.3 Free**: the same documentation lists this free tier as "heavily discounted token pricing in exchange for permission to use your prompts and completions to train future Meta models". Emails often contain other people's personal data, so a dialog asks before anything is sent: *Use local Qwen*, *Send once* or *Always send*. `MUSE_CONSENT=never` in `config.zsh` skips Muse Spark entirely.
- **Qwen**: runs on this Mac; nothing leaves it.
- The log (`~/Library/Logs/AI Services.log`) records which model answered and why others failed — never the text.

## What each entry does

| Entry | Result |
|---|---|
| AI: Improve | replaces the selected text with the corrected version |
| AI: Reply | drafts the reply, copies it; paste with ⌘V |
| AI: Reply to Selection | drafts a reply to the selected passage only, copies it |
| AI: Resume | shows a summary (*resumo*) in a dialog and copies it |
| AI: Add to Calendar | opens the event in Calendar, which asks which calendar to add it to |

If an old "Claude: …" entry replaced the selected text, the installer makes its "AI: …" successor do the same. Replies and summaries answer in the language of the text; Portuguese is written in European Portuguese.

## Install

Requirements
- macOS 15 or later (`jq` ships with it; on older versions: `brew install jq`).
- For Claude: [Claude Code](https://code.claude.com) installed and signed in with your subscription. An API key is optional (see Settings).
- For offline use: [LM Studio Bionic](https://lmstudio.ai) with a Qwen model downloaded (Settings → Local Models → Explore).
- For LongCat and Muse Spark: nothing. OpenCode is optional; with it installed, run `/connect` to use your Zen key instead of the public free access.

In Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/ncorticos/architecture-advisor-pt/claude/exciting-shannon-33prun/macos-ai-services/install.zsh | zsh
```

(After this branch is merged, put `AI_SERVICES_REF=main` before `zsh`.) Or download this folder and run `zsh install.zsh`.

The installer:
1. copies the engine, prompts and settings to `~/Library/Application Support/AI Services/`;
2. moves `~/Library/Services/Claude: *.workflow` into `backup/<date>/` there, with a text copy of what each one ran;
3. creates the five "AI: …" Quick Actions in `~/Library/Services/`;
4. copies the keyboard shortcuts of the "Claude: …" entries to the new names;
5. refreshes the Services menu, runs each Quick Action once with a test marker (no AI is called) and prints the status of every provider.

If the "Claude: …" entries are Shortcuts rather than Quick Actions, the installer lists them; rename or delete them in the Shortcuts app.

## Try it in Terminal

```sh
S="$HOME/Library/Application Support/AI Services/ai-service"
"$S" --doctor                                          # what is installed and reachable
echo "Obrigado, vejo isso amanha e depois respondo." | "$S" improve --output stdout
echo "Obrigado, vejo isso amanha e depois respondo." | "$S" improve --output stdout --only qwen
```

`--only claude|longcat|muse|qwen` tests one provider.

## Settings

`~/Library/Application Support/AI Services/config.zsh` (the installer never overwrites it; `config.example.zsh` holds the defaults):

| Setting | Default | Meaning |
|---|---|---|
| `AI_CHAIN` | `(claude longcat muse qwen)` | order of the providers |
| `CLAUDE_METHOD` | `auto` | `auto`: Claude Code, then API key · `cli` · `api` |
| `CLAUDE_CLI_MODEL` | empty | e.g. `sonnet`; empty uses Claude Code's default |
| `CLAUDE_API_MODEL` | `claude-opus-5` | model for the API key |
| `LONGCAT_MODEL` | `longcat-2.5-preview-free` | any Zen chat-completions model, e.g. `space-bunny-free` |
| `MUSE_CONSENT` | `ask` | `ask` · `always` · `never` |
| `QWEN_MODEL` | empty | a model key from `lms ls`; empty takes the first Qwen model |
| `CLAUDE_TIMEOUT` / `LONGCAT_TIMEOUT` / `MUSE_TIMEOUT` / `QWEN_TIMEOUT` | 120 / 120 / 120 / 300 s | Qwen's includes loading the model |
| `NOTIFY` | `1` | `0` turns notifications off |

To store an Anthropic API key in the Keychain:

```sh
security add-generic-password -U -s 'AI Services: Anthropic API key' -a "$USER" -w
```

Prompts are in `prompts/`. To change one, copy it into `prompts.local/` and edit the copy; updates never touch `prompts.local/`. To be asked again before Muse Spark after choosing *Always send*, delete `state/muse-consent`.

## Uninstall

```sh
zsh "$HOME/Library/Application Support/AI Services/install.zsh" --uninstall
```

This removes the "AI: …" entries and restores the latest backed-up "Claude: …" ones.

## Troubleshooting

- **An entry is missing**: System Settings → Keyboard → Keyboard Shortcuts… → Services → Text; tick it. Logging out and in also refreshes the menu.
- **No notifications**: System Settings → Notifications → Script Editor → allow.
- **A Quick Action does nothing**: open it in Automator (`open -a Automator "$HOME/Library/Services/AI: Improve.workflow"`), save with ⌘S, try again.
- **Qwen is not found**: `--doctor` lists what LM Studio reports; set `QWEN_MODEL` to a key from `lms ls`.
- **Details of a failure**: `~/Library/Logs/AI Services.log`.

## Tests

```sh
zsh tests/run-tests.zsh
```

Runs the installer and the engine against stand-ins for every program and service (`tests/stubs/`, `tests/mock_server.py`), so it needs no Mac and sends nothing anywhere. Needs zsh, jq, curl and python3.

## Limits

- Tested with stand-ins, not yet on a Mac. The Quick Action files follow Automator's format, and the installer test-runs each one after creating it.
- OpenCode lists LongCat 2.5 Preview Free and Muse Spark 1.3 Contributor Free as free "for a limited time". When one goes, the chain skips to the next; `LONGCAT_MODEL` and `MUSE_MODEL` can name other Zen models.
- The prompts of the original "Claude: …" Services were not available; these are new. The text copies in `backup/<date>/` show what the old ones ran.
