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

  it 'suggests names when nothing matches' do
    data, error = call('get_docs', { name: 'nginx::resource::servr' })
    expect(error).to be(true)
    expect(data['did_you_mean']).to include('nginx::resource::server')
  end
end
