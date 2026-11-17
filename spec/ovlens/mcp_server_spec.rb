# frozen_string_literal: true

require 'ovlens/mcp_server'

RSpec.describe Ovlens::McpServer do
  subject(:server) { described_class.build(tmp) }

  before { write_docs(tmp, 'production', sample_modules) }

  # Sends one tools/call request the way a client would and returns
  # [parsed payload or raw text, error flag].
  def call(tool, arguments = {})
    response = server.handle({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: tool, arguments: arguments } })
    result = response[:result]
    text = result[:content].first[:text]
    [(JSON.parse(text) rescue text), result[:isError]] # rubocop:disable Style/RescueModifier
  end

  it 'offers four read-only tools' do
    tools = server.handle({ jsonrpc: '2.0', id: 1, method: 'tools/list' })[:result][:tools]
    expect(tools.map { |t| t[:name] }).to eq(%w[list_modules search_code get_docs compare_environments])
    expect(tools.map { |t| t[:annotations][:readOnlyHint] }).to all(be(true))
  end

  it 'lists modules for the default environment' do
    data, error = call('list_modules')
    expect(error).to be(false)
    expect(data).to include('environment' => 'production', 'environments' => ['production'])
    expect(data['modules'].map { |m| m['name'] }).to eq(%w[nginx systemd stdlib])
    expect(data['modules'].first.keys).to contain_exactly('name', 'version', 'entities')
  end

  it 'reports an unknown environment as a tool error' do
    text, error = call('list_modules', { environment: 'nosuch' })
    expect(error).to be(true)
    expect(text).to include('Available: production')
  end

  it 'searches, hiding private entities unless asked' do
    data, = call('search_code', { module: 'nginx', type: 'puppet_classes' })
    expect(data).to include('matches' => 1, 'private_hidden' => 1, 'match' => 'all')
    expect(data['results'].map { |e| e['name'] }).to eq(['nginx'])

    data, = call('search_code', { module: 'nginx', type: 'puppet_classes', include_private: true })
    expect(data['results'].map { |e| e['name'] }).to eq(%w[nginx nginx::params])
  end

  it 'honours the search limit' do
    data, = call('search_code', { limit: 2 })
    expect(data).to include('returned' => 2, 'matches' => 6)
  end

  it 'returns full documentation by exact name, ignoring case' do
    data, error = call('get_docs', { name: 'NGINX::Resource::Server' })
    expect(error).to be(false)
    expect(data['results'].first['docs']['docstring']['tags'].first).to include('name' => 'proxy')
  end

  it 'returns every entity sharing a name, and narrows with module' do
    data, = call('get_docs', { name: 'ruby' })
    expect(data['results'].map { |r| r['module'] }).to contain_exactly('systemd', 'stdlib')
    data, = call('get_docs', { name: 'ruby', module: 'stdlib' })
    expect(data['results'].map { |r| r['docs']['type_name'] }).to eq(['file_line'])
  end

  it 'reads several names in one call, and says which it could not find' do
    data, error = call('get_docs', { names: ['nginx', 'systemd::escape', 'nginx::nope'] })
    expect(error).to be(false)
    expect(data['results'].map { |r| r['docs']['name'] }).to eq(%w[nginx systemd::escape])
    expect(data['not_found'].map { |n| n['name'] }).to eq(['nginx::nope'])
  end

  it 'fails when none of several names exist, and when no name is given' do
    data, error = call('get_docs', { names: %w[nope nada] })
    expect(error).to be(true)
    expect(data['not_found'].size).to eq(2)
    text, error = call('get_docs', {})
    expect([text, error]).to eq(['Give at least one entity name in `names`.', true])
  end

  context 'with resource types too big for one reply' do
    let(:long) { "What it does.\n\n#{'More detail. ' * 30}" }
    let(:big) do
      properties = (1..150).map { |n| { 'name' => "prop#{n}", 'description' => long, 'data_type' => 'String' } }
      %w[fw1 fw2 fw3 fw4 fw5 fw6 fw7].to_h { |name| [name, { 'resource_types' => [entity(name, long, properties: properties)] }] }
    end

    before { write_docs(tmp, 'production', big) }

    it 'shortens one and says how to read the rest' do
      data, = call('get_docs', { name: 'fw1' })
      result = data['results'].first
      expect(result['detail']).to eq('condensed')
      expect(result['docs']['properties'].size).to eq(150)
      expect(result['docs']['properties'].first['description']).to eq('What it does.')
      expect(data['hint']).to include('`parameters`')
      expect(JSON.generate(data).size).to be < 45_000
    end

    it 'returns chosen properties in full' do
      data, = call('get_docs', { name: 'fw1', parameters: %w[prop7 nope] })
      result = data['results'].first
      expect(result['docs']['properties']).to eq([{ 'name' => 'prop7', 'description' => long, 'data_type' => 'String' }])
      expect(result['unknown_parameters']).to eq(['nope'])
      expect(result).not_to have_key('detail')
    end

    it 'keeps a reply for many of them within its budget and names what was left out' do
      data, = call('get_docs', { names: big.keys })
      expect(JSON.generate(data).size).to be < 45_000
      expect(data['results'].map { |r| r['detail'] }.uniq - %w[condensed outline]).to be_empty
      expect(data['results'].size + data['omitted'].size).to eq(7)
      expect(data['omitted']).not_to be_empty
      expect(data['hint']).to include('omitted')
    end
  end

  it 'says in its instructions that built-in types are not covered' do
    request = { jsonrpc: '2.0', id: 1, method: 'initialize',
                params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'spec', version: '0' } } }
    expect(server.handle(request)[:result][:instructions]).to include('built-in types', 'several names')
  end

  describe 'compare_environments' do
    it 'reports what differs between two environments' do
      write_docs(tmp, 'staging', sample_modules.except('stdlib'), 'systemd' => { 'fingerprint' => 'edited' })
      data, error = call('compare_environments', { from: 'production', to: 'staging' })
      expect(error).to be(false)
      expect(data['summary']['modules']).to eq('added' => 0, 'removed' => 1, 'changed' => 1, 'unchanged' => 1)
      expect(data['changed'].first).to include('name' => 'systemd', 'docs' => 'unchanged')
    end

    it 'reports an unknown environment as a tool error' do
      text, error = call('compare_environments', { from: 'production', to: 'nosuch' })
      expect([error, text]).to match([true, /Available: production/])
    end

    it 'keeps a large comparison within its budget' do
      many = (1..800).to_h { |n| ["module#{n}_with_a_longer_name", { 'puppet_classes' => [entity("module#{n}", 'x')] }] }
      write_docs(tmp, 'staging', many)
      data, = call('compare_environments', { from: 'production', to: 'staging' })
      expect(JSON.generate(data).size).to be <= described_class::CompareEnvironments::BUDGET
      expect(data['added_omitted']).to be_positive
      expect(data['hint']).to include('`module`')
      expect(data['summary']['modules']['added']).to eq(800)
    end
  end

  context 'with Hiera data indexed for an environment' do
    before do
      write_docs(tmp, 'staging', ntp_module)
      write_hiera(tmp, 'staging', 'ntp::servers' => ['pool.example.com'], 'ntp::srvers' => ['typo.example.com'])
    end

    it 'offers three more read-only tools, and says so in its instructions' do
      tools = server.handle({ jsonrpc: '2.0', id: 1, method: 'tools/list' })[:result][:tools]
      expect(tools.map { |t| t[:name] }.last(3)).to eq(%w[find_hiera_key hiera_for_class check_hiera])
      expect(tools.map { |t| t[:annotations][:readOnlyHint] }).to all(be(true))
      request = { jsonrpc: '2.0', id: 1, method: 'initialize',
                  params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'spec', version: '0' } } }
      expect(server.handle(request)[:result][:instructions]).to include('find_hiera_key', '<masked>', '<encrypted>')
    end

    it 'answers from the Hiera data' do
      data, error = call('find_hiera_key', { key: 'ntp::servers', environment: 'staging' })
      expect(error).to be(false)
      expect(data['keys'].first['parameter']).to eq('class' => 'ntp', 'name' => 'servers', 'types' => ['Any'])
      data, = call('hiera_for_class', { class: 'ntp', environment: 'staging' })
      expect(data['parameters'].map { |p| p['name'] }).to eq(%w[servers burst])
      data, = call('check_hiera', { environment: 'staging' })
      expect(data['unknown_parameters'].map { |o| o['key'] }).to eq(['ntp::srvers'])
    end

    it 'says how to index an environment without Hiera data' do
      text, error = call('check_hiera', { environment: 'production' })
      expect([error, text]).to match([true, /generate --hiera/])
    end

    it 'cuts the list of places a key is set when they do not fit, and says how many were left out' do
      write_hiera(tmp, 'staging', {})
      data = JSON.parse(File.read(File.join(tmp, 'staging', 'hiera.json')))
      data['keys'] = (1..500).map do |n|
        { 'key' => 'ntp::servers', 'layer' => 'environment', 'level' => 'Per node',
          'file' => "data/nodes/node#{n}.example.com.yaml", 'value' => ["ntp#{n}.example.com"] }
      end
      File.write(File.join(tmp, 'staging', 'hiera.json'), JSON.generate(data))
      reply, error = call('find_hiera_key', { key: 'ntp::servers', environment: 'staging' })
      expect(error).to be(false)
      expect(JSON.generate(reply).size).to be <= described_class::HieraTool::BUDGET
      key = reply['keys'].first
      expect(key['set_in'].size + key['set_in_omitted']).to eq(500)
      expect(reply['hint']).to include('_omitted')
    end

    it 'shortens values to keep a reply within its budget' do
      names = (1..100).map { |n| "setting#{n}" }
      tags = names.map { |name| { 'tag_name' => 'param', 'name' => name, 'text' => '', 'types' => ['String'] } }
      write_docs(tmp, 'staging', { 'big' => { 'puppet_classes' => [entity('big', 'Big', tags: tags)] } })
      write_hiera(tmp, 'staging', names.to_h { |name| ["big::#{name}", 'x' * 450] })
      data, = call('hiera_for_class', { class: 'big', environment: 'staging' })
      expect(JSON.generate(data).size).to be <= described_class::HieraTool::BUDGET
      expect(data['parameters'].first['environment_data'].first['value']).to end_with('... (452 characters)')
      expect(data['hint']).to be_nil
    end
  end

  it 'suggests names when nothing matches' do
    data, error = call('get_docs', { name: 'nginx::resource::servr' })
    expect(error).to be(true)
    expect(data['did_you_mean']).to include('nginx::resource::server')
  end
end
