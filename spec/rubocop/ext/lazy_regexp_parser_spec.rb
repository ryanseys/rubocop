# frozen_string_literal: true

require 'open3'

RSpec.describe RuboCop::Ext::LazyRegexpParser do
  def run_ruby(script)
    lib = File.expand_path('../../../lib', __dir__)

    Open3.capture3(RbConfig.ruby, '-w', '-I', lib, '-e', script)
  end

  it 'loads `regexp_parser` when one of its constants is first used' do
    script = <<~RUBY
      require 'rubocop'
      print defined?(Regexp::Parser).inspect, ' ', Regexp::Parser.parse('a').class
    RUBY
    output, _error, _status = run_ruby(script)

    expect(output).to eq('nil Regexp::Expression::Root')
  end

  it 'lets `regexp_parser` be required directly' do
    script = <<~RUBY
      require 'rubocop'
      require 'regexp_parser'
      print Regexp::Expression::Literal
    RUBY
    output, error, _status = run_ruby(script)

    expect(output).to eq('Regexp::Expression::Literal')
    expect(error).not_to include('circular require')
  end
end
