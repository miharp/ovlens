# frozen_string_literal: true

require 'optparse'
require_relative '../ovlens'

module Ovlens
  # The `ovlens` command. Each subcommand loads only what it needs, so
  # `ovlens mcp` works without OpenVox and `ovlens generate` without the MCP SDK.
  module CLI
    USAGE = <<~TEXT.freeze
      Usage: ovlens generate [options] [ENVIRONMENT ...]   document environments after a deploy
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
      options = { all: false, force: false }
      OptionParser.new do |o|
        o.banner = 'Usage: ovlens generate [options] [ENVIRONMENT ...]'
        o.on('--environmentpath DIR', 'Directory holding the environments (default: the environmentpath setting)') do |v|
          options[:environmentpath] = File.expand_path(v)
        end
        o.on('--docs-dir DIR', 'Where to write the documentation') { |v| options[:docs_dir] = v }
        o.on('--all', 'Document every environment in the environmentpath') { options[:all] = true }
        o.on('--force', 'Parse every module again, even when nothing changed') { options[:force] = true }
      end.parse!(argv)

      require_relative 'generator'
      generator = Generator.new(
        docs_dir: Ovlens.docs_dir(options[:docs_dir]), environmentpath: options[:environmentpath],
        force: options[:force], out: out, err: err
      )
      # r10k substitutes "$modifiedenvs" as one space-separated argument.
      generator.run(argv.flat_map(&:split).uniq, all: options[:all]) ? 0 : 1
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
