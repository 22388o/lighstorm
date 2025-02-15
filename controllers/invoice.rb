# frozen_string_literal: true

require_relative './invoice/all'
require_relative './invoice/find_by_secret_hash'
require_relative './invoice/actions/create'

module Lighstorm
  module Controllers
    module Invoice
      def self.all(limit: nil)
        All.model(All.data(limit: limit))
      end

      def self.first
        All.model(All.data).first
      end

      def self.last
        All.model(All.data).last
      end

      def self.find_by_secret_hash(secret_hash)
        FindBySecretHash.model(FindBySecretHash.data(secret_hash))
      end

      def self.create(description: nil, milisatoshis: nil, preview: false, fake: false)
        Create.perform(
          description: description,
          milisatoshis: milisatoshis,
          preview: preview,
          fake: fake
        )
      end
    end
  end
end
