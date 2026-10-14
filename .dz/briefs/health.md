# Brief: is the project healthy?

Daily checkup, fired by `schedules: health` in `.dz/maintainer/maintainer.yml`. Wurk is maintained
so that nobody has to watch it. This brief covers the failures no issue or PR announces.

| Signal | Command | Healthy |
|---|---|---|
| `main` is green | `gh run list --workflow test.yml --branch main --event push --limit 1 --json conclusion,headSha` | `success` |
| the last release published | `gh run list --workflow release.yml --limit 1 --json conclusion,displayTitle` | `success` |
| RubyGems serves `Wurk::VERSION` | `gem list wurk --remote --exact` vs `lib/wurk/version.rb` | equal, or a release run is in flight |
| the demo deployed | `gh run list --workflow deploy-demo.yml --limit 1 --json conclusion` | `success` |
| topology and ecosystem lanes | `gh run list --workflow topology.yml --limit 1` · `--workflow ecosystem.yml` | `success` |
| Dependabot is not stuck | `gh pr list --author app/dependabot --json number,createdAt` | none older than 7 days |

For each unhealthy signal, file one ask unless an open issue already names it. The title names the
signal (`main is red at <sha>`, `release <v> did not publish`), and the body carries the command,
its output and the run URL. A red `main` comes first: nothing releases from it. Recovery is
`RELEASE.md`'s *If a release fails*. Never delete a tag, re-run a publish or `gem push` from here.
