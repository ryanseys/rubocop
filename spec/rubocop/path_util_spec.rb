# frozen_string_literal: true

RSpec.describe RuboCop::PathUtil do
  describe '#relative_path' do
    it 'builds paths relative to PWD by default as a stop-gap' do
      relative = File.join(Dir.pwd, 'relative')
      expect(described_class.relative_path(relative)).to eq('relative')
    end

    it 'supports custom base paths' do
      expect(described_class.relative_path('/foo/bar', '/foo')).to eq('bar')
    end

    if RuboCop::Platform.windows?
      it 'works for different drives' do
        expect(described_class.relative_path('D:/foo/bar', 'C:/foo')).to eq('D:/foo/bar')
      end

      it 'works for the same drive' do
        expect(described_class.relative_path('D:/foo/bar', 'D:/foo')).to eq('bar')
      end
    end
  end

  describe '#absolute?' do
    it 'returns a truthy value for a path beginning with slash' do
      expect(described_class).to be_absolute('/Users/foo')
    end

    it 'returns a falsey value for a path beginning with a directory name' do
      expect(described_class).not_to be_absolute('Users/foo')
    end

    if RuboCop::Platform.windows?
      it 'returns a truthy value for a path beginning with an upper case drive letter' do
        expect(described_class).to be_absolute('C:/Users/foo')
      end

      it 'returns a truthy value for a path beginning with a lower case drive letter' do
        expect(described_class).to be_absolute('d:/Users/foo')
      end
    end
  end

  describe '#match_path?', :isolated_environment do
    include FileHelper

    before do
      create_empty_file('file')
      create_empty_file('dir/file')
      create_empty_file('dir/files')
      create_empty_file('dir/dir/file')
      create_empty_file('dir/sub/file')
      create_empty_file('dir/.hidden/file')
      create_empty_file('dir/.hidden_file')
    end

    it 'does not match dir/** for file in hidden dir' do
      expect(described_class).not_to be_match_path('dir/**', 'dir/.hidden/file')
    end

    it 'matches dir/** for hidden file' do
      expect(described_class).to be_match_path('dir/**', 'dir/.hidden_file')
    end

    it 'does not match file in a subdirectory' do
      expect(described_class).not_to be_match_path('file', 'dir/files')
      expect(described_class).not_to be_match_path('dir', 'dir/file')
    end

    it 'matches strings to the full path' do
      expect(described_class).to be_match_path("#{Dir.pwd}/dir/file", "#{Dir.pwd}/dir/file")
      expect(described_class).not_to be_match_path(
        "#{Dir.pwd}/dir/file",
        "#{Dir.pwd}/dir/dir/file"
      )
    end

    it 'matches glob expressions' do
      expect(described_class).to be_match_path('dir/*', 'dir/file')
      expect(described_class).to be_match_path('dir/**/*', 'dir/sub/file')
      expect(described_class).to be_match_path('dir/**/*', 'dir/file')
      expect(described_class).to be_match_path('**/*', 'dir/sub/file')
      expect(described_class).to be_match_path('**/file', 'file')

      expect(described_class).not_to be_match_path('sub/*', 'dir/sub/file')

      expect(described_class).not_to be_match_path('**/*', 'dir/.hidden/file')
      expect(described_class).to be_match_path('**/*', 'dir/.hidden_file')
      expect(described_class).to be_match_path('**/.*/*', 'dir/.hidden/file')
      expect(described_class).to be_match_path('**/.*', 'dir/.hidden_file')

      expect(described_class).to be_match_path('c{at,ub}s', 'cats')
      expect(described_class).to be_match_path('c{at,ub}s', 'cubs')
      expect(described_class).not_to be_match_path('c{at,ub}s', 'gorillas')
      expect(described_class).to be_match_path('**/*.{rb,txt}', 'dir/foo.txt')
    end

    it 'matches regexps' do
      expect(described_class).to be_match_path(/^d.*e$/, 'dir/file')
      expect(described_class).not_to be_match_path(/^d.*e$/, 'dir/filez')
    end

    it 'does not match invalid UTF-8 paths' do
      expect(described_class).not_to be_match_path(/^d.*$/, "dir/file\xBF")
    end
  end

  describe '#literal_glob_prefix' do
    it 'returns the text before the first special character' do
      expect(described_class.literal_glob_prefix('/project/vendor/**/*')).to eq('/project/vendor/')
      expect(described_class.literal_glob_prefix('/project/{app,lib}/*.rb')).to eq('/project/')
      expect(described_class.literal_glob_prefix('**/*.rb')).to eq('')
    end

    it 'returns the whole pattern when it has no special character' do
      expect(described_class.literal_glob_prefix('/project/Gemfile')).to eq('/project/Gemfile')
    end
  end

  describe '#literal_glob_suffix' do
    it 'returns the text after the last special character' do
      expect(described_class.literal_glob_suffix('**/*.rb')).to eq('.rb')
      expect(described_class.literal_glob_suffix('**/*Fastfile')).to eq('Fastfile')
      expect(described_class.literal_glob_suffix('lib/[ab]x.rb')).to eq('x.rb')
      expect(described_class.literal_glob_suffix('**/*.{rb,rake}')).to eq('')
    end

    it 'drops a leading separator, which `**/` can match without' do
      expect(described_class.literal_glob_suffix('**/Gemfile')).to eq('Gemfile')
      expect(described_class.literal_glob_suffix('**/config/routes.rb')).to eq('config/routes.rb')
    end
  end

  describe 'literal affixes of a pattern' do
    let(:patterns) do
      %w[
        **/*.rb **/Gemfile **/.pryrc **/*Fastfile **/*.{rb,rake} **/[Rr]akefile lib/**/*.rb
        /project/vendor/**/* /project/Gemfile /project/config/*.rb /project/{app,lib}/**
        /project/a?c /project/**/spec/**/*_spec.rb /project/*
      ]
    end
    let(:paths) do
      %w[
        Gemfile lib/Gemfile .pryrc lib/.pryrc Fastfile lib/MyFastfile foo.rb lib/foo.rb lib/a/b.rb
        lib/.hidden.rb .hidden/foo.rb Rakefile rakefile x.rake /project/Gemfile /project/vendor/a.rb
        /project/vendor/.a/b.rb /project/config/x.rb /project/app/x.rb /project/abc
        /project/spec/a_spec.rb /project/a/spec/b/c_spec.rb /project/.rubocop.yml /other/Gemfile
      ]
    end

    it 'are kept by every path that `#match_path?` matches with the pattern' do
      patterns.product(paths).each do |pattern, path|
        next unless described_class.match_path?(pattern, path)

        expect(path).to start_with(described_class.literal_glob_prefix(pattern))
        expect(path).to end_with(described_class.literal_glob_suffix(pattern))
      end
    end
  end

  describe '.remote_file?' do
    subject(:smart_path) { described_class.remote_file?(path) }

    context 'when the path is an HTTP URL' do
      let(:path) { 'http://example.com' }

      it { is_expected.to be(true) }
    end

    context 'when the path is an HTTPS URL' do
      let(:path) { 'https://example.com' }

      it { is_expected.to be(true) }
    end

    context 'when the path is a relative path' do
      let(:path) { './relative/path/to' }

      it { is_expected.to be(false) }
    end

    context 'when path is an absolute path' do
      let(:path) { '/absolute/path/to' }

      it { is_expected.to be(false) }
    end
  end

  describe '#smart_path', :isolated_environment do
    subject(:smart_path) { described_class.smart_path(path) }

    context 'when given a path relative to Dir.pwd' do
      let(:path) { File.join(Dir.pwd, 'relative') }

      it { is_expected.to eq('relative') }
    end

    context 'when given a path that is not relative to Dir.pwd' do
      let(:path) { '/src/rubocop/foo' }

      it { is_expected.to eq(path) }
    end

    context 'when given a RuboCop::RemoteConfig object' do
      let(:uri) { 'https://www.example.com/rubocop.yml' }
      let(:path) { RuboCop::RemoteConfig.new(uri, Dir.pwd) }

      it { is_expected.to eq(uri) }
    end
  end
end
