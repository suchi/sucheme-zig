#!/bin/sh
# PreToolUse hook for Edit/Write and Bash (registered in .claude/settings.json).
#
# Asks for user confirmation before the agent modifies the files that make up
# this repository's security guardrails, and denies reading secret files
# through a shell (AGENTS.md: security section). Both guards also work in
# auto-accept permission modes, because a hook decision outranks the
# permission rules.
#
# Edit/Write are matched on their file_path. Bash is matched on the command
# text as well, because a shell reaches both sets without going through the
# guarded tool: it writes a guarded file with a redirection, sed -i, cp or
# mv, and it reads a secret file with cat or grep, which the Read deny rules
# in .claude/settings.json cannot see. The Bash allow list in that file makes
# those commands run without a prompt, so this is where the two sets are
# held.
#
# The patterns are deliberately coarse and match the text anywhere, so a
# relative path cannot slip past an anchor and a command that merely names a
# guarded file is treated like one that writes it. Over-asking is the
# intended failure direction. Read these files with the Read tool, which the
# deny rules cover, rather than through a shell.
#
# Requires jq to parse the hook payload (jq is a prerequisite tool of this
# repository). If jq is missing or the payload does not parse, the hook asks
# instead of deciding, so the guard fails safe rather than silently
# allowing everything.

input=$(cat)

emit() {
  # $1: permission decision (deny|ask), $2: reason (escaped by jq)
  jq -cn --arg decision "$1" --arg reason "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $decision, permissionDecisionReason: $reason}}'
  exit 0
}

if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"jq is required by this hook but was not found. Install jq (a prerequisite tool of this repository)."}}\n'
  exit 0
fi

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null) ||
  emit ask "Failed to parse the hook payload as JSON. Confirm with the user first."
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) ||
  emit ask "Failed to parse the hook payload as JSON. Confirm with the user first."

# Edit/Write carry a file_path, Bash carries a command, and no tool carries
# both, so one subject covers every caller. Backslashes become slashes first
# because Windows-native setups pass paths such as
# C:\repo\.claude\settings.json, which the patterns below would miss.
subject=$(printf '%s%s' "$path" "$cmd" | tr '\\' '/')

[ -n "$subject" ] || exit 0

has() {
  # `--` keeps a pattern that starts with a dash from being read as an option.
  printf '%s' "$subject" | grep -Eq -- "$1"
}

# --- Secret files: never read, never write -------------------------------

secret=false

# A dotted suffix is a template (.env.example and its siblings) and holds no
# values; a bare .env or any other suffix holds them.
if has '(^|[^[:alnum:]_.-])\.env([^.[:alnum:]]|$)'; then secret=true; fi
if has '(^|[^[:alnum:]_.-])\.env\.[[:alnum:]]'; then
  if ! has '\.env\.(example|sample|template)([^[:alnum:]]|$)'; then secret=true; fi
fi

# A file name must precede the extension, so a shell or jq expression such as
# '.key' is not mistaken for a key file.
if has '[[:alnum:]_.-]\.(pem|key|p12|pfx)([^[:alnum:]]|$)'; then secret=true; fi
if has '(^|[^[:alnum:]_.-])(secrets|\.ssh|\.aws)/'; then secret=true; fi

if [ "$secret" = true ]; then
  emit deny "Refusing to touch a secret file. Secret values must not reach the conversation, the logs or a commit (AGENTS.md: security). This matches the Read deny rules in .claude/settings.json."
fi

# --- Guardrail configuration: ask the user first --------------------------

case "$subject" in
*.claude/settings.json* | *.claude/settings.local.json* | *.claude/hooks* | *.github/workflows* | *.github/dependabot.yml*)
  emit ask "Touching security-related configuration: $subject. Requires user approval (AGENTS.md: security)."
  ;;
esac

# --- An alternate build script: ask the user first -------------------------

# `zig build` is on the allow list, and a permission rule matches by command
# prefix, so it also covers `zig build --build-file <path>/build.zig`, which
# runs that file's Zig code on the host at configure time. A prefix cannot
# exclude a flag that may appear anywhere in the command, so the flag is held
# here instead.
if has '--build-file([[:space:]=]|$)'; then
  emit ask "Running a build script other than this repository's build.zig executes that script's code on the host. Confirm with the user first (ADR-0025)."
fi

exit 0
