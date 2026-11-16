# frozen_string_literal: true

require_relative 'lib/ovlens/version'

Gem::Specification.new do |spec|
  spec.name = 'ovlens'
  spec.version = Ovlens::VERSION
  spec.authors = ['Michael Harp']
  spec.summary = 'Documentation for the Puppet code deployed in OpenVox environments, for people and AI assistants'
  spec.description = 'Runs openvox-strings over every module in an OpenVox environment after a deploy, ' \
                     'and serves the result to AI assistants through a read-only MCP server.'
  spec.homepage = 'https://github.com/miharp/ovlens'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.2'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.bindir = 'exe'
  spec.executables = ['ovlens']

  # OpenVox itself is deliberately not a dependency: `ovlens generate` runs in
  # a Ruby that already has it (the agent's, on a server), and declaring it
  # would make `gem install` pull a second copy in beside the packaged one.
  spec.add_dependency 'mcp', '~> 1.10'
  spec.add_dependency 'openvox-strings', '>= 6.0', '< 8'
end
