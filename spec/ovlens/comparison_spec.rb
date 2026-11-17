# frozen_string_literal: true

require 'ovlens/comparison'
require 'ovlens/docs'

RSpec.describe Ovlens::Comparison do
  let(:docs) { Ovlens::Docs.new(tmp) }
  let(:base) { sample_modules }

  def compare(module_name: nil) = described_class.new(docs, 'production', 'staging', module_name: module_name)

  before { write_docs(tmp, 'production', base) }

  it 'finds no differences between identical environments' do
    write_docs(tmp, 'staging', base)
    result = compare.to_h
    expect(result.values_at('added', 'removed', 'changed')).to all(be_empty)
    expect(result['summary']['modules']).to eq('added' => 0, 'removed' => 0, 'changed' => 0, 'unchanged' => 3)
    expect(compare.text).to eq("production -> staging\nNo differences in 3 modules.")
  end

  it 'lists added and removed modules with their entity counts' do
    write_docs(tmp, 'staging', base.except('stdlib').merge('web' => { 'puppet_classes' => [entity('web', 'Web')] }))
    result = compare.to_h
    expect(result['added']).to eq([{ 'name' => 'web', 'version' => '1.0.0', 'entities' => 1 }])
    expect(result['removed']).to eq([{ 'name' => 'stdlib', 'version' => '1.0.0', 'entities' => 1 }])
    expect(result['summary']['entities']).to eq('added' => 1, 'removed' => 1)
  end

  it 'reports a version change with the entities that came and went' do
    nginx = base['nginx'].merge('defined_types' => [base['nginx']['defined_types'].first, entity('nginx::stream', 'Streams')])
    write_docs(tmp, 'staging', base.merge('nginx' => nginx), 'nginx' => { 'version' => '2.0.0', 'fingerprint' => 'new' })
    change = compare.to_h['changed'].first
    expect(change).to include('name' => 'nginx', 'from_version' => '1.0.0', 'to_version' => '2.0.0', 'docs' => 'changed')
    expect(change['entities_added']).to eq([{ 'name' => 'nginx::stream', 'type' => 'defined_types' }])
    expect(change['entities_removed']).to eq([{ 'name' => 'nginx::resource::location', 'type' => 'defined_types' }])
  end

  it 'reports changed code within the same version, and whether the docs changed with it' do
    write_docs(tmp, 'staging', base, 'systemd' => { 'fingerprint' => 'edited' })
    change = compare.to_h['changed'].first
    expect(change).to include('name' => 'systemd', 'from_version' => '1.0.0', 'to_version' => '1.0.0', 'docs' => 'unchanged',
                              'entities_added' => [], 'entities_removed' => [])
    expect(compare.text).to include('  ~ systemd 1.0.0, code changed (docs unchanged)')
  end

  it 'tells apart providers of the same name and marks private entities' do
    stdlib = { 'providers' => [entity('ruby', 'Lines', type_name: 'file_line'), entity('ruby', 'Other', type_name: 'other_type')],
               'puppet_classes' => [entity('stdlib::internal', 'x', tags: [{ 'tag_name' => 'api', 'text' => 'private' }])] }
    write_docs(tmp, 'staging', base.merge('stdlib' => stdlib), 'stdlib' => { 'fingerprint' => 'new' })
    change = compare.to_h['changed'].first
    expect(change['entities_added']).to contain_exactly(
      { 'name' => 'ruby', 'type' => 'providers', 'resource_type' => 'other_type' },
      { 'name' => 'stdlib::internal', 'type' => 'puppet_classes', 'private' => true },
    )
    expect(compare.text).to include('+ ruby (provider for other_type)', '+ stdlib::internal (class, private)')
  end

  it 'cannot say whether docs changed for an environment written before content digests' do
    write_docs(tmp, 'staging', base, 'systemd' => { 'fingerprint' => 'edited', 'content' => nil })
    expect(compare.to_h['changed'].first['docs']).to eq('unknown')
  end

  it 'lists modules that could not be documented' do
    write_docs(tmp, 'staging', base, 'stdlib' => { 'fingerprint' => 'x', 'error' => 'RuntimeError: boom' })
    expect(compare.to_h['failed']).to eq([{ 'name' => 'stdlib', 'environment' => 'staging', 'error' => 'RuntimeError: boom' }])
    expect(compare.text).to include('Not documented:', '  ! stdlib in staging: RuntimeError: boom')
  end

  it 'compares one module when asked, and refuses a module neither has' do
    write_docs(tmp, 'staging', base.except('stdlib'), 'systemd' => { 'fingerprint' => 'edited' })
    expect(compare(module_name: 'systemd').to_h['summary']['modules']).to eq('added' => 0, 'removed' => 0, 'changed' => 1, 'unchanged' => 0)
    expect { compare(module_name: 'nope').to_h }.to raise_error(Ovlens::Error, /No module named "nope" in production or staging/)
  end

  it 'shortens long lists and counts what it left out' do
    many = (1..30).to_h { |n| ["mod#{n}", { 'puppet_classes' => [entity("mod#{n}", 'x')] }] }
    big = { 'puppet_classes' => (1..25).map { |n| entity("nginx::c#{n}", 'x') } }
    write_docs(tmp, 'staging', base.merge(many).merge('nginx' => big), 'nginx' => { 'fingerprint' => 'new' })
    short = compare.shortened(entities: 5, modules: 10)
    expect(short['added'].size).to eq(10)
    expect(short['added_omitted']).to eq(20)
    nginx = short['changed'].first
    expect(nginx['entities_added'].size).to eq(5)
    expect(nginx['entities_added_omitted']).to eq(20)
    expect(compare.to_h['added'].size).to eq(30)
  end
end
