# housekeep

Small Claude Code skills for keeping your dev workflow tidy.

Four self-contained skills. No external services, no shared state, no opinions beyond what's in each file. Drop them into `~/.claude/skills/` (or your project's `.claude/skills/`) and Claude Code will pick them up.

## The skills

| Skill | Trigger | What it does |
|-------|---------|--------------|
| [`todo`](skills/todo/SKILL.md) | `/todo <task>` | Append a task to `~/.claude/todos.md`. That's it. |
| [`do`](skills/do/SKILL.md) | `/do` | Show pending todos, pick one, execute it. |
| [`papercut`](skills/papercut/SKILL.md) | `/papercut <annoyance>` | Capture mid-conversation workflow friction to `~/.papercut/wiki.md` without derailing the current task. |
| [`audit-permission-requests`](skills/audit-permission-requests/SKILL.md) | `/audit-permission-requests` | Analyze the Claude Code permission log to find safe commands to auto-allow, wrapping opportunities, and settings consolidation. |

## Install

```bash
git clone https://github.com/aguerlain-lr/housekeep.git
mkdir -p ~/.claude/skills
cp -r housekeep/skills/* ~/.claude/skills/
```

Or symlink if you want updates from `git pull` to flow through:

```bash
for skill in housekeep/skills/*/; do
  ln -s "$PWD/$skill" "$HOME/.claude/skills/$(basename "$skill")"
done
```

## Philosophy

- **One job per skill.** A skill should be small enough that you can read it in 30 seconds.
- **Plain files, no daemons.** `~/.claude/todos.md` is just a markdown file. Edit it by hand any time.
- **Capture friction without breaking flow.** `/papercut` is for the things you'd never bother to file an issue about — log them and keep working.
- **Audit your own permission noise.** If Claude Code prompts you for the same command 50 times a week, that's a config bug, not a feature. The audit skill is how you find it.

## The `audit-permission-requests` setup

This one needs a hook to start logging permission requests. Add to `~/.claude/settings.json`:

```json
{
  "PermissionRequest": [{
    "hooks": [{
      "type": "command",
      "command": "jq --argjson noop 0 '. + {logged_at: (now | todate)}' >> ~/.claude/permission-requests.log",
      "async": true
    }]
  }]
}
```

The skill itself documents the full analysis flow once the log starts filling up.

## License

MIT. See [LICENSE](LICENSE).
