# frozen_string_literal: true

require 'date'
require 'json'
require 'yaml'
require_relative '../ovlens'

module Ovlens
  # Reads the Hiera data of an environment and of its modules, for the docs.
  #
  # It indexes what a person could read in the files, without resolving it for
  # any node: every key in every data file, with the hierarchy level and file
  # it comes from. Interpolations in a level's path, such as
  # %{trusted.certname}, become wildcards, so every node's or role's file is
  # included. Data from YAML, JSON and eyaml files is indexed; levels that use
  # other backends, URIs, or functions without files are listed as not indexed.
  #
  # Nothing is decrypted, and values are masked before they are stored: an
  # eyaml value becomes ENCRYPTED, and the value of a key, or of a key inside a
  # hash, whose name matches a mask pattern becomes MASKED.
  #
  # It also records the keys Puppet code looks up by name, with lookup() or
  # hiera(), so a key that is read that way is not taken for a typo.
  class HieraIndex
    DEFAULT_MASKS = %w[*password* *passwd* *secret* *token* *private_key* *api_key* *apikey* *credential*].freeze
    ENCRYPTED = '<encrypted>'
    MASKED = '<masked>'
    # What OpenVox uses for an environment without a hiera.yaml.
    DEFAULT_CONFIG = {
      'version' => 5,
      'defaults' => { 'datadir' => 'data', 'data_hash' => 'yaml_data' },
      'hierarchy' => [{ 'name' => 'Common', 'path' => 'common.yaml' }],
    }.freeze
    BACKENDS = { 'yaml_data' => :yaml, 'json_data' => :json, 'eyaml_lookup_key' => :yaml }.freeze
    FUNCTION_KEYS = %w[data_hash lookup_key data_dig hiera3_backend].freeze
    FILE_KEYS = %w[path paths glob globs mapped_paths].freeze
    URI_KEYS = %w[uri uris].freeze
    ENCRYPTED_VALUE = /ENC\[[A-Z0-9_]+,/
    INTERPOLATION = /%\{[^}]*\}/
    LOOKUP_CALL = /\b(?:lookup|hiera|hiera_array|hiera_hash|hiera_include)\s*\(\s*\[?\s*(['"])([^'"$\s]+)\1/
    CODE = '{manifests,functions,plans}/**/*.pp'

    # `modules` lists [name, path, fingerprint]; module data is read only from
    # modules with a hiera.yaml, as OpenVox does. The lookups found in a module
    # are taken from `previous`, an earlier index, while its fingerprint is
    # the same.
    def initialize(environment, path, modules, masks: DEFAULT_MASKS, previous: nil)
      @environment = environment
      @root = File.expand_path(path)
      @modules = modules
      @masks = masks
      @previous = previous || {}
    end

    def build
      @keys = []
      @lookup_options = []
      @errors = []
      layers = [layer('environment', nil, @root, File.join(@root, 'hiera.yaml'), default: true)]
      @modules.each do |name, path|
        config = File.join(path, 'hiera.yaml')
        layers << layer('module', name, path, config, default: false) if File.file?(config)
      end
      lookups, scanned = code_lookups
      {
        'environment' => @environment,
        'masks' => @masks,
        'layers' => layers,
        'keys' => @keys,
        'lookup_options' => @lookup_options,
        'lookups' => lookups,
        'scanned' => scanned,
        'errors' => @errors,
      }
    end

    # The value with eyaml values and values under masked names replaced.
    def mask(value, name = nil)
      return MASKED if name && masked_name?(name)

      case value
      when String then value.match?(ENCRYPTED_VALUE) ? ENCRYPTED : value
      when Hash then value.to_h { |key, inner| [key.to_s, mask(inner, key.to_s)] }
      when Array then value.map { |inner| mask(inner) }
      when Date, Time, Symbol then value.to_s
      else value
      end
    end

    private

    def masked_name?(name)
      @masks.any? { |pattern| File.fnmatch?(pattern, name, File::FNM_CASEFOLD) }
    end

    def layer(kind, module_name, root, config_path, default:)
      info = { 'layer' => kind }
      info['module'] = module_name if module_name
      config = read_config(config_path, info, default)
      return info.merge('levels' => []) unless config

      defaults = config['defaults'] || {}
      hierarchy = config['hierarchy'] || DEFAULT_CONFIG['hierarchy']
      fallback = config['default_hierarchy'] || []
      unless defaults.is_a?(Hash) && [hierarchy, fallback].all? { |list| list.is_a?(Array) && list.all?(Hash) }
        @errors << { 'file' => relative(config_path), 'error' => 'defaults, hierarchy or default_hierarchy is malformed' }
        return info.merge('levels' => [])
      end

      levels = hierarchy.map { |level| read_level(level, defaults, root) }
      fallback.each do |level|
        levels << read_level(level.merge('name' => "#{level['name']} (default hierarchy)"), defaults, root)
      end
      assign_files(levels)
      info.merge('levels' => levels.map { |level| index_level(level, info) })
    end

    # Gives each file to one level. A path with an interpolation becomes a
    # wildcard that can match files meant for other levels: %{facts.os.name}.yaml
    # matches common.yaml and RedHat-family.yaml too. A file a level names
    # exactly belongs to that level; any other to the level whose pattern has
    # the most fixed text, and equally specific levels share it as "A or B".
    def assign_files(levels)
      claimed = levels.flat_map { |level| level[:exact] || [] }
      levels.each { |level| level[:files] = (level[:exact] || []).to_h { |file| [file, level['name']] } }
      candidates = Hash.new { |hash, file| hash[file] = [] }
      levels.each do |level|
        (level[:wild] || {}).each { |file, fixed| candidates[file] << [level, fixed] unless claimed.include?(file) }
      end
      candidates.each do |file, found|
        best = found.map(&:last).max
        winners = found.select { |_, fixed| fixed == best }.map(&:first)
        winners.first[:files][file] = winners.map { |level| level['name'] }.join(' or ')
      end
    end

    def read_config(path, info, default)
      unless File.file?(path)
        info['config'] = nil
        return default ? DEFAULT_CONFIG : nil
      end

      info['config'] = relative(path)
      config = YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: true)
      unless config.is_a?(Hash) && config['version'].to_i == 5
        info['note'] = 'not a Hiera version 5 configuration; not indexed'
        return nil
      end
      config
    rescue Psych::Exception, SystemCallError => e
      @errors << { 'file' => relative(path), 'error' => "#{e.class}: #{e.message}" }
      nil
    end

    # The level's description, and the files its patterns match: :exact from
    # patterns without interpolations, and :wild from the others, with the
    # length of the pattern's fixed text.
    def read_level(level, defaults, root)
      name = level['name'].to_s
      # Hiera reads YAML when neither the level nor the defaults name a function.
      function_key = FUNCTION_KEYS.find { |key| level.key?(key) } || FUNCTION_KEYS.find { |key| defaults.key?(key) } || 'data_hash'
      backend = level[function_key] || defaults[function_key] || 'yaml_data'
      info = { 'name' => name, 'backend' => backend }
      format = function_key != 'data_dig' && function_key != 'hiera3_backend' && BACKENDS[backend]
      location = FILE_KEYS.find { |key| level.key?(key) }
      return info.merge('indexed' => false, 'reason' => "backend #{backend.inspect} is not read from files") unless format
      return info.merge('indexed' => false, 'reason' => 'reads URIs, not files') if URI_KEYS.any? { |key| level.key?(key) }
      return info.merge('indexed' => false, 'reason' => 'no path') unless location

      # Both may be absolute.
      datadir = File.expand_path(wildcard(level['datadir'] || defaults['datadir'] || 'data'), root)
      exact = []
      wild = {}
      paths(level, location).each do |path|
        files = Dir.glob(File.expand_path(wildcard(path), datadir)).select { |f| File.file?(f) }
        if path.match?(INTERPOLATION)
          fixed = path.gsub(INTERPOLATION, '').length
          files.each { |file| wild[file] = [wild.fetch(file, 0), fixed].max }
        else
          exact.concat(files)
        end
      end
      info.merge('indexed' => true, 'patterns' => paths(level, location).map { |path| wildcard(path) },
                 format: format, exact: exact, wild: wild)
    end

    def index_level(level, layer_info)
      info = level.reject { |key, _| key.is_a?(Symbol) }
      return info unless info['indexed']

      files = level[:files].sort.to_h
      files.each { |file, label| index_file(file, level[:format], label, layer_info) }
      info.merge('files' => files.keys.map { |f| relative(f) })
    end

    # [lookups, scanned]: each key the code looks up by name, with its file,
    # and the fingerprint of each module scanned.
    def code_lookups
      before = @previous.fetch('lookups', []).group_by { |entry| entry['module'] }
      lookups = scan(@root, nil)
      scanned = {}
      @modules.each do |name, path, print|
        same = print && @previous.dig('scanned', name) == print
        lookups.concat(same ? before.fetch(name, []) : scan(path, name))
        scanned[name] = print if print
      end
      [lookups, scanned]
    end

    def scan(dir, module_name)
      Dir.glob(File.join(dir, CODE)).flat_map do |file|
        keys = File.read(file, encoding: 'UTF-8').scrub.scan(LOOKUP_CALL).map(&:last).uniq
        keys.map do |key|
          entry = { 'key' => key, 'file' => relative(file) }
          entry['module'] = module_name if module_name
          entry
        end
      rescue SystemCallError
        []
      end
    end

    # The paths or globs a level names.
    def paths(level, location)
      values = location == 'mapped_paths' ? [Array(level['mapped_paths'])[2]].compact : Array(level[location])
      values.map(&:to_s)
    end

    def wildcard(text)
      text.gsub(INTERPOLATION, '*')
    end

    def index_file(file, format, level, layer_info)
      data = format == :json ? JSON.parse(File.read(file, encoding: 'UTF-8')) : load_yaml(file)
      return if data.nil?
      raise TypeError, "not a hash of keys (#{data.class})" unless data.is_a?(Hash)

      module_name = layer_info['module']
      data.each do |key, value|
        key = key.to_s
        where = { 'layer' => layer_info['layer'], 'level' => level, 'file' => relative(file) }
        where['module'] = module_name if module_name
        if key == 'lookup_options'
          lookup_options(value, where)
        elsif module_name.nil? || key.start_with?("#{module_name}::")
          # OpenVox ignores module data for keys outside the module's namespace.
          @keys << { 'key' => key }.merge(where).merge('value' => mask(value, key))
        end
      end
    rescue Psych::Exception, JSON::ParserError, TypeError, SystemCallError => e
      @errors << { 'file' => relative(file), 'error' => "#{e.class}: #{e.message}" }
    end

    def load_yaml(file)
      YAML.safe_load(File.read(file, encoding: 'UTF-8'), permitted_classes: [Symbol, Date, Time], aliases: true)
    end

    def lookup_options(value, where)
      return unless value.is_a?(Hash)

      value.each { |key, options| @lookup_options << { 'key' => key.to_s, 'options' => mask(options) }.merge(where) }
    end

    def relative(path)
      path = File.expand_path(path)
      path.start_with?("#{@root}/") ? path.delete_prefix("#{@root}/") : path
    end
  end
end
