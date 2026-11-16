# frozen_string_literal: true

require 'open3'
require 'rbconfig'

# Runs the real command against real environments, with OpenVox and
# openvox-strings doing the parsing.
RSpec.describe 'ovlens generate' do # rubocop:disable RSpec/DescribeClass
  let(:envs) { File.join(tmp, 'environments') }
  let(:docs) { File.join(tmp, 'docs') }

  def write_module(environment, name, body: "# @summary Manages #{name}\nclass #{name} { }\n")
    dir = File.join(envs, environment, 'modules', name)
    FileUtils.mkdir_p(File.join(dir, 'manifests'))
    File.write(File.join(dir, 'manifests', 'init.pp'), body)
    metadata = { name: "acme-#{name}", version: '1.2.3', author: 'acme', license: 'Apache-2.0', summary: name, source: '',
                 dependencies: [] }
    File.write(File.join(dir, 'metadata.json'), JSON.generate(metadata))
    # Keep the workstation's own module directories out of the run.
    File.write(File.join(envs, environment, 'environment.conf'), "modulepath = modules\n")
    dir
  end

  def generate(*args)
    exe = File.expand_path('../../exe/ovlens', __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, exe, 'generate', '--environmentpath', envs, '--docs-dir', docs, *args)
    [out, err, status.exitstatus]
  end

  def index(environment) = JSON.parse(File.read(File.join(docs, environment, 'index.json')))

  before do
    write_module('production', 'web')
    write_module('production', 'db')
    write_module('staging', 'web')
  end

  it 'documents every environment and reuses identical modules across them' do
    out, err, status = generate('--all')
    expect([err, status]).to eq(['', 0])
    expect(out).to match(/production: 2 modules \(\d parsed\), 2 entities/).and match(/staging: 1 modules \(\d parsed\), 1 entities/)
    expect(out.scan(/\((\d) parsed\)/).flatten.sum(&:to_i)).to eq(2)

    expect(index('production')['entities']).to include(
      'name' => 'web', 'type' => 'puppet_classes', 'module' => 'web', 'summary' => 'Manages web',
    )
    expect(index('production')['modules'].map { |m| m.values_at('name', 'version') }).to contain_exactly(%w[web 1.2.3], %w[db 1.2.3])
    module_docs = JSON.parse(File.read(File.join(docs, 'production', 'modules', 'web.json')))
    expect(module_docs['puppet_classes'].first).to include('name' => 'web', 'file' => 'manifests/init.pp')
    expect(Dir.glob(File.join(envs, '**', '.yardoc'), File::FNM_DOTMATCH)).to be_empty
  end

  it 'leaves an unchanged environment alone and reparses only a changed module' do
    generate('--all')
    stamp = index('staging')['generated_at']

    out, = generate('--all')
    expect(out).to include('production: unchanged', 'staging: unchanged')

    write_module('production', 'db', body: "# @summary A database\nclass db { }\n")
    out, = generate('production staging')
    expect(out).to include('production: 2 modules (1 parsed)', 'staging: unchanged')
    expect(index('production')['entities'].find { |e| e['name'] == 'db' }['summary']).to eq('A database')
    expect(index('staging')['generated_at']).to eq(stamp)
  end

  it 'drops a module that was removed from the environment' do
    generate('production')
    FileUtils.rm_rf(File.join(envs, 'production', 'modules', 'db'))
    out, = generate('production')
    expect(out).to include('production: 1 modules (0 parsed)')
    expect(Dir.children(File.join(docs, 'production', 'modules'))).to eq(['web.json'])
  end

  it 'parses everything again with --force' do
    generate('production')
    out, = generate('--force', 'production')
    expect(out).to include('production: 2 modules (2 parsed)')
  end

  it 'fails for an environment that does not exist, and still does the others' do
    out, err, status = generate('nosuch', 'staging')
    expect(status).to eq(1)
    expect(err).to include('nosuch: no such environment')
    expect(out).to include('staging: 1 modules')
  end

  it 'says why a module OpenVox cannot load is missing' do
    File.write(File.join(envs, 'staging', 'modules', 'web', 'metadata.json'), '{"name":"acme-web"}')
    out, err, = generate('staging')
    expect(out).to include('staging: 0 modules')
    expect(err).to include('module metadata')
  end

  it 'does nothing when given no environments' do
    out, _err, status = generate('')
    expect([out.strip, status]).to eq(['No environments given; nothing to do.', 0])
  end
end
