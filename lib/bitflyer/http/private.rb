module Bitflyer
  module HTTP
    module Private
      class Client
        def initialize
          @connection = Connection.new
        end
      end
    end
  end
end