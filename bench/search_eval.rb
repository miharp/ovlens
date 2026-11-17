# frozen_string_literal: true

# Scores search ranking against the judged queries in queries.yaml, and fails
# when fewer than min_top3 of them have a wanted entity in the top three.
#
#   ruby -I <ovlens lib> bench/search_eval.rb <docs dir> [--verbose]
#
# To try a ranking change without editing lib/, put it in a file that reopens
# Ovlens::SearchIndex (rank_key is the sort key) and load it with -r.
require 'yaml'
require 'ovlens/docs'

docs_dir = ARGV.reject { |arg| arg.start_with?('-') }.first or abort('usage: search_eval.rb <docs dir> [--verbose]')
verbose = ARGV.include?('--verbose')
judged = YAML.safe_load_file(File.join(__dir__, 'queries.yaml'))
docs = Ovlens::Docs.new(docs_dir)

found_count = 0
reciprocal = 0.0
judged['queries'].each do |item|
  results = docs.search('production', item['query'], type: item['type']).first
  names = results.reject { |entry| entry['private'] }.map { |entry| entry['name'] }
  rank = names.index { |name| item['want'].include?(name) }
  found = rank && rank < 3
  found_count += 1 if found
  reciprocal += rank ? 1.0 / (rank + 1) : 0.0
  next unless verbose || !found

  label = found ? 'found' : 'MISS '
  puts format('%<label>s %<query>-25s rank %<rank>-3s top: %<top>s',
              label: label, query: item['query'], rank: rank ? rank + 1 : '-', top: names.first(3).join(', '))
end

total = judged['queries'].size
puts format('%<found>d of %<total>d queries have a wanted entity in the top three (at least %<min>d needed); MRR %<mrr>.2f',
            found: found_count, total: total, min: judged['min_top3'], mrr: reciprocal / total)
exit(found_count >= judged['min_top3'] ? 0 : 1)
