# frozen_string_literal: true

require 'optparse'
require_relative '../ovlens'

module Ovlens
  # The `ovlens` command. Each subcommand loads only what it needs, so
  # `ovlens mcp` works without OpenVox and `ovlens generate` without the MCP SDK.
  module CLI
    USAGE = <<~TEXT.freeze
      Usage: ovlens generate [options] [ENVIRONMENT ...]   document environments after a deploy
             ovlens diff [options] FROM TO                 compare the modules of two documented environments
             ovlens hiera key KEY | class NAME | check      look up indexed Hiera data (generate --hiera)
             ovlens mcp [--docs-dir DIR]                   serve the documentation to an MCP client over stdio
             ovlens version

      Run `ovlens generate --help` for its options. The documentation directory
      defaults to $OVLENS_DOCS_DIR, then #{DEFAULT_DOCS_DIR}.
    TEXT

    # Returns the process exit status.
    def self.run(argv, out: $stdout, err: $stderr)
      # Puppet code and the generated JSON are UTF-8 whatever the locale says,
      # and a systemd unit or an SSH forced command often runs with none. This
      # covers the libraries ovlens calls as well as its own reads.
      Encoding.default_external = Encoding::UTF_8
      argv = argv.dup
      case argv.shift
      when 'generate' then generate(argv, out, err)
      when 'diff' then diff(argv, out)
      when 'hiera' then hiera(argv, out)
      when 'mcp' then mcp(argv)
      when 'version', '--version', '-v' then out.puts(VERSION) || 0
      when nil, 'help', '--help', '-h' then out.puts(USAGE) || 0
      else
        err.puts USAGE
        2
      end
    rescue Error, OptionParser::ParseError => e
      err.puts "ovlens: #{e.message}"
      2
    end

    def self.generate(argv, out, err)
      options = { all: false, force: false, hiera: false, masks: [] }
      OptionParser.new do |o|
        o.banner = 'Usage: ovlens generate [options] [ENVIRONMENT ...]'
        o.on('--environmentpath DIR', 'Directory holding the environments (default: the environmentpath setting)') do |v|
          options[:environmentpath] = File.expand_path(v)
        end
        o.on('--docs-dir DIR', 'Where to write the documentation') { |v| options[:docs_dir] = v }
        o.on('--all', 'Document every environment in the environmentpath') { options[:all] = true }
        o.on('--force', 'Parse every module again, even when nothing changed') { options[:force] = true }
        o.on('--hiera', 'Index Hiera data too, with secrets masked (off by default)') { options[:hiera] = true }
        o.on('--hiera-mask PATTERN', 'Also mask values of keys matching this pattern, such as *ldap*') do |v|
          options[:masks] << v
        end
      end.parse!(argv)

      require_relative 'generator'
      require_relative 'hiera_index'
      generator = Generator.new(
        docs_dir: Ovlens.docs_dir(options[:docs_dir]), environmentpath: options[:environmentpath],
        force: options[:force], hiera: options[:hiera],
        hiera_masks: HieraIndex::DEFAULT_MASKS + options[:masks], out: out, err: err
      )
      # r10k substitutes "$modifiedenvs" as one space-separated argument.
      generator.run(argv.flat_map(&:split).uniq, all: options[:all]) ? 0 : 1
    end

    def self.diff(argv, out)
      options = {}
      OptionParser.new do |o|
        o.banner = 'Usage: ovlens diff [--docs-dir DIR] [--module NAME] [--json] FROM TO'
        o.on('--docs-dir DIR', 'Where the documentation is') { |v| options[:docs_dir] = v }
        o.on('--module NAME', 'Compare only this module') { |v| options[:module] = v }
        o.on('--json', 'Print JSON instead of text') { options[:json] = true }
      end.parse!(argv)
      raise Error, 'diff needs two environments: ovlens diff FROM TO' unless argv.size == 2

      require 'json'
      require_relative 'comparison'
      require_relative 'docs'
      docs = Docs.new(Ovlens.docs_dir(options[:docs_dir]))
      comparison = Comparison.new(docs, *argv.map { |name| docs.resolve(name) }, module_name: options[:module])
      out.puts(options[:json] ? JSON.pretty_generate(comparison.to_h) : comparison.text)
      0
    end

    def self.hiera(argv, out)
      options = {}
      parser = OptionParser.new do |o|
        o.banner = 'Usage: ovlens hiera [--docs-dir DIR] [-e ENVIRONMENT] [--json] key KEY | class NAME | check'
        o.on('--docs-dir DIR', 'Where the documentation is') { |v| options[:docs_dir] = v }
        o.on('-e', '--environment NAME', 'The environment (default: production)') { |v| options[:environment] = v }
        o.on('--json', 'Print JSON instead of text') { options[:json] = true }
      end
      parser.parse!(argv)
      command, subject = argv
      valid = (%w[key class].include?(command) && argv.size == 2) || (command == 'check' && argv.size == 1)
      raise Error, parser.banner.delete_prefix('Usage: ') unless valid

      require 'json'
      require_relative 'docs'
      require_relative 'hiera_query'
      require_relative 'hiera_text'
      docs = Docs.new(Ovlens.docs_dir(options[:docs_dir]))
      query = HieraQuery.new(docs, docs.resolve(options[:environment]))
      result = case command
               when 'key' then query.find(subject)
               when 'class' then query.for_class(subject)
               else query.check
               end
      out.puts(options[:json] ? JSON.pretty_generate(result) : HieraText.public_send(HieraText::FOR[command], result))
      # `check` fails when something needs fixing, so it can gate CI.
      command == 'check' && (result['unknown_parameters'].any? || result['errors'].any?) ? 1 : 0
    end

    def self.mcp(argv)
      docs_dir = nil
      OptionParser.new do |o|
        o.banner = 'Usage: ovlens mcp [--docs-dir DIR]'
        o.on('--docs-dir DIR', 'Where the documentation is') { |v| docs_dir = v }
      end.parse!(argv)

      require_relative 'mcp_server'
      McpServer.run(Ovlens.docs_dir(docs_dir))
      0
    end
  end
end
