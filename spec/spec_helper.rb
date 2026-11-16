# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fileutils'
require 'ovlens'
require 'ovlens/index'

# Builds documentation trees shaped like the generator's output.
module DocsFixture
  # The temporary directory each example gets.
  attr_reader :tmp

  # `modules` maps a module name to its strings JSON (a hash of entity lists).
  def write_docs(dir, environment, modules)
    FileUtils.mkdir_p(File.join(dir, environment, 'modules'))
    entities = []
    listing = modules.map do |name, docs|
      File.write(File.join(dir, environment, 'modules', "#{name}.json"), JSON.generate(docs))
      found = Ovlens::Index.entries(name, docs)
      entities.concat(found)
      { 'name' => name, 'version' => '1.0.0', 'path' => "/code/#{name}", 'fingerprint' => "print-#{name}", 'entities' => found.size }
    end
    index = { 'environment' => environment, 'generated_at' => '2026-01-01T00:00:00Z', 'modules' => listing, 'entities' => entities }
    File.write(File.join(dir, environment, 'index.json'), JSON.generate(index))
  end

  def entity(name, text, tags: [], **extra)
    { 'name' => name, 'file' => 'manifests/init.pp', 'line' => 1,
      'docstring' => { 'text' => text, 'tags' => tags } }.merge(extra.transform_keys(&:to_s))
  end

  def sample_modules
    {
      'nginx' => {
        'puppet_classes' => [
          entity('nginx', 'Manage NGINX', source: 'class nginx { } # sourceonlytoken'),
          entity('nginx::params', 'Defaults', tags: [{ 'tag_name' => 'api', 'text' => 'private' }])
        ],
        'defined_types' => [
          entity('nginx::resource::server', "Create a virtual host\n\nLonger text.",
                 tags: [{ 'tag_name' => 'param', 'name' => 'proxy', 'text' => 'Upstream to proxy requests to' }]),
          entity('nginx::resource::location', 'Create a location')
        ],
      },
      'systemd' => {
        'providers' => [entity('ruby', 'Manages linger', type_name: 'loginctl_user')],
        'puppet_functions' => [entity('systemd::escape', '', tags: [{ 'tag_name' => 'summary', 'text' => 'Escape a unit name' }])],
      },
      'stdlib' => { 'providers' => [entity('ruby', 'Manages lines', type_name: 'file_line')] },
    }
  end
end

RSpec.configure do |config|
  config.include DocsFixture
  config.disable_monkey_patching!
  config.order = :random
  config.around do |example|
    Dir.mktmpdir('ovlens-spec') do |dir|
      @tmp = dir
      example.run
    end
  end
end
