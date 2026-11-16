# frozen_string_literal: true

require_relative 'ovlens/version'

# Documentation for the Puppet code deployed in OpenVox environments: a
# generator that runs openvox-strings over every module, and a read-only MCP
# server over its output.
module Ovlens
  DEFAULT_DOCS_DIR = '/opt/puppetlabs/server/data/ovlens'

  # Raised for problems the user can fix; the CLI prints the message.
  class Error < StandardError; end

  # Where the documentation lives: an explicit choice, then OVLENS_DOCS_DIR,
  # then the default under the server's data directory.
  def self.docs_dir(choice = nil)
    File.expand_path(choice || ENV.fetch('OVLENS_DOCS_DIR', DEFAULT_DOCS_DIR))
  end
end
