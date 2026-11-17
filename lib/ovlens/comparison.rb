# frozen_string_literal: true

require_relative '../ovlens'

module Ovlens
  # Compares two documented environments: the modules added, removed and
  # changed, and the entities that came and went with them.
  #
  # A module has changed when its version differs, or when its version is the
  # same but its code is not, as with a git-pinned module moved to another
  # commit or a site module edited on a branch; the fingerprint the generator
  # records tells. For a changed module, `docs` says whether its documentation
  # changed with it: an edit inside a manifest changes the code, not the docs.
  # Unchanged modules are only counted.
  class Comparison
    LABELS = {
      'puppet_classes' => 'class', 'defined_types' => 'defined type', 'puppet_functions' => 'function',
      'data_types' => 'data type', 'data_type_aliases' => 'type alias', 'resource_types' => 'resource type',
      'providers' => 'provider', 'puppet_tasks' => 'task', 'puppet_plans' => 'plan'
    }.freeze

    attr_reader :from, :to

    def initialize(docs, from, to, module_name: nil)
      @from = from
      @to = to
      @old = docs.index(from)
      @new = docs.index(to)
      @module_name = module_name
    end

    def to_h
      @to_h ||= build
    end

    # A copy with at most `entities` entities listed per module and at most
    # `modules` modules per list, and counts of what was left out.
    def shortened(entities: nil, modules: nil)
      full = to_h
      short = full.merge('added' => [], 'removed' => [], 'changed' => [])
      %w[added removed changed].each do |list|
        kept = modules ? full[list].first(modules) : full[list]
        short[list] = kept.map { |mod| entities ? cap_entities(mod, entities) : mod }
        short["#{list}_omitted"] = full[list].size - kept.size if kept.size < full[list].size
      end
      short
    end

    # The comparison as text, for people.
    def text
      data = to_h
      lines = ["#{@from} -> #{@to}"]
      if [data['added'], data['removed'], data['changed']].all?(&:empty?)
        lines << "No differences in #{data.dig('summary', 'modules', 'unchanged')} modules."
      else
        lines.concat(summary_lines(data['summary']))
        lines.concat(section('Added', data['added']) { |mod| "  + #{mod['name']} #{mod['version']} (#{count(mod['entities'])})" })
        lines.concat(section('Removed', data['removed']) { |mod| "  - #{mod['name']} #{mod['version']} (#{count(mod['entities'])})" })
        lines.concat(section('Changed', data['changed']) { |mod| changed_lines(mod) })
      end
      lines.concat(section('Not documented', data.fetch('failed', [])) { |f| "  ! #{f['name']} in #{f['environment']}: #{f['error']}" })
      lines.join("\n")
    end

    private

    def build
      before = by_name(@old['modules'])
      after = by_name(@new['modules'])
      names = (before.keys | after.keys).sort
      if @module_name
        raise Error, "No module named #{@module_name.inspect} in #{@from} or #{@to}." unless names.include?(@module_name)

        names = [@module_name]
      end
      old_entities = entities_by_module(@old)
      new_entities = entities_by_module(@new)

      result = { 'added' => [], 'removed' => [], 'changed' => [] }
      unchanged = 0
      failed = []
      names.each do |name|
        old_mod = before[name]
        new_mod = after[name]
        failed << failure(name, @from, old_mod) if old_mod&.dig('error')
        failed << failure(name, @to, new_mod) if new_mod&.dig('error')
        if old_mod.nil?
          result['added'] << listing(new_mod)
        elsif new_mod.nil?
          result['removed'] << listing(old_mod)
        elsif same?(old_mod, new_mod)
          unchanged += 1
        else
          result['changed'] << change(old_mod, new_mod, old_entities.fetch(name, {}), new_entities.fetch(name, {}))
        end
      end

      report = {
        'from' => @from, 'to' => @to,
        'generated_at' => { @from => @old['generated_at'], @to => @new['generated_at'] },
        'summary' => summary(result, unchanged)
      }.merge(result)
      report['failed'] = failed unless failed.empty?
      report
    end

    def by_name(modules)
      modules.to_h { |mod| [mod['name'], mod] }
    end

    # module => { entity key => entity }
    def entities_by_module(index)
      index['entities'].group_by { |e| e['module'] }.transform_values do |list|
        list.to_h { |e| [[e['type'], e['name'], e['resource_type']], e] }
      end
    end

    def same?(old_mod, new_mod)
      return false unless old_mod['version'] == new_mod['version']
      return old_mod['fingerprint'] == new_mod['fingerprint'] if old_mod['fingerprint'] && new_mod['fingerprint']

      old_mod['content'] && old_mod['content'] == new_mod['content']
    end

    def listing(mod)
      { 'name' => mod['name'], 'version' => mod['version'], 'entities' => mod['entities'].to_i }
    end

    def change(old_mod, new_mod, before, after)
      {
        'name' => old_mod['name'], 'from_version' => old_mod['version'], 'to_version' => new_mod['version'],
        'docs' => docs_state(old_mod, new_mod),
        'entities_added' => (after.keys - before.keys).map { |key| brief(after[key]) },
        'entities_removed' => (before.keys - after.keys).map { |key| brief(before[key]) }
      }
    end

    def docs_state(old_mod, new_mod)
      return 'unknown' unless old_mod['content'] && new_mod['content']

      old_mod['content'] == new_mod['content'] ? 'unchanged' : 'changed'
    end

    def brief(entity)
      found = entity.slice('name', 'type')
      found['resource_type'] = entity['resource_type'] if entity['resource_type']
      found['private'] = true if entity['private']
      found
    end

    def failure(name, environment, mod)
      { 'name' => name, 'environment' => environment, 'error' => mod['error'] }
    end

    def summary(result, unchanged)
      {
        'modules' => {
          'added' => result['added'].size, 'removed' => result['removed'].size,
          'changed' => result['changed'].size, 'unchanged' => unchanged
        },
        'entities' => {
          'added' => result['added'].sum { |m| m['entities'] } + result['changed'].sum { |m| m['entities_added'].size },
          'removed' => result['removed'].sum { |m| m['entities'] } + result['changed'].sum { |m| m['entities_removed'].size },
        },
      }
    end

    def cap_entities(mod, limit)
      return mod unless mod.key?('entities_added')

      capped = mod.dup
      %w[entities_added entities_removed].each do |key|
        next if mod[key].size <= limit

        capped[key] = mod[key].first(limit)
        capped["#{key}_omitted"] = mod[key].size - limit
      end
      capped
    end

    def summary_lines(summary)
      m = summary['modules']
      e = summary['entities']
      ["Modules: #{m['added']} added, #{m['removed']} removed, #{m['changed']} changed, #{m['unchanged']} unchanged",
       "Entities: #{e['added']} added, #{e['removed']} removed"]
    end

    def section(title, items, &block)
      return [] if items.empty?

      ['', "#{title}:"] + items.flat_map { |item| Array(block.call(item)) }
    end

    def changed_lines(mod)
      version = if mod['from_version'] == mod['to_version']
                  "#{mod['to_version']}, code changed"
                else
                  "#{mod['from_version']} -> #{mod['to_version']}"
                end
      docs = { 'changed' => 'docs changed', 'unchanged' => 'docs unchanged', 'unknown' => 'docs not compared' }[mod['docs']]
      ["  ~ #{mod['name']} #{version} (#{docs})"] +
        mod['entities_added'].map { |e| "      + #{describe(e)}" } +
        mod['entities_removed'].map { |e| "      - #{describe(e)}" }
    end

    def describe(entity)
      label = LABELS.fetch(entity['type'], entity['type'])
      label = "provider for #{entity['resource_type']}" if entity['type'] == 'providers' && entity['resource_type']
      "#{entity['name']} (#{label}#{', private' if entity['private']})"
    end

    def count(entities)
      entities == 1 ? '1 entity' : "#{entities} entities"
    end
  end
end
