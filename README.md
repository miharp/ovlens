# ovlens

Give your AI assistant the documentation for the Puppet code you actually
deploy.

An assistant writing Puppet code works from memory: the module versions it saw
in training, and none of your own modules. Its mistakes show up when a catalog
fails to compile. ovlens documents every module in your OpenVox environments,
at the versions deployed there, so the assistant can look things up before it
writes.

- **The versions you run.** puppetlabs-firewall 7 replaced `action` with
  `jump`. From memory, an assistant writes `action => 'accept'`; with ovlens it
  checks the deployed type and writes `jump => 'ACCEPT'`.
- **Your own modules.** Roles, profiles and internal modules an assistant has
  never seen are documented like any Forge module.
- **Every environment.** Production, staging and each feature branch, with its
  own module versions.
- **What a promotion changes.** Compare two environments: modules added,
  removed or changed, and the classes, types and functions that came and went.
- **Where a value comes from.** Optionally, your Hiera data too, with secrets
  masked: where a key is set, which class parameter it feeds, and keys for
  parameters that do not exist.
- **Safe on a server.** ovlens only reads. It has no AI and no API key, and
  nothing listens on the network: the assistant starts it over SSH.
- **Cheap to keep current.** Only changed modules are parsed, so a run after
  a deploy with nothing new takes seconds.

## How it works

`ovlens generate` runs
[openvox-strings](https://github.com/voxpupuli/openvox-strings) over every
module in an environment and stores the result outside the code. `ovlens mcp`
serves it to any [MCP](https://modelcontextprotocol.io/) client, such as
Claude Code, with four tools:

| Tool | Answers |
| --- | --- |
| `list_modules` | Which modules and versions an environment has |
| `search_code` | Which classes, defined types, functions, types, tasks or plans match some words |
| `get_docs` | The parameters, types, defaults, examples, file and line of one or more entities |
| `compare_environments` | What differs between two environments |

With [Hiera data](#hiera-data) indexed, three more:

| Tool | Answers |
| --- | --- |
| `find_hiera_key` | Where a key is set, with its values, and the class parameter it feeds |
| `hiera_for_class` | How each parameter of a class gets its value, and which have none |
| `check_hiera` | Keys for class parameters that do not exist |

## Quick start

Install the package on the OpenVox server from the
[harpworks repository](https://packages.harpworks.org). It runs on the OpenVox
agent's Ruby and carries everything else it needs, so one package serves
OpenVox 8 and 9, and a server without internet access can install the file:

```shell
# RHEL, AlmaLinux, Rocky, CentOS Stream
sudo curl -fsSL https://packages.harpworks.org/rpm/harpworks.repo -o /etc/yum.repos.d/harpworks.repo
sudo dnf install ovlens
```

```shell
# Debian, Ubuntu
sudo curl -fsSL https://packages.harpworks.org/harpworks.asc -o /etc/apt/keyrings/harpworks.asc
echo "deb [signed-by=/etc/apt/keyrings/harpworks.asc] https://packages.harpworks.org/deb stable main" | sudo tee /etc/apt/sources.list.d/harpworks.list
sudo apt-get update && sudo apt-get install ovlens
```

Document every environment:

```shell
sudo ovlens generate --all
```

Point your assistant at the server. For Claude Code, in `.mcp.json`:

```json
{
  "mcpServers": {
    "ovlens": { "command": "ssh", "args": ["openvox.example.com", "ovlens", "mcp"] }
  }
}
```

To keep the docs current, either use the
[Puppet module](https://github.com/miharp/puppet-ovlens), which installs
ovlens, regenerates on a timer, and can add an SSH account that can only run
the MCP server, or run it after every r10k deploy:

```yaml
postrun: ['/usr/bin/ovlens', 'generate', '$modifiedenvs']
```

### Without a server

To document a control repo checkout on your own machine (Ruby 3.2 or later),
install the gem, plus `openvox` to generate:

```shell
gem install --clear-sources --source https://packages.harpworks.org/gems ovlens
gem install openvox
r10k puppetfile install
mkdir -p ~/ovlens/environments && ln -s "$PWD" ~/ovlens/environments/production
ovlens generate --environmentpath ~/ovlens/environments --docs-dir ~/ovlens/docs production
```

Then use `"command": "ovlens", "args": ["mcp", "--docs-dir", "/home/you/ovlens/docs"]`
in `.mcp.json`.

## Reference

### ovlens generate

```shell
ovlens generate [--environmentpath DIR] [--docs-dir DIR] [--all] [--force]
                [--hiera [--hiera-mask PATTERN ...]] [ENVIRONMENT ...]
```

- `--environmentpath`: default, the `environmentpath` setting.
- `--docs-dir`: default, `$OVLENS_DOCS_DIR`, then
  `/opt/puppetlabs/server/data/ovlens`.
- `--all`: every environment. Otherwise, name them.
- `--force`: parse every module again.
- `--hiera`: index Hiera data too. See [Hiera data](#hiera-data).
- `--hiera-mask`: also mask the values of keys matching this pattern.

Modules come from each environment's own `modulepath`, `site-modules`
included. Each module's docs are written to
`<docs-dir>/<environment>/modules/<module>.json` in openvox-strings' JSON
format, with an `index.json` per environment. A module that is identical in
several environments is stored once, and readers never see a half-written
environment.

The exit code is 1 when an environment does not exist or a module fails; the
other modules are still documented.

### ovlens diff

```shell
ovlens diff [--docs-dir DIR] [--module NAME] [--json] FROM TO
```

Compares two documented environments, as `compare_environments` does: modules
added or removed, version changes, code that changed within the same version
(and whether its docs changed with it), and the entities added or removed.
Unchanged modules are only counted. It does not compare parameters.

```text
production -> staging
Modules: 1 added, 0 removed, 2 changed, 41 unchanged
Entities: 6 added, 1 removed

Added:
  + acme_backup 0.3.0 (4 entities)

Changed:
  ~ acme_web 1.4.0 -> 2.0.0 (docs changed)
      + acme_web::vhost (defined type)
      - acme_web::site (defined type)
  ~ profile 0.1.0, code changed (docs changed)
      + profile::backup (class)
```

### Hiera data

Off by default. With `generate --hiera`, ovlens reads each environment's
`hiera.yaml` and the `hiera.yaml` of each module that has one, and records
every key in every data file, with its level and file. It does not resolve
data for a node: `%{trusted.certname}` in a path matches every node's file.

Values are masked before they are written, so the docs directory holds no
secrets:

- eyaml values become `<encrypted>`. Nothing is decrypted.
- A key, or a key inside a hash, whose name matches `*password*`, `*passwd*`,
  `*secret*`, `*token*`, `*private_key*`, `*api_key*`, `*apikey*` or
  `*credential*` gets `<masked>`. Add patterns with `--hiera-mask`.

Other values are stored as written, for anyone who can read the docs
directory.

Not indexed: the global layer (`/etc/puppetlabs/puppet/hiera.yaml`), levels
whose backend does not read YAML, JSON or eyaml files (Vault, for example),
and configurations older than version 5. `check_hiera` lists these levels. A key that
Puppet code reads with `lookup()` is not reported as missing a parameter.

A `generate` run without `--hiera` removes the environment's Hiera data.

### ovlens hiera

```shell
ovlens hiera [--docs-dir DIR] [-e ENVIRONMENT] [--json] key KEY | class NAME | check
```

The Hiera tools on the command line. `check` exits 1 when it finds a key for
a parameter that does not exist or a data file it cannot read, so it can
gate a pull request.

### ovlens mcp

```shell
ovlens mcp [--docs-dir DIR]
```

Every tool takes an optional `environment`, `production` by default.
`search_code` ranks names and summaries above the body text and hides entities
marked `@api private` unless asked. `get_docs` takes several names at once,
shortens an entity too large for one reply, and returns chosen parameters in
full with `parameters`.

### Limits

- Puppet's built-in types and functions (`file`, `package`, `service`, `cron`
  and so on) are not documented, and the assistant is told so.
- Search matches words, not meanings: "kernel parameter" does not find
  `sysctl`. Assistants usually try other words.

On the 296 most-downloaded Forge modules in 30 environments, documenting
everything from scratch takes about a minute, a run with nothing changed takes
a few seconds, the docs take 50 MB, and the MCP server stays under 300 MB. See
[bench/README.md](bench/README.md).

## Development

```shell
bundle install
bundle exec rake    # rubocop and rspec
```

- Develop on Ruby 3.2, the oldest supported. `Gemfile.lock` must resolve for
  it, and it pins the gems the packages ship. Dependabot proposes updates
  weekly.
- `bench/run` benchmarks a large estate and checks search ranking against
  judged queries. CI runs the ranking check on every pull request.
- Changes go through pull requests. A `v*` tag on `main` releases: the gems,
  rpm and deb go to a GitHub Release, and the harpworks repository picks them
  up within the hour.
