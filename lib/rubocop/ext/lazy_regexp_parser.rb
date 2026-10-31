# frozen_string_literal: true

module RuboCop
  module Ext
    # Loads `regexp_parser`, with RuboCop's extensions to it, the first time
    # code refers to one of its constants (`Regexp::Parser`, `Regexp::Expression`
    # and so on). The gem takes a while to load and many runs never parse a
    # regexp, so RuboCop does not load it up front, but cops and plugins can
    # keep using its constants without requiring it.
    #
    # `autoload` would not do: the gem defines its constants across several
    # files, so a plain `require 'regexp_parser'` (as some plugins do) would
    # trigger the autoload halfway through and fail.
    module LazyRegexpParser
      def const_missing(name)
        require_relative 'regexp_parser'

        const_defined?(name, false) ? const_get(name, false) : super
      end

      ::Regexp.singleton_class.prepend(self)
    end
  end
end
