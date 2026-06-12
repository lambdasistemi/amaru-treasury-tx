# `skills/`

[Agent Skills](https://agentskills.io/home) for the
`amaru-treasury-tx` repo. Vendor-neutral activatable procedures any
compatible LLM agent (Claude Code, OpenAI Codex, Cursor, GitHub
Copilot, Gemini CLI, OpenCode, Goose, OpenHands, Cline, Roo Code,
Amp, Junie, Kiro, …) will discover by name + description and load
on demand.

The format is a folder per skill with a required `SKILL.md`
(YAML frontmatter `name` + `description`, then a markdown body)
and optional `references/`, `scripts/`, `assets/`. Spec at
[anthropics/skills](https://github.com/anthropics/skills); the
SKILL.md grammar is documented at
[deepwiki/anthropics/skills](https://deepwiki.com/anthropics/skills/2.2-skill.md-format-specification).

## Discovery model

Each skill loads in three stages:

1. **Discovery** at session start: only the YAML frontmatter
   (`name`, `description`) is in context (~100 words per skill).
2. **Activation** when a task matches the description: the full
   `SKILL.md` body loads.
3. **Execution**: the body links into `references/<file>.md` /
   `scripts/<file>` on demand.

That means a vague `description` field will never trigger — write
descriptions that name concrete verbs, file paths, error strings,
and library names so a matching prompt finds the skill.

## Skills in this repo

### `amaru-treasury-tx-guide/`

Orientation for working *on* this codebase: repository map, build /
test / run commands, where each feature is implemented, how `tx-build`
dispatches on the intent action, where the intent schema and golden
fixtures live, and where the answers to common user questions are
documented. Load this first when navigating or modifying the repo.

Triggers: "where is the swap/disburse/withdraw builder", "how does the
API indexer work", "how do I add a CLI flag or a wizard", `just ci` /
`just smoke` / `nix flake check`, GHC 9.12.3 + haskell.nix, fourmolu
70-column, and questions about what the repo does.

### `amaru-treasury-tx-operator/`

End-to-end operator workflow for the treasury tx pipeline:
intent → unsigned CBOR → detached witnesses → assembled signed
tx → inspect → validate → submit → archive into the in-repo
`transactions/` log. Conducts a one-time first-run interview on
new hosts and stores the answers at
`~/.config/amaru-treasury-tx/operator.json` so subsequent runs
propose complete commands without re-asking for paths, vault
locations, or scope-owner identities.

Triggers: `amaru-treasury-tx`, any `*-wizard` subcommand,
`attach-witness`, `treasury-inspect`, anything about signing for
or archiving a treasury transaction.

## Adding a new skill

1. Create `skills/<lowercase-kebab-name>/SKILL.md`.
2. Required frontmatter:

   ```yaml
   ---
   name: <lowercase-kebab-name>
   description: One paragraph describing what the skill does and exactly when an agent should load it. Be specific about triggers — verbs, file paths, error strings, library names — because this is the only text in context until the skill activates.
   ---
   ```

3. Push heavy content into `references/<topic>.md` and link from
   the body. The body should be lean (progressive disclosure).
4. Folder name == frontmatter `name`.
5. Don't duplicate the skill under `.claude/skills/`,
   `.cursor/rules/`, or any other tool-specific path —
   `skills/<name>/SKILL.md` is the canonical location and every
   compatible agent finds it from there.
6. Mention the new skill in `../AGENTS.md` so cross-tool agents
   that read the root pointer file discover it.

## Why this layout

`skills/<name>/SKILL.md` is the cross-vendor convention used by
the [Anthropic skills repository](https://github.com/anthropics/skills),
[agentskills.io](https://agentskills.io/home), and the ~35 tools
that implement it. `AGENTS.md` at the repo root is the
complementary [agents.md](https://agents.md) entry point used by
60k+ open-source projects and OpenAI Codex, Cursor, Copilot,
Aider, etc. Together they give portable, progressive context
loading without locking the repo to any single agent.
