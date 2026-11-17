# frozen_string_literal: true

require 'json'
require_relative '../ovlens'

module Ovlens
  # Answers questions about an environment's indexed Hiera data, and connects
  # it to class parameters: a key such as ntp::servers feeds parameter
  # `servers` of class ntp through automatic parameter lookup.
  class HieraQuery
    VALUE_LIMIT = 500

    def initialize(docs, environment, value_limit: VALUE_LIMIT)
      @docs = docs
      @environment = environment
      @data = docs.hiera(environment)
      @value_limit = value_limit
      @classes = {}
    end

    # Where a key is set, or, when no key is called that, the keys containing
    # the text. Each with the class parameter it feeds, if any.
    def find(text, limit: 20)
      names = @data['keys'].map { |entry| entry['key'] }.uniq
      exact = names.include?(text)
      found = exact ? [text] : names.select { |name| name.downcase.include?(text.downcase) }.sort
      {
        'environment' => @environment,
        'query' => text,
        'match' => exact ? 'exact' : 'contains',
        'matches' => found.size,
        'keys' => found.first(limit).map { |key| describe_key(key) },
      }
    end

    # Each parameter of a class with its default and the Hiera data that sets
    # it, and keys under the class's name for parameters it does not have.
    def for_class(name)
      params = parameters(name) or raise Error, "No class named #{name.inspect} in #{@environment}."
      {
        'environment' => @environment,
        'class' => name,
        'parameters' => params.map { |param| parameter_row(name, param) },
        'unknown_parameters' => unknown_parameters.select { |orphan| orphan['class'] == name },
      }
    end

    # Keys in the environment's own data for class parameters that do not
    # exist, levels that could not be indexed, and files that could not be read.
    # A key the code looks up by name is not reported.
    def check
      {
        'environment' => @environment,
        'keys' => @data['keys'].count { |e| e['layer'] == 'environment' },
        'files' => @data['keys'].select { |e| e['layer'] == 'environment' }.map { |e| e['file'] }.uniq.size,
        'unknown_parameters' => unknown_parameters,
        'not_indexed' => not_indexed,
        'errors' => @data['errors'],
      }
    end

    private

    def describe_key(key)
      found = { 'key' => key }
      klass, param = split(key)
      params = klass && parameters(klass)
      used = lookups(key)
      if params && (match = params.find { |p| p['name'] == param })
        found['parameter'] = { 'class' => klass, 'name' => param }.merge(match.slice('types', 'default'))
      elsif params && used.empty?
        found['parameter'] = { 'class' => klass, 'name' => param, 'unknown' => true }
      end
      found['looked_up_in'] = used.map { |entry| entry['file'] } unless used.empty?
      found['set_in'] = entries(key).map { |entry| place(entry) }
      options = @data['lookup_options'].select { |entry| entry['key'] == key }
      found['lookup_options'] = options.map { |entry| place(entry, 'options') } unless options.empty?
      found
    end

    def parameter_row(klass, param)
      set = entries("#{klass}::#{param['name']}")
      module_data = set.select { |e| e['layer'] == 'module' }
      environment_data = set.select { |e| e['layer'] == 'environment' }
      row = param.slice('name', 'types', 'default')
      row['module_data'] = module_data.map { |e| place(e) } unless module_data.empty?
      row['environment_data'] = environment_data.map { |e| place(e) } unless environment_data.empty?
      if !param.key?('default') && module_data.empty?
        row['required'] = true
        # Then the class can only be used with a value from somewhere else.
        row['no_data'] = true if environment_data.empty?
      end
      row
    end

    def unknown_parameters
      @unknown_parameters ||= @data['keys'].select { |e| e['layer'] == 'environment' }.group_by { |e| e['key'] }.filter_map do |key, set|
        klass, param = split(key)
        params = klass && parameters(klass)
        next unless params&.none? { |p| p['name'] == param }
        next unless lookups(key).empty?

        { 'key' => key, 'class' => klass, 'parameter' => param, 'files' => set.map { |e| e['file'] }.uniq }
      end
    end

    def not_indexed
      @data['layers'].flat_map do |layer|
        missing = layer['levels'].reject { |level| level['indexed'] }.map do |level|
          { 'layer' => layer['layer'], 'level' => level['name'], 'reason' => level['reason'] }.merge(layer.slice('module'))
        end
        missing << { 'layer' => layer['layer'], 'reason' => layer['note'] }.merge(layer.slice('module')) if layer['note']
        missing
      end
    end

    def entries(key)
      @data['keys'].select { |entry| entry['key'] == key }
    end

    # Where the code looks the key up by name.
    def lookups(key)
      @lookups ||= @data.fetch('lookups', []).group_by { |entry| entry['key'] }
      @lookups.fetch(key, [])
    end

    def place(entry, field = 'value')
      found = entry.slice('layer', 'module', 'level', 'file')
      found[field] = trim(entry[field])
      found
    end

    def trim(value)
      json = JSON.generate(value)
      json.size > @value_limit ? "#{json[0, @value_limit]}... (#{json.size} characters)" : value
    end

    # "a::b::c" is parameter "c" of class "a::b".
    def split(key)
      parts = key.delete_prefix('::').split('::')
      return [nil, nil] if parts.size < 2

      [parts[0..-2].join('::'), parts.last]
    end

    # [{ 'name', 'types', 'default' }] for a documented class, or nil.
    def parameters(klass)
      return @classes[klass] if @classes.key?(klass)

      @classes[klass] = begin
        entry = class_entries[klass]
        entry && read_parameters(@docs.entity(@environment, entry)['docs'] || {})
      end
    end

    def class_entries
      @class_entries ||= @docs.entries(@environment, type: 'puppet_classes').to_h { |e| [e['name'], e] }
    end

    def read_parameters(docs)
      defaults = docs['defaults'] || {}
      tags = (docs.dig('docstring', 'tags') || []).select { |t| t['tag_name'] == 'param' }
      tags.map do |tag|
        param = { 'name' => tag['name'], 'types' => tag['types'] }.compact
        param['default'] = defaults[tag['name']] if defaults.key?(tag['name'])
        param
      end
    end
  end
end
