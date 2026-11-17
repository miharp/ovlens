# frozen_string_literal: true

require 'ovlens/search_index'

RSpec.describe Ovlens::SearchIndex do
  # name => [text, summary, type]
  def build(docs)
    rows = docs.map do |name, (text, summary, type)|
      [{ 'name' => name, 'type' => type || 'puppet_classes', 'module' => name.split('::').first, 'summary' => summary.to_s }, text.to_s]
    end
    described_class.new(rows)
  end

  def names(index, query) = index.search(query).first.map { |e| e['name'] }

  let(:filler) { (1..10).to_h { |n| ["filler#{n}", ["a server and another server for item #{n}"]] } }

  it 'ranks an entity that is more about the word higher' do
    index = build('one' => ['proxy settings'], 'many' => ['proxy proxy proxy proxy settings'])
    expect(names(index, 'proxy')).to eq(%w[many one])
  end

  it 'counts a word in the summary for more than one in the body' do
    index = build('body' => ['handles the proxy here'], 'summary' => ['handles things here', 'Sets up a proxy'])
    expect(names(index, 'proxy')).to eq(%w[summary body])
  end

  it 'weighs a rare word more than a common one' do
    index = build(filler.merge('timekeeper' => ['ntp ntp ntp, and a server'], 'webapp' => ['server server server, and ntp']))
    expect(names(index, 'ntp server')).to eq(%w[timekeeper webapp])
  end

  it 'ranks a name the words cover more of above a longer one' do
    index = build('apache::vhost::fragment' => ['vhost fragment'], 'apache::vhost' => ['vhost'], 'php::apache_vhost' => ['vhost'])
    found = names(index, 'vhost')
    expect(found.first).to eq('apache::vhost')
    expect(found.drop(1)).to contain_exactly('apache::vhost::fragment', 'php::apache_vhost')
  end

  it 'does not let a long entry lose to a short one that mentions the word less' do
    index = build('main' => ["#{'vhost ' * 6}#{'other words here ' * 200}"], 'aside' => ['vhost once'])
    expect(names(index, 'vhost')).to eq(%w[main aside])
  end

  it 'puts the exact name first, then names containing every word' do
    index = build('apache::vhost::proxy' => ['apache vhost'], 'other' => ['apache vhost ' * 5], 'apache::vhost' => ['apache vhost'])
    expect(names(index, 'apache vhost')).to eq(%w[apache::vhost apache::vhost::proxy other])
    expect(names(index, 'apache::vhost').first).to eq('apache::vhost')
  end

  it 'prefers a class to a type alias or a provider with the same documentation' do
    index = build('Web::Options' => ['the listen port', nil, 'data_type_aliases'], 'web::config' => ['the listen port'],
                  'ruby' => ['the listen port', nil, 'providers'])
    expect(names(index, 'listen port')).to eq(%w[web::config Web::Options ruby])
  end

  it 'matches the start of longer words, but two-letter words only whole' do
    index = build('accounts' => ['creates users and sets the username'], 'disks' => ['tunes ioctl calls'])
    expect(names(index, 'user')).to eq(['accounts'])
    expect(names(index, 'io')).to be_empty
    expect(names(index, 'ioc')).to eq(['disks'])
  end

  it 'ignores filler words unless they are all there is' do
    index = build('accounts' => ['creates users'], 'notes' => ['the user is set by the caller'])
    expect(index.search('how to create a user').first.map { |e| e['name'] }).to eq(['accounts'])
    expect(names(index, 'the')).to eq(['notes'])
  end

  it 'falls back to entities matching some of the words, most words first, and says so' do
    index = build('two' => ['alpha beta'], 'one' => ['alpha'], 'none' => ['gamma'])
    found, mode = index.search('alpha beta delta')
    expect([found.map { |e| e['name'] }, mode]).to eq([%w[two one], 'any'])
  end

  it 'leaves out what the filter rejects' do
    index = build('web' => ['port'], 'db' => ['port'])
    expect(index.search('port') { |entry| entry['name'] == 'db' }.first.map { |e| e['name'] }).to eq(['db'])
  end

  describe '.text' do
    it 'collects every string except source, file positions and markup' do
      docs = { 'name' => 'web', 'file' => 'manifests/init.pp', 'line' => 3, 'source' => 'class web {}',
               'docstring' => { 'text' => 'Runs it', 'tags' => [{ 'tag_name' => 'param', 'name' => 'port', 'types' => ['Integer'] }] } }
      expect(described_class.text(docs).split("\n")).to eq(['web', 'Runs it', 'port', 'Integer'])
    end
  end
end
