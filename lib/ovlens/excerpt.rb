# frozen_string_literal: true

require 'json'

module Ovlens
  # Cuts one entity's documentation down to a size an assistant can read.
  #
  # Most entities are small, but a resource type with a hundred properties is
  # tens of thousands of characters, more than an MCP client will pass on in
  # one tool result. Nothing is dropped silently: the shorter forms keep every
  # parameter and property name, and the caller can ask for any of them in
  # full with `only`.
  module Excerpt
    LINE = 120
    TEXT = 1200
    EXAMPLES = 2

    # The fullest form of `docs` that fits in `limit` characters, and its name:
    # "full", "condensed" (descriptions cut to their first sentence) or
    # "outline" (names, types and defaults only).
    def self.fit(docs, limit)
      return [docs, 'full'] if size(docs) <= limit

      condensed = condense(docs)
      return [condensed, 'condensed'] if size(condensed) <= limit

      [outline(docs), 'outline']
    end

    def self.size(docs)
      JSON.generate(docs).size
    end

    def self.condense(docs)
      short = docs.except('source')
      short['docstring'] = condense_docstring(docs['docstring']) if docs['docstring']
      %w[properties parameters].each do |key|
        next unless docs[key].is_a?(Array)

        short[key] = docs[key].map { |item| item.merge('description' => first_sentence(item['description'])) }
      end
      if docs['signatures'].is_a?(Array)
        short['signatures'] = docs['signatures'].map { |s| s.merge('docstring' => condense_docstring(s['docstring'] || {})) }
      end
      short['alias_of'] = clip(docs['alias_of'], TEXT) if docs['alias_of']
      short
    end

    def self.outline(docs)
      short = docs.slice('name', 'file', 'line', 'type', 'defaults')
      short['summary'] = first_sentence((docs['docstring'] || {})['text'])
      params = ((docs['docstring'] || {})['tags'] || []).select { |t| t['tag_name'] == 'param' }
      short['params'] = params.map { |t| t.slice('name', 'types') } unless params.empty?
      %w[properties parameters].each do |key|
        short[key] = docs[key].map { |item| item.slice('name', 'data_type', 'default', 'isnamevar') } if docs[key].is_a?(Array)
      end
      short['signatures'] = docs['signatures'].map { |s| s['signature'] } if docs['signatures'].is_a?(Array)
      short
    end

    # The named parameters and properties in full, and the names that the
    # entity does not have.
    def self.only(docs, names)
      wanted = names.map(&:to_s)
      found = []
      picked = docs.slice('name', 'file', 'line')
      tags = ((docs['docstring'] || {})['tags'] || []).select { |t| %w[param option].include?(t['tag_name']) && wanted.include?(t['name']) }
      unless tags.empty?
        picked['docstring'] = { 'tags' => tags }
        found.concat(tags.map { |t| t['name'] })
      end
      %w[properties parameters].each do |key|
        next unless docs[key].is_a?(Array)

        items = docs[key].select { |item| wanted.include?(item['name']) }
        picked[key] = items unless items.empty?
        found.concat(items.map { |item| item['name'] })
      end
      defaults = (docs['defaults'] || {}).slice(*wanted)
      picked['defaults'] = defaults unless defaults.empty?
      [picked, wanted - found]
    end

    def self.condense_docstring(docstring)
      short = docstring.dup
      short['text'] = clip(docstring['text'], TEXT) if docstring['text']
      examples = 0
      tags = (docstring['tags'] || []).filter_map do |tag|
        case tag['tag_name']
        when 'param', 'option' then tag.merge('text' => first_sentence(tag['text']))
        when 'example' then (examples += 1) <= EXAMPLES ? tag.merge('text' => clip(tag['text'], TEXT)) : nil
        else tag.merge('text' => clip(tag['text'], TEXT))
        end
      end
      short['tags'] = tags if docstring['tags']
      short
    end

    # The first paragraph, on one line, cut at LINE characters.
    def self.first_sentence(text)
      clip(text.to_s.strip.split(/\n\s*\n/).first.to_s.gsub(/\s+/, ' '), LINE)
    end

    def self.clip(text, length)
      text = text.to_s
      text.size > length ? "#{text[0, length].rstrip}..." : text
    end
  end
end
