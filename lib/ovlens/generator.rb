# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require 'tmpdir'
require_relative '../ovlens'
require_relative 'fingerprint'
require_relative 'index'

module Ovlens
  # Runs openvox-strings over every module in an environment and writes the
  # JSON, with an index, to a directory outside the code.
  #
  # A module is only parsed when its fingerprint is new. Output for a
  # fingerprint seen before, in any environment, is copied; an environment
  # whose modules are all unchanged is not rewritten at all.
  class Generator
    # Bump when the shape of the output changes, so earlier output is rebuilt.
    FORMAT = 1
    YARD_ARGS = %w[--no-save --no-stats --no-yardopts --no-document --quiet].freeze

    def initialize(docs_dir:, environmentpath: nil, force: false, out: $stdout, err: $stderr)
      @docs_dir = docs_dir
      @environmentpath = environmentpath
      @force = force
      @out = out
      @err = err
    end

    # Documents the named environments, or all of them. Returns true when
    # every one succeeded.
    def run(names, all: false)
      load_openvox
      environments = Puppet.lookup(:environments)
      names = environments.list.map { |e| e.name.to_s } if all
      if names.empty?
        @out.puts 'No environments given; nothing to do.'
        return true
      end

      FileUtils.mkdir_p(@docs_dir)
      names.map { |name| document(environments.get(name), name) }.all?
    end

    private

    # Settings load in the user run mode, so an environmentpath set only in the
    # [server] section of puppet.conf has to be passed explicitly.
    def load_openvox
      require 'puppet'
      require 'yard'
      require 'openvox-strings'
      Puppet.initialize_settings(@environmentpath ? ['--environmentpath', @environmentpath] : [])
      # OpenVox skips a module it cannot load (broken metadata.json, say) and
      # only logs why. Send those errors to stderr so the gap is explained.
      Puppet::Util::Log.newdestination(:console)
      Puppet::Util::Log.level = :err
    rescue LoadError => e
      raise Error, "generating needs OpenVox and openvox-strings in this Ruby (#{e.message}). " \
                   "On a server, install ovlens into the agent's Ruby with /opt/puppetlabs/puppet/bin/gem."
    end

    def document(env, name)
      unless env
        @err.puts "#{name}: no such environment in #{Puppet[:environmentpath]}"
        return false
      end

      modules = env.modules.map { |mod| [mod, Fingerprint.of(mod.path, mod.name, salt, patterns)] }
      if !@force && unchanged?(name, modules)
        @out.puts "#{name}: unchanged"
        return true
      end
      write(name, modules)
    end

    def salt
      @salt ||= "#{FORMAT}:#{Gem.loaded_specs['openvox-strings']&.version}"
    end

    def patterns
      @patterns ||= ['metadata.json'] + OpenvoxStrings::DEFAULT_SEARCH_PATTERNS
    end

    def read_index(file)
      JSON.parse(File.read(file, encoding: 'UTF-8'))
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # True when the environment's last run covered exactly these modules,
    # none of them failed, and none has changed since.
    def unchanged?(name, modules)
      previous = read_index(File.join(@docs_dir, name, 'index.json'))
      return false unless previous
      return false if previous['modules'].any? { |m| m['error'] }

      previous['modules'].map { |m| [m['name'], m['fingerprint']] } == modules.map { |mod, print| [mod.name, print] }
    end

    # Module output already on disk, keyed by fingerprint. Read fresh for each
    # environment, because writing one replaces files an earlier read pointed at.
    def cache
      return {} if @force

      Dir.glob(File.join(@docs_dir, '*', 'index.json')).each_with_object({}) do |file, found|
        index = read_index(file) or next
        entities = index['entities'].group_by { |e| e['module'] }
        index['modules'].each do |mod|
          next if mod['error'] || mod['fingerprint'].nil?

          found[mod['fingerprint']] ||= {
            file: File.join(File.dirname(file), 'modules', "#{mod['name']}.json"),
            entities: entities.fetch(mod['name'], []),
          }
        end
      end
    end

    # Builds the new tree beside the old one and swaps it in, so readers never
    # see a half-written environment and removed modules disappear.
    def write(name, modules)
      final = File.join(@docs_dir, name)
      staging = Dir.mktmpdir(".#{name}.", @docs_dir)
      FileUtils.mkdir_p(File.join(staging, 'modules'))

      known = cache
      entities = []
      parsed = 0
      listing = modules.map do |mod, print|
        info = { 'name' => mod.name, 'version' => mod.version, 'path' => mod.path, 'fingerprint' => print }
        out_file = File.join(staging, 'modules', "#{mod.name}.json")
        begin
          found = reuse(known[print], out_file)
          unless found
            found = Index.entries(mod.name, parse(mod, out_file))
            parsed += 1
          end
          info['entities'] = found.size
          entities.concat(found)
        rescue StandardError, ScriptError => e
          info['error'] = "#{e.class}: #{e.message}"
          @err.puts "#{name}: module #{mod.name} failed: #{info['error']}"
        end
        info
      end

      File.write(File.join(staging, 'index.json'), "#{JSON.pretty_generate(index(name, listing, entities))}\n")
      FileUtils.chmod(0o755, staging)
      swap(staging, final)
      @out.puts "#{name}: #{listing.size} modules (#{parsed} parsed), #{entities.size} entities -> #{final}"
      listing.none? { |m| m['error'] }
    ensure
      FileUtils.rm_rf(staging) if staging && File.exist?(staging)
    end

    def reuse(cached, out_file)
      return nil unless cached && File.file?(cached[:file])

      FileUtils.cp(cached[:file], out_file)
      cached[:entities]
    end

    # Runs strings from inside the module so the recorded file paths are
    # relative to it. --no-save keeps YARD from writing a .yardoc into the
    # deployed code.
    def parse(mod, out_file)
      YARD::Registry.clear
      Dir.chdir(mod.path) do
        OpenvoxStrings.generate(OpenvoxStrings::DEFAULT_SEARCH_PATTERNS, json: true, path: out_file, yard_args: YARD_ARGS)
      end
      JSON.parse(File.read(out_file, encoding: 'UTF-8'))
    ensure
      YARD::Registry.clear
    end

    def index(name, listing, entities)
      {
        'environment' => name,
        'generated_at' => Time.now.utc.iso8601,
        'generator' => {
          'ovlens' => VERSION,
          'openvox-strings' => Gem.loaded_specs['openvox-strings']&.version.to_s,
          'puppet' => Puppet.version,
        },
        'modules' => listing,
        'entities' => entities,
      }
    end

    def swap(staging, final)
      previous = "#{staging}.old"
      File.rename(final, previous) if File.exist?(final)
      File.rename(staging, final)
      FileUtils.rm_rf(previous)
    end
  end
end
