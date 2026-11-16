# frozen_string_literal: true

require 'ovlens/docs'

RSpec.describe Ovlens::Docs do
  subject(:docs) { described_class.new(tmp) }

  before do
    write_docs(tmp, 'production', sample_modules)
    write_docs(tmp, 'staging', sample_modules.slice('stdlib'))
  end

  def names(result) = result.first.map { |e| e['name'] }

  describe '#resolve' do
    it 'defaults to production' do
      expect(docs.resolve(nil)).to eq('production')
    end

    it 'defaults to the first environment when there is no production' do
      FileUtils.rm_rf(File.join(tmp, 'production'))
      expect(docs.resolve(nil)).to eq('staging')
    end

    it 'rejects names that are not documented environments, including paths' do
      expect { docs.resolve('../production') }.to raise_error(Ovlens::Error, /Available: production, staging/)
    end

    it 'explains an empty or missing directory' do
      expect { described_class.new(File.join(tmp, 'none')).resolve(nil) }.to raise_error(Ovlens::Error, /OVLENS_DOCS_DIR/)
      FileUtils.rm_rf(Dir[File.join(tmp, '*')])
      expect { docs.resolve(nil) }.to raise_error(Ovlens::Error, /ovlens generate/)
    end
  end

  describe '#search' do
    it 'ranks an exact name first, then names containing the words' do
      expect(names(docs.search('production', 'nginx')).first).to eq('nginx')
      expect(names(docs.search('production', 'nginx resource'))).to eq(%w[nginx::resource::location nginx::resource::server])
    end

    it 'finds entities by words in their parameter documentation' do
      found, mode = docs.search('production', 'upstream proxy')
      expect(found.map { |e| e['name'] }).to eq(['nginx::resource::server'])
      expect(mode).to eq('all')
    end

    it 'falls back to entities matching any word, and says so' do
      found, mode = docs.search('production', 'location banana')
      expect(found.map { |e| e['name'] }).to eq(['nginx::resource::location'])
      expect(mode).to eq('any')
    end

    it 'does not match on source code' do
      expect(docs.search('production', 'sourceonlytoken').first).to be_empty
    end

    it 'lists everything, narrowed by type and module, when there is no text' do
      expect(names(docs.search('production', nil, type: 'providers'))).to eq(%w[ruby ruby])
      expect(names(docs.search('production', '', module_name: 'systemd'))).to eq(%w[ruby systemd::escape])
    end

    it 'sees regenerated documentation without a restart' do
      docs.search('staging', 'ruby')
      sleep 0.01
      write_docs(tmp, 'staging', sample_modules.slice('systemd'))
      File.utime(Time.now + 5, Time.now + 5, File.join(tmp, 'staging', 'index.json'))
      expect(names(docs.search('staging', 'escape'))).to eq(['systemd::escape'])
    end
  end

  describe '#entity' do
    let(:entry) { docs.entries('production').find { |e| e['name'] == 'nginx' } }

    it 'returns the full documentation without the source by default' do
      found = docs.entity('production', entry)
      expect(found).to include('type' => 'puppet_classes', 'module' => 'nginx')
      expect(found['docs']).to include('name' => 'nginx').and(satisfy { |d| !d.key?('source') })
    end

    it 'includes the source when asked' do
      expect(docs.entity('production', entry, include_source: true)['docs']['source']).to include('sourceonlytoken')
    end

    it 'tells two providers of the same name apart by resource type' do
      providers = docs.entries('production', type: 'providers')
      expect(providers.map { |e| docs.entity('production', e)['docs']['type_name'] }).to contain_exactly('loginctl_user', 'file_line')
    end
  end

  it 'suggests close names' do
    expect(docs.suggestions(docs.entries('production'), 'nginx::resource::servr').first).to eq('nginx::resource::server')
  end
end
