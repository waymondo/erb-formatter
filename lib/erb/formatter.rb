# frozen_string_literal: false

# $DEBUG = true
require "erb"
require "cgi"
require "ripper"
require 'securerandom'
require 'strscan'
require 'pp'
require 'stringio'

class ERB::Formatter
  VERSION = "0.1.1"
  autoload :IgnoreList, 'erb/formatter/ignore_list'

  class Error < StandardError; end

  # https://stackoverflow.com/a/317081
  ATTR_NAME = %r{[^\r\n\t\f\v= '"<>]*[^\r\n\t\f\v= '"<>/]} # not ending with a slash
  UNQUOTED_VALUE = ATTR_NAME
  UNQUOTED_ATTR = %r{#{ATTR_NAME}=#{UNQUOTED_VALUE}}
  SINGLE_QUOTE_ATTR = %r{(?:#{ATTR_NAME}='[^']*?')}m
  DOUBLE_QUOTE_ATTR = %r{(?:#{ATTR_NAME}="[^"]*?")}m
  BAD_ATTR = %r{#{ATTR_NAME}=\s+}
  QUOTED_ATTR = Regexp.union(SINGLE_QUOTE_ATTR, DOUBLE_QUOTE_ATTR)
  ATTR = Regexp.union(SINGLE_QUOTE_ATTR, DOUBLE_QUOTE_ATTR, UNQUOTED_ATTR, UNQUOTED_VALUE)
  MULTILINE_ATTR_NAMES = %w[class data-action]

  ERB_TAG = %r{(<%(?:==|=|-|))\s*(.*?)\s*(-?%>)}m
  ERB_PLACEHOLDER = %r{erb[a-z0-9]+tag}
  ERB_END = %r{(<%-?)\s*(end)\s*(-?%>)}
  ERB_ELSE = %r{(<%-?)\s*(else|elsif\b.*)\s*(-?%>)}

  HTML_ATTR = %r{\s+#{SINGLE_QUOTE_ATTR}|\s+#{DOUBLE_QUOTE_ATTR}|\s+#{UNQUOTED_ATTR}|\s+#{ATTR_NAME}}m
  HTML_TAG_OPEN = %r{<(\w+)((?:#{HTML_ATTR})*)(\s*?)(/>|>)}m
  HTML_TAG_CLOSE = %r{</\s*(\w+)\s*>}

  SELF_CLOSING_TAG = /\A(area|base|br|col|command|embed|hr|img|input|keygen|link|menuitem|meta|param|source|track|wbr)\z/i

  ERB_OPEN_BLOCK = ->(code) do
    # is nil when the parsing is broken, meaning it's an open expression
    Ripper.sexp(code).nil?
  end.freeze

  RUBOCOP_STDIN_MARKER = "===================="

  # Override the max line length to account from already indented ERB
  module RubocopForcedMaxLineLength
    def max
      Thread.current['RuboCop::Cop::Layout::LineLength#max'] || super
    end
  end

  module DebugShovel
    def <<(string)
      puts "ADDING: #{string.inspect} FROM:\n  #{caller(1, 5).join("\n  ")}"
      super
    end
  end

  def self.format(source, filename: nil)
    new(source, filename: filename).html
  end

  def initialize(source, line_width: 80, filename: nil)
    @original_source = source
    @filename = filename || '(erb)'
    @line_width = line_width
    @source = source.dup
    @html = +""

    html.extend DebugShovel if $DEBUG

    @tag_stack = []
    @pre_pos = 0

    build_uid = -> { ['erb', SecureRandom.uuid, 'tag'].join.delete('-') }

    @pre_placeholders = {}
    @erb_tags = {}

    @source.gsub!(ERB_PLACEHOLDER) { |tag| build_uid[].tap { |uid| pre_placeholders[uid] = tag } }
    @source.gsub!(ERB_TAG) { |tag| build_uid[].tap { |uid| erb_tags[uid] = tag } }

    @erb_tags_regexp = /(#{Regexp.union(erb_tags.keys)})/
    @pre_placeholders_regexp = /(#{Regexp.union(pre_placeholders.keys)})/
    @tags_regexp = Regexp.union(HTML_TAG_CLOSE, HTML_TAG_OPEN)

    format
    freeze
  end

  attr_accessor \
    :source, :html, :tag_stack, :pre_pos, :pre_placeholders, :erb_tags, :erb_tags_regexp,
    :pre_placeholders_regexp, :tags_regexp, :line_width

  alias to_s html

  def format_attributes(tag_name, attrs, tag_closing)
    return "" if attrs.strip.empty?

    plain_attrs = attrs.tr("\n", " ").squeeze(" ").gsub(erb_tags_regexp, erb_tags)
    return " #{plain_attrs}" if "<#{tag_name} #{plain_attrs}#{tag_closing}".size <= line_width

    attr_html = ""
    tag_stack_push(['attr='], attrs)
    attrs.scan(ATTR).flatten.each do |attr|
      attr.strip!
      full_attr = indented(attr)
      name, value = attr.split('=', 2)

      if full_attr.size > line_width && MULTILINE_ATTR_NAMES.include?(name) && attr.match?(QUOTED_ATTR)
        attr_html << indented("#{name}=#{value[0]}")
        tag_stack_push('attr"', value)
        value[1...-1].strip.split(/\s+/).each do |value_part|
          attr_html << indented(value_part)
        end
        tag_stack_pop('attr"', value)
        attr_html << indented(value[-1])
      else
        attr_html << full_attr
      end
    end
    tag_stack_pop(['attr='], attrs)
    attr_html << indented("")
    attr_html
  end

  def format_erb_attributes(string)
    erb_scanner = StringScanner.new(string.to_s)
    erb_pre_pos = 0
    until erb_scanner.eos?
      if erb_scanner.scan_until(erb_tags_regexp)
        erb_pre_match = erb_scanner.pre_match
        erb_pre_match = erb_pre_match[erb_pre_pos..]
        erb_pre_pos = erb_scanner.pos

        erb_code = erb_tags[erb_scanner.captures.first]

        format_attributes(erb_pre_match)

        erb_open, ruby_code, erb_close = ERB_TAG.match(erb_code).captures
        full_erb_tag = "#{erb_open} #{ruby_code} #{erb_close}"

        case ruby_code
        when /\Aend\z/
          tag_stack_pop('%erb%', ruby_code)
          html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
        when /\A(else|elsif\b(.*))\z/
          tag_stack_pop('%erb%', ruby_code)
          html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
          tag_stack_push('%erb%', ruby_code)
        when ERB_OPEN_BLOCK
          ruby_code = format_ruby(ruby_code, autoclose: true)
          html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
          tag_stack_push('%erb%', ruby_code)
        else
          ruby_code = format_ruby(ruby_code, autoclose: false)
          html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
        end
      else
        rest = erb_scanner.rest.to_s
        format_erb_attributes(rest)
        erb_scanner.terminate
      end
    end
  end

  def tag_stack_push(tag_name, code)
    tag_stack << [tag_name, code]
    p PUSH: tag_stack if $DEBUG
  end

  def tag_stack_pop(tag_name, code)
    if tag_name == tag_stack.last&.first
      tag_stack.pop
      p POP_: tag_stack if $DEBUG
    else
      raise "Unmatched close tag, tried with #{[tag_name, code]}, but #{tag_stack.last} was on the stack"
    end
  end

  def raise(message)
    line = @original_source[0..pre_pos].count("\n")
    location = "#{@filename}:#{line}:in `#{tag_stack.last&.first}'"
    error = RuntimeError.new([
      nil,
      "==> FORMATTED:",
      html,
      "==> STACK:",
      tag_stack.pretty_inspect,
      "==> ERROR: #{message}",
    ].join("\n"))
    error.set_backtrace caller.to_a + [location]
    super error
  end

  def indented(string)
    indent = "  " * tag_stack.size
    "\n#{indent}#{string.strip}"
  end

  def format_text(text)
    starting_space = text.match?(/\A\s/)

    final_newlines_count = text.match(/(\s*)\z/m).captures.last.count("\n")
    html << "\n" if final_newlines_count > 1

    return if text.match?(/\A\s*\z/m) # empty

    text = text.gsub(/\s+/m, ' ').strip

    offset = indented("").size
    # Restore full line width if there are less than 40 columns available
    offset = 0 if (line_width - offset) <= 40
    available_width = line_width - offset

    lines = []

    until text.empty?
      if text.size >= available_width
        last_space_index = text[0..available_width].rindex(' ')
        lines << text.slice!(0..last_space_index)
      else
        lines << text.slice!(0..-1)
      end
      offset = 0
    end

    html << lines.shift.strip unless starting_space
    lines.each do |line|
      html << indented(line)
    end
  end

  def format_code_with_rubocop(code, line_width)
    stdin, stdout = $stdin, $stdout
    $stdin = StringIO.new(code)
    $stdout = StringIO.new

    Thread.current['RuboCop::Cop::Layout::LineLength#max'] = line_width

    @rubocop_cli ||= begin
      RuboCop::Cop::Layout::LineLength.prepend self
      RuboCop::CLI.new
    end

    @rubocop_cli.run([
      '--auto-correct',
      '--stdin', @filename,
      '-f', 'quiet',
    ])

    $stdout.string.split(RUBOCOP_STDIN_MARKER, 2).last
  ensure
    $stdin, $stdout = stdin, stdout
    Thread.current['RuboCop::Cop::Layout::LineLength#max'] = nil
  end

  def format_ruby(code, autoclose: false)
    if autoclose
      code += "\nend" unless ERB_OPEN_BLOCK["#{code}\nend"]
      code += "\n}" unless ERB_OPEN_BLOCK["#{code}\n}"]
    end
    p RUBY_IN_: code if $DEBUG

    offset = tag_stack.size * 2
    if defined? Rubocop
      code = format_code_with_rubocop(code, line_width - offset) if (offset + code.size) > line_width
    elsif defined?(Rufo)
      code = Rufo.format(code) rescue code
    end

    lines = code.strip.lines
    lines = lines[0...-1] if autoclose
    code = lines.map { indented(_1) }.join.strip
    p RUBY_OUT: code if $DEBUG
    code
  end

  def format_erb_tags(string)
    if %w[style script].include?(tag_stack.last&.first)
      html << string.rstrip
      return
    end

    erb_scanner = StringScanner.new(string.to_s)
    erb_pre_pos = 0
    until erb_scanner.eos?
      if erb_scanner.scan_until(erb_tags_regexp)
        erb_pre_match = erb_scanner.pre_match
        erb_pre_match = erb_pre_match[erb_pre_pos..]
        erb_pre_pos = erb_scanner.pos

        erb_code = erb_tags[erb_scanner.captures.first]

        format_text(erb_pre_match)

        erb_open, ruby_code, erb_close = ERB_TAG.match(erb_code).captures
        erb_open << ' ' unless ruby_code.start_with?('#')
        full_erb_tag = "#{erb_open}#{ruby_code} #{erb_close}"

        case ruby_code
        when /\Aend\z/
          tag_stack_pop('%erb%', ruby_code)
          html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
        when /\A(else|elsif\b(.*))\z/
          tag_stack_pop('%erb%', ruby_code)
          html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
          tag_stack_push('%erb%', ruby_code)
        when ERB_OPEN_BLOCK
          ruby_code = format_ruby(ruby_code, autoclose: true)
          html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
          tag_stack_push('%erb%', ruby_code)
        else
          ruby_code = format_ruby(ruby_code, autoclose: false)
          html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
        end
      else
        rest = erb_scanner.rest.to_s
        format_text(rest)
        erb_scanner.terminate
      end
    end
  end

  def format
    scanner = StringScanner.new(source)

    until scanner.eos?

      if matched = scanner.scan_until(tags_regexp)
        pre_match = scanner.pre_match[pre_pos..]
        self.pre_pos = scanner.pos

        # Don't accept `name= "value"` attributes
        raise "Bad attribute, please fix spaces after the equal sign." if BAD_ATTR.match? pre_match

        format_erb_tags(pre_match) if pre_match

        if matched.match?(HTML_TAG_CLOSE)
          tag_name = scanner.captures.first

          full_tag = "</#{tag_name}>"
          tag_stack_pop(tag_name, full_tag)
          html << (scanner.pre_match.match?(/\s+\z/) ? indented(full_tag) : full_tag)

        elsif matched.match(HTML_TAG_OPEN)
          _, tag_name, tag_attrs, _, tag_closing = *scanner.captures

          raise "Unknown tag #{tag_name.inspect}" unless tag_name.match?(/\A[a-z0-9]+\z/)

          tag_self_closing = tag_closing == '/>' || SELF_CLOSING_TAG.match?(tag_name)
          tag_attrs.strip!
          formatted_tag_name = format_attributes(tag_name, tag_attrs.strip, tag_closing).gsub(erb_tags_regexp, erb_tags)
          full_tag = "<#{tag_name}#{formatted_tag_name}#{tag_closing}"
          html << (scanner.pre_match.match?(/\s+\z/) ? indented(full_tag) : full_tag)

          tag_stack_push(tag_name, full_tag) unless tag_self_closing
        else
          raise "Unrecognized content: #{matched.inspect}"
        end
      else
        format_erb_tags(scanner.rest.to_s)
        scanner.terminate
      end
    end

    html.gsub!(erb_tags_regexp, erb_tags)
    html.gsub!(pre_placeholders_regexp, pre_placeholders)
    html.strip!
    html << "\n"
  end
end
