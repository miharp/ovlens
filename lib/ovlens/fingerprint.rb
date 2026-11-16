# frozen_string_literal: true

require 'digest'

module Ovlens
  # A digest of everything in a module that its documentation is built from.
  # Two modules with the same fingerprint produce the same documentation, so
  # the generator can reuse earlier output instead of parsing again.
  module Fingerprint
    PATTERNS = %w[
      metadata.json manifests/**/*.pp functions/**/*.pp types/**/*.pp lib/**/*.rb tasks/*.json plans/**/*.pp
    ].freeze

    # `salt` carries whatever else decides the output, such as the
    # openvox-strings version.
    def self.of(path, name, salt, patterns = PATTERNS)
      digest = Digest::SHA256.new
      digest << salt << "\0" << name << "\0"
      Dir.glob(patterns, base: path).uniq.sort.each do |relative|
        file = File.join(path, relative)
        next unless File.file?(file)

        digest << relative << "\0" << Digest::SHA256.file(file).hexdigest << "\0"
      end
      digest.hexdigest
    end
  end
end
