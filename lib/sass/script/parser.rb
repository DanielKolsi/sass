require 'sass/script/lexer'

module Sass
  module Script
    # The parser for SassScript.
    # It parses a string of code into a tree of {Script::Tree::Node}s.
    class Parser
      # The line number of the parser's current position.
      #
      # @return [Fixnum]
      def line
        @lexer.line
      end

      # The column number of the parser's current position.
      #
      # @return [Fixnum]
      def offset
        @lexer.offset
      end

      # @param str [String, StringScanner] The source text to parse
      # @param line [Fixnum] The line on which the SassScript appears.
      #   Used for error reporting and sourcemap building
      # @param offset [Fixnum] The character (not byte) offset where the script starts in the line.
      #   Used for error reporting and sourcemap building
      # @param options [{Symbol => Object}] An options hash; see
      #   {file:SASS_REFERENCE.md#sass_options the Sass options documentation}.
      #   This supports an additional `:allow_extra_text` option that controls
      #   whether the parser throws an error when extra text is encountered
      #   after the parsed construct.
      def initialize(str, line, offset, options = {})
        @options = options
        @allow_extra_text = options.delete(:allow_extra_text)
        @lexer = lexer_class.new(str, line, offset, options)
        @stop_at = nil
      end

      # Parses a SassScript expression within an interpolated segment (`#{}`).
      # This means that it stops when it comes across an unmatched `}`,
      # which signals the end of an interpolated segment,
      # it returns rather than throwing an error.
      #
      # @param warn_for_color [Boolean] Whether raw color values passed to
      #   interoplation should cause a warning.
      # @return [Script::Tree::Node] The root node of the parse tree
      # @raise [Sass::SyntaxError] if the expression isn't valid SassScript
      def parse_interpolated(warn_for_color = false)
        # Start two characters back to compensate for #{
        start_pos = Sass::Source::Position.new(line, offset - 2)
        expr = assert_expr :expr
        assert_tok :end_interpolation
        expr = Sass::Script::Tree::Interpolation.new(expr, warn_for_color)
        expr.options = @options
        node(expr, start_pos)
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses a SassScript expression.
      #
      # @return [Script::Tree::Node] The root node of the parse tree
      # @raise [Sass::SyntaxError] if the expression isn't valid SassScript
      def parse
        expr = assert_expr :expr
        assert_done
        expr.options = @options
        expr
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses a SassScript expression,
      # ending it when it encounters one of the given identifier tokens.
      #
      # @param tokens [#include?(String)] A set of strings that delimit the expression.
      # @return [Script::Tree::Node] The root node of the parse tree
      # @raise [Sass::SyntaxError] if the expression isn't valid SassScript
      def parse_until(tokens)
        @stop_at = tokens
        expr = assert_expr :expr
        assert_done
        expr.options = @options
        expr
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses the argument list for a mixin include.
      #
      # @return [(Array<Script::Tree::Node>,
      #          {String => Script::Tree::Node},
      #          Script::Tree::Node,
      #          Script::Tree::Node)]
      #   The root nodes of the positional arguments, keyword arguments, and
      #   splat argument(s). Keyword arguments are in a hash from names to values.
      # @raise [Sass::SyntaxError] if the argument list isn't valid SassScript
      def parse_mixin_include_arglist
        args, keywords = [], {}
        if try_tok(:lparen)
          args, keywords, splat, kwarg_splat = mixin_arglist
          assert_tok(:rparen)
        end
        assert_done

        args.each {|a| a.options = @options}
        keywords.each {|_k, v| v.options = @options}
        splat.options = @options if splat
        kwarg_splat.options = @options if kwarg_splat
        return args, keywords, splat, kwarg_splat
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses the argument list for a mixin definition.
      #
      # @return [(Array<Script::Tree::Node>, Script::Tree::Node)]
      #   The root nodes of the arguments, and the splat argument.
      # @raise [Sass::SyntaxError] if the argument list isn't valid SassScript
      def parse_mixin_definition_arglist
        args, splat = defn_arglist!(false)
        assert_done

        args.each do |k, v|
          k.options = @options
          v.options = @options if v
        end
        splat.options = @options if splat
        return args, splat
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses the argument list for a function definition.
      #
      # @return [(Array<Script::Tree::Node>, Script::Tree::Node)]
      #   The root nodes of the arguments, and the splat argument.
      # @raise [Sass::SyntaxError] if the argument list isn't valid SassScript
      def parse_function_definition_arglist
        args, splat = defn_arglist!(true)
        assert_done

        args.each do |k, v|
          k.options = @options
          v.options = @options if v
        end
        splat.options = @options if splat
        return args, splat
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parse a single string value, possibly containing interpolation.
      # Doesn't assert that the scanner is finished after parsing.
      #
      # @return [Script::Tree::Node] The root node of the parse tree.
      # @raise [Sass::SyntaxError] if the string isn't valid SassScript
      def parse_string
        unless (peek = @lexer.peek) &&
            (peek.type == :string ||
            (peek.type == :funcall && peek.value.downcase == 'url'))
          lexer.expected!("string")
        end

        expr = assert_expr :funcall
        expr.options = @options
        @lexer.unpeek!
        expr
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @lexer.line, :filename => @options[:filename]
        raise e
      end

      # Parses a SassScript expression.
      #
      # @overload parse(str, line, offset, filename = nil)
      # @return [Script::Tree::Node] The root node of the parse tree
      # @see Parser#initialize
      # @see Parser#parse
      def self.parse(*args)
        new(*args).parse
      end

      PRECEDENCE = [
        :comma, :single_eq, :space, :or, :and,
        [:eq, :neq],
        [:gt, :gte, :lt, :lte],
        [:plus, :minus],
        [:times, :div, :mod],
      ]

      ASSOCIATIVE = [:plus, :times]

      class << self
        # Returns an integer representing the precedence
        # of the given operator.
        # A lower integer indicates a looser binding.
        #
        # @private
        def precedence_of(op)
          PRECEDENCE.each_with_index do |e, i|
            return i if Array(e).include?(op)
          end
          raise "[BUG] Unknown operator #{op.inspect}"
        end

        # Returns whether or not the given operation is associative.
        #
        # @private
        def associative?(op)
          ASSOCIATIVE.include?(op)
        end

        private

        # Defines a simple left-associative production.
        # name is the name of the production,
        # sub is the name of the production beneath it,
        # and ops is a list of operators for this precedence level
        def production(name, sub, *ops)
          class_eval <<RUBY, __FILE__, __LINE__ + 1
            def #{name}
              return unless e = #{sub}
              while tok = try_toks(#{ops.map {|o| o.inspect}.join(', ')})
                e = node(Tree::Operation.new(e, assert_expr(#{sub.inspect}), tok.type),
                         e.source_range.start_pos)
              end
              e
            end
RUBY
        end

        def unary(op, sub)
          class_eval <<RUBY, __FILE__, __LINE__ + 1
            def unary_#{op}
              return #{sub} unless try_tok(:#{op})
              start_pos = source_position
              node(Tree::UnaryOperation.new(assert_expr(:unary_#{op}), :#{op}), start_pos)
            end
RUBY
        end
      end

      private

      def source_position
        Sass::Source::Position.new(line, offset)
      end

      def range(start_pos, end_pos = source_position)
        Sass::Source::Range.new(start_pos, end_pos, @options[:filename], @options[:importer])
      end

      # @private
      def lexer_class; Lexer; end

      def map
        start_pos = source_position
        e = space
        return unless e
        return list e, start_pos unless @lexer.peek && @lexer.peek.type == :colon

        pair = map_pair(e)
        map = node(Sass::Script::Tree::MapLiteral.new([pair]), start_pos)
        while try_tok(:comma)
          pair = map_pair
          return map unless pair
          map.pairs << pair
        end
        map
      end

      def map_pair(key = nil)
        return unless key ||= space
        assert_tok :colon
        return key, assert_expr(:space)
      end

      def expr
        start_pos = source_position
        e = space
        return unless e
        list e, start_pos
      end

      def list(first, start_pos)
        return first unless @lexer.peek && @lexer.peek.type == :comma

        list = node(Sass::Script::Tree::ListLiteral.new([first], separator: :comma), start_pos)
        while try_tok(:comma)
          return list unless (e = space)
          list.elements << e
          list.source_range.end_pos = list.elements.last.source_range.end_pos
        end
        list
      end


      production :equals, :space, :single_eq

      # Returns whether `expr` is safe as the value immediately before an
      # interpolation.
      #
      # It's safe as long as the previous expression is an identifier or number,
      # or a list whose last element is also safe.
      def is_safe_value?(expr)
        return is_safe_value?(expr.elements.last) if expr.is_a?(Script::Tree::ListLiteral)
        return false unless expr.is_a?(Script::Tree::Literal)
        expr.value.is_a?(Script::Value::Number) ||
          (expr.value.is_a?(Script::Value::String) && expr.value.type == :identifier)
      end

      def space
        start_pos = source_position
        e = or_expr
        return unless e
        arr = [e]
        while (e = or_expr)
          arr << e
        end
        if arr.size == 1
          arr.first
        else
          node(Sass::Script::Tree::ListLiteral.new(arr, separator: :space), start_pos)
        end
      end

      production :or_expr, :and_expr, :or
      production :and_expr, :eq_or_neq, :and
      production :eq_or_neq, :relational, :eq, :neq
      production :relational, :plus_or_minus, :gt, :gte, :lt, :lte
      production :plus_or_minus, :times_div_or_mod, :plus, :minus
      production :times_div_or_mod, :unary_plus, :times, :div, :mod

      unary :plus, :unary_minus
      unary :minus, :unary_div
      unary :div, :unary_not # For strings, so /foo/bar works
      unary :not, :ident

      def ident
        return funcall unless (first = @lexer.peek)

        contents = []
        if first.type == :ident
          return if @stop_at && @stop_at.include?(first.value)
          contents << @lexer.next.value
        elsif first.type == :begin_interpolation
          @lexer.next # Move through :begin_interpolation
          contents << assert_expr(:expr)
          assert_tok(:end_interpolation)
        else
          return funcall
        end

        while (tok = @lexer.peek)
          break if @lexer.whitespace_before?(tok)

          if tok.type == :ident
            contents << @lexer.next.value
            next
          end

          break unless try_tok(:begin_interpolation)
          contents << assert_expr(:expr)
          assert_tok(:end_interpolation)
        end

        if contents.length > 1 || contents.first.is_a?(Sass::Script::Tree::Node)
          return node(
            Sass::Script::Tree::StringInterpolation.new(contents, :identifier),
            first.source_range.start_pos)
        end

        if (color = Sass::Script::Value::Color::COLOR_NAMES[first.value.downcase])
          literal_node(Sass::Script::Value::Color.new(color, first.value), first.source_range)
        elsif first.value == "true"
          literal_node(Sass::Script::Value::Bool.new(true), first.source_range)
        elsif first.value == "false"
          literal_node(Sass::Script::Value::Bool.new(false), first.source_range)
        elsif first.value == "null"
          literal_node(Sass::Script::Value::Null.new, first.source_range)
        else
          literal_node(
            Sass::Script::Value::String.new(first.value, :identifier),
            first.source_range)
        end
      end

      def funcall
        tok = try_tok(:funcall)
        return raw unless tok
        args, keywords, splat, kwarg_splat = fn_arglist
        assert_tok(:rparen)
        node(Script::Tree::Funcall.new(tok.value, args, keywords, splat, kwarg_splat),
          tok.source_range.start_pos, source_position)
      end

      def defn_arglist!(must_have_parens)
        if must_have_parens
          assert_tok(:lparen)
        else
          return [], nil unless try_tok(:lparen)
        end

        res = []
        splat = nil
        must_have_default = false
        loop do
          break if peek_tok(:rparen)
          c = assert_tok(:const)
          var = node(Script::Tree::Variable.new(c.value), c.source_range)
          if try_tok(:colon)
            val = assert_expr(:space)
            must_have_default = true
          elsif try_tok(:splat)
            splat = var
            break
          elsif must_have_default
            raise SyntaxError.new(
              "Required argument #{var.inspect} must come before any optional arguments.")
          end
          res << [var, val]
          break unless try_tok(:comma)
        end
        assert_tok(:rparen)
        return res, splat
      end

      def fn_arglist
        arglist(:equals, "function argument")
      end

      def mixin_arglist
        arglist(:space, "mixin argument")
      end

      def arglist(subexpr, description)
        args = []
        keywords = Sass::Util::NormalizedMap.new
        splat = nil
        while (e = send(subexpr))
          if @lexer.peek && @lexer.peek.type == :colon
            name = e
            @lexer.expected!("comma") unless name.is_a?(Tree::Variable)
            assert_tok(:colon)
            value = assert_expr(subexpr, description)

            if keywords[name.name]
              raise SyntaxError.new("Keyword argument \"#{name.to_sass}\" passed more than once")
            end

            keywords[name.name] = value
          else
            if try_tok(:splat)
              return args, keywords, splat, e if splat
              splat, e = e, nil
            elsif splat
              raise SyntaxError.new("Only keyword arguments may follow variable arguments (...).")
            elsif !keywords.empty?
              raise SyntaxError.new("Positional arguments must come before keyword arguments.")
            end
            args << e if e
          end

          return args, keywords, splat unless try_tok(:comma)
        end
        return args, keywords
      end

      def raw
        tok = try_tok(:raw)
        return special_fun unless tok
        literal_node(Script::Value::String.new(tok.value), tok.source_range)
      end

      def special_fun
        first = try_tok(:special_fun)
        return square_list unless first

        unless try_tok(:string_interpolation)
          return literal_node(first.value, first.source_range)
        end

        contents = [first.value.value]
        begin
          contents << assert_expr(:expr)
          assert_tok :end_interpolation
          contents << assert_tok(:special_fun).value.value
        end while try_tok(:string_interpolation)

        node(
          Tree::StringInterpolation.new(contents, :identifier),
          first.source_range.start_pos)
      end

      def square_list
        start_pos = source_position
        return paren unless try_tok(:lsquare)

        space_start_pos = source_position
        e = or_expr
        separator = nil
        if e
          elements = [e]
          while (e = or_expr)
            elements << e
          end

          # If there's a comma after a space-separated list, it's actually a
          # space-separated list nested in a comma-separated list.
          if try_tok(:comma)
            e = if elements.length == 1
                  elements.first
                else
                  node(
                    Sass::Script::Tree::ListLiteral.new(elements, separator: :space),
                    space_start_pos)
                end
            elements = [e]

            while (e = space)
              elements << e
              break unless try_tok(:comma)
            end
            separator = :comma
          else
            separator = :space if elements.length > 1
          end
        else
          elements = []
        end

        assert_tok(:rsquare)
        end_pos = source_position

        node(Sass::Script::Tree::ListLiteral.new(elements, separator: separator, bracketed: true),
             start_pos, end_pos)
      end

      def paren
        return variable unless try_tok(:lparen)
        start_pos = source_position
        e = map
        e.force_division! if e
        end_pos = source_position
        assert_tok(:rparen)
        e || node(Sass::Script::Tree::ListLiteral.new([]), start_pos, end_pos)
      end

      def variable
        start_pos = source_position
        c = try_tok(:const)
        return string unless c
        node(Tree::Variable.new(*c.value), start_pos)
      end

      def string
        first = try_tok(:string)
        return number unless first

        unless try_tok(:string_interpolation)
          return literal_node(first.value, first.source_range)
        end

        contents = [first.value.value]
        begin
          contents << assert_expr(:expr)
          assert_tok :end_interpolation
          contents << assert_tok(:string).value.value
        end while try_tok(:string_interpolation)

        node(
          Tree::StringInterpolation.new(contents, first.value.type),
          first.source_range.start_pos)
      end

      def number
        tok = try_tok(:number)
        return selector unless tok
        num = tok.value
        num.options = @options
        num.original = num.to_s
        literal_node(num, tok.source_range.start_pos)
      end

      def selector
        tok = try_tok(:selector)
        return literal unless tok
        node(tok.value, tok.source_range.start_pos)
      end

      def literal
        t = try_tok(:color)
        return literal_node(t.value, t.source_range) if t
      end

      # It would be possible to have unified #assert and #try methods,
      # but detecting the method/token difference turns out to be quite expensive.

      EXPR_NAMES = {
        :string => "string",
        :default => "expression (e.g. 1px, bold)",
        :mixin_arglist => "mixin argument",
        :fn_arglist => "function argument",
        :splat => "..."
      }

      def assert_expr(name, expected = nil)
        e = send(name)
        return e if e
        @lexer.expected!(expected || EXPR_NAMES[name] || EXPR_NAMES[:default])
      end

      def assert_tok(name)
        # Avoids an array allocation caused by argument globbing in assert_toks.
        t = try_tok(name)
        return t if t
        @lexer.expected!(Lexer::TOKEN_NAMES[name] || name.to_s)
      end

      def assert_toks(*names)
        t = try_toks(*names)
        return t if t
        @lexer.expected!(names.map {|tok| Lexer::TOKEN_NAMES[tok] || tok}.join(" or "))
      end

      def peek_tok(name)
        # Avoids an array allocation caused by argument globbing in the try_toks method.
        peeked = @lexer.peek
        peeked && name == peeked.type
      end

      def try_tok(name)
        peek_tok(name) && @lexer.next
      end

      def try_toks(*names)
        peeked = @lexer.peek
        peeked && names.include?(peeked.type) && @lexer.next
      end

      def assert_done
        if @allow_extra_text
          # If extra text is allowed, just rewind the lexer so that the
          # StringScanner is pointing to the end of the parsed text.
          @lexer.unpeek!
        else
          return if @lexer.done?
          @lexer.expected!(EXPR_NAMES[:default])
        end
      end

      # @overload node(value, source_range)
      #   @param value [Sass::Script::Value::Base]
      #   @param source_range [Sass::Source::Range]
      # @overload node(value, start_pos, end_pos = source_position)
      #   @param value [Sass::Script::Value::Base]
      #   @param start_pos [Sass::Source::Position]
      #   @param end_pos [Sass::Source::Position]
      def literal_node(value, source_range_or_start_pos, end_pos = source_position)
        node(Sass::Script::Tree::Literal.new(value), source_range_or_start_pos, end_pos)
      end

      # @overload node(node, source_range)
      #   @param node [Sass::Script::Tree::Node]
      #   @param source_range [Sass::Source::Range]
      # @overload node(node, start_pos, end_pos = source_position)
      #   @param node [Sass::Script::Tree::Node]
      #   @param start_pos [Sass::Source::Position]
      #   @param end_pos [Sass::Source::Position]
      def node(node, source_range_or_start_pos, end_pos = source_position)
        source_range =
          if source_range_or_start_pos.is_a?(Sass::Source::Range)
            source_range_or_start_pos
          else
            range(source_range_or_start_pos, end_pos)
          end

        node.line = source_range.start_pos.line
        node.source_range = source_range
        node.filename = @options[:filename]
        node
      end
    end
  end
end
