# frozen_string_literal: true

require 'did_you_mean'
require 'json'
require_relative '../ovlens'
require_relative 'hiera_index'
require_relative 'search_index'

module Ovlens
  # Reads the tree the generator writes and answers questions about it. Files
  # are read on every call, so regenerated documentation is picked up at once.
  class Docs
    TYPES = %w[
      puppet_classes defined_types puppet_functions data_types data_type_aliases
      resource_types providers puppet_tasks puppet_plans
    ].freeze
    # Search indexes kept in memory, most recently used first. Building one
    # takes a fraction of a second; keeping one costs tens of megabytes for a
    # large environment, so a session that visits many keeps only a few.
    CACHED_ENVIRONMENTS = 3

    attr_reader :dir

    def initialize(dir, cached_environments: CACHED_ENVIRONMENTS)
      @dir = dir
      @limit = cached_environments
      @indexes = {}
    end

    # The environments whose search index is in memory, most recent first.
    def cached_environments
      @indexes.keys.reverse
    end

    def environments
      Dir.children(@dir).select { |d| !d.start_with?('.') && File.file?(File.join(@dir, d, 'index.json')) }.sort
    rescue SystemCallError
      raise Error, "Cannot read #{@dir}. Set OVLENS_DOCS_DIR to the directory `ovlens generate` writes to."
    end

    # Environment names only ever come from the directory listing, so a caller
    # cannot use one to reach outside the documentation tree.
    def resolve(environment)
      available = environments
      raise Error, "No environments are documented in #{@dir}. Run `ovlens generate` first." if available.empty?

      name = environment || (available.include?('production') ? 'production' : available.first)
      return name if available.include?(name)

      raise Error, "No documentation for environment #{name.inspect}. Available: #{available.join(', ')}."
    end

    def index(environment)
      JSON.parse(File.read(File.join(@dir, environment, 'index.json'), encoding: 'UTF-8'))
    end

    # The environment's Hiera index, written only by `ovlens generate --hiera`.
    def hiera(environment)
      file = File.join(@dir, environment, 'hiera.json')
      raise Error, "Hiera data is not indexed for #{environment}. It is opt-in: run `ovlens generate --hiera`." unless File.file?(file)

      data = JSON.parse(File.read(file, encoding: 'UTF-8'))
      return data if data['format'] == HieraIndex::FORMAT

      raise Error, "Hiera data for #{environment} was indexed by another version of ovlens. Run `ovlens generate --hiera` again."
    end

    # The environments with indexed Hiera data.
    def hiera_environments
      environments.select { |name| File.file?(File.join(@dir, name, 'hiera.json')) }
    end

    # Index entries, optionally narrowed to one kind of entity or one module.
    def entries(environment, type: nil, module_name: nil)
      narrow(index(environment)['entities'], type, module_name)
    end

    # Returns the matching index entries, best first, and whether every word
    # matched ("all") or the search fell back to entities matching some ("any").
    # Without text, everything that passes the filters, by name.
    def search(environment, text, type: nil, module_name: nil)
      return [narrow(index(environment)['entities'], type, module_name).sort_by { |e| e['name'] }, 'all'] if SearchIndex.words(text).empty?

      search_index(environment).search(text) do |entry|
        (type.nil? || entry['type'] == type) && (module_name.nil? || entry['module'] == module_name)
      end
    end

    # The full strings entry for one index entry.
    def entity(environment, entry, include_source: false)
      found = lookup(module_docs(environment, entry['module']), entry)
      found = found.except('source') if found && !include_source
      { 'type' => entry['type'], 'module' => entry['module'], 'docs' => found }
    end

    # Names close to one that was not found.
    def suggestions(entries, name)
      DidYouMean::SpellChecker.new(dictionary: entries.map { |e| e['name'] }.uniq).correct(name).first(5)
    end

    private

    def narrow(entries, type, module_name)
      entries = entries.select { |e| e['type'] == type } if type
      entries = entries.select { |e| e['module'] == module_name } if module_name
      entries
    end

    def module_docs(environment, module_name)
      JSON.parse(File.read(File.join(@dir, environment, 'modules', "#{module_name}.json"), encoding: 'UTF-8'))
    end

    def lookup(docs, entry)
      docs.fetch(entry['type'], []).find do |candidate|
        candidate['name'] == entry['name'] && (entry['type'] != 'providers' || candidate['type_name'] == entry['resource_type'])
      end
    end

    # The environment's search index, built on first use and rebuilt when the
    # environment is regenerated. The least recently used is dropped when more
    # than the limit are in memory.
    def search_index(environment)
      stamp = File.mtime(File.join(@dir, environment, 'index.json'))
      cached = @indexes.delete(environment)
      cached = nil unless cached && cached[:stamp] == stamp
      cached ||= { stamp: stamp, index: build_index(environment) }
      @indexes[environment] = cached
      @indexes.shift while @indexes.size > @limit
      cached[:index]
    end

    def build_index(environment)
      docs = Hash.new { |loaded, module_name| loaded[module_name] = module_docs(environment, module_name) }
      rows = index(environment)['entities'].map do |entry|
        [entry, SearchIndex.text(lookup(docs[entry['module']], entry) || {})]
      end
      SearchIndex.new(rows)
    end
  end
end
