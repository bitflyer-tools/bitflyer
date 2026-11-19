# frozen_string_literal: true

require_relative '../lib/bitflyer/realtime/channels'

path = File.expand_path('../sig/bitflyer/realtime/client.rbs', __dir__)
signature = File.read(path)
section = /^(      # BEGIN GENERATED CHANNEL SETTERS\n).*?(^      # END GENERATED CHANNEL SETTERS$)/m
abort "Generated channel setter markers are missing from #{path}" unless section.match?(signature)

declarations = Bitflyer::Realtime::CHANNEL_NAMES.map do |channel_name|
  setter_name = Bitflyer::Realtime.channel_setter_name(channel_name)
  "      def #{setter_name}: (message_callback callback) -> message_callback"
end

generated = signature.sub(section) { "#{Regexp.last_match(1)}#{declarations.join("\n\n")}\n#{Regexp.last_match(2)}" }
if ARGV == ['--check']
  abort 'Realtime signatures are stale. Run ruby script/generate_realtime_signatures.rb.' unless signature == generated
else
  File.write(path, generated)
end
