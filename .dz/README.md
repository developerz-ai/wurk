# `.dz/`

Repo-scoped configuration for the developerz.ai maintainer agent lives here,
under the namespace each config belongs to:

- `pipeline/`: the agent pipeline definition (`agent-pipeline.json`).
- `maintainer/`: the maintainer policy (`maintainer.yml`).
- `briefs/`: what each scheduled checkup in `maintainer.yml` does.
- `schedules/`: briefs for lanes not registered yet (`docs-drift.md`).

The maintainer agent reads its policy from `maintainer/maintainer.yml` here,
preferring it over the repository root. The root `.maintainer.yml` is still
honored as a legacy fallback until it is deprecated, so nothing breaks while
a repo carries both.

Three agent configs stay at the repository root, because the tools that read
them look there and nowhere else:

- `.coderabbit.yml`: CodeRabbit (https://docs.coderabbit.ai/configure-coderabbit)
- `.mcp.json`: Claude Code (https://code.claude.com/docs/en/mcp)
- `.ui-debugger-mcp.json`: the UI debugger MCP

Docs: https://developerz.ai/docs/maintainer-yml
