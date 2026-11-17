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

    # The files under `path` that documentation is built from, relative to it.
    def self.files(path, patterns = PATTERNS)
      Dir.glob(patterns, base: path).uniq.sort.select { |relative| File.file?(File.join(path, relative)) }
    end

    # `salt` carries whatever else decides the output, such as the
    # openvox-strings version.
    def self.of(path, name, salt, patterns = PATTERNS, files: self.files(path, patterns))
      digest = Digest::SHA256.new
      digest << salt << "\0" << name << "\0"
      files.each do |relative|
        digest << relative << "\0" << Digest::SHA256.file(File.join(path, relative)).hexdigest << "\0"
      end
      digest.hexdigest
    end

    # A digest of the same files' metadata only: size, modification and change
    # times, and inode. It is cheap to compute, and when it matches the one
    # recorded with a fingerprint, the files have not been touched and the
    # fingerprint still holds without reading them. Writing a file always
    # updates its change time, which cannot be set back by hand, so an edit
    # that restores the size and the modification time is still noticed.
    def self.stat_key(path, name, salt, files)
      digest = Digest::SHA256.new
      digest << salt << "\0" << name << "\0" << path << "\0"
      files.each do |relative|
        stat = File.stat(File.join(path, relative))
        digest << relative << "\0" << [stat.size, stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec,
                                       stat.ino].join(':') << "\0"
      end
      digest.hexdigest
    end
  end
end
