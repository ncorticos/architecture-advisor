# AI Services — settings.
# This file is config.zsh in ~/Library/Application Support/AI Services/. The installer never
# overwrites it; config.example.zsh next to it always holds the current defaults.
# Uncomment a line to change a setting.

# Order of the providers. Offline, only qwen is tried.
# AI_CHAIN=(claude longcat muse qwen)

# ---- Claude ----
# auto: Claude Code (your Claude subscription) first, then an Anthropic API key if one is
#       stored in the Keychain; cli: only Claude Code; api: only the API key.
# CLAUDE_METHOD=auto
# CLAUDE_CLI_MODEL=sonnet            # empty: Claude Code's default model
# CLAUDE_API_MODEL=claude-opus-5
# CLAUDE_API_EFFORT=medium           # low | medium | high
# CLAUDE_TIMEOUT=120                 # seconds
# Store an API key (optional):
#   security add-generic-password -U -s 'AI Services: Anthropic API key' -a "$USER" -w

# ---- LongCat 2.5 Preview Free on OpenCode Zen (its provider keeps no data; no dialog) ----
# LONGCAT_MODEL=longcat-2.5-preview-free   # any Zen chat-completions model, e.g. space-bunny-free
# LONGCAT_TIMEOUT=120

# ---- Muse Spark 1.3 Free on OpenCode Zen ----
# ask: a dialog asks before text is sent (Meta may train on this free tier's prompts)
# always: send without asking; never: skip Muse Spark and go straight to local Qwen
# MUSE_CONSENT=ask
# MUSE_MODEL=muse-spark-1.3-contributor-free
# MUSE_TIMEOUT=120
# LongCat and Muse Spark use the Zen key saved by OpenCode's /connect
# (~/.local/share/opencode/auth.json) when there is one, otherwise OpenCode's public free
# access. OPENCODE_API_KEY in the environment wins.

# ---- Qwen in Bionic (LM Studio runtime, local, works offline) ----
# QWEN_MODEL=                        # empty: first downloaded model with "qwen" in its name
# QWEN_TEMPERATURE=0.5
# QWEN_TIMEOUT=300                   # includes loading the model into memory
# LMSTUDIO_URL=http://127.0.0.1:1234
# LMSTUDIO_API_TOKEN=                # only if "Require Authentication" is on in LM Studio

# ---- Other ----
# NOTIFY=1                           # 0: no notifications (errors still show a dialog)
