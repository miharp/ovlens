# frozen_string_literal: true

require 'ovlens/hiera_index'

RSpec.describe Ovlens::HieraIndex do
  let(:root) { File.join(tmp, 'production') }
  let(:modules) { [] }
  let(:masks) { described_class::DEFAULT_MASKS }
  let(:index) { described_class.new('production', root, modules, masks: masks).build }

  def write(path, text)
    file = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, text)
  end

  def keys(layer = 'environment') = index['keys'].select { |k| k['layer'] == layer }
  def key(name) = index['keys'].find { |k| k['key'] == name }
  def level(name, layer = 0) = index['layers'][layer]['levels'].find { |l| l['name'] == name }

  context 'with an environment hiera.yaml' do
    before do
      write('hiera.yaml', <<~YAML)
        version: 5
        defaults:
          datadir: data
          data_hash: yaml_data
        hierarchy:
          - name: Per node
            path: "nodes/%{trusted.certname}.yaml"
          - name: Roles
            glob: "roles/*.yaml"
          - name: OS
            mapped_paths: [os_list, os, "os/%{facts.os.name}.yaml"]
          - name: Secrets
            lookup_key: eyaml_lookup_key
            path: secrets.eyaml
          - name: JSON
            data_hash: json_data
            path: common.json
          - name: Vault
            lookup_key: vault_lookup
          - name: Remote
            uri: "https://example.com/data"
          - name: Common
            path: common.yaml
      YAML
      write('data/nodes/web01.example.com.yaml', "profile::web::port: 8080\n")
      write('data/nodes/db01.example.com.yaml', "profile::web::port: 9090\n")
      write('data/roles/web.yaml', "profile::web::workers: 4\n")
      write('data/os/RedHat.yaml', "ntp::servers: [a.example.com, b.example.com]\n")
      write('data/secrets.eyaml', "profile::db::user: ENC[PKCS7,MIIBiQYJKoZI]\nprofile::db::password: ENC[PKCS7,MIIBiQYJ]\n")
      write('data/common.json', '{"ntp::burst": true}')
      write('data/common.yaml', <<~YAML)
        profile::app::settings:
          db_password: hunter2
          port: 5432
          backends: [{ name: one, api_key: abc123 }]
        profile::app::api_token: abc
        profile::ssh::key_passphrase: hunter3
        profile::web::ssl_key: |
          -----BEGIN RSA PRIVATE KEY-----
          SYNTHETICRSAKEY
          -----END RSA PRIVATE KEY-----
        profile::web::ssl_cert: "-----BEGIN CERTIFICATE-----\nPUBLICCERT\n-----END CERTIFICATE-----\n"
        profile::web::extra_keys: ["-----BEGIN OPENSSH PRIVATE KEY-----\nSYNTHETICSSHKEY\n-----END OPENSSH PRIVATE KEY-----\n"]
        profile::app::started: 2026-01-01
        lookup_options:
          profile::app::settings:
            merge: deep
      YAML
    end

    it 'indexes every file a level could read, with interpolations as wildcards' do
      expect(level('Per node')).to include('indexed' => true, 'patterns' => ['nodes/*.yaml'],
                                           'files' => ['data/nodes/db01.example.com.yaml', 'data/nodes/web01.example.com.yaml'])
      expect(level('OS')['files']).to eq(['data/os/RedHat.yaml'])
      expect(level('Roles')['files']).to eq(['data/roles/web.yaml'])
      expect(index['keys'].select { |k| k['key'] == 'profile::web::port' }.map { |k| k['value'] }).to eq([9090, 8080])
      expect(key('ntp::burst')).to include('level' => 'JSON', 'file' => 'data/common.json', 'value' => true)
      expect(key('profile::web::workers')).to include('layer' => 'environment', 'level' => 'Roles', 'file' => 'data/roles/web.yaml')
    end

    it 'lists levels it cannot read from files' do
      expect(level('Vault')).to include('indexed' => false, 'reason' => 'backend "vault_lookup" is not read from files')
      expect(level('Remote')).to include('indexed' => false, 'reason' => 'reads URIs, not files')
    end

    it 'never stores an encrypted value or a value under a secret name' do
      expect(key('profile::db::user')['value']).to eq('<encrypted>')
      expect(key('profile::db::password')['value']).to eq('<masked>')
      expect(key('profile::app::api_token')['value']).to eq('<masked>')
      expect(key('profile::app::settings')['value']).to eq(
        'db_password' => '<masked>', 'port' => 5432, 'backends' => [{ 'name' => 'one', 'api_key' => '<masked>' }],
      )
      expect(JSON.generate(index)).not_to include('hunter2', 'abc123', 'MIIB')
    end

    it 'masks a private key whatever its name, and a passphrase' do
      expect(key('profile::web::ssl_key')['value']).to eq('<masked>')
      expect(key('profile::web::extra_keys')['value']).to eq(['<masked>'])
      expect(key('profile::ssh::key_passphrase')['value']).to eq('<masked>')
      expect(key('profile::web::ssl_cert')['value']).to include('PUBLICCERT')
      expect(JSON.generate(index)).not_to include('SYNTHETIC', 'hunter3')
    end

    it 'keeps lookup_options apart from the keys, and stores dates as text' do
      expect(index['lookup_options']).to eq([{ 'key' => 'profile::app::settings', 'options' => { 'merge' => 'deep' },
                                               'layer' => 'environment', 'level' => 'Common', 'file' => 'data/common.yaml' }])
      expect(key('lookup_options')).to be_nil
      expect(key('profile::app::started')['value']).to eq('2026-01-01')
    end

    context 'with an extra mask pattern' do
      let(:masks) { described_class::DEFAULT_MASKS + ['*port*'] }

      it 'masks those values too' do
        expect(key('profile::web::port')['value']).to eq('<masked>')
        expect(key('profile::app::settings')['value']['port']).to eq('<masked>')
      end
    end

    it 'reports a file it cannot parse without quoting it' do
      write('data/common.json', '{"profile::db::password": SYNTHETIC_SECRET_ONE}')
      write('data/roles/web.yaml', "profile::db::password: \"SYNTHETIC_SECRET_TWO\n  other: [\n")
      errors = index['errors'].to_h { |e| e.values_at('file', 'error') }
      expect(errors['data/common.json']).to start_with('JSON syntax error')
      expect(errors['data/roles/web.yaml']).to match(/\AYAML syntax error at line \d+ column \d+: /)
      expect(JSON.generate(index)).not_to include('SYNTHETIC_SECRET')
    end

    it 'records a file it cannot parse and indexes the rest' do
      write('data/roles/broken.yaml', "a: [unclosed\n")
      write('data/roles/list.yaml', "- not\n- a hash\n")
      expect(index['errors'].map { |e| e['file'] }).to eq(['data/roles/broken.yaml', 'data/roles/list.yaml'])
      expect(index['errors'].last['error']).to include('not a hash of keys')
      expect(key('profile::web::workers')).not_to be_nil
    end
  end

  describe 'keys the code looks up by name' do
    let(:modules) { [['ntp', File.join(root, 'modules', 'ntp'), 'print-1']] }
    let(:previous) { nil }
    let(:index) { described_class.new('production', root, modules, previous: previous).build }

    before do
      write('manifests/site.pp', "lookup('classes', Array[String], 'unique', []).include\n")
      write('modules/ntp/manifests/init.pp', <<~PUPPET)
        class ntp {
          # lookup('ntp::commented')
          /* hiera('ntp::block_commented') */
          $note = "lookup('ntp::in_a_string')"
          $a = lookup('ntp::extra_servers', Array, 'first', [])
          $b = lookup(["ntp::first", 'ntp::second'])
          $c = hiera("ntp::legacy")
          $d = lookup("ntp::${name}")
          $e = 'ntp::method'.lookup
          $f = lookup({ name => 'ntp::hashed', default_value => 1 })
        }
      PUPPET
      write('modules/ntp/plans/sync.pp', "plan ntp::sync(TargetSpec $targets) { $s = lookup('ntp::plan_setting') }\n")
      write('modules/ntp/manifests/broken.pp', "class ntp::broken { lookup('ntp::unparsed') \n")
    end

    it 'finds the literal names the code looks up, and not those in comments or strings' do
      init = %w[ntp::extra_servers ntp::first ntp::second ntp::legacy ntp::method ntp::hashed]
      expect(index['lookups'].map { |l| l.values_at('key', 'module', 'file') }).to eq(
        [['classes', nil, 'manifests/site.pp']] + init.map { |key| [key, 'ntp', 'modules/ntp/manifests/init.pp'] } +
        [['ntp::plan_setting', 'ntp', 'modules/ntp/plans/sync.pp']],
      )
      expect(index['scanned']).to eq('ntp' => 'print-1')
    end

    it 'parses a module once for every environment with the same copy' do
      cache = {}
      described_class.new('production', root, modules, cache: cache).build
      # Nothing exists under staging: what it finds comes from the cache.
      staging = File.join(tmp, 'staging')
      again = described_class.new('staging', staging, [['ntp', File.join(staging, 'modules', 'ntp'), 'print-1']], cache: cache).build
      expect(again['lookups'].map { |l| l.values_at('key', 'file') }).to include(['ntp::first', 'modules/ntp/manifests/init.pp'])
    end

    context 'when a module is unchanged since the previous index' do
      let(:previous) do
        { 'format' => described_class::FORMAT, 'scanned' => { 'ntp' => 'print-1' },
          'lookups' => [{ 'key' => 'ntp::kept', 'module' => 'ntp', 'file' => 'x.pp' }] }
      end

      it 'reuses what was found in it' do
        expect(index['lookups'].map { |l| l['key'] }).to eq(%w[classes ntp::kept])
      end

      it 'parses it again when the previous index is in another format' do
        previous['format'] = described_class::FORMAT - 1
        keys = index['lookups'].map { |l| l['key'] }
        expect(keys).to include('ntp::first')
        expect(keys).not_to include('ntp::kept')
        expect(index['format']).to eq(described_class::FORMAT)
      end
    end
  end

  it "uses OpenVox's default hierarchy when the environment has no hiera.yaml" do
    write('data/common.yaml', "ntp::servers: [pool.example.com]\n")
    layer = index['layers'].first
    expect(layer).to include('layer' => 'environment', 'config' => nil)
    expect(layer['levels']).to eq([{ 'name' => 'Common', 'backend' => 'yaml_data', 'indexed' => true,
                                     'patterns' => ['common.yaml'], 'files' => ['data/common.yaml'] }])
    expect(keys.map { |k| k['key'] }).to eq(['ntp::servers'])
  end

  it 'reads YAML from the data directory when the configuration has no defaults' do
    write('hiera.yaml', "version: 5\nhierarchy: [{ name: Common, path: common.yaml }]\n")
    write('data/common.yaml', "ntp::servers: [pool.example.com]\n")
    expect(level('Common')).to include('backend' => 'yaml_data', 'files' => ['data/common.yaml'])
  end

  it 'reports a malformed hierarchy, and reads a level with an absolute data directory' do
    write('hiera.yaml', "version: 5\nhierarchy: common.yaml\n")
    expect(index['errors']).to eq([{ 'file' => 'hiera.yaml', 'error' => 'defaults, hierarchy or default_hierarchy is malformed' }])

    shared = File.join(tmp, 'shared')
    FileUtils.mkdir_p(shared)
    File.write(File.join(shared, 'site.yaml'), "site::name: example\n")
    write('hiera.yaml', "version: 5\nhierarchy: [{ name: Site, datadir: #{shared}, path: site.yaml }]\n")
    found = described_class.new('production', root, []).build['keys'].first
    expect(found).to include('key' => 'site::name', 'file' => File.join(shared, 'site.yaml'))
  end

  it 'does not index a configuration older than version 5' do
    write('hiera.yaml', ":backends: [yaml]\n:hierarchy: [common]\n")
    expect(index['layers'].first).to include('note' => 'not a Hiera version 5 configuration; not indexed', 'levels' => [])
  end

  context 'with module data' do
    let(:modules) { [['ntp', File.join(root, 'modules', 'ntp')], ['plain', File.join(root, 'modules', 'plain')]] }

    before do
      write('modules/ntp/hiera.yaml', <<~YAML)
        version: 5
        defaults: { datadir: data, data_hash: yaml_data }
        hierarchy:
          - name: OS family
            path: "%{facts.os.family}.yaml"
        default_hierarchy:
          - name: Defaults
            path: defaults.yaml
      YAML
      write('modules/ntp/data/RedHat.yaml', "ntp::servers: [rhel.pool.example.com]\nother::setting: 1\n")
      write('modules/ntp/data/defaults.yaml', "ntp::burst: false\n")
      # Without a hiera.yaml OpenVox reads no data from a module.
      write('modules/plain/data/common.yaml', "plain::enabled: true\n")
    end

    it "reads the module's own keys, from its hierarchy and its default hierarchy" do
      expect(index['layers'].map { |l| l.values_at('layer', 'module') }).to eq([['environment', nil], %w[module ntp]])
      expect(keys('module')).to contain_exactly(
        { 'key' => 'ntp::servers', 'layer' => 'module', 'level' => 'OS family', 'file' => 'modules/ntp/data/RedHat.yaml',
          'module' => 'ntp', 'value' => ['rhel.pool.example.com'] },
        { 'key' => 'ntp::burst', 'layer' => 'module', 'level' => 'Defaults (default hierarchy)',
          'file' => 'modules/ntp/data/defaults.yaml', 'module' => 'ntp', 'value' => false },
      )
    end

    it 'gives a file several wildcard levels match to the most specific, or to all equally specific ones' do
      write('modules/ntp/hiera.yaml', <<~YAML)
        version: 5
        hierarchy:
          - { name: Full, path: "%{facts.os.name}-%{facts.os.release.full}.yaml" }
          - { name: Major, path: "%{facts.os.name}-%{facts.os.release.major}.yaml" }
          - { name: Name, path: "%{facts.os.name}.yaml" }
          - { name: Family, path: "%{facts.os.family}-family.yaml" }
          - { name: Common, path: common.yaml }
      YAML
      %w[Debian-12 RedHat-family Solaris common].each { |name| write("modules/ntp/data/#{name}.yaml", "ntp::#{name.tr('-', '_')}: 1\n") }
      levels = keys('module').to_h { |k| [k['key'], k['level']] }
      # RedHat.yaml and defaults.yaml, written in the before block, match only Name.
      expect(levels).to eq('ntp::Debian_12' => 'Full or Major', 'ntp::RedHat_family' => 'Family', 'ntp::Solaris' => 'Name',
                           'ntp::servers' => 'Name', 'ntp::burst' => 'Name', 'ntp::common' => 'Common')
      expect(index['layers'].last['levels'].map { |l| l['files'].size }).to eq([1, 0, 3, 1, 1])
    end

    it "ignores keys outside the module's namespace and modules without a hiera.yaml" do
      expect(key('other::setting')).to be_nil
      expect(key('plain::enabled')).to be_nil
    end
  end
end
