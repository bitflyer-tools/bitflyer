# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'bitflyer/version'

Gem::Specification.new do |spec|
  spec.name          = 'bitflyer'
  spec.version       = Bitflyer::VERSION
  spec.authors       = ['Yuji Ueki']
  spec.email         = ['unhappychoice@gmail.com']
  spec.summary       = %q{Bitflyer API wrapper}
  spec.description   = %q{Bitflyer API wrapper}
  spec.homepage      = 'https://github.com/unhappychoice/bitflyer'
  spec.license       = 'MIT'
  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']
  spec.add_development_dependency 'bundler', '~> 1.12'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
end
