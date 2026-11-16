# frozen_string_literal: true

require 'did_you_mean'
require 'json'
require_relative '../ovlens'

module Ovlens
  # Reads the tree the generator writes and answers questions about it. Files
  # are read on every call, so regenerated documentation is picked up at once.
  class Docs
    TYPES = %w[
      puppet_classes defined_types puppet_functions data_types data_type_aliases
      resource_types providers puppet_tasks puppet_plans
    ].freeze

    attr_reader :dir

    def initialize(dir)
      @dir = dir
      @corpus = {}
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
      JSON.parse(File.read(File.join(@dir, environment, 'index.json')))
    end

    # Index entries, optionally narrowed to one kind of entity or one module.
    def entries(environment, type: nil, module_name: nil)
      narrow(index(environment)['entities'], type, module_name)
    end

    # Returns the matching index entries, best first, and whether every word
    # matched ("all") or the search fell back to entities matching some ("any").
    def search(environment, text, type: nil, module_name: nil)
      rows = corpus(environment).select { |entry, _| narrow([entry], type, module_name).any? }
      words = text.to_s.downcase.split
      return [rows.map(&:first).sort_by { |e| e['name'] }, 'all'] if words.empty?

      mode = 'all'
      ranked = rows.filter_map { |entry, body| (score = rank(entry, body, words)) && [score, entry['name'], entry] }
      if ranked.empty?
        mode = 'any'
        ranked = rows.filter_map do |entry, body|
          hits = words.count { |w| body.include?(w) }
          [-hits, entry['name'], entry] if hits.positive?
        end
      end
      [ranked.sort_by { |score, name, _| [score, name] }.map(&:last), mode]
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
      JSON.parse(File.read(File.join(@dir, environment, 'modules', "#{module_name}.json")))
    end

    def lookup(docs, entry)
      docs.fetch(entry['type'], []).find do |candidate|
        candidate['name'] == entry['name'] && (entry['type'] != 'providers' || candidate['type_name'] == entry['resource_type'])
      end
    end

    # Each index entry paired with the lower-cased text of its documentation
    # (description, parameters, types, defaults, examples). Cached until the
    # environment's index is regenerated.
    def corpus(environment)
      stamp = File.mtime(File.join(@dir, environment, 'index.json'))
      cached = @corpus[environment]
      return cached[:rows] if cached && cached[:stamp] == stamp

      docs = Hash.new { |loaded, module_name| loaded[module_name] = module_docs(environment, module_name) }
      rows = index(environment)['entities'].map do |entry|
        [entry, JSON.generate((lookup(docs[entry['module']], entry) || {}).except('source')).downcase]
      end
      @corpus[environment] = { stamp: stamp, rows: rows }
      rows
    end

    # How well an entity matches when every word is present: name matches
    # first, then the summary, then anywhere in its documentation.
    def rank(entry, body, words)
      name = entry['name'].downcase
      summary = entry['summary'].to_s.downcase
      phrase = words.join(' ')
      return 0 if [phrase, words.join('::')].include?(name)
      return 1 if name.start_with?(phrase) || name.end_with?("::#{phrase}")
      return 2 if words.all? { |w| name.include?(w) }
      return 3 if words.all? { |w| name.include?(w) || summary.include?(w) }

      4 if words.all? { |w| body.include?(w) }
    end
  end
end
