# ovlens

Documentation for the Puppet code an OpenVox server has deployed, for people
and AI assistants. Pre-release.

`ovlens generate` runs
[openvox-strings](https://github.com/voxpupuli/openvox-strings) over every
module in an environment and writes the JSON, with an index, to a directory
outside the code. `ovlens mcp` is a read-only
[MCP](https://modelcontextprotocol.io/) server over that output, so an
assistant can answer questions such as "which parameters does `profile::base`
take" or "which module provides `ensure_packages`" from what is really deployed.

## Install

### On an OpenVox server

Install the rpm or deb from the
[harpworks repository](https://packages.harpworks.org):

```shell
# RPM: RHEL, AlmaLinux, Rocky, CentOS Stream
sudo curl -fsSL https://packages.harpworks.org/rpm/harpworks.repo -o /etc/yum.repos.d/harpworks.repo
sudo dnf install ovlens
```

```shell
# DEB: Debian, Ubuntu
sudo curl -fsSL https://packages.harpworks.org/harpworks.asc -o /etc/apt/keyrings/harpworks.asc
echo "deb [signed-by=/etc/apt/keyrings/harpworks.asc] https://packages.harpworks.org/deb stable main" | sudo tee /etc/apt/sources.list.d/harpworks.list
sudo apt-get update && sudo apt-get install ovlens
```

The package carries its gems under `/opt/ovlens` and runs them with the
OpenVox agent's Ruby, so it needs `openvox-agent` and nothing else, and the
same package serves OpenVox 8 and 9. Installing it downloads nothing more. On
a server without internet access, copy the package over and install the file:

```shell
sudo dnf install ./ovlens_0.1.1_linux_noarch.rpm
```

The command is `/usr/bin/ovlens`. The
[ovlens Puppet module](https://github.com/miharp/puppet-ovlens) installs the
package and sets up regular generation.

### On a workstation

To run `ovlens mcp` on your own machine, install the gem. It is not published
on RubyGems; the harpworks repository carries it and its dependencies, so
`--clear-sources` installs from there alone:

```shell
gem install --clear-sources --source https://packages.harpworks.org/gems ovlens
```

It needs Ruby 3.2 or later. OpenVox is deliberately not a gem dependency:
`ovlens mcp` does not need it, and `ovlens generate` does, so add the `openvox`
gem if you generate on a workstation.

To build from a checkout instead: the gem with `gem build ovlens.gemspec`, the
packages with `script/release-assets` and `script/package`.

## Generate

```shell
ovlens generate [--environmentpath DIR] [--docs-dir DIR] [--all] [--force] [ENVIRONMENT ...]
```

- `--environmentpath` defaults to the `environmentpath` setting.
- `--docs-dir` defaults to `$OVLENS_DOCS_DIR`, then
  `/opt/puppetlabs/server/data/ovlens`.
- `--all` documents every environment. Without it, name the environments.
- `--force` parses every module again.

Modules are found through each environment's own `modulepath`, so
`site-modules` and the base module path are included.

Running it after every deploy or from a timer is cheap:

- A module is parsed only when its documented files have changed.
- Its files are read only when their sizes, times or inodes have changed, so
  an unchanged environment costs a directory walk, not a read of every file.
- A module's docs that already exist, in any environment and with the same
  input or the same output, are hard-linked, so an estate whose environments
  share most of their modules stores each module's docs about once.
- An environment with no changes is left untouched.

The first run after upgrading from 0.1 rewrites every environment once, without
parsing anything, to record the new metadata.

The exit code is 1 if an environment is missing or a module fails. A failed
module is recorded in the index and the rest of the environment is still
written. A module OpenVox itself cannot load, for example one with a broken
`metadata.json`, is left out and the reason goes to stderr.

### After an r10k deploy

r10k replaces `$modifiedenvs` with the environments it just deployed:

```yaml
postrun: ['/usr/bin/ovlens', 'generate', '$modifiedenvs']
```

### Output

```text
<docs-dir>/<environment>/index.json
<docs-dir>/<environment>/modules/<module>.json
```

Each `modules/<module>.json` is exactly what
`puppet strings generate --format json` writes for that module.

`index.json` lists the modules (name, version, path, fingerprint, entity count
or error) and one entry per entity:

```json
{ "name": "systemd::unit_file", "type": "defined_types", "module": "systemd", "summary": "Creates a systemd unit file" }
```

Entities tagged `@api private` carry `"private": true`, and providers carry the
`resource_type` they belong to.

Each run builds the environment's tree beside the old one and swaps it in, so
readers never see a partial result and removed modules disappear.

## MCP server

```shell
ovlens mcp [--docs-dir DIR]
```

The server contains no AI and needs no API key. An MCP client starts it as a
subprocess and talks to it over stdio.

| Tool | Answers |
| --- | --- |
| `list_modules` | Which modules and versions are deployed, and when the docs were generated |
| `search_code` | Which classes, defined types, functions, types, tasks or plans match some words |
| `get_docs` | The description, parameters with types and defaults, examples, file and line of one or more entities |

`search_code` looks at names, summaries and the full documentation text, and
hides entities marked `@api private` unless asked. An entity named exactly what
was searched for comes first, then those whose names contain more of the words;
within that, rarer words and words in the name or summary count for more.
Every tool takes an optional `environment`, which defaults to `production`.

The server builds an environment's search index on the first search there,
which takes under a second for a few hundred modules, and keeps those of the
three most recently used environments in memory.

`get_docs` takes several names in one call. A reply is kept to a size an MCP
client will pass on: an entity too large for it, such as a resource type with a
hundred properties, comes back shortened, with every parameter still listed,
and `parameters` then returns chosen ones in full.

Only the modules on an environment's module path are documented. Puppet's
built-in types and functions (`file`, `package`, `service`, `cron` and so on)
are not, and the server tells the assistant so.

For Claude Code, add this to `.mcp.json` in the project you work in:

```json
{
  "mcpServers": {
    "ovlens": {
      "command": "ovlens",
      "args": ["mcp", "--docs-dir", "/path/to/docs"]
    }
  }
}
```

Two ways to use it:

- **Locally.** Run `ovlens generate` against a control repo checkout after
  `r10k puppetfile install`, and point the server at the output.
- **Against a server.** Generate on the OpenVox server and start the MCP server
  there over SSH: `"command": "ssh", "args": ["openvox.example.com",
  "/usr/bin/ovlens", "mcp"]`. Nothing listens on the network.

## Development

```shell
bundle install
bundle exec rake    # rubocop and rspec
```

The specs in `spec/integration` run the real command with OpenVox and
openvox-strings.

Develop on Ruby 3.2, the oldest supported, as `.ruby-version` says. The
lockfile has to resolve for it, and `bundle install` on a newer Ruby adds gem
variants that 3.2 cannot install.

`Gemfile.lock` is committed and pins what ships: the packages and the gem
index are built from it, at the versions CI tested. Dependabot proposes
updates weekly. A merged update reaches servers only with the next release.

A `v*` tag releases: the workflow runs the checks, builds the gems, the rpm and
the deb, and attaches them to a GitHub Release. The harpworks repository picks
them up from there within the hour.

## Status

The packages were tested with every package repository disabled for the
install: the rpm on AlmaLinux 9 with openvox-agent 8.33.0 (Ruby 3.2), and the
deb on Ubuntu 24.04 with openvox-agent 9.4.0 (Ruby 4.0) with no locale set, as
under systemd.

With the [Puppet module](https://github.com/miharp/puppet-ovlens), 0.1.0 was
applied on 2026-11-16 to an OpenVox 9 server (AlmaLinux 10): the timer's
service documented 7 environments of 24 to 35 modules each in 4 seconds of
CPU, a second run left them unchanged in about a second, and the MCP server
answered over SSH in about 150 ms per call.

An assistant with only these tools answered questions about a 24-module
environment correctly, including writing resources with the parameter names
of the module versions deployed there. 0.1.1 fixes what that trial showed:
one call per entity, a resource type too large for one reply, and no word
that built-in types are not covered.

On a synthetic estate of the 296 most-downloaded Forge modules in 30
environments (3.7 GB of code, in a container with openvox-agent 8.33.0):

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

Most of the queries 0.2.0 still misses ask in other words than the docs use,
such as "kernel parameter" for `sysctl`.

Not tested on a package-installed OpenVox 8 server.
