# frozen_string_literal: true

require 'pathname'

module RuboCop
  # Common methods for finding files.
  # @api private
  module FileFinder
    class << self
      attr_accessor :root_level
    end

    def find_file_upwards(filename, start_dir, stop_dir = nil)
      traverse_files_upwards(filename, start_dir, stop_dir) do |file|
        # minimize iteration for performance
        return file if file
      end
    end

    def find_last_file_upwards(filename, start_dir, stop_dir = nil)
      last_file = nil
      traverse_files_upwards(filename, start_dir, stop_dir) { |file| last_file = file }
      last_file
    end

    def traverse_directories_upwards(start_dir, stop_dir = nil)
      each_directory_upwards(start_dir, stop_dir) { |dir| yield(Pathname.new(dir)) }
    end

    private

    def traverse_files_upwards(filename, start_dir, stop_dir)
      each_directory_upwards(start_dir, stop_dir) do |dir|
        file = File.join(dir, filename)
        yield(file) if File.exist?(file)
      end
    end

    # Plain strings are much faster here than `Pathname#ascend`.
    def each_directory_upwards(start_dir, stop_dir)
      dir = File.expand_path(start_dir)

      loop do
        yield(dir)
        break if dir == stop_dir || dir == FileFinder.root_level

        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end
    end
  end
end
