# frozen_string_literal: true

require 'ovlens/excerpt'

RSpec.describe Ovlens::Excerpt do
  let(:long) { "First sentence of the description.\n\nA second paragraph. #{'More detail. ' * 40}" }
  let(:klass) do
    entity('web', long, defaults: { 'port' => '80' }, source: 'class web { }', tags: [
             { 'tag_name' => 'param', 'name' => 'port', 'types' => ['Integer'], 'text' => long },
             { 'tag_name' => 'param', 'name' => 'user', 'types' => ['String'], 'text' => 'Who runs it' },
             { 'tag_name' => 'example', 'name' => 'one', 'text' => 'include web' },
             { 'tag_name' => 'example', 'name' => 'two', 'text' => 'include web' },
             { 'tag_name' => 'example', 'name' => 'three', 'text' => 'include web' }
           ])
  end
  let(:type) do
    properties = (1..150).map { |n| { 'name' => "prop#{n}", 'description' => long, 'data_type' => 'String', 'default' => 'x' } }
    entity('fw', long, properties: properties, parameters: [{ 'name' => 'name', 'description' => 'The rule name', 'isnamevar' => true }])
  end

  describe '.fit' do
    it 'returns the documentation untouched when it fits' do
      expect(described_class.fit(klass, 100_000)).to eq([klass, 'full'])
    end

    it 'condenses when the full form is too big' do
      docs, detail = described_class.fit(type, 40_000)
      expect(detail).to eq('condensed')
      expect(described_class.size(docs)).to be <= 40_000
      expect(docs['properties'].map { |p| p['name'] }).to eq((1..150).map { |n| "prop#{n}" })
    end

    it 'falls back to an outline when even that is too big' do
      docs, detail = described_class.fit(type, 15_000)
      expect(detail).to eq('outline')
      expect(described_class.size(docs)).to be <= 15_000
      expect(docs['properties'].first).to eq('name' => 'prop1', 'data_type' => 'String', 'default' => 'x')
      expect(docs['summary']).to eq('First sentence of the description.')
    end
  end

  describe '.condense' do
    subject(:short) { described_class.condense(klass) }

    it 'cuts parameter descriptions to their first paragraph and keeps types' do
      port = short['docstring']['tags'].find { |t| t['name'] == 'port' }
      expect(port).to include('text' => 'First sentence of the description.', 'types' => ['Integer'])
    end

    it 'keeps the first two examples, the defaults, and drops the source' do
      expect(short['docstring']['tags'].count { |t| t['tag_name'] == 'example' }).to eq(2)
      expect(short['defaults']).to eq('port' => '80')
      expect(short).not_to have_key('source')
    end

    it 'clips a long description and marks the cut' do
      text = described_class.condense(entity('big', long * 4))['docstring']['text']
      expect(text.size).to be <= described_class::TEXT + 3
      expect(text).to end_with('...')
    end

    it 'leaves a description that fits alone' do
      expect(short['docstring']['text']).to eq(long)
    end
  end

  describe '.only' do
    it 'returns the named class parameters in full, with their defaults' do
      docs, unknown = described_class.only(klass, %w[port nope])
      expect(docs['docstring']['tags']).to eq([{ 'tag_name' => 'param', 'name' => 'port', 'types' => ['Integer'], 'text' => long }])
      expect(docs['defaults']).to eq('port' => '80')
      expect(unknown).to eq(['nope'])
    end

    it 'returns the named properties and parameters of a resource type in full' do
      docs, unknown = described_class.only(type, %w[prop7 name])
      expect(docs['properties']).to eq([{ 'name' => 'prop7', 'description' => long, 'data_type' => 'String', 'default' => 'x' }])
      expect(docs['parameters'].map { |p| p['name'] }).to eq(['name'])
      expect(unknown).to be_empty
    end
  end
end
