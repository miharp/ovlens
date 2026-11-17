# frozen_string_literal: true

require 'json'

module Ovlens
  # Renders HieraQuery results as text, for `ovlens hiera`.
  module HieraText
    FOR = { 'key' => :key, 'class' => :klass, 'check' => :check }.freeze

    def self.key(result)
      return "No Hiera key contains #{result['query'].inspect} in #{result['environment']}." if result['keys'].empty?

      lines = []
      if result['match'] == 'contains'
        verb = result['matches'] == 1 ? 'contains' : 'contain'
        shown = result['keys'].size
        lines << "#{count(result['matches'], 'key')} #{verb} the text#{", first #{shown}" if result['matches'] > shown}:"
      end
      result['keys'].each do |found|
        lines << '' unless lines.empty?
        lines << found['key']
        lines << "  #{parameter(found['parameter'])}" if found['parameter']
        Array(found['looked_up_in']).each { |file| lines << "  looked up in #{file}" }
        found['set_in'].each { |place| lines << "  #{where(place)}: #{value(place['value'])}" }
        Array(found['lookup_options']).each { |place| lines << "  lookup_options in #{where(place)}: #{value(place['options'])}" }
      end
      lines.join("\n")
    end

    def self.klass(result)
      lines = ["class #{result['class']} in #{result['environment']}"]
      result['parameters'].each do |param|
        head = "  #{param['name']}#{" (#{param['types'].join(', ')})" if param['types']}"
        head += ", default #{param['default']}" if param.key?('default')
        head += ', required' if param['required']
        lines << head
        Array(param['module_data']).each { |place| lines << "      #{where(place)}: #{value(place['value'])}" }
        Array(param['environment_data']).each { |place| lines << "      #{where(place)}: #{value(place['value'])}" }
        lines << '      no default and no Hiera data: a value must be declared' if param['no_data']
      end
      unless result['unknown_parameters'].empty?
        lines << '' << 'Keys for parameters the class does not have:'
        result['unknown_parameters'].each { |orphan| lines << "  #{orphan['key']} in #{orphan['files'].join(', ')}" }
      end
      lines.join("\n")
    end

    def self.check(result)
      size = "#{count(result['keys'], 'key')} in #{count(result['files'], 'file')}"
      lines = ["#{result['environment']}: #{size} of the environment's own data"]
      section(lines, 'Keys for class parameters that do not exist', result['unknown_parameters']) do |orphan|
        "#{orphan['key']}: #{orphan['class']} has no parameter #{orphan['parameter']} (#{orphan['files'].join(', ')})"
      end
      section(lines, 'Not indexed', result['not_indexed']) do |missing|
        [missing['layer'], missing['module'], missing['level']].compact.join(', ') + ": #{missing['reason']}"
      end
      section(lines, 'Unreadable files', result['errors']) { |error| "#{error['file']}: #{error['error']}" }
      lines << '' << 'Nothing to fix.' if result['unknown_parameters'].empty? && result['errors'].empty?
      lines.join("\n")
    end

    def self.section(lines, title, items)
      return if items.empty?

      lines << '' << "#{title}:"
      items.each { |item| lines << "  #{yield(item)}" }
    end

    def self.parameter(param)
      return "#{param['class']} has no parameter #{param['name']}" if param['unknown']

      text = "parameter #{param['name']} of class #{param['class']}"
      text += " (#{param['types'].join(', ')})" if param['types']
      text += ", default #{param['default']}" if param.key?('default')
      text
    end

    def self.count(number, noun)
      "#{number} #{noun}#{'s' unless number == 1}"
    end

    def self.where(place)
      [place['module'] ? "module #{place['module']}" : place['layer'], place['level'], place['file']].compact.join(', ')
    end

    def self.value(value)
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end
end
