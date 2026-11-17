# frozen_string_literal: true

require 'openvox-strings'
require 'ovlens/generator'

RSpec.describe Ovlens::Generator do
  let(:mod) { Struct.new(:name, :path).new('web', File.join(tmp, 'web')) }
  let(:env) { Struct.new(:modules).new([mod]) }
  let(:manifest) { File.join(mod.path, 'manifests', 'init.pp') }
  let(:generator) { described_class.new(docs_dir: File.join(tmp, 'docs')) }

  before do
    FileUtils.mkdir_p(File.dirname(manifest))
    File.write(manifest, "class web { }\n")
    allow(Ovlens::Fingerprint).to receive(:of).and_call_original
  end

  def recorded(modules) = { 'modules' => modules.map { |m, print, stat| { 'path' => m.path, 'fingerprint' => print, 'stat' => stat } } }

  it "reads a module's files only when their sizes or times have changed" do
    first = generator.send(:fingerprints, env, nil)
    again = generator.send(:fingerprints, env, recorded(first))
    expect(again).to eq(first)
    expect(Ovlens::Fingerprint).to have_received(:of).once

    File.write(manifest, "class web { } # edited\n")
    edited = generator.send(:fingerprints, env, recorded(first))
    expect(Ovlens::Fingerprint).to have_received(:of).twice
    expect(edited.first[1]).not_to eq(first.first[1])
  end

  it 'does not trust a recorded fingerprint for a module that failed' do
    first = generator.send(:fingerprints, env, nil)
    previous = recorded(first)
    previous['modules'].first['error'] = 'boom'
    generator.send(:fingerprints, env, previous)
    expect(Ovlens::Fingerprint).to have_received(:of).twice
  end
end
