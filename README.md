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
sudo dnf install ./ovlens_0.1.0_linux_noarch.rpm
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

There is no release yet. Until the first one, build from a checkout: the gem
with `gem build ovlens.gemspec`, the packages with `script/release-assets` and
`script/package`.

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

A module is parsed only when its documented files have changed. Output for a
module seen before, in any environment, is copied, and an environment with no
changes is left untouched, so running it after every deploy or from a timer is
cheap.

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
| `get_docs` | One entity's description, parameters with types and defaults, examples, file and line |

`search_code` looks at names, summaries and the full documentation text, and
hides entities marked `@api private` unless asked. Every tool takes an optional
`environment`, which defaults to `production`.

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

`Gemfile.lock` is committed and pins what ships: the packages and the gem
index are built from it, at the versions CI tested. Dependabot proposes
updates weekly. A merged update reaches servers only with the next release.

A `v*` tag releases: the workflow runs the checks, builds the gems, the rpm and
the deb, and attaches them to a GitHub Release. The harpworks repository picks
them up from there within the hour.

## Status

Tested from locally built packages, with every package repository disabled for
the install:

- the rpm on AlmaLinux 9 with openvox-agent 8.33.0 (Ruby 3.2)
- the deb on Ubuntu 24.04 with openvox-agent 9.4.0 (Ruby 4.0), with no locale
  set, as under systemd

Both ran `ovlens generate`, including the reuse of unchanged modules, and
`ovlens mcp`.

An earlier script version of the generator was tested on 2026-11-16 on a
package-installed OpenVox 9 server (AlmaLinux 10, r10k 5.0.3): 7 environments
of 24 to 35 modules each in 18 seconds, as an r10k `postrun`, with the MCP
server started over SSH.

Not yet released, not yet tried from an assistant, and the release workflow
has not run on GitHub.
