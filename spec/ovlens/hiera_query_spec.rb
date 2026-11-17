# frozen_string_literal: true

require 'ovlens/docs'
require 'ovlens/hiera_query'

RSpec.describe Ovlens::HieraQuery do
  subject(:query) { described_class.new(Ovlens::Docs.new(tmp), 'production') }

  def param(name, type) = { 'tag_name' => 'param', 'name' => name, 'text' => '', 'types' => [type] }

  def place(key, value, level: 'Common', file: 'data/common.yaml', module_name: nil)
    entry = { 'key' => key, 'layer' => module_name ? 'module' : 'environment', 'level' => level, 'file' => file }
    entry['module'] = module_name if module_name
    entry.merge('value' => value)
  end

  before do
    ntp = entity('ntp', 'Manages NTP', tags: [param('servers', 'Array[String]'), param('burst', 'Boolean'), param('iburst', 'Boolean')],
                                       defaults: { 'burst' => 'false' })
    write_docs(tmp, 'production', { 'ntp' => { 'puppet_classes' => [ntp] } })
    hiera = {
      'format' => Ovlens::HieraIndex::FORMAT,
      'environment' => 'production',
      'layers' => [
        { 'layer' => 'environment', 'config' => 'hiera.yaml',
          'levels' => [{ 'name' => 'Common', 'indexed' => true }, { 'name' => 'Vault', 'indexed' => false, 'reason' => 'no files' }] },
        { 'layer' => 'module', 'module' => 'ntp', 'config' => 'modules/ntp/hiera.yaml',
          'levels' => [{ 'name' => 'Common', 'indexed' => true }] }
      ],
      'keys' => [
        place('ntp::servers', ['pool.example.com'], file: 'modules/ntp/data/common.yaml', module_name: 'ntp'),
        place('ntp::servers', %w[a.example.com b.example.com], level: 'OS', file: 'data/os/RedHat.yaml'),
        place('ntp::burst', true),
        place('ntp::srvers', ['typo.example.com']),
        place('ntp::srvers', ['typo.example.com'], level: 'Per node', file: 'data/nodes/web01.yaml'),
        place('profile::web::port', 'x' * 600),
        place('ntp::extra', ['extra.example.com'])
      ],
      'lookups' => [{ 'key' => 'ntp::extra', 'module' => 'ntp', 'file' => 'modules/ntp/manifests/init.pp' }],
      'lookup_options' => [{ 'key' => 'ntp::servers', 'options' => { 'merge' => 'unique' }, 'layer' => 'environment',
                             'level' => 'Common', 'file' => 'data/common.yaml' }],
      'errors' => [{ 'file' => 'data/broken.yaml', 'error' => 'Psych::SyntaxError: bad' }],
    }
    File.write(File.join(tmp, 'production', 'hiera.json'), JSON.generate(hiera))
  end

  it 'does not read Hiera data indexed in another format' do
    File.write(File.join(tmp, 'production', 'hiera.json'), JSON.generate('environment' => 'production', 'keys' => []))
    expect { query }.to raise_error(Ovlens::Error, /another version of ovlens. Run `ovlens generate --hiera` again/)
  end

  it 'says Hiera data is opt-in when an environment has none' do
    write_docs(tmp, 'staging', {})
    expect { described_class.new(Ovlens::Docs.new(tmp), 'staging') }.to raise_error(Ovlens::Error, /generate --hiera/)
  end

  describe '#find' do
    it 'shows every place a key is set and the class parameter it feeds' do
      found = query.find('ntp::servers')
      expect(found).to include('match' => 'exact', 'matches' => 1)
      key = found['keys'].first
      expect(key['parameter']).to eq('class' => 'ntp', 'name' => 'servers', 'types' => ['Array[String]'])
      from_module = { 'layer' => 'module', 'module' => 'ntp', 'level' => 'Common', 'file' => 'modules/ntp/data/common.yaml' }
      from_environment = { 'layer' => 'environment', 'level' => 'OS', 'file' => 'data/os/RedHat.yaml' }
      expect(key['set_in']).to eq(
        [from_module.merge('value' => ['pool.example.com']), from_environment.merge('value' => %w[a.example.com b.example.com])],
      )
      expect(key['lookup_options'].first['options']).to eq('merge' => 'unique')
    end

    it 'lists the keys containing some text, and marks one for a parameter that does not exist' do
      found = query.find('NTP::')
      expect(found).to include('match' => 'contains', 'matches' => 4)
      expect(found['keys'].map { |k| k['key'] }).to eq(%w[ntp::burst ntp::extra ntp::servers ntp::srvers])
      expect(found['keys'].last['parameter']).to eq('class' => 'ntp', 'name' => 'srvers', 'unknown' => true)
      expect(query.find('ntp', limit: 1)['keys'].size).to eq(1)
    end

    it 'does not take a key the code looks up by name for a missing parameter' do
      key = query.find('ntp::extra')['keys'].first
      expect(key).to include('looked_up_in' => ['modules/ntp/manifests/init.pp'])
      expect(key).not_to have_key('parameter')
      expect(query.check['unknown_parameters'].map { |o| o['key'] }).to eq(['ntp::srvers'])
    end

    it 'leaves out parameter details for a class it has no docs for, and shortens long values' do
      key = query.find('profile::web::port')['keys'].first
      expect(key).not_to have_key('parameter')
      expect(key['set_in'].first['value']).to start_with('"xxx').and end_with('... (602 characters)')
    end
  end

  describe '#for_class' do
    it 'shows how each parameter gets its value' do
      result = query.for_class('ntp')
      servers, burst, iburst = result['parameters']
      expect(servers['module_data'].size).to eq(1)
      expect(servers['environment_data'].first['file']).to eq('data/os/RedHat.yaml')
      expect(servers).not_to have_key('required')
      expect(burst).to include('default' => 'false', 'environment_data' => [include('value' => true)])
      expect(iburst).to eq('name' => 'iburst', 'types' => ['Boolean'], 'required' => true, 'no_data' => true)
      expect(result['unknown_parameters'].map { |o| o['key'] }).to eq(['ntp::srvers'])
    end

    it 'fails for a class that is not documented' do
      expect { query.for_class('nosuch') }.to raise_error(Ovlens::Error, 'No class named "nosuch" in production.')
    end
  end

  it "checks the environment's own data" do
    result = query.check
    expect(result).to include('keys' => 6, 'files' => 3)
    expect(result['unknown_parameters']).to eq([{ 'key' => 'ntp::srvers', 'class' => 'ntp', 'parameter' => 'srvers',
                                                  'files' => ['data/common.yaml', 'data/nodes/web01.yaml'] }])
    expect(result['not_indexed']).to eq([{ 'layer' => 'environment', 'level' => 'Vault', 'reason' => 'no files' }])
    expect(result['errors'].size).to eq(1)
  end
end
