# frozen_string_literal: true

RSpec.describe Ovlens::Index do
  subject(:entries) { described_class.entries('systemd', sample_modules['systemd']) }

  it 'makes one entry per entity with its type and module' do
    expect(entries.map { |e| e.values_at('name', 'type', 'module') }).to contain_exactly(
      %w[ruby providers systemd], %w[systemd::escape puppet_functions systemd]
    )
  end

  it 'prefers the @summary tag over the description' do
    expect(entries.find { |e| e['name'] == 'systemd::escape' }['summary']).to eq('Escape a unit name')
  end

  it 'falls back to the first paragraph of the description, on one line' do
    docs = { 'puppet_classes' => [entity('a', "First  line\nstill first.\n\nSecond paragraph.")] }
    expect(described_class.entries('m', docs).first['summary']).to eq('First line still first.')
  end

  it 'records which resource type a provider belongs to' do
    expect(entries.find { |e| e['type'] == 'providers' }['resource_type']).to eq('loginctl_user')
  end

  it 'flags entities tagged @api private and leaves the key off the rest' do
    found = described_class.entries('nginx', sample_modules['nginx'])
    expect(found.select { |e| e['private'] }.map { |e| e['name'] }).to eq(['nginx::params'])
    expect(found.find { |e| e['name'] == 'nginx' }).not_to have_key('private')
  end
end
