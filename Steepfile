# frozen_string_literal: true

D = Steep::Diagnostic

target :lib do
  signature 'sig'
  check 'lib'

  library 'forwardable', 'json', 'monitor', 'net-http', 'openssl', 'uri'

  configure_code_diagnostics(D::Ruby.default)
end
