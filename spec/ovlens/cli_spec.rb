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

  it 'prefers an explicit docs directory, then the environment variable' do
    expect(Ovlens.docs_dir('/explicit')).to eq('/explicit')
    stub_const('ENV', ENV.to_h.merge('OVLENS_DOCS_DIR' => '/from/env'))
    expect(Ovlens.docs_dir).to eq('/from/env')
  end
end
