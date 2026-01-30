# frozen_string_literal: false

require "pp"
require "erb"
require "yaml"
require "strscan"
require "stringio"
require "securerandom"
require "erb/formatter/version"

require "syntax_tree"

class ERB::Formatter
  module SyntaxTreeCommandPatch
    def format(q)
      q.group do
        q.format(message)
        q.text(" ")
        q.format(arguments) # WAS: q.nest(message.value.length + 1) { q.format(arguments) }
      end
    end
  end

  autoload :IgnoreList, "erb/formatter/ignore_list"

  class Error < StandardError; end

  SPACES = /\s+/m

  # https://stackoverflow.com/a/317081
  ATTR_NAME = %r{[^\r\n\t\f\v= '"<>]*[^\r\n\t\f\v= '"<>/]}u # not ending with a slash
  UNQUOTED_VALUE = %r{[^<>'"\s]+}u
  UNQUOTED_ATTR = %r{#{ATTR_NAME}=#{UNQUOTED_VALUE}}u
  SINGLE_QUOTE_ATTR = %r{(?:#{ATTR_NAME}='[^']*?')}mu
  DOUBLE_QUOTE_ATTR = %r{(?:#{ATTR_NAME}="[^"]*?")}mu
  BAD_ATTR = %r{#{ATTR_NAME}=\s+}u
  QUOTED_ATTR = Regexp.union(SINGLE_QUOTE_ATTR, DOUBLE_QUOTE_ATTR)
  ATTR = Regexp.union(SINGLE_QUOTE_ATTR, DOUBLE_QUOTE_ATTR, UNQUOTED_ATTR, UNQUOTED_VALUE)
  MULTILINE_ATTR_NAMES = %w[class data-action]

  ERB_TAG = %r{(<%(?:=|-|#)*)(?:(?!\n)\s)*(.*?)\s*(-?%>)}m
  ERB_PLACEHOLDER = %r{erb[a-z0-9]+tag}

  TAG_NAME = /[a-z0-9_:-]+/u
  TAG_NAME_ONLY = /\A#{TAG_NAME}\z/
  HTML_ATTR = %r{\s+#{SINGLE_QUOTE_ATTR}|\s+#{DOUBLE_QUOTE_ATTR}|\s+#{UNQUOTED_ATTR}|\s+#{ATTR_NAME}}m
  HTML_TAG_OPEN = %r{<(#{TAG_NAME})((?:#{HTML_ATTR})*)(\s*?)(/>|>)}m
  HTML_TAG_CLOSE = %r{</\s*(#{TAG_NAME})\s*>}

  SELF_CLOSING_TAG = /\A(area|base|br|col|command|embed|hr|img|input|keygen|link|menuitem|meta|param|source|track|wbr)\z/i

  begin
    require "prism" # ruby 3.3
    RUBY_OPEN_BLOCK = Prism.method(:parse_failure?)
  rescue LoadError
    require "ripper"
    RUBY_OPEN_BLOCK = ->(code) do
      # is nil when the parsing is broken, meaning it's an open expression
      Ripper.sexp(code).nil?
    end.freeze
  end

  RUBY_STANDALONE_BLOCK = /\A(yield|next)\b/
  RUBY_CLOSE_BLOCK = /\Aend\z/
  RUBY_REOPEN_BLOCK = /\A(else|(elsif|when|in)\b(.*))\z/

  RUBOCOP_STDIN_MARKER = "===================="

  module DebugShovel
    def <<(string)
      puts "ADDING: #{string.inspect} FROM:\n  #{caller(1, 5).join("\n  ")}"
      super
    end
  end

  def self.format(source, filename: nil)
    new(source, filename: filename).html
  end

  def initialize(source, line_width: 80, single_class_per_line: false, filename: nil, css_class_sorter: nil,
    debug: $DEBUG)
    @original_source = source.to_s
    @original_source = +@original_source if @original_source.frozen?
    @original_source.force_encoding("UTF-8")

    @filename = filename || "(erb)"
    @line_width = line_width
    @source = remove_front_matter @original_source.dup
    @html = +"".force_encoding("UTF-8")
    @debug = debug
    @single_class_per_line = single_class_per_line
    @css_class_sorter = css_class_sorter

    html.extend DebugShovel if @debug

    @tag_stack = []
    @pre_pos = 0

    build_uid = -> { ["erb", SecureRandom.uuid, "tag"].join.delete("-") }

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

  def remove_front_matter(source)
    return source unless source.start_with?("---\n")

    first_body_line = YAML.parse(source).children.first.end_line + 1
    lines = source.lines

    @front_matter = lines[0...first_body_line].join
    lines[first_body_line..].join
  end

  attr_accessor \
    :source, :html, :tag_stack, :pre_pos, :pre_placeholders, :erb_tags, :erb_tags_regexp,
    :pre_placeholders_regexp, :tags_regexp, :line_width

  alias_method :to_s, :html

  def format_attributes(tag_name, attrs, tag_closing)
    return "" if attrs.strip.empty?

    plain_attrs = attrs.tr("\n", " ").squeeze(" ").gsub(erb_tags_regexp, erb_tags)

    if @css_class_sorter
      sorted_attrs = build_single_line_attrs(attrs)
      within_line_width = "<#{tag_name} #{sorted_attrs}#{tag_closing}".size <= line_width
      return " #{sorted_attrs}" if within_line_width
    else
      within_line_width = "<#{tag_name} #{plain_attrs}#{tag_closing}".size <= line_width
      return " #{plain_attrs}" if within_line_width
    end

    attr_html = ""
    tag_stack_push(["attr="], attrs)
    # Calculate alignment for subsequent attributes (align with first attr position)
    # Account for: "<" + tag_name + " "
    # Use tag_stack.size - 1 because we just pushed 'attr=' onto the stack
    base_indent = "  " * (tag_stack.size - 1)
    attr_indent = " " * (tag_name.length + 2)
    first_attr = true
    attrs.scan(ATTR).flatten.each do |attr|
      attr.strip!
      name, value = attr.split("=", 2)
      # Build the full attribute string
      if value.nil?
        full_attr = name
      elsif /\A#{UNQUOTED_VALUE}\z/o.match?(value)
        full_attr = "#{name}=\"#{value}\""
      else
        value_parts = value[1...-1].strip.split(SPACES)
        value_parts.sort_by!(&@css_class_sorter) if name == "class" && @css_class_sorter
        quote_char = value[0]

        # Check if this attribute can have its value split across lines
        if MULTILINE_ATTR_NAMES.include?(name)

          test_attr = "#{name}=#{quote_char}#{value_parts.join(" ")}#{value[-1]}"
          # For first attr, position is base_indent + "<" + tag_name + " "
          # For subsequent attrs, position is base_indent + attr_indent
          attr_position = base_indent.length + (first_attr ? (tag_name.length + 2) : attr_indent.length)

          if (attr_position + test_attr.length) > line_width && value_parts.length > 1
            equals_and_quote_length = 2
            value_indent = " " * (attr_position + name.length + equals_and_quote_length)

            lines = []
            current_line = []
            current_length = attr_position + name.length + equals_and_quote_length

            value_parts.each do |part|
              space_length = current_line.empty? ? 0 : 1
              test_length = current_length + space_length + part.length

              if test_length <= line_width || current_line.empty?
                current_line << part
                current_length = test_length
              else
                lines << current_line.join(" ")
                current_line = [part]
                current_length = value_indent.length + part.length
              end
            end
            lines << current_line.join(" ") unless current_line.empty?
            full_attr = "#{name}=#{quote_char}#{lines.join("\n#{value_indent}")}#{value[-1]}"
          else
            full_attr = "#{name}=#{quote_char}#{value_parts.join(" ")}#{value[-1]}"
          end
        else
          full_attr = "#{name}=#{value[0]}#{value_parts.join(" ")}#{value[-1]}"
        end

      end
      # First attribute goes on same line as tag, rest are aligned
      if first_attr
        attr_html << " #{full_attr}"
        first_attr = false
      else
        # Align with first attribute position
        attr_html << "\n#{base_indent}#{attr_indent}#{full_attr}"
      end
    end
    tag_stack_pop(["attr="], attrs)
    # Closing tag stays on same line as last attribute
    attr_html
  end

  def build_single_line_attrs(attrs)
    attrs.scan(ATTR).flatten.map do |attr|
      attr = attr.strip
      name, value = attr.split("=", 2)
      if value.nil?
        name
      elsif /\A#{UNQUOTED_VALUE}\z/o.match?(value)
        "#{name}=\"#{value}\""
      else
        value_parts = value[1...-1].strip.split(SPACES)
        value_parts.sort_by!(&@css_class_sorter) if name == "class" && @css_class_sorter
        "#{name}=#{value[0]}#{value_parts.join(" ")}#{value[-1]}"
      end
    end.join(" ")
  end

  def tag_stack_push(tag_name, code, multiline: false)
    tag_stack << [tag_name, code, multiline]
    p PUSH: tag_stack if @debug
  end

  def tag_stack_pop(tag_name, code)
    unless tag_name == tag_stack.last&.first
      raise "Unmatched close tag, tried with #{[tag_name, code]}, but #{tag_stack.last} was on the stack"
    end

    entry = tag_stack.pop
    p POP_: tag_stack if @debug
    entry
  end

  def current_tag_multiline?
    tag_stack.last&.[](2) || false
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
      "==> ERROR: #{message}"
    ].join("\n"))
    error.set_backtrace caller.to_a + [location]
    super(error)
  end

  def indented(string, strip: true)
    string = string.strip if strip
    indent = "  " * tag_stack.size
    "\n#{indent}#{string}"
  end

  def format_text(text)
    p format_text: text if @debug
    return unless text

    starting_space = text.match?(/\A\s/) || current_tag_multiline?

    final_newlines_count = text.match(/(\s*)\z/m).captures.last.count("\n")
    html << "\n" if final_newlines_count > 1

    return if text.match?(/\A\s*\z/m) # empty

    text = text.gsub(SPACES, " ").strip

    offset = indented("").size
    # Restore full line width if there are less than 40 columns available
    offset = 0 if (line_width - offset) <= 40
    available_width = line_width - offset

    lines = []

    until text.empty?
      if text.size >= available_width
        last_space_index = text[0..available_width].rindex(" ")
        lines << text.slice!(0..last_space_index)
      else
        lines << text.slice!(0..-1)
      end
      0
    end
    p lines: lines if @debug
    html << lines.shift.strip unless starting_space
    lines.each do |line|
      html << indented(line)
    end
  end

  def format_ruby(code, autoclose: false, open_length: 3)
    if autoclose
      code += "\nend" unless RUBY_OPEN_BLOCK["#{code}\nend"]
      code += "\n}" unless RUBY_OPEN_BLOCK["#{code}\n}"]
    end
    p RUBY_IN_: code if @debug

    # SyntaxTree::Command.prepend SyntaxTreeCommandPatch

    code = begin
      # TODO: For single-lines, 7 should be subtracted instead of 2: 3 for opening, 2 for closing and 2 surrounding spaces
      # Subtract 4 for multiline indentation or for the surrounding tags
      # Then subtract twice the tag_stack size to respect indentation
      width = @line_width - 4 - tag_stack.size * 2
      SyntaxTree.format(code, width)
    rescue SyntaxTree::Parser::ParseError => error
      p RUBY_PARSE_ERROR: error if @debug
      code
    end

    lines = code.strip.lines
    lines = lines[0...-1] if autoclose
    code = lines.map { |l| indented("#{" " * (open_length - 1)}#{l.chomp("\n")}", strip: false) }.join
    p RUBY_OUT: code if @debug
    code
  end

  def format_erb_tags(string)
    p format_erb_tags: string if @debug
    if %w[style script].include?(tag_stack.last&.first)
      html << string.rstrip
      return
    end

    erb_scanner = StringScanner.new(string.to_s)
    erb_pre_pos = 0
    until erb_scanner.eos?
      if erb_scanner.scan_until(erb_tags_regexp)
        p PRE_MATCH: [erb_pre_pos, "..", erb_scanner.pre_match] if @debug
        erb_pre_match = erb_scanner.pre_match
        erb_pre_match = erb_pre_match[erb_pre_pos..].to_s
        erb_pre_pos = erb_scanner.pos

        erb_code = erb_tags[erb_scanner.captures.first]

        format_text(erb_pre_match)

        erb_open, ruby_code, erb_close = ERB_TAG.match(erb_code).captures
        ruby_code.strip!

        block_type =
          if erb_open.include?("#")
            :comment
          else
            case ruby_code
            when RUBY_STANDALONE_BLOCK then :standalone
            when RUBY_CLOSE_BLOCK then :close
            when RUBY_REOPEN_BLOCK then :reopen
            when RUBY_OPEN_BLOCK then :open
            else :other
            end
          end

        # Format Ruby code, and indent if it's multiline
        if block_type == :open
          # Block openers aren't complete ruby scripts, so syntax_tree won't like them.
          # These are two workarounds to help make most of them valid, so we can format them anyway.
          if (match = ruby_code.match(/(?:\s+do|\s*\{)(?:\s*\|\s*\w+\s*(?:,\s*\w+\s*)*\|)?\s*\z/))
            # If this is a block starter (ends with "do" or "{" followed by optional block parameters), it usually is a
            #   valid statement without the suffix
            suffix = match[0]
            ruby_code = "#{format_ruby(ruby_code.chomp(suffix), autoclose: false,
              open_length: erb_open.length)} #{suffix.strip}"
          elsif ruby_code.start_with?("if ", "unless ", "while ", "until ")
            # If this is a condition or loop, it may be a valid expression without first word
            keyword, rest = ruby_code.split(/\s+/, 2)
            ruby_code = format_ruby(rest, autoclose: false, open_length: erb_open.length).sub(/^(\s*)/,
              "\\1#{keyword} ")
          end
          ruby_code.gsub!(/^/, "  ") if ruby_code.strip.include?("\n")
        elsif %i[standalone other].include?(block_type)
          ruby_code = format_ruby(ruby_code, autoclose: false, open_length: erb_open.length)
          ruby_code.gsub!(/^/, "  ") if ruby_code.strip.include?("\n")
        end

        # Remove the first line if it only has whitespace
        ruby_code.sub!(/\A((?!\n)\s)*\n/, "")

        # Reset "common" indentation of multi-line comments
        if block_type == :comment && ruby_code.strip.include?("\n")
          # Leave comments intact, but if they're multiline, replace common indentation
          ruby_code.gsub!(/^#{ruby_code.scan(/^ */).min_by(&:length)}/, "  ")
        end

        full_erb_tag = "#{erb_open} #{ruby_code.strip}#{ruby_code.strip.include?("\n") ? indented(erb_close) : " #{erb_close}"}"

        tag_stack_pop("%erb%", ruby_code) if %i[close reopen].include? block_type
        html << (erb_pre_match.match?(/\s+\z/) ? indented(full_erb_tag) : full_erb_tag)
        tag_stack_push("%erb%", ruby_code) if %i[reopen open].include? block_type
      else
        p ERB_REST: erb_scanner.rest if @debug
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
        p format_pre_match: [pre_pos, "..", scanner.pre_match[pre_pos..]] if @debug
        pre_match = scanner.pre_match[pre_pos..]
        p POS: pre_pos...scanner.pos, advanced: source[pre_pos...scanner.pos] if @debug
        p MATCHED: matched if @debug
        self.pre_pos = scanner.charpos

        # Don't accept `name= "value"` attributes
        raise "Bad attribute, please fix spaces after the equal sign:\n#{pre_match}" if BAD_ATTR.match? pre_match

        format_erb_tags(pre_match) if pre_match

        if matched.match?(HTML_TAG_CLOSE)
          tag_name = scanner.captures.first

          full_tag = "</#{tag_name}>"
          popped_entry = tag_stack_pop(tag_name, full_tag)
          multiline = popped_entry&.[](2) || false
          should_indent = scanner.pre_match.match?(/\s+\z/) || multiline
          html << (should_indent ? indented(full_tag) : full_tag)

        elsif matched.match(HTML_TAG_OPEN)
          _, tag_name, tag_attrs, _, tag_closing = *scanner.captures

          raise "Unknown tag #{tag_name.inspect}" unless tag_name.match?(TAG_NAME_ONLY)

          tag_self_closing = tag_closing == "/>" || SELF_CLOSING_TAG.match?(tag_name)
          tag_attrs.strip!
          formatted_tag_name = format_attributes(tag_name, tag_attrs.strip, tag_closing).gsub(erb_tags_regexp, erb_tags)
          closing = (tag_closing == "/>") ? " />" : tag_closing
          full_tag = "<#{tag_name}#{formatted_tag_name}#{closing}"
          tag_multiline = formatted_tag_name.include?("\n")
          html << (scanner.pre_match.match?(/\s+\z/) ? indented(full_tag) : full_tag)

          tag_stack_push(tag_name, full_tag, multiline: tag_multiline) unless tag_self_closing
        else
          raise "Unrecognized content: #{matched.inspect}"
        end
      else
        p format_rest: scanner.rest if @debug
        format_erb_tags(scanner.rest.to_s)
        scanner.terminate
      end
    end

    html.gsub!(erb_tags_regexp, erb_tags)
    html.gsub!(pre_placeholders_regexp, pre_placeholders)
    html.strip!
    html.prepend @front_matter + "\n" if @front_matter
    html << "\n"
  end
end
