# frozen_string_literal: true

module Ovlens
  # Builds the per-environment index entries from a module's strings JSON.
  module Index
    # One entry per documented entity: enough to search and to find the full
    # documentation again.
    def self.entries(module_name, docs)
      docs.flat_map do |type, entities|
        entities.map do |entity|
          docstring = entity['docstring'] || {}
          entry = { 'name' => entity['name'], 'type' => type, 'module' => module_name, 'summary' => summary(docstring) }
          entry['resource_type'] = entity['type_name'] if type == 'providers'
          entry['private'] = true if private?(docstring)
          entry
        end
      end
    end

    # The first thing people wrote about an entity: its @summary tag, or the
    # first paragraph of its description.
    def self.summary(docstring)
      tag = (docstring['tags'] || []).find { |t| t['tag_name'] == 'summary' }
      text = tag ? tag['text'] : docstring['text'].to_s.split(/\n\s*\n/).first
      text.to_s.gsub(/\s+/, ' ').strip
    end

    def self.private?(docstring)
      (docstring['tags'] || []).any? { |t| t['tag_name'] == 'api' && t['text'] == 'private' }
    end
  end
end
