# frozen_string_literal: true

require 'ovlens/fingerprint'

RSpec.describe Ovlens::Fingerprint do
  def module_dir(name)
    dir = File.join(tmp, name)
    FileUtils.mkdir_p(File.join(dir, 'manifests'))
    File.write(File.join(dir, 'manifests', 'init.pp'), "class #{File.basename(name)} { }\n")
    File.write(File.join(dir, 'metadata.json'), '{"version":"1.0.0"}')
    dir
  end

  let(:dir) { module_dir('one/web') }

  it 'is the same for identical modules in different places' do
    expect(described_class.of(dir, 'web', 's')).to eq(described_class.of(module_dir('two/web'), 'web', 's'))
  end

  it 'changes when a documented file changes' do
    before = described_class.of(dir, 'web', 's')
    File.write(File.join(dir, 'manifests', 'init.pp'), "# Documented now\nclass web { }\n")
    expect(described_class.of(dir, 'web', 's')).not_to eq(before)
  end

  it 'changes when a documented file is added' do
    before = described_class.of(dir, 'web', 's')
    File.write(File.join(dir, 'manifests', 'extra.pp'), "class web::extra { }\n")
    expect(described_class.of(dir, 'web', 's')).not_to eq(before)
  end

  it 'ignores files that documentation is not built from' do
    before = described_class.of(dir, 'web', 's')
    File.write(File.join(dir, 'README.md'), 'hello')
    FileUtils.mkdir_p(File.join(dir, 'templates'))
    File.write(File.join(dir, 'templates', 'a.epp'), 'x')
    expect(described_class.of(dir, 'web', 's')).to eq(before)
  end

  it 'depends on the module name and the salt' do
    base = described_class.of(dir, 'web', 's')
    expect(described_class.of(dir, 'other', 's')).not_to eq(base)
    expect(described_class.of(dir, 'web', 'different')).not_to eq(base)
  end
end
