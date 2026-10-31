# frozen_string_literal: true

module RuboCop
  module Cop
    # Commissioner class is responsible for processing the AST and delegating
    # work to the specified cops.
    class Commissioner
      include RuboCop::AST::Traversal

      RESTRICTED_CALLBACKS = %i[on_send on_csend after_send after_csend].freeze
      private_constant :RESTRICTED_CALLBACKS

      # A run sees only a few distinct lists of cop classes, one per config and
      # kind of file, so this many is plenty.
      MAX_CALLBACK_TABLES = 64
      private_constant :MAX_CALLBACK_TABLES

      # How a Commissioner returns the results of the investigation
      # as a list of Cop::InvestigationReport and any errors caught
      # during the investigation.
      # Immutable
      # Consider creation API private
      InvestigationReport = Struct.new(:processed_source, :cop_reports, :errors) do
        def cops
          @cops ||= cop_reports.map(&:cop)
        end

        def offenses_per_cop
          @offenses_per_cop ||= cop_reports.map(&:offenses)
        end

        def correctors
          @correctors ||= cop_reports.map(&:corrector)
        end

        def offenses
          @offenses ||= offenses_per_cop.flatten(1)
        end

        def merge(investigation)
          InvestigationReport.new(processed_source,
                                  cop_reports + investigation.cop_reports,
                                  errors + investigation.errors)
        end
      end

      attr_reader :errors

      class << self
        # The callback tables for a list of cop classes, holding indices into
        # the list. Building them is a large part of the cost of a file when
        # many cops are enabled, so they are built once per list.
        #
        # @api private
        # @return [Array(Hash, Hash)] the callbacks and the restricted callbacks
        def callback_tables(cop_classes)
          @callback_tables ||= {}
          @callback_tables.fetch(cop_classes) do
            @callback_tables.clear if @callback_tables.size >= MAX_CALLBACK_TABLES
            @callback_tables[cop_classes.freeze] = build_callback_tables(cop_classes)
          end
        end

        private

        def build_callback_tables(cop_classes)
          callbacks = {}
          cop_classes.each_with_index do |cop_class, index|
            cop_class.callbacks_needed.each do |callback|
              (callbacks[callback] ||= []) << index
            end
          end
          restricted = RESTRICTED_CALLBACKS.to_h do |callback|
            [callback, restricted_table(cop_classes, callbacks[callback])]
          end
          [callbacks.freeze, restricted.freeze]
        end

        # NOTE: mutates `indices` in place
        def restricted_table(cop_classes, indices)
          table = {}
          indices&.select! do |index|
            restrictions = cop_classes[index].send :restrict_on_send
            restrictions.each { |name| (table[name] ||= []) << index }
            restrictions.empty?
          end
          table
        end
      end

      def initialize(cops, forces = [], options = {})
        @cops = cops
        @forces = forces
        @options = options
        initialize_callbacks

        reset
      end

      # Create methods like :on_send, :on_super, etc. They will be called
      # during AST traversal and try to call corresponding methods on cops.
      # A call to `super` is used
      # to continue iterating over the children of a node.
      # However, if we know that a certain node type (like `int`) never has
      # child nodes, there is no reason to pay the cost of calling `super`.
      Parser::Meta::NODE_TYPES.each do |node_type|
        method_name = :"on_#{node_type}"
        next unless method_defined?(method_name)

        # Hacky: Comment-out code as needed
        r = '#' unless RESTRICTED_CALLBACKS.include?(method_name) # has Restricted?
        c = '#' if NO_CHILD_NODES.include?(node_type) # has Children?

        # The `after_` calls are guarded because barely any cop defines an `after_`
        # callback, and the guard is cheaper than the method call it avoids.
        class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
                  def on_#{node_type}(node)                                                                                # def on_send(node)
                    trigger_responding_cops(:on_#{node_type}, node)                                                        #   trigger_responding_cops(:on_send, node)
              #{r}  trigger_restricted_cops(:on_#{node_type}, node)                                                        #   trigger_restricted_cops(:on_send, node)
          #{c}      super(node)                                                                                            #   super(node)
          #{c}      trigger_responding_cops(:after_#{node_type}, node) if @callbacks[:after_#{node_type}]                  #   trigger_responding_cops(:after_send, node) if @callbacks[:after_send]
          #{c}#{r}  trigger_restricted_cops(:after_#{node_type}, node) unless @restricted_map[:after_#{node_type}].empty?  #   trigger_restricted_cops(:after_send, node) unless @restricted_map[:after_send].empty?
                  end                                                                                                      # end
        RUBY
      end

      # @return [InvestigationReport]
      def investigate(processed_source, offset: 0, original: processed_source)
        reset

        begin_investigation(processed_source, offset: offset, original: original)
        if processed_source.valid_syntax?
          invoke(:on_new_investigation, @callbacks[:on_new_investigation])
          invoke_with_argument(:investigate, @forces, processed_source)

          walk(processed_source.ast) unless @cops.empty?
          invoke(:on_investigation_end, @callbacks[:on_investigation_end])
        else
          invoke(:on_other_file, @callbacks[:on_other_file])
        end
        reports = @cops.map { |cop| cop.send(:complete_investigation) }
        InvestigationReport.new(processed_source, reports, @errors)
      end

      private

      def begin_investigation(processed_source, offset:, original:)
        @cops.each do |cop|
          cop.begin_investigation(processed_source, offset: offset, original: original)
        end
      end

      def trigger_responding_cops(callback, node)
        @callbacks[callback]&.each do |cop|
          with_cop_error_handling(cop, node) do
            cop.public_send(callback, node)
          end
        end
      end

      def reset
        @errors = []
      end

      def initialize_callbacks
        callbacks, restricted = self.class.callback_tables(@cops.map(&:class))
        @callbacks = callbacks.transform_values { |indices| @cops.values_at(*indices) }
        @restricted_map = restricted.transform_values do |table|
          table.transform_values { |indices| @cops.values_at(*indices) }
        end
      end

      def trigger_restricted_cops(event, node)
        name = node.method_name
        @restricted_map[event][name]&.each do |cop|
          with_cop_error_handling(cop, node) do
            cop.public_send(event, node)
          end
        end
      end

      def invoke(callback, cops)
        cops&.each { |cop| with_cop_error_handling(cop) { cop.send(callback) } }
      end

      def invoke_with_argument(callback, cops, arg)
        cops.each { |cop| with_cop_error_handling(cop) { cop.send(callback, arg) } }
      end

      # Allow blind rescues here, since we're absorbing and packaging or
      # re-raising exceptions that can be raised from within the individual
      # cops' `#investigate` methods.
      def with_cop_error_handling(cop, node = nil)
        yield
      rescue StandardError => e
        raise e if @options[:raise_error] # For internal testing

        err = ErrorWithAnalyzedFileLocation.new(cause: e, node: node, cop: cop)
        raise err if @options[:raise_cop_error] # From user-input option

        @errors << err
      end
    end
  end
end
