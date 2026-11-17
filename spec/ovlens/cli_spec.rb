# frozen_string_literal: true

require 'stringio'
require 'ovlens/cli'

RSpec.describe Ovlens::CLI do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def run(*argv) = described_class.run(argv, out: out, err: err)

  it 'prints the version' do
    expect(run('version')).to eq(0)
    expect(out.string.strip).to eq(Ovlens::VERSION)
  end

  it 'prints usage with no command' do
    expect(run).to eq(0)
    expect(out.string).to include('ovlens generate', 'ovlens mcp')
  end

  it 'rejects an unknown command' do
    expect(run('frobnicate')).to eq(2)
    expect(err.string).to include('Usage:')
  end

  it 'rejects an unknown option' do
    expect(run('generate', '--bogus')).to eq(2)
    expect(err.string).to include('invalid option')
  end

  describe 'diff' do
    before do
      write_docs(tmp, 'production', sample_modules)
      write_docs(tmp, 'staging', sample_modules.except('stdlib'))
    end

    it 'prints the comparison as text' do
      expect(run('diff', '--docs-dir', tmp, 'production', 'staging')).to eq(0)
      expect(out.string).to include("production -> staging\nModules: 0 added, 1 removed", "Removed:\n  - stdlib 1.0.0 (1 entity)")
    end

    it 'prints JSON with --json' do
      expect(run('diff', '--docs-dir', tmp, '--json', 'production', 'staging')).to eq(0)
      expect(JSON.parse(out.string)['removed'].map { |m| m['name'] }).to eq(['stdlib'])
    end

    it 'needs exactly two environments that exist' do
      expect(run('diff', '--docs-dir', tmp, 'production')).to eq(2)
      expect(run('diff', '--docs-dir', tmp, 'production', 'nosuch')).to eq(2)
      expect(err.string).to include('needs two environments', 'No documentation for environment "nosuch"')
    end
  end

  describe 'hiera' do
    before do
      write_docs(tmp, 'production', ntp_module)
      write_hiera(tmp, 'production', 'ntp::servers' => ['pool.example.com'], 'ntp::srvers' => ['typo.example.com'])
    end

    def hiera(*args) = run('hiera', '--docs-dir', tmp, *args)

    it 'shows where a key is set and the parameter it feeds' do
      expect(hiera('key', 'ntp::servers')).to eq(0)
      expect(out.string).to eq(<<~TEXT)
        ntp::servers
          parameter servers of class ntp (Any)
          environment, Common, data/common.yaml: ["pool.example.com"]
      TEXT
    end

    it "shows how a class's parameters get their values" do
      expect(hiera('class', 'ntp')).to eq(0)
      expect(out.string).to include("  burst (Any), default false\n", "Keys for parameters the class does not have:\n  ntp::srvers")
    end

    it 'fails a check that finds a key for a parameter that does not exist' do
      expect(hiera('check')).to eq(1)
      expect(out.string).to include('ntp::srvers: ntp has no parameter srvers (data/common.yaml)')

      write_hiera(tmp, 'production', 'ntp::servers' => ['pool.example.com'])
      out.string = +''
      expect(hiera('--json', 'check')).to eq(0)
      expect(JSON.parse(out.string)['unknown_parameters']).to eq([])
    end

    it 'needs a command, and Hiera data for the environment' do
      expect(hiera('key')).to eq(2)
      expect(err.string).to include('key KEY | class NAME | check')
      write_docs(tmp, 'staging', {})
      expect(hiera('-e', 'staging', 'check')).to eq(2)
      expect(err.string).to include('run `ovlens generate --hiera`')
    end
  end

  it 'prefers an explicit docs directory, then the environment variable' do
    expect(Ovlens.docs_dir('/explicit')).to eq('/explicit')
    stub_const('ENV', ENV.to_h.merge('OVLENS_DOCS_DIR' => '/from/env'))
    expect(Ovlens.docs_dir).to eq('/from/env')
  end
end
