# Benchmarks

These scripts measure ovlens on a synthetic estate large enough to show how it
scales, and check that search ranking has not got worse. The numbers in the
main README's Status section come from them.

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

None of this runs in CI: the estate is a 128 MB download and 3.7 GB of copies.
