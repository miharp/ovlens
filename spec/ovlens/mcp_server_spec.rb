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

  it 'offers three read-only tools' do
    tools = server.handle({ jsonrpc: '2.0', id: 1, method: 'tools/list' })[:result][:tools]
    expect(tools.map { |t| t[:name] }).to eq(%w[list_modules search_code get_docs])
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

  it 'suggests names when nothing matches' do
    data, error = call('get_docs', { name: 'nginx::resource::servr' })
    expect(error).to be(true)
    expect(data['did_you_mean']).to include('nginx::resource::server')
  end
end
