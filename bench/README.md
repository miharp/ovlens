# Benchmarks

These scripts measure ovlens on a synthetic estate large enough to show how it
scales, and check that search ranking has not got worse. Results are at the
end.

```shell
bench/run            # build the estate if needed, then run every measurement
bench/run search     # only the ranking check
bench/run clean      # remove the container
```

They need Docker and nothing else on the host. Everything runs in a container
named `ovlens-bench` with a real OpenVox agent, which is kept between runs:
building the estate takes about two minutes and needs 4 GB of space in it.

## The estate

`modules.txt` pins the 296 most-downloaded Forge modules, with versions.
`make_envs.py` copies them into 30 environments (3.7 GB) as r10k would, and
drifts each copy: 10 modules get an edited manifest and 3 are removed. Keep
`modules.txt` fixed so that results stay comparable; `modules.py select 300`
prints the current list if the estate ever has to be renewed.

## What is measured

| Step | Script | Measures |
| --- | --- | --- |
| `generate` | `generate.sh` | Cold, unchanged and one-edit runs over all 30 environments; disk use |
| `mcp` | `mcp.py` | Start-up, first and later searches, lookups, and memory while visiting every environment |
| `search` | `search_eval.rb` | Ranking against the judged queries in `queries.yaml` |

`search` exits non-zero when fewer than `min_top3` of the judged queries have a
wanted entity in the top three results. The queries were written before any
ranking was tuned against them. Add queries rather than editing them, and raise
`min_top3` only when a change has earned it.

By default the checkout is measured, through `ovlens-dev`, which loads `lib/`
with the dependency gems of the installed package. To measure a release
instead:

```shell
OVLENS_BENCH_INSTALLED=1 OVLENS_BENCH_PACKAGE=ovlens-0.1.1 bench/run search
```

The package is installed only when the container has none, so run `bench/run
clean` first when switching versions.

To try a ranking change without editing `lib/`, put it in a file that reopens
`Ovlens::SearchIndex` and redefines `rank_key`, copy it into `bench/`, and load
it in the container with `-r`:

```shell
docker exec ovlens-bench /opt/puppetlabs/puppet/bin/ruby -I /src/lib -r /bench/variant.rb \
  /bench/search_eval.rb /srv/docs-search --verbose
```

## In CI

- **Every pull request and push to main** runs the ranking check, through
  `bench/search-check`: the same score as `bench/run search`, without Docker,
  using the checkout's bundle on one environment. The modules are cached on
  the hash of `modules.txt`. It fails the build below `min_top3`.
- **Weekly, on demand, and on pull requests that change `bench/`**, the
  Benchmark workflow runs `bench/run` for the checkout and for the latest
  release on the same runner, and puts both in the job summary, with the raw
  output kept as an artifact for 90 days. Only the checkout's ranking can fail
  it.

The runners are x86 machines with 4 CPUs, so their timings are not comparable
with the numbers in the main README, or from one week to the next. Compare the
checkout with the release within one run.

`bench/search-check` also works locally without Docker, but downloads the
modules onto the host: `bench/search-check [work dir]`, after `bundle install`.

## Results

0.1.1 against 0.2.0, on a 10-CPU Arm Mac:

| | 0.1.1 | 0.2.0 |
| --- | --- | --- |
| Generate all 30, cold | 55 s | 34 s |
| Generate all 30, nothing changed | 14 s | 3 s |
| Generate all 30, one manifest edited | 8 s | 4 s |
| Docs on disk | 646 MB | 50 MB |
| MCP server after searching all 30 | 418 MB | 294 MB |
| Search, index already built | 10 to 15 ms | 0 to 7 ms |
| Search, first in an environment | 0.25 s | 0.7 s |
| Judged queries with a wanted entity in the top 3 | 23 of 40 | 28 of 40 |

On a 4-CPU x86 GitHub runner the disk, memory and ranking results are the
same and unchanged runs are about a third faster, but a cold run takes as long
as with 0.1.1, about a minute: there the time goes to parsing, not to writing
copies.

Most of the queries 0.2.0 still misses ask in other words than the docs use,
such as "kernel parameter" for `sysctl`.
