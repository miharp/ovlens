# frozen_string_literal: true

module Ovlens
  # Ranks the entities of one environment for a search.
  #
  # Entities named exactly what was searched for come first, then those whose
  # names contain more of the words. Within that, scoring is BM25: a word that
  # few entities contain counts for more than a common one, and repeats count
  # with diminishing returns. A word in the name or summary counts as several
  # in the body. Long documentation is barely penalised (B is low), because
  # here the long entries are usually the main ones, such as apache::vhost.
  # The score grows with the share of the name the words cover, so
  # "apache::vhost" fits "vhost" better than "apache::vhost::fragment" does,
  # and kinds of entity people rarely look for (providers, type aliases) are
  # weighted down.
  #
  # The constants were chosen on a judged set of 40 everyday queries over the
  # 296 most-downloaded Forge modules: 28 of the 40 have a wanted entity in the
  # top three, where substring matching had 23.
  #
  # A search word matches a whole word of the documentation, or the start of
  # one when it is at least MIN_PREFIX letters long, so "user" also finds
  # "users" and "username".
  class SearchIndex
    K1 = 1.2
    B = 0.15
    COVERAGE_WEIGHT = 2
    NAME_WEIGHT = 5
    SUMMARY_WEIGHT = 2
    MIN_PREFIX = 3
    TYPE_WEIGHT = Hash.new(1.0).merge(
      'puppet_functions' => 0.9, 'puppet_tasks' => 0.9, 'puppet_plans' => 0.9,
      'data_types' => 0.7, 'data_type_aliases' => 0.7, 'providers' => 0.6
    ).freeze
    # Dropped from a search unless nothing else is left.
    STOPWORDS = %w[
      a an and are as at be by can do does for from how i in into is it its my of on or so that the this to use
      using what when which with
    ].to_set.freeze
    # Keys whose values are not words a person would search for.
    SKIP_KEYS = %w[source file line tag_name].to_set.freeze

    def self.words(text)
      text.to_s.downcase.scan(/[a-z0-9]+/)
    end

    # The searchable text of an entity's documentation: every string in it
    # except source code, file positions and markup.
    def self.text(docs, out = +'')
      case docs
      when Hash then docs.each { |key, value| text(value, out) unless SKIP_KEYS.include?(key) }
      when Array then docs.each { |value| text(value, out) }
      when String then out << docs << "\n"
      end
      out
    end

    attr_reader :entries

    # `rows` pairs each index entry with its searchable text.
    def initialize(rows)
      @entries = []
      @names = []
      @lengths = []
      postings = Hash.new { |hash, word| hash[word] = [[], []] }
      rows.each_with_index do |(entry, text), doc|
        name = self.class.words(entry['name'])
        counts = Hash.new(0)
        body = self.class.words(text)
        body.each { |word| counts[word] += 1 }
        self.class.words(entry['summary']).each { |word| counts[word] += SUMMARY_WEIGHT }
        name.each { |word| counts[word] += NAME_WEIGHT }
        counts.each do |word, count|
          docs, weights = postings[word]
          docs << doc
          weights << count
        end
        @entries << entry
        @names << name
        @lengths << [body.size, 1].max
      end
      @postings = postings
      @vocabulary = postings.keys.sort
      @average = @lengths.empty? ? 1.0 : @lengths.sum.fdiv(@lengths.size)
    end

    # The entries matching `text`, best first, and "all" when each one
    # contains every word, or "any" when none did and the search fell back to
    # entries containing some of them. `keep` narrows the candidates.
    def search(text, &keep)
      raw = self.class.words(text)
      words = raw.reject { |word| STOPWORDS.include?(word) }
      words = raw if words.empty?
      words = words.uniq
      return [[], 'all'] if words.empty?

      hits = words.map { |word| frequencies(word) }
      matched = Hash.new(0)
      hits.each { |freq| freq.each_key { |doc| matched[doc] += 1 } }
      matched.select! { |doc, _| keep.nil? || keep.call(@entries[doc]) }

      every = matched.select { |_, count| count == words.size }.keys
      if every.any?
        mode = 'all'
        ranked = every.map { |doc| [*rank_key(doc, raw, words, hits), @entries[doc]['name'], doc] }
      else
        mode = 'any'
        ranked = matched.keys.map { |doc| [-matched[doc], *rank_key(doc, raw, words, hits), @entries[doc]['name'], doc] }
      end
      [ranked.sort.map(&:last).map { |doc| @entries[doc] }, mode]
    end

    private

    # doc => weighted count of the words that `word` matches.
    def frequencies(word)
      freq = Hash.new(0)
      matching(word).each do |token|
        docs, weights = @postings[token]
        docs.each_with_index { |doc, i| freq[doc] += weights[i] }
      end
      freq
    end

    def matching(word)
      return @postings.key?(word) ? [word] : [] if word.size < MIN_PREFIX

      start = @vocabulary.bsearch_index { |token| token >= word } or return []
      @vocabulary[start..].take_while { |token| token.start_with?(word) }
    end

    def score(doc, hits)
      norm = K1 * (1 - B + (B * @lengths[doc] / @average))
      sum = hits.sum do |freq|
        tf = freq[doc]
        next 0.0 if tf.zero?

        idf(freq.size) * tf * (K1 + 1) / (tf + norm)
      end
      sum * TYPE_WEIGHT[@entries[doc]['type']]
    end

    def idf(found)
      Math.log(1 + ((@entries.size - found + 0.5) / (found + 0.5)))
    end

    # Sort key for one match, lowest first.
    def rank_key(doc, raw, words, hits)
      [tier(doc, raw, words), -name_hits(doc, words), -score(doc, hits) * (1 + (COVERAGE_WEIGHT * coverage(doc, words)))]
    end

    # 0: named exactly what was searched for; 1: every word is in the name.
    def tier(doc, raw, words)
      return 0 if @names[doc] == raw

      name_hits(doc, words) == words.size ? 1 : 2
    end

    # How many of the search words are in the entity's name.
    def name_hits(doc, words)
      words.count { |word| @names[doc].any? { |part| matches?(part, word) } }
    end

    # The share of the name's words that some search word matches, so that
    # "apache::vhost" fits "vhost" better than "apache::vhost::fragment" does.
    def coverage(doc, words)
      name = @names[doc]
      return 0.0 if name.empty?

      name.count { |part| words.any? { |word| matches?(part, word) } }.fdiv(name.size)
    end

    def matches?(part, word)
      part == word || (word.size >= MIN_PREFIX && part.start_with?(word))
    end
  end
end
